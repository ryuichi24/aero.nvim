import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { GitBrowser } from './git-browser';
import type { Snapshot } from './types';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it('organizes changes into sorted, collapsible folders and selects files by their full path', async () => {
  const entries = [
    { path: 'src/ui/new.tsx', index: '?', worktree: '?' },
    { path: 'src/main.ts', index: 'M', worktree: 'M' },
    { path: 'README.md', index: ' ', worktree: 'M' },
    { path: 'tests/main.ts', index: ' ', worktree: 'D' },
    { path: 'src/renamed.ts', original_path: 'old/name.ts', index: 'R', worktree: ' ' },
  ];
  const fetch = vi.fn(async (url: string) => ({
    ok: true,
    json: async () => (url.endsWith('/status') ? { entries } : { content: '+nested change' }),
  }));
  vi.stubGlobal('fetch', fetch);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={client}>
      <GitBrowser
        snapshot={{ connected: true, worktrees: [{ path: '/repo', branch: 'main' }] } as Snapshot}
      />
    </QueryClientProvider>,
  );
  const navigation = await screen.findByRole('navigation', { name: 'Changed files' });
  await within(navigation).findByText('Unstaged (4)');
  const unstaged = within(navigation).getByText('Unstaged (4)').parentElement!;
  const tree = unstaged.querySelector('ul')!;
  expect(
    [...tree.children].map((node) => node.querySelector('summary, button')?.textContent),
  ).toEqual(['src/ (2)', 'tests/ (1)', 'M README.md']);
  const src = unstaged.querySelector<HTMLDetailsElement>('details')!;
  expect(src.open).toBe(true);
  expect(within(src).getByText('ui/')).toBeTruthy();
  expect(within(src).getByText('(untracked)', { exact: false })).toBeTruthy();
  fireEvent.click(within(src).getByRole('button', { name: '? new.tsx (untracked)' }));
  await screen.findByText('+nested change');
  expect(fetch).toHaveBeenCalledWith(
    '/api/git/diff',
    expect.objectContaining({
      body: JSON.stringify({ worktree: '/repo', path: 'src/ui/new.tsx', staged: false }),
    }),
  );
  expect(
    within(src).getByRole('button', { name: '? new.tsx (untracked)' }).getAttribute('aria-current'),
  ).toBe('true');
  expect(within(navigation).getByRole('button', { name: 'R renamed.ts ← old/name.ts' }).title).toBe(
    'old/name.ts → src/renamed.ts',
  );
  fireEvent.click(src.querySelector('summary')!);
  expect(src.open).toBe(false);
  await act(async () => {
    client.setQueryData(['git', '/repo', 'status'], { entries: [...entries] });
  });
  expect(src.open).toBe(false);
  client.clear();
});

it('groups sibling worktrees by workspace, shows summaries, and clears diffs when switching', async () => {
  const fetch = vi.fn(async (url: string, options: RequestInit) => {
    const body = JSON.parse(options.body as string);
    return {
      ok: true,
      json: async () =>
        url.endsWith('/status')
          ? {
              entries:
                body.worktree === '/beta' ? [] : [{ path: 'code.ts', index: 'M', worktree: ' ' }],
            }
          : { content: `+change in ${body.worktree}` },
    };
  });
  vi.stubGlobal('fetch', fetch);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const snapshot = {
    connected: true,
    cursor: '1',
    inbox: [],
    sessions: [],
    workspaces: [
      { root: '/alpha', name: 'Alpha' },
      { root: '/beta', name: 'Beta' },
    ],
    worktrees: [
      { path: '/alpha', workspace: '/alpha', branch: 'main' },
      { path: '/sibling-feature', workspace: '/alpha', branch: 'feature' },
      { path: '/beta', workspace: '/beta', branch: 'beta-main' },
    ],
  } as Snapshot;
  render(
    <QueryClientProvider client={client}>
      <GitBrowser snapshot={snapshot} selectedWorktree="/sibling-feature" />
    </QueryClientProvider>,
  );
  expect((screen.getByRole('combobox', { name: 'Workspace' }) as HTMLSelectElement).value).toBe(
    '/alpha',
  );
  await screen.findByRole('button', { name: /feature.*1 staged/ });
  fireEvent.click(await screen.findByRole('button', { name: 'M code.ts' }));
  await screen.findByText('+change in /sibling-feature');
  fireEvent.click(screen.getByRole('button', { name: /main.*\/alpha/ }));
  await waitFor(() => expect(screen.queryByLabelText('File diff')).toBeNull());
  expect(screen.getByText('Alpha / alpha (main)')).toBeTruthy();
  fireEvent.change(screen.getByRole('combobox', { name: 'Workspace' }), {
    target: { value: '/beta' },
  });
  await screen.findByRole('button', { name: /beta-main.*Working tree clean/ });
  expect(screen.queryByRole('button', { name: /feature.*sibling/ })).toBeNull();
  expect(screen.getByText('Beta / beta (beta-main)')).toBeTruthy();
  expect(fetch.mock.calls.filter(([url]) => url.endsWith('/diff'))).toHaveLength(1);
  client.clear();
});

it('shows both sides of partially staged files and requests the selected diff', async () => {
  const fetch = vi.fn(async (url: string, options: RequestInit) => {
    const body = JSON.parse(options.body as string);
    return {
      ok: true,
      json: async () =>
        url.endsWith('/status')
          ? {
              entries: [
                { path: 'code.ts', index: 'M', worktree: 'M' },
                { path: 'new.ts', index: '?', worktree: '?' },
              ],
            }
          : { content: body.staged ? '-old\n+staged\n' : '-staged\n+unstaged\n' },
    };
  });
  vi.stubGlobal('fetch', fetch);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={client}>
      <GitBrowser
        snapshot={{ connected: true, worktrees: [{ path: '/repo', branch: 'main' }] } as Snapshot}
      />
    </QueryClientProvider>,
  );
  const files = await screen.findAllByRole('button', { name: 'M code.ts' });
  expect(files).toHaveLength(2);
  expect(screen.getByText('Staged (1)')).toBeTruthy();
  expect(screen.getByText('Unstaged (2)')).toBeTruthy();
  fireEvent.click(files[0]);
  await screen.findByText('+staged');
  fireEvent.click(files[1]);
  await screen.findByText('+unstaged');
  expect(
    fetch.mock.calls.some(
      ([url, options]) =>
        url.endsWith('/diff') && JSON.parse(options.body as string).staged === false,
    ),
  ).toBe(true);
  client.clear();
});
