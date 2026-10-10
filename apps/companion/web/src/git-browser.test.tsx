import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { GitBrowser } from './git-browser';
import type { Snapshot } from './types';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
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
