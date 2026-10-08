import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { SourceBrowser } from './source-browser';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it('folds source lines, retains nested folds in fullscreen, and expands all', async () => {
  class FoldWorker {
    onmessage?: (event: { data: unknown }) => void;
    postMessage() {
      queueMicrotask(() =>
        this.onmessage?.({
          data: {
            ranges: [
              { start: 0, end: 4 },
              { start: 1, end: 3 },
            ],
          },
        }),
      );
    }
    terminate() {}
  }
  vi.stubGlobal('Worker', FoldWorker);
  vi.stubGlobal(
    'fetch',
    vi.fn(async (_url: unknown, options: RequestInit) => ({
      ok: true,
      json: async () =>
        JSON.parse(options.body as string).path
          ? { content: 'function example() {\n  if (true) {\n    return 42;\n  }\n}\nexample();' }
          : { entries: [{ name: 'main.ts', directory: false }] },
    })),
  );
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={client}>
      <SourceBrowser
        snapshot={{
          connected: true,
          cursor: '1',
          sessions: [],
          inbox: [],
          workspaces: [],
          worktrees: [{ path: '/repo' }],
        }}
      />
    </QueryClientProvider>,
  );
  const user = userEvent.setup();
  await user.click(await screen.findByRole('button', { name: 'main.ts' }));
  await user.click(await screen.findByRole('button', { name: 'Collapse lines 2–4' }));
  expect(screen.getByLabelText('main.ts').textContent).not.toContain('return 42');
  await user.click(screen.getByRole('button', { name: 'Collapse all' }));
  const dialog = document.querySelector('dialog')!;
  dialog.showModal = vi.fn(() => dialog.setAttribute('open', ''));
  dialog.close = vi.fn(() => dialog.removeAttribute('open'));
  await user.click(screen.getByRole('button', { name: 'Fullscreen' }));
  await user.click(within(dialog).getByRole('button', { name: 'Expand lines 1–5' }));
  expect(within(dialog).getByRole('button', { name: 'Expand lines 2–4' })).toBeTruthy();
  await user.click(within(dialog).getByRole('button', { name: 'Expand all' }));
  expect(within(dialog).getByLabelText('main.ts').textContent).toContain('return 42');
  await user.click(within(dialog).getByRole('button', { name: 'Exit fullscreen' }));
  client.clear();
});

it('lists reports and opens rendered Markdown with a source toggle', async () => {
  const fetch = vi.fn(async (_url: unknown, options: RequestInit) => {
    const { path } = JSON.parse(options.body as string);
    return {
      ok: true,
      json: async () =>
        path === ''
          ? { entries: [{ name: 'findings.md', directory: false }] }
          : { content: '# Findings\n\n**Verified** result.' },
    };
  });
  vi.stubGlobal('fetch', fetch);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={client}>
      <SourceBrowser
        mode="reports"
        snapshot={{
          connected: true,
          cursor: '1',
          sessions: [],
          inbox: [],
          workspaces: [],
          worktrees: [{ path: '/repo' }],
        }}
      />
    </QueryClientProvider>,
  );
  const user = userEvent.setup();
  await user.click(await screen.findByRole('button', { name: 'findings.md' }));
  expect(await screen.findByRole('heading', { name: 'Findings' })).toBeTruthy();
  expect(screen.getByLabelText('findings.md preview').textContent).toContain('Verified result.');
  expect(fetch.mock.calls.every(([url]) => url === '/api/reports')).toBe(true);
  await user.click(screen.getByRole('button', { name: 'Show source' }));
  expect(screen.getByLabelText('findings.md').textContent).toContain('# Findings');
  await user.click(screen.getByRole('button', { name: 'Show preview' }));
  expect(screen.getByRole('heading', { name: 'Findings' })).toBeTruthy();
  client.clear();
});

