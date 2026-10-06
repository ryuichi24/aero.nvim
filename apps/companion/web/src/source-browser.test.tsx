import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { SourceBrowser } from './source-browser';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
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
  client.clear();
});
