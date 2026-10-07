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
  it('shows each populated media gallery once below the session actions and hides empty galleries', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(new Response(new Uint8Array([0]), { status: 206 })),
    );
    render(<App />);
    connect(initial);
    await open();
    expect(screen.queryByText('Screenshots (0)')).toBeNull();
    expect(screen.queryByText('Recordings (0)')).toBeNull();
    connect({
      ...initial,
      sessions: [
        {
          ...initial.sessions[0],
          blocks: [{ kind: 'agent', text: '[Screenshot](mobile.png)\n\n[Recording](demo.webm)' }],
        },
      ],
    });
    const screenshots = screen.getAllByText('Screenshots (1)');
    const recordings = screen.getAllByText('Recordings (1)');
    expect(screenshots).toHaveLength(1);
    expect(recordings).toHaveLength(1);
    const rename = screen.getByText('Rename session', { selector: 'summary' });
    expect(
      rename.compareDocumentPosition(screenshots[0]) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
    expect(
      rename.compareDocumentPosition(recordings[0]) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
    await waitFor(() => expect(screen.getByText('Saved for later')).toBeTruthy());
    connect(initial);
    expect(document.querySelectorAll('.session-screenshots')).toHaveLength(0);
    expect(document.querySelectorAll('#transcript')).toHaveLength(1);
  });
  it('keeps a session screenshot list available above the transcript', async () => {
    render(<App />);
    connect({
      ...initial,
      sessions: [
        {
          ...initial.sessions[0],
          blocks: [{ kind: 'tool', text: '[Mobile capture](mobile.png)' }],
        },
      ],
    });
    await open();
    const summary = screen.getByText('Screenshots (1)');
    await userEvent.click(summary);
    const gallery = screen.getByRole('list', { name: 'Session screenshots' });
    await userEvent.click(gallery.querySelector('a')!);
    expect(screen.getByRole('dialog', { name: 'Screenshot preview' })).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Close' }));
    await userEvent.click(screen.getByRole('button', { name: '← All sessions' }));
    await open();
    expect(screen.getByRole('list', { name: 'Session screenshots' })).toBeTruthy();
  });
  it('answers permissions from the inbox without selecting a session', async () => {
    const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    const snapshot: Snapshot = {
      ...initial,
      sessions: [
        {
          ...initial.sessions[0],
          status: 'waiting',
          permission: {
            id: 'inbox-permission',
            title: 'Allow command?',
            options: [
              { optionId: 'allow', name: 'Allow once' },
              { optionId: 'reject', name: 'Reject' },
            ],
          },
        },
      ],
      inbox: [
        {
          id: 'event-1',
          session: 'stable-session',
          conversation: 'generation-1',
          kind: 'permission',
          text: 'Command needs approval',
        },
      ],
    };
    connect(snapshot);
    await userEvent.click(screen.getByRole('button', { name: /Inbox/ }));
    connect({ ...snapshot, connected: false });
    expect((screen.getByRole('button', { name: 'Allow once' }) as HTMLButtonElement).disabled).toBe(
      true,
    );
    connect(snapshot);
    await userEvent.click(screen.getByRole('button', { name: 'Allow once' }));
    await screen.findByText('Action accepted');
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch.mock.calls[0][0]).toBe('/api/permission');
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      session: 'stable-session',
      conversation: 'generation-1',
      permission: 'inbox-permission',
      option: 'allow',
    });
    expect(screen.getByRole('heading', { name: 'Attention inbox' })).toBeTruthy();
    connect({ ...snapshot, sessions: [{ ...snapshot.sessions[0], conversation: 'generation-2' }] });
    expect(screen.queryByRole('button', { name: 'Allow once' })).toBeNull();
  });

  it.each(['before', 'after'])(
    'waits for initialization when the starting snapshot arrives %s the creation receipt',
    async (timing) => {
      let resolveCreation!: (value: Response) => void;
      const fetch = vi
        .fn()
        .mockImplementationOnce(
          () =>
            new Promise<Response>((resolve) => {
              resolveCreation = resolve;
            }),
        )
        .mockResolvedValue(response({ result: { status: 'accepted' } }));
      vi.stubGlobal('fetch', fetch);
      render(<App />);
      const snapshot: Snapshot = {
        ...initial,
        epoch: 'host-epoch',
        agents: ['fixture'],
        sessions: [],
        workspaces: [{ root: '/workspace', name: 'Project' }],
        worktrees: [{ path: '/workspace', workspace: '/workspace', branch: 'main' }],
      };
      connect(snapshot);
      await userEvent.click(screen.getByText('New AI session', { selector: 'summary' }));
      await userEvent.click(screen.getByRole('button', { name: 'New AI session' }));
      const starting: Snapshot = {
        ...snapshot,
        cursor: 'epoch:2',
        sessions: [
          { ...initial.sessions[0], status: 'starting', conversation: 'initializing-generation' },
        ],
      };
      if (timing === 'before') connect(starting);
      resolveCreation(response({ result: { status: 'accepted', session: 'stable-session' } }));
      await screen.findByText('Action accepted');
      if (timing === 'after') connect(starting);
      expect(screen.queryByText('Session or conversation unavailable')).toBeNull();
      expect(screen.getByRole('heading', { name: 'Agent sessions' })).toBeTruthy();
      connect({
        ...starting,
        cursor: 'epoch:3',
        sessions: [{ ...initial.sessions[0], conversation: 'ready-generation' }],
      });
      expect(screen.getByRole('heading', { name: 'Test agent · idle' })).toBeTruthy();
      expect(screen.queryByText('Session or conversation unavailable')).toBeNull();
      draft('First prompt');
      await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
      await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
      expect(JSON.parse(fetch.mock.calls[1][1].body).conversation).toBe('ready-generation');
    },
  );
  it.each([
    { status: 'accepted', httpStatus: 200, clear: true },
    { status: 'unknown', httpStatus: 200, clear: false },
    { status: 'rejected', httpStatus: 409, clear: false },
  ])(
    'resets the new-session form only after success ($status)',
    async ({ status, httpStatus, clear }) => {
      const fetch = vi
        .fn()
        .mockResolvedValue(
          response(
            status === 'rejected' ? { error: 'Name already exists' } : { result: { status } },
            httpStatus,
          ),
        );
      vi.stubGlobal('fetch', fetch);
      render(<App />);
      connect({
        ...initial,
        epoch: 'host-epoch',
        agents: ['fixture'],
        sessions: [],
        workspaces: [{ root: '/workspace', name: 'Project' }],
        worktrees: [{ path: '/workspace', workspace: '/workspace', branch: 'main' }],
      });
      const summary = screen.getByText('New AI session', { selector: 'summary' });
      await userEvent.click(summary);
      const input = screen.getByRole('textbox', {
        name: 'Session name (optional)',
      }) as HTMLInputElement;
      await userEvent.type(input, 'Phone');
      await userEvent.click(screen.getByRole('button', { name: 'New AI session' }));
      await waitFor(() => {
        expect(input.value).toBe(clear ? '' : 'Phone');
        expect((summary.parentElement as HTMLDetailsElement).open).toBe(!clear);
        expect(
          screen.getByText(
            clear
              ? 'Action accepted'
              : status === 'unknown'
                ? 'Outcome unknown. Retry the identical action or check the host.'
                : 'Action rejected: Name already exists',
          ),
        ).toBeTruthy();
      });
      if (clear) {
        await userEvent.click(summary);
        expect(
          (screen.getByRole('textbox', { name: 'Session name (optional)' }) as HTMLInputElement)
            .value,
        ).toBe('');
      }
    },
  );
  it('resumes a stopped session explicitly and follows its new conversation', async () => {
    const fetch = vi
      .fn()
      .mockResolvedValue(response({ result: { status: 'accepted', session: 'stable-session' } }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect({
      ...initial,
      epoch: 'host-epoch',
      sessions: [
        {
          ...initial.sessions[0],
          conversation: undefined,
          status: 'stopped',
          target: 'session-target',
        },
      ],
    });
    await open();
    expect(fetch).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole('button', { name: 'Resume session' }));
    await screen.findByText('Action accepted');
    expect(fetch.mock.calls[0][0]).toBe('/api/session_resume');
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      epoch: 'host-epoch',
      session: 'stable-session',
      target: 'session-target',
    });
    connect({
      ...initial,
      epoch: 'host-epoch',
      sessions: [{ ...initial.sessions[0], conversation: 'resumed-generation' }],
    });
    expect(screen.getByText('Existing transcript')).toBeTruthy();
    expect(
      (screen.getByRole('button', { name: 'Send prompt' }) as HTMLButtonElement).disabled,
    ).toBe(false);
  });
  it('creates sessions in an empty worktree and retains unknown lifecycle actions across remounts', async () => {
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('Disconnected'))
      .mockResolvedValueOnce(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    const first = render(<App />);
    const snapshot: Snapshot = {
      ...initial,
      epoch: 'host-epoch',
      agents: ['fixture'],
      sessions: [],
      workspaces: [{ root: '/workspace', name: 'Project' }],
      worktrees: [{ path: '/workspace', workspace: '/workspace', branch: 'main' }],
    };
    connect(snapshot);
    await userEvent.click(screen.getByText('New AI session', { selector: 'summary' }));
    await userEvent.type(screen.getByRole('textbox', { name: 'Session name (optional)' }), 'Phone');
    await userEvent.click(screen.getByRole('button', { name: 'New AI session' }));
    await screen.findByText(/Outcome unknown/);
    const body = fetch.mock.calls[0][1].body;
    expect(JSON.parse(body)).toMatchObject({
      epoch: 'host-epoch',
      workspace: '/workspace',
      worktree: '/workspace',
      agent: 'fixture',
      name: 'Phone',
    });
    first.unmount();
    render(<App />);
    connect(snapshot);
    await userEvent.click(screen.getByRole('button', { name: 'Retry identical action' }));
    await screen.findByText('Action accepted');
    expect(fetch.mock.calls[1][1].body).toBe(body);
    expect(sessionStorage.getItem('aero_pending')).toBeNull();
  });
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