it('filters report worktrees by branch or full path and resets the reader when switching', async () => {
  const fetch = vi.fn(async (_url: unknown, options: RequestInit) => {
    const { path, worktree } = JSON.parse(options.body as string);
    return {
      ok: true,
      json: async () =>
        path === ''
          ? { entries: [{ name: 'findings.md', directory: false }] }
          : { content: `# Findings for ${worktree}` },
    };
  });
  vi.stubGlobal('fetch', fetch);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={client}>
      <SourceBrowser
        mode="reports"
        snapshot={{
          connected: true,
          cursor: '1',
          sessions: [],
          inbox: [],
          workspaces: [],
          worktrees: [
            { path: '/very/long/project/main', branch: 'main' },
            { path: '/another/project/review', branch: 'feature/review' },
          ],
        }}
      />
    </QueryClientProvider>,
  );
  const user = userEvent.setup();
  expect(screen.queryByRole('combobox')).toBeNull();
  await user.click(await screen.findByRole('button', { name: 'findings.md' }));
  await screen.findByRole('heading', { name: 'Findings for /very/long/project/main' });
  await user.type(screen.getByRole('searchbox', { name: 'Find a worktree' }), 'missing');
  expect(screen.getByRole('status').textContent).toBe('No matching worktrees.');
  await user.clear(screen.getByRole('searchbox'));
  await user.type(screen.getByRole('searchbox'), '/another');
  const options = within(screen.getByRole('group', { name: 'Report worktrees' }));
  expect(options.queryByRole('button', { name: /main/ })).toBeNull();
  await user.click(options.getByRole('button', { name: /feature\/review/ }));
  expect(
    screen.queryByRole('heading', { name: 'Findings for /very/long/project/main' }),
  ).toBeNull();
  expect(screen.getByText('Select a report to preview its Markdown.')).toBeTruthy();
  await user.click(await screen.findByRole('button', { name: 'findings.md' }));
  await screen.findByRole('heading', { name: 'Findings for /another/project/review' });
  expect(
    fetch.mock.calls.some(
      ([, options]) => JSON.parse(options.body as string).worktree === '/another/project/review',
    ),
  ).toBe(true);
  client.clear();
});

it('expands nested folders and keeps the tree while reading a file', async () => {
  const fetch = vi.fn(async (_url: unknown, options: RequestInit) => {
    const { path } = JSON.parse(options.body as string);
    const data =
      path === ''
        ? { entries: [{ name: 'src', directory: true }] }
        : path === 'src'
          ? { entries: [{ name: 'nested', directory: true }] }
          : path === 'src/nested'
            ? { entries: [{ name: 'main.ts', directory: false }] }
            : { content: 'const answer = 42;' };
    return { ok: true, json: async () => data };
  });
  vi.stubGlobal('fetch', fetch);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={client}>
      <SourceBrowser
        snapshot={{
          connected: true,
          cursor: '1',
          sessions: [],
          inbox: [],
          workspaces: [],
          worktrees: [{ path: '/repo' }],
        }}
      />
    </QueryClientProvider>,
  );
  const user = userEvent.setup();
  const tree = within(screen.getByRole('navigation', { name: 'File tree' }));
  const src = await tree.findByRole('button', { name: 'src/' });
  expect(
    fetch.mock.calls.some(([, options]) => JSON.parse(options.body as string).path === 'src'),
  ).toBe(false);
  await user.click(src);
  await user.click(await tree.findByRole('button', { name: 'nested/' }));
  await user.click(await tree.findByRole('button', { name: 'main.ts' }));
  await screen.findByLabelText('src/nested/main.ts');
  expect(tree.getByRole('button', { name: 'main.ts' }).getAttribute('aria-current')).toBe('true');
  await user.click(src);
  expect(tree.queryByRole('button', { name: 'main.ts' })).toBeNull();
  expect(screen.getByLabelText('src/nested/main.ts').textContent).toContain('const answer = 42;');
  const dialog = document.querySelector('dialog')!;
  // jsdom does not implement the native dialog lifecycle.
  dialog.showModal = vi.fn(() => dialog.setAttribute('open', ''));
  dialog.close = vi.fn(() => dialog.removeAttribute('open'));
  await user.click(screen.getByRole('button', { name: 'Fullscreen' }));
  expect(screen.getByRole('dialog', { name: 'Fullscreen source reader' })).toBe(dialog);
  expect(within(dialog).getByLabelText('src/nested/main.ts').textContent).toContain(
    'const answer = 42;',
  );
  expect(document.body.style.overflow).toBe('hidden');
  await user.click(within(dialog).getByRole('button', { name: 'Exit fullscreen' }));
  expect(dialog.open).toBe(false);
  expect(document.body.style.overflow).toBe('');
  expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Fullscreen' }));
  await user.click(screen.getByRole('button', { name: 'Fullscreen' }));
  fireEvent(dialog, new Event('cancel', { cancelable: true }));
  expect(dialog.open).toBe(false);
  expect(screen.getByLabelText('src/nested/main.ts').textContent).toContain('const answer = 42;');
  client.clear();
});
