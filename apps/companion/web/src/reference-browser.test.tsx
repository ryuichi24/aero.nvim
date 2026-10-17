import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { CancelReferenceTransfer, ReferenceBrowser, ReferenceCommand } from './reference-browser';
import type { Snapshot } from './types';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
const snapshot: Snapshot = {
  connected: true,
  epoch: 'host',
  cursor: '1',
  sessions: [],
  inbox: [],
  workspaces: [],
  worktrees: [
    { path: '/repo', branch: 'feature', target: 'tree', reference_directory: '/data/references' },
  ],
};
function mount(component: React.ReactNode) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(<QueryClientProvider client={client}>{component}</QueryClientProvider>);
  return client;
}
function mockFiles(allowCut = true, roots: string[] = []) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string, options: RequestInit) => {
      const body = JSON.parse(options.body as string);
      let data;
      if (url === '/api/reference_browse') {
        data =
          body.path === '/home/folder'
            ? {
                path: '/home/folder',
                parent: '/home',
                entries: [
                  { name: 'nested.txt', directory: false, path: '/home/folder/nested.txt' },
                ],
              }
            : {
                path: '/home',
                parent: '/',
                entries: [
                  { name: 'folder', directory: true, path: '/home/folder' },
                  { name: 'cut.txt', directory: false, path: '/home/cut.txt' },
                ],
              };
        data = { ...data, allow_cut: allowCut, roots };
      } else if (body.path === 'refs') data = { entries: [{ name: 'note.md', directory: false }] };
      else if (body.path) data = { content: '# Reference content' };
      else
        data = {
          entries: [
            { name: 'refs', directory: true },
            { name: 'hello.jpeg', directory: false },
          ],
        };
      return { ok: true, json: async () => data };
    }),
  );
}

it('expands folders inline, previews files, renames just the stem and confirms deletion', async () => {
  mockFiles();
  const action = vi.fn(async () => true);
  vi.spyOn(window, 'confirm').mockReturnValue(false);
  mount(<ReferenceBrowser snapshot={snapshot} worktree="/repo" onAction={action} />);
  const user = userEvent.setup();
  await user.click(await screen.findByRole('button', { name: '▸ refs/' }));
  await user.click(await screen.findByRole('button', { name: '· note.md' }));
  expect(await screen.findByRole('heading', { name: 'Reference content' })).toBeTruthy();
  await user.click(screen.getByRole('button', { name: '· hello.jpeg' }));
  const input = screen.getByRole('textbox', { name: 'Reference item name' }) as HTMLInputElement;
  await user.click(input);
  expect(input.selectionStart).toBe(0);
  expect(input.selectionEnd).toBe(5);
  await user.keyboard('test');
  expect(input.value).toBe('test.jpeg');
  await user.click(screen.getByRole('button', { name: 'Rename reference item' }));
  expect(action).toHaveBeenCalledWith('reference_update', {
    target: 'tree',
    worktree: '/repo',
    reference_action: 'rename',
    path: 'hello.jpeg',
    name: 'test.jpeg',
  });
  await user.click(screen.getByRole('button', { name: '▾ refs/' }));
  await user.click(screen.getByRole('button', { name: 'Delete reference item' }));
  expect(action).toHaveBeenCalledTimes(1);
  vi.mocked(window.confirm).mockReturnValue(true);
  await user.click(screen.getByRole('button', { name: 'Delete reference item' }));
  expect(action).toHaveBeenLastCalledWith('reference_update', {
    target: 'tree',
    worktree: '/repo',
    reference_action: 'delete',
    path: 'refs',
  });
});

it('stages finder selections across folders and transfers only saved selections on finish', async () => {
  mockFiles();
  const action = vi.fn(async () => true);
  mount(<ReferenceBrowser snapshot={snapshot} worktree="/repo" onAction={action} />);
  const user = userEvent.setup();
  await user.click(screen.getByRole('button', { name: 'Add reference' }));
  const finder = within(screen.getByRole('region', { name: 'Reference finder' }));
  expect(finder.getAllByText('/repo').length).toBeGreaterThan(0);
  await user.click(await finder.findByRole('button', { name: 'Copy folder' }));
  await user.click(finder.getByRole('button', { name: 'Cut cut.txt' }));
  expect(action).not.toHaveBeenCalled();
  await user.click(finder.getByRole('button', { name: 'Save selections' }));
  const staged = within(finder.getByRole('complementary', { name: 'Staged references' }));
  expect(staged.getByText('/home/folder')).toBeTruthy();
  expect(staged.getByText('/home/cut.txt')).toBeTruthy();
  await user.click(finder.getByRole('button', { name: 'folder/' }));
  await user.click(await finder.findByRole('button', { name: 'Copy nested.txt' }));
  await user.click(finder.getByRole('button', { name: 'Parent folder' }));
  await waitFor(() =>
    expect(finder.getByRole('button', { name: 'folder/' })).toBe(document.activeElement),
  );
  await user.click(finder.getByRole('button', { name: 'Finish finder' }));
  expect(action).toHaveBeenCalledWith('reference_update', {
    target: 'tree',
    worktree: '/repo',
    reference_action: 'transfer',
    items: [
      { path: '/home/folder', action: 'copy' },
      { path: '/home/cut.txt', action: 'cut' },
    ],
  });
  await waitFor(() =>
    expect(screen.queryByRole('region', { name: 'Reference finder' })).toBeNull(),
  );
});

