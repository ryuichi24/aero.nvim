import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { ArticleBrowser } from './article-browser';
import type { Session } from './types';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const session: Session = {
  id: 'chat',
  name: 'Writer',
  agent: 'fixture',
  worktree: '/workspace',
  status: 'idle',
  conversation: 'generation',
};

function browser(online = true, active = true) {
  render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <ArticleBrowser session={session} epoch="host" online={online} active={active} />
    </QueryClientProvider>,
  );
}

it('opens the active article, switches translations, and shows complete source', async () => {
  const content = '---\ntitle: Example\n---\n# Saved article\n\nReview this text.';
  const fetch = vi.fn().mockImplementation((_url, options) => {
    const body = JSON.parse(options.body);
    return Promise.resolve(
      new Response(
        JSON.stringify(
          body.path
            ? {
                name: body.path,
                content: body.path.endsWith('.mdx')
                  ? '# Japanese translation\n\n<Custom />'
                  : content,
              }
            : { entries: [{ name: 'post.en.md' }, { name: 'post.ja.mdx' }], active: 'post.en.md' },
        ),
      ),
    );
  });
  vi.stubGlobal('fetch', fetch);
  browser();
  expect(await screen.findByRole('heading', { name: 'Saved article' })).toBeTruthy();
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
    epoch: 'host',
    session: 'chat',
    conversation: 'generation',
  });
  await userEvent.click(screen.getByRole('button', { name: 'Show source' }));
  expect(screen.getByText(/title: Example/, { selector: 'code' }).textContent).toBe(content);
  await userEvent.click(screen.getByRole('button', { name: 'post.ja.mdx' }));
  expect(await screen.findByText(/# Japanese translation/)).toBeTruthy();
  await userEvent.click(screen.getByRole('button', { name: 'Show preview' }));
  expect(await screen.findByRole('heading', { name: 'Japanese translation' })).toBeTruthy();
  expect(screen.getByText(/custom components are available in source view/)).toBeTruthy();
});

it('refreshes the saved content', async () => {
  let content = '# First draft';
  vi.stubGlobal(
    'fetch',
    vi
      .fn()
      .mockImplementation((_url, options) =>
        Promise.resolve(
          new Response(
            JSON.stringify(
              JSON.parse(options.body).path ? { content } : { entries: [{ name: 'draft.md' }] },
            ),
          ),
        ),
      ),
  );
  browser();
  expect(await screen.findByRole('heading', { name: 'First draft' })).toBeTruthy();
  content = '# Revised draft';
  await userEvent.click(screen.getByRole('button', { name: 'Refresh articles' }));
  expect(await screen.findByRole('heading', { name: 'Revised draft' })).toBeTruthy();
});

it('explains an empty library', async () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ entries: [] }))));
  browser();
  expect(await screen.findByText(/No saved articles yet/)).toBeTruthy();
});

it('shows errors and allows retrying with refresh', async () => {
  const fetch = vi
    .fn()
    .mockResolvedValue(
      new Response(JSON.stringify({ error: 'article unavailable' }), { status: 400 }),
    );
  vi.stubGlobal('fetch', fetch);
  browser();
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'article unavailable');
  fetch.mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ entries: [] }))));
  await userEvent.click(screen.getByRole('button', { name: 'Refresh articles' }));
  expect(await screen.findByText(/No saved articles yet/)).toBeTruthy();
});

it.each([
  [false, true],
  [true, false],
])('does not fetch when online=%s and active=%s', (online, active) => {
  const fetch = vi.fn();
  vi.stubGlobal('fetch', fetch);
  browser(online, active);
  expect(fetch).not.toHaveBeenCalled();
});
