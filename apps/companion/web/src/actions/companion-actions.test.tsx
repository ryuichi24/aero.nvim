import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { expect, it, vi } from 'vitest';
import { App } from '../app';
import { initial, response, connect, open, draft } from '../test/companion-harness';

it('persists a lost receipt and retries once with identical arguments', async () => {
  const fetch = vi
    .fn()
    .mockRejectedValueOnce(new TypeError('Connection lost'))
    .mockResolvedValueOnce(response({ result: { status: 'accepted' } }));
  vi.stubGlobal('fetch', fetch);
  const first = render(<App />);
  connect();
  await open();
  draft('Phone followup');
  await userEvent.dblClick(screen.getByRole('button', { name: 'Send prompt' }));
  await screen.findByText(/Outcome unknown/);
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(JSON.parse(sessionStorage.getItem('aero_pending')!).data.text).toBe('Phone followup');
  first.unmount();
  render(<App />);
  connect();
  await userEvent.click(screen.getByRole('button', { name: 'Retry identical action' }));
  await screen.findByText('Action accepted');
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(fetch.mock.calls[1][1].body).toBe(fetch.mock.calls[0][1].body);
  expect(sessionStorage.getItem('aero_pending')).toBeNull();
});

it('targets live permission choices and disables actions during disconnection', async () => {
  const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
  vi.stubGlobal('fetch', fetch);
  render(<App />);
  connect({
    ...initial,
    sessions: [
      {
        ...initial.sessions[0],
        status: 'waiting',
        permission: {
          id: 'live-permission',
          title: 'Read file?',
          options: [
            { optionId: 'allow', name: 'Allow once' },
            { optionId: 'deny', name: 'Reject once' },
          ],
        },
      },
    ],
  });
  await open();
  await userEvent.click(screen.getByRole('button', { name: 'Reject once' }));
  await screen.findByText('Action accepted');
  expect(fetch.mock.calls[0][0]).toBe('/api/permission');
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
    session: 'stable-session',
    conversation: 'generation-1',
    permission: 'live-permission',
    option: 'deny',
  });
  connect({ ...initial, connected: false });
  expect(screen.getByText('Neovim unavailable')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Send prompt' }) as HTMLButtonElement).disabled).toBe(
    true,
  );
});

it('reports queued and rejected outcomes and retains uncertain actions through reconnects', async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(response({ result: { status: 'queued' } }))
    .mockResolvedValueOnce(response({ error: 'stale conversation' }, 409))
    .mockResolvedValueOnce(response({ error: 'pairing required' }, 401))
    .mockResolvedValueOnce(response({ result: { status: 'accepted' } }));
  vi.stubGlobal('fetch', fetch);
  render(<App />);
  connect();
  await open();
  draft('Queued prompt');
  await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
  await screen.findByText('Action queued');
  expect(sessionStorage.getItem('aero_pending')).toBeNull();
  await userEvent.click(screen.getByRole('button', { name: 'Cancel turn & queue' }));
  await screen.findByText('Action rejected: stale conversation');
  await userEvent.click(screen.getByRole('button', { name: 'Cancel turn & queue' }));
  await screen.findByText(/Outcome unknown/);
  expect(sessionStorage.getItem('aero_pending')).not.toBeNull();
  connect({ ...initial, cursor: 'restart:1' });
  await userEvent.click(screen.getByRole('button', { name: 'Retry identical action' }));
  await waitFor(() => expect(sessionStorage.getItem('aero_pending')).toBeNull());
  expect(fetch.mock.calls[3][1].body).toBe(fetch.mock.calls[2][1].body);
});

it('manages references without a selected session and recovers an identical mutation after reload', async () => {
  const updates: string[] = [];
  const fetch = vi.fn(async (url: string, options: RequestInit) => {
    if (url === '/api/reference_update') {
      updates.push(options.body as string);
      if (updates.length === 1) throw new TypeError('Connection lost');
      return response({ result: { status: 'accepted' } });
    }
    return response({ entries: [{ name: 'note.md', directory: false }] });
  });
  vi.stubGlobal('fetch', fetch);
  const snapshot = {
    ...initial,
    epoch: 'host',
    sessions: [],
    workspaces: [{ root: '/repo', name: 'Repo' }],
    worktrees: [
      {
        path: '/repo',
        workspace: '/repo',
        target: 'tree',
        reference_directory: '/data/references',
      },
    ],
  };
  const first = render(<App />);
  connect(snapshot);
  await userEvent.click(screen.getByRole('button', { name: 'References' }));
  await userEvent.click(screen.getByText('Repo', { selector: 'summary' }));
  await userEvent.click(screen.getByRole('button', { name: /Main worktree/ }));
  await userEvent.click(await screen.findByRole('button', { name: '· note.md' }));
  const input = screen.getByRole('textbox', { name: 'Reference item name' });
  await userEvent.clear(input);
  await userEvent.type(input, 'renamed.md');
  await userEvent.click(screen.getByRole('button', { name: 'Rename reference item' }));
  await screen.findByText(/Outcome unknown/);
  expect(JSON.parse(updates[0])).toMatchObject({
    epoch: 'host',
    target: 'tree',
    worktree: '/repo',
    reference_action: 'rename',
    name: 'renamed.md',
  });
  expect(JSON.parse(updates[0]).session).toBeUndefined();
  first.unmount();
  render(<App />);
  connect(snapshot);
  await userEvent.click(screen.getByRole('button', { name: 'Retry identical action' }));
  await screen.findByText('Action accepted');
  expect(updates[1]).toBe(updates[0]);
  expect(sessionStorage.getItem('aero_pending')).toBeNull();
});