it('keeps staged items after a rejected transfer and drafts reference selection without submitting', async () => {
  mockFiles();
  const choose = vi.fn();
  mount(<ReferenceCommand worktree="/repo" online onChoose={choose} />);
  const user = userEvent.setup();
  await user.click(await screen.findByRole('button', { name: '▸ refs/' }));
  expect(choose).toHaveBeenCalledWith('/reference select refs');
  cleanup();
  const action = vi.fn(async () => false);
  mount(<ReferenceBrowser snapshot={snapshot} worktree="/repo" onAction={action} />);
  await user.click(screen.getByRole('button', { name: 'Add reference' }));
  await user.click(await screen.findByRole('button', { name: 'Copy folder' }));
  await user.click(screen.getByRole('button', { name: 'Save selections' }));
  await user.click(screen.getByRole('button', { name: 'Finish finder' }));
  expect(screen.getByRole('region', { name: 'Reference finder' })).toBeTruthy();
  expect(
    within(screen.getByRole('complementary', { name: 'Staged references' })).getByText(
      '/home/folder',
    ),
  ).toBeTruthy();
});

it('honors copy-only host policy in both finder buttons and shortcuts', async () => {
  mockFiles(false);
  mount(
    <ReferenceBrowser snapshot={snapshot} worktree="/repo" onAction={vi.fn(async () => true)} />,
  );
  const user = userEvent.setup();
  await user.click(screen.getByRole('button', { name: 'Add reference' }));
  const cut = (await screen.findByRole('button', { name: 'Cut folder' })) as HTMLButtonElement;
  expect(cut.disabled).toBe(true);
  await user.click(screen.getByRole('button', { name: 'folder/' }));
  const file = await screen.findByRole('button', { name: 'nested.txt' });
  file.focus();
  await user.keyboard('d');
  expect(
    (screen.getByRole('button', { name: 'Save selections' }) as HTMLButtonElement).disabled,
  ).toBe(true);
  await user.keyboard('y');
  expect(
    (screen.getByRole('button', { name: 'Save selections' }) as HTMLButtonElement).disabled,
  ).toBe(false);
});

it('lets a restricted finder switch between disjoint allowed roots', async () => {
  mockFiles(true, ['/home', '/references']);
  mount(
    <ReferenceBrowser snapshot={snapshot} worktree="/repo" onAction={vi.fn(async () => true)} />,
  );
  const user = userEvent.setup();
  await user.click(screen.getByRole('button', { name: 'Add reference' }));
  await user.selectOptions(
    await screen.findByRole('combobox', { name: 'Allowed source root' }),
    '/references',
  );
  await waitFor(() =>
    expect(
      vi
        .mocked(fetch)
        .mock.calls.some(
          ([url, options]) =>
            url === '/api/reference_browse' &&
            JSON.parse(options!.body as string).path === '/references',
        ),
    ).toBe(true),
  );
});

it('cancels a running transfer using an identical retry without replacing the original pending action', async () => {
  const fetch = vi
    .fn()
    .mockRejectedValueOnce(new TypeError('Connection lost'))
    .mockResolvedValueOnce({
      ok: true,
      json: async () => ({ result: { status: 'accepted' } }),
    });
  vi.stubGlobal('fetch', fetch);
  const pending = {
    path: 'reference_update' as const,
    data: {
      operation_id: 'original-transfer',
      epoch: 'host',
      target: 'tree',
      worktree: '/repo',
      reference_action: 'transfer' as const,
    },
  };
  mount(<CancelReferenceTransfer pending={pending} disabled={false} />);
  const user = userEvent.setup();
  await user.click(screen.getByRole('button', { name: 'Cancel reference transfer' }));
  await screen.findByText('Connection lost');
  await user.click(screen.getByRole('button', { name: 'Cancel reference transfer' }));
  await screen.findByText(/Cancellation requested/);
  expect(fetch.mock.calls[0][0]).toBe('/api/reference_cancel');
  expect(fetch.mock.calls[0][1].body).toBe(fetch.mock.calls[1][1].body);
  expect(JSON.parse(fetch.mock.calls[1][1].body)).toMatchObject({
    epoch: 'host',
    target: 'tree',
    worktree: '/repo',
    transfer_id: 'original-transfer',
  });
  expect(pending.data.operation_id).toBe('original-transfer');
});
