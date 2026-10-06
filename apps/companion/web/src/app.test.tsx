import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from './app';
import type { Snapshot } from './types';

class FakeEvents {
  static instances: FakeEvents[] = [];
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => unknown) | null = null;
  close = vi.fn();
  constructor() {
    FakeEvents.instances.push(this);
  }
  static emit(snapshot: Snapshot) {
    FakeEvents.instances
      .at(-1)
      ?.onmessage?.(new MessageEvent('message', { data: JSON.stringify(snapshot) }));
  }
}
const initial: Snapshot = {
  connected: true,
  cursor: 'epoch:1',
  workspaces: [],
  worktrees: [],
  inbox: [],
  sessions: [
    {
      id: 'stable-session',
      conversation: 'generation-1',
      name: 'Test agent',
      agent: 'fixture',
      worktree: '/workspace',
      status: 'idle',
      blocks: [{ kind: 'agent', text: 'Existing transcript' }],
      queue: [],
    },
  ],
};
function response(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
function connect(snapshot = initial) {
  act(() => FakeEvents.emit(snapshot));
}
async function open() {
  await userEvent.click(screen.getByRole('button', { name: /Test agent ·/ }));
}
function draft(text: string) {
  fireEvent.change(screen.getByRole('textbox', { name: 'Follow-up prompt' }), {
    target: { value: text },
  });
}
beforeEach(() => {
  sessionStorage.clear();
  FakeEvents.instances = [];
  vi.stubGlobal('EventSource', FakeEvents);
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('mobile companion', () => {
  it('pairs using exactly six digits while preserving leading zeros', async () => {
    const fetch = vi.fn().mockResolvedValue(response({ device: 'device-id' }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    const code = screen.getByRole('textbox', { name: 'Pairing code' }) as HTMLInputElement;
    expect(code.inputMode).toBe('numeric');
    expect(code.maxLength).toBe(6);
    await userEvent.type(code, '000042');
    await userEvent.click(screen.getByRole('button', { name: 'Pair device' }));
    expect(fetch.mock.calls[0][0]).toBe('/api/pair');
    expect(JSON.parse(fetch.mock.calls[0][1].body).code).toBe('000042');
  });
  it('submits cryptographic IDs on HTTP origins without randomUUID', async () => {
    vi.stubGlobal('crypto', {
      getRandomValues: globalThis.crypto.getRandomValues.bind(globalThis.crypto),
    });
    const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect();
    await open();
    draft('HTTP followup');
    await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
    await screen.findByText('Action accepted');
    expect(JSON.parse(fetch.mock.calls[0][1].body).operation_id).toMatch(/^[0-9a-f]{32}$/);
  });
  it('browses without side effects and replaces reconnect snapshots without duplicate events', async () => {
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    const snapshot = {
      ...initial,
      inbox: [
        {
          id: 'event-1',
          session: 'stable-session',
          conversation: 'generation-1',
          kind: 'completed',
          text: 'Turn completed',
        },
      ],
    };
    connect(snapshot);
    await open();
    expect(screen.getByText('Existing transcript')).toBeTruthy();
    connect({ ...snapshot, cursor: 'epoch:2' });
    connect({ ...snapshot, cursor: 'new-epoch:1' });
    await userEvent.click(screen.getByRole('button', { name: /^Inbox/ }));
    expect(screen.getAllByRole('button', { name: 'completed: Turn completed' })).toHaveLength(1);
    expect(fetch).not.toHaveBeenCalled();
    connect({ ...initial, sessions: [{ ...initial.sessions[0], conversation: 'replacement' }] });
    await userEvent.click(screen.getByRole('button', { name: 'Transcript' }));
    expect(screen.getByText('Session or conversation unavailable')).toBeTruthy();
    expect(
      (screen.getByRole('button', { name: 'Send prompt' }) as HTMLButtonElement).disabled,
    ).toBe(true);
  });
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
    expect(
      (screen.getByRole('button', { name: 'Send prompt' }) as HTMLButtonElement).disabled,
    ).toBe(true);
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
  it('switches sessions without mixing drafts or prompt targets', async () => {
    const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect({
      ...initial,
      sessions: [
        { ...initial.sessions[0], name: 'Alpha' },
        {
          ...initial.sessions[0],
          id: 'beta-session',
          conversation: 'beta-generation',
          name: 'Beta',
        },
      ],
    });
    await userEvent.click(screen.getByRole('button', { name: /^Alpha ·/ }));
    draft('Alpha draft');
    await userEvent.click(screen.getByRole('button', { name: '← All sessions' }));
    await userEvent.click(screen.getByRole('button', { name: /^Beta ·/ }));
    expect(
      (screen.getByRole('textbox', { name: 'Follow-up prompt' }) as HTMLTextAreaElement).value,
    ).toBe('');
    draft('Beta draft');
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await userEvent.click(screen.getByRole('button', { name: /^Alpha ·/ }));
    expect(
      (screen.getByRole('textbox', { name: 'Follow-up prompt' }) as HTMLTextAreaElement).value,
    ).toBe('Alpha draft');
    await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
    await screen.findByText('Action accepted');
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      session: 'stable-session',
      conversation: 'generation-1',
      text: 'Alpha draft',
    });
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await userEvent.click(screen.getByRole('button', { name: /^Beta ·/ }));
    expect(
      (screen.getByRole('textbox', { name: 'Follow-up prompt' }) as HTMLTextAreaElement).value,
    ).toBe('Beta draft');
  });
  it('opens inbox events with breadcrumbs and returns focus to the selected worktree', async () => {
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect({
      ...initial,
      workspaces: [
        { root: '/workspace', name: 'Aero' },
        { root: '/other', name: 'Other project' },
      ],
      worktrees: [
        { path: '/workspace', workspace: '/workspace', branch: 'mobile-ui' },
        { path: '/other', workspace: '/other', branch: 'main' },
      ],
      inbox: [
        {
          id: 'event',
          session: 'stable-session',
          conversation: 'generation-1',
          kind: 'completed',
          text: 'Turn completed',
        },
      ],
    });
    await userEvent.click(screen.getByRole('button', { name: 'Inbox (1)' }));
    await userEvent.click(screen.getByRole('button', { name: 'completed: Turn completed' }));
    expect(screen.getByRole('navigation', { name: 'Current session location' }).textContent).toBe(
      'Aero/mobile-ui/Test agent',
    );
    await userEvent.click(screen.getByRole('button', { name: '← All sessions' }));
    expect(
      screen.getByRole('button', { name: /^Test agent · idle/ }).getAttribute('aria-current'),
    ).toBe('page');
    await waitFor(() =>
      expect(document.activeElement).toBe(
        screen.getByRole('button', { name: /^Test agent · idle/ }),
      ),
    );
    expect(fetch).not.toHaveBeenCalled();
  });
});
