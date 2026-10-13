import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { FileContext, fileReference } from './file-preview';
import { Markdown } from './markdown';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it.each([
  'lua/aero/config.lua:13',
  '`lua/aero/config.lua:13`',
  '[config](lua/aero/config.lua#L13)',
  '[config](file:///workspace/lua/aero/config.lua#L13)',
])('previews %s on click with the referenced line and full-file toggle', async (text) => {
  const fetch = vi.fn().mockResolvedValue({
    ok: true,
    json: async () => ({
      content: Array.from({ length: 30 }, (_, i) => `code ${i + 1}`).join('\n'),
    }),
  });
  vi.stubGlobal('fetch', fetch);
  const { container } = render(
    <QueryClientProvider client={new QueryClient()}>
      <FileContext.Provider value={{ worktree: '/workspace', online: true }}>
        <Markdown text={text} />
      </FileContext.Provider>
    </QueryClientProvider>,
  );
  expect(fetch).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('link'));
  await waitFor(() =>
    expect(container.querySelector('.referenced')?.textContent).toContain('code 13'),
  );
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
    worktree: '/workspace',
    path: 'lua/aero/config.lua',
  });
  expect(container.querySelector('pre')?.textContent).not.toContain('code 1\n');
  fireEvent.click(screen.getByRole('button', { name: 'Show full file' }));
  expect(container.querySelector('pre')?.textContent).toContain('code 1\n');
  fireEvent.click(screen.getByRole('button', { name: 'Close preview' }));
  expect(screen.queryByRole('region')).toBeNull();
});

it('leaves fenced code and external links intact and does not linkify outside logs', () => {
  const { rerender } = render(
    <FileContext.Provider value={{ worktree: '/workspace', online: true }}>
      <Markdown
        text={'```text\nlua/aero/config.lua:13\n```\n\n[Docs](https://example.com/config.lua)'}
      />
    </FileContext.Provider>,
  );
  expect(screen.getAllByRole('link')).toHaveLength(1);
  expect(screen.getByRole('link').getAttribute('target')).toBe('_blank');
  rerender(<Markdown text="lua/aero/config.lua:13" />);
  expect(screen.queryByRole('link')).toBeNull();
});

it('normalizes local paths and rejects remote URLs and paths outside the worktree', () => {
  expect(fileReference('config.lua:13', '/workspace')).toEqual({
    path: 'config.lua',
    line: 13,
    end: 13,
  });
  expect(fileReference('/workspace/src/main.ts:10:2', '/workspace')).toEqual({
    path: 'src/main.ts',
    line: 10,
    end: 10,
  });
  expect(fileReference('src/main.ts#L10-L15', '/workspace')).toEqual({
    path: 'src/main.ts',
    line: 10,
    end: 15,
  });
  for (const value of [
    '../secret.txt',
    '/other/file.ts',
    'https://example.com/file.ts',
    'file://remote/workspace/file.ts',
    '//remote/file.ts',
  ])
    expect(fileReference(value, '/workspace')).toBeUndefined();
});

it('shows a readable error when the file is unavailable', async () => {
  vi.stubGlobal(
    'fetch',
    vi
      .fn()
      .mockResolvedValue({ ok: false, status: 404, text: async () => 'source path unavailable' }),
  );
  render(
    <QueryClientProvider client={new QueryClient()}>
      <FileContext.Provider value={{ worktree: '/workspace', online: true }}>
        <Markdown text="src/missing.ts" />
      </FileContext.Provider>
    </QueryClientProvider>,
  );
  fireEvent.click(screen.getByRole('link'));
  expect(await screen.findByRole('alert')).toBeTruthy();
});
