import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
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
  if (!screen.queryByRole('button', { name: /Test agent ·/ }))
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
  await userEvent.click(screen.getByRole('button', { name: /Test agent ·/ }));
}
function draft(text: string) {
  fireEvent.change(screen.getByRole('textbox', { name: 'Follow-up prompt' }), {
    target: { value: text },
  });
}
beforeEach(() => {
  window.history.replaceState(null, '', '/');
  sessionStorage.clear();
  const storage = new Map<string, string>();
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => storage.set(key, value),
  });
  FakeEvents.instances = [];
  vi.stubGlobal('EventSource', FakeEvents);
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('mobile companion', () => {
  it('quotes transcript text into an existing draft, reveals and focuses input without submitting', async () => {
    const fetch = vi.fn().mockResolvedValue(response({}));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect();
    await open();
    draft('Please explain');
    await userEvent.click(screen.getByRole('button', { name: 'Hide input' }));
    const text = screen.getByText('Existing transcript');
    const range = document.createRange();
    range.selectNodeContents(text);
    window.getSelection()!.removeAllRanges();
    window.getSelection()!.addRange(range);
    fireEvent(document, new Event('selectionchange'));
    fireEvent.click(screen.getByRole('button', { name: 'Quote to prompt' }));
    const input = screen.getByRole('textbox', { name: 'Follow-up prompt' }) as HTMLTextAreaElement;
    expect(input.value).toBe(
      'Please explain\n\nQuoted from agent log: Test agent:\n\n```text\nExisting transcript\n```',
    );
    expect(document.activeElement).toBe(input);
    expect(fetch).not.toHaveBeenCalled();
  });
  it('dismisses Attention and Device on outside clicks while keeping inside clicks and trigger toggles working', async () => {
    render(<App />);
    connect();
    const attention = screen.getByRole('button', { name: 'Attention' });
    await userEvent.click(attention);
    await userEvent.click(screen.getByRole('heading', { name: 'Attention inbox' }));
    expect(screen.getByRole('heading', { name: 'Attention inbox' })).toBeTruthy();
    await userEvent.click(screen.getByRole('heading', { name: 'Aero Companion' }));
    expect(screen.queryByRole('heading', { name: 'Attention inbox' })).toBeNull();
    await userEvent.click(attention);
    await userEvent.click(attention);
    expect(screen.queryByRole('heading', { name: 'Attention inbox' })).toBeNull();
    const summary = screen.getByText('Device', { selector: 'summary' });
    const menu = summary.parentElement as HTMLDetailsElement;
    await userEvent.click(summary);
    expect(menu.open).toBe(true);
    await userEvent.click(screen.getByRole('checkbox', { name: 'Light appearance' }));
    expect(menu.open).toBe(true);
    await userEvent.click(screen.getByRole('heading', { name: 'Aero Companion' }));
    expect(menu.open).toBe(false);
    await userEvent.click(summary);
    await userEvent.click(summary);
    expect(menu.open).toBe(false);
  });
  it('shares workspace scope with review and groups worktrees when browsing all workspaces', async () => {
    render(<App />);
    connect({
      ...initial,
      workspaces: [
        { root: '/alpha', name: 'Alpha' },
        { root: '/beta', name: 'Beta' },
      ],
      worktrees: [
        { path: '/alpha', workspace: '/alpha', branch: 'alpha-main' },
        { path: '/alpha-feature', workspace: '/alpha', branch: 'alpha-feature' },
        { path: '/beta', workspace: '/beta', branch: 'beta-main' },
      ],
    });
    await userEvent.selectOptions(
      screen.getByRole('combobox', { name: 'Workspace scope' }),
      '/alpha',
    );
    await userEvent.click(screen.getByRole('button', { name: 'Workspace' }));
    const context = screen.getByRole('region', { name: 'Workspace review context' });
    expect(within(context).getByRole('button', { name: /alpha-main/ })).toBeTruthy();
    expect(within(context).getByRole('button', { name: /alpha-feature/ })).toBeTruthy();
    expect(within(context).queryByRole('button', { name: /beta-main/ })).toBeNull();
    expect(within(context).queryByText('Alpha', { selector: 'summary' })).toBeNull();

    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Workspace scope' }), '');
    await userEvent.click(within(context).getByText('Beta', { selector: 'summary' }));
    expect(within(context).getByRole('button', { name: /beta-main/ })).toBeTruthy();
    await userEvent.click(within(context).getByRole('button', { name: /beta-main/ }));
    await userEvent.selectOptions(
      screen.getByRole('combobox', { name: 'Workspace scope' }),
      '/alpha',
    );
    expect(
      within(context).getByText('Choose a worktree to review its reports, changes, and source.'),
    ).toBeTruthy();
    expect(within(context).queryByText('Manage worktree')).toBeNull();
  });

  it('shows only requests with current selectable options in Inbox and attention counts', async () => {
    render(<App />);
    const snapshot: Snapshot = {
      ...initial,
      sessions: [
        {
          ...initial.sessions[0],
          status: 'waiting',
          permission: {
            id: 'pending',
            title: 'Allow command?',
            options: [{ optionId: 'allow', name: 'Allow once' }],
          },
        },
      ],
      inbox: [
        {
          id: 'done',
          session: 'stable-session',
          conversation: 'generation-1',
          kind: 'completed',
          text: 'Turn completed',
        },
        {
          id: 'pending',
          session: 'stable-session',
          conversation: 'generation-1',
          kind: 'permission',
          text: 'Select an option',
        },
        {
          id: 'stale',
          session: 'stable-session',
          conversation: 'older-generation',
          kind: 'permission',
          text: 'Old request',
        },
      ],
    };
    connect(snapshot);
    expect(screen.getByRole('button', { name: 'Attention (1)' })).toBeTruthy();
    expect(screen.getByText('1 permission requires a response')).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Inbox (1)' }));
    expect(screen.getByRole('button', { name: 'Allow once' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'completed: Turn completed' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'permission: Old request' })).toBeNull();
    connect({
      ...snapshot,
      sessions: [
        {
          ...snapshot.sessions[0],
          permission: { ...snapshot.sessions[0].permission!, options: [] },
        },
      ],
    });
    expect(screen.getByText('No attention events right now.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Attention' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Inbox' })).toBeTruthy();
  });
  it('remembers workspace scope, review worktree, and tool after closing the browser session', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response({ entries: [] })));
    const snapshot: Snapshot = {
      ...initial,
      workspaces: [
        { root: '/workspace', name: 'Project' },
        { root: '/other', name: 'Other' },
      ],
      worktrees: [
        { path: '/workspace', workspace: '/workspace', branch: 'main' },
        { path: '/other', workspace: '/other', branch: 'review' },
      ],
      sessions: [
        ...initial.sessions,
        { ...initial.sessions[0], id: 'other-session', name: 'Other agent', worktree: '/other' },
      ],
    };
    const first = render(<App />);
    connect(snapshot);
    await userEvent.selectOptions(
      screen.getByRole('combobox', { name: 'Workspace scope' }),
      '/other',
    );
    await userEvent.click(screen.getByRole('button', { name: 'Reports' }));
    await userEvent.click(screen.getByRole('button', { name: 'review /other' }));
    await userEvent.click(screen.getByRole('button', { name: 'Changes' }));
    first.unmount();
    sessionStorage.clear();
    window.history.replaceState(null, '', '/');
    render(<App />);
    connect(snapshot);
    expect(screen.getByRole<HTMLSelectElement>('combobox', { name: 'Workspace scope' }).value).toBe(
      '/other',
    );
    expect(screen.getByRole('button', { name: /^Other agent ·/ })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /^Test agent ·/ })).toBeNull();
    await userEvent.click(screen.getByRole('button', { name: 'Workspace' }));
    expect(await screen.findByRole('heading', { name: 'Git changes' })).toBeTruthy();
    expect(screen.getByText(/review · Change context/)).toBeTruthy();
  });

  it('falls back to all workspaces when a remembered workspace is no longer available', async () => {
    localStorage.setItem('aero-workspace-scope', JSON.stringify('/removed'));
    render(<App />);
    connect({ ...initial, connected: false });
    expect(localStorage.getItem('aero-workspace-scope')).toBe(JSON.stringify('/removed'));
    connect(initial);
    await waitFor(() =>
      expect(localStorage.getItem('aero-workspace-scope')).toBe(JSON.stringify('')),
    );
    expect(screen.getByRole('button', { name: /^Test agent ·/ })).toBeTruthy();
  });

  it('keeps a newer draft through reload and identical-action recovery', async () => {
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('Lost receipt'))
      .mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    const first = render(<App />);
    connect();
    await open();
    draft('Original request');
    await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
    await screen.findByRole('button', { name: 'Retry identical action' });
    const sent = fetch.mock.calls[0][1].body;
    draft('New draft written while recovering');
    first.unmount();
    render(<App />);
    connect();
    expect(
      screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' }).value,
    ).toBe('New draft written while recovering');
    await userEvent.click(screen.getByRole('button', { name: 'Retry identical action' }));
    await screen.findByText('Action accepted');
    expect(fetch.mock.calls[1][1].body).toBe(sent);
    expect(
      screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' }).value,
    ).toBe('New draft written while recovering');
  });
  it('keeps review context and report selection independent of the selected conversation', async () => {
    const fetch = vi.fn().mockImplementation((_url, options) => {
      const data = JSON.parse(options.body);
      return Promise.resolve(
        response(
          data.path
            ? { content: `# Report for ${data.worktree}` }
            : { entries: [{ name: 'plan.md', directory: false }] },
        ),
      );
    });
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    const snapshot: Snapshot = {
      ...initial,
      workspaces: [{ root: '/workspace', name: 'Project' }],
      worktrees: [
        { path: '/workspace', workspace: '/workspace', branch: 'main' },
        { path: '/other', workspace: '/workspace', branch: 'review' },
      ],
    };
    connect(snapshot);
    expect(
      within(screen.getByRole('navigation', { name: 'Companion navigation' }))
        .getAllByRole('button')
        .map((button) => button.textContent),
    ).toEqual(['Home', 'Sessions', 'Inbox', 'Workspace']);
    await userEvent.click(screen.getByRole('button', { name: 'Reports' }));
    await userEvent.click(screen.getByRole('button', { name: 'review /other' }));
    await screen.findByRole('button', { name: 'plan.md' });
    await userEvent.type(screen.getByRole('searchbox', { name: 'Search report names' }), 'missing');
    expect(screen.queryByRole('button', { name: 'plan.md' })).toBeNull();
    expect(screen.getByText('No matching reports in this folder.')).toBeTruthy();
    await userEvent.clear(screen.getByRole('searchbox', { name: 'Search report names' }));
    await userEvent.click(await screen.findByRole('button', { name: 'plan.md' }));
    expect(await screen.findByRole('heading', { name: 'Report for /other' })).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await open();
    draft('Review without losing my draft');
    await userEvent.click(screen.getByRole('button', { name: 'Workspace' }));
    expect(await screen.findByRole('heading', { name: 'Report for /other' })).toBeTruthy();
    expect(screen.getByText(/review · Change context/)).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await open();
    expect(
      screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' }).value,
    ).toBe('Review without losing my draft');
    expect(
      fetch.mock.calls.every(([, options]) => JSON.parse(options.body).worktree === '/other'),
    ).toBe(true);
  });

  it('restores drafts and Details after reload and browser Back returns to Home', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response({})));
    const first = render(<App />);
    connect();
    await open();
    draft('Survive reload');
    await userEvent.click(screen.getByRole('button', { name: 'Details' }));
    expect(screen.getByRole('region', { name: 'Session metadata' })).toBeTruthy();
    first.unmount();
    render(<App />);
    connect();
    expect(screen.getByRole('region', { name: 'Session metadata' })).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Conversation' }));
    expect(
      screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' }).value,
    ).toBe('Survive reload');
    await userEvent.click(screen.getByRole('button', { name: 'Home' }));
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await act(async () => {
      window.history.back();
      await new Promise((resolve) => setTimeout(resolve, 30));
    });
    expect(screen.getByRole('heading', { name: 'Your workspace, at a glance' })).toBeTruthy();
  });

  it('filters the flat session list and retains grouping as an explicit option', async () => {
    render(<App />);
    connect({
      ...initial,
      sessions: [
        ...initial.sessions,
        { ...initial.sessions[0], id: 'running', name: 'Worker', status: 'busy' },
      ],
    });
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await userEvent.click(screen.getByRole('button', { name: 'Running' }));
    expect(screen.getByRole('button', { name: /^Worker · busy/ })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /^Test agent ·/ })).toBeNull();
    await userEvent.click(screen.getByRole('button', { name: 'Group by workspace/worktree' }));
    expect(screen.getByRole('button', { name: /^Worker · busy/ })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /^Test agent ·/ })).toBeNull();
  });
  it('explains connection-related send blocking and preserves typing until reconnection', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response({})));
    render(<App />);
    connect();
    await open();
    draft('Keep this draft');
    await act(async () => {
      await FakeEvents.instances.at(-1)?.onerror?.();
    });
    expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Send prompt' }).disabled).toBe(
      true,
    );
    expect(
      screen.getByText(/Sending and cancellation are unavailable until the connection returns/),
    ).toBeTruthy();
    expect(
      screen.getByRole<HTMLButtonElement>('button', { name: 'Cancel turn & queue' }).disabled,
    ).toBe(true);
    draft('Keep this draft while offline');
    connect();
    expect(
      screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' }).value,
    ).toBe('Keep this draft while offline');
    expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Send prompt' }).disabled).toBe(
      false,
    );
    expect(
      screen.queryByText(/Sending and cancellation are unavailable until the connection returns/),
    ).toBeNull();
    expect(
      screen.getByRole<HTMLButtonElement>('button', { name: 'Cancel turn & queue' }).disabled,
    ).toBe(false);
    connect({ ...initial, sessions: [{ ...initial.sessions[0], status: 'busy' }] });
    expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Send prompt' }).disabled).toBe(
      false,
    );
  });

  it('ignores a delayed unauthorized connection check after the live stream recovers', async () => {
    let resolve!: (value: Response) => void;
    vi.stubGlobal(
      'fetch',
      vi.fn().mockImplementation(
        () =>
          new Promise<Response>((done) => {
            resolve = done;
          }),
      ),
    );
    render(<App />);
    connect();
    await open();
    draft('Still typing');
    let check: unknown;
    act(() => {
      check = FakeEvents.instances.at(-1)?.onerror?.();
    });
    connect();
    await act(async () => {
      resolve(response({}, 401));
      await check;
    });
    expect(FakeEvents.instances.at(-1)?.close).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'Pair device' })).toBeNull();
    expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Send prompt' }).disabled).toBe(
      false,
    );
    expect(
      screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' }).value,
    ).toBe('Still typing');
  });

  it('selects slash-command options in the companion and submits the session-scoped command', async () => {
    const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect({
      ...initial,
      sessions: [
        {
          ...initial.sessions[0],
          models: { current: 'one', choices: [{ id: 'two', name: 'Second' }] },
        },
      ],
    });
    await open();
    draft('/model');
    expect(screen.getByRole<HTMLButtonElement>('button', { name: 'Send prompt' }).disabled).toBe(
      true,
    );
    await userEvent.click(screen.getByRole('button', { name: 'Second (two)' }));
    expect(fetch).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      text: '/model two',
      session: 'stable-session',
      conversation: 'generation-1',
    });
  });

  it('exports an exited session and displays the saved host path', async () => {
    const fetch = vi
      .fn()
      .mockResolvedValue(
        response({ result: { status: 'accepted', message: 'Exported log: /host/log.md' } }),
      );
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect({ ...initial, sessions: [{ ...initial.sessions[0], status: 'exited' }] });
    await open();
    draft('/export');
    expect(
      screen.getByRole<HTMLButtonElement>('button', { name: 'Cancel turn & queue' }).disabled,
    ).toBe(true);
    expect(screen.getByText(/Cancellation is unavailable/)).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
    expect(await screen.findByText('Exported log: /host/log.md')).toBeTruthy();
    expect(JSON.parse(fetch.mock.calls[0][1].body).text).toBe('/export');
  });

  it('opens attention inside fullscreen logs and persists the fullscreen control setting', async () => {
    const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    const first = render(<App />);
    connect({
      ...initial,
      sessions: [
        {
          ...initial.sessions[0],
          status: 'waiting',
          permission: {
            id: 'fullscreen-permission',
            title: 'Allow fullscreen command?',
            options: [{ optionId: 'allow', name: 'Approve fullscreen command' }],
          },
        },
      ],
      inbox: [
        {
          id: 'fullscreen-event',
          session: 'stable-session',
          conversation: 'generation-1',
          kind: 'permission',
          text: 'Approval needed',
        },
      ],
    });
    await open();
    const dialog = screen.getByRole<HTMLDialogElement>('dialog', { hidden: true });
    dialog.showModal = () => dialog.setAttribute('open', '');
    dialog.close = () => dialog.removeAttribute('open');
    await userEvent.click(screen.getByRole('button', { name: 'Fullscreen logs' }));
    const trigger = within(dialog).getByRole('button', { name: 'Attention (1)' });
    await userEvent.click(trigger);
    expect(dialog.contains(screen.getByRole('region', { name: 'Attention inbox' }))).toBe(true);
    await userEvent.click(
      within(dialog).getByRole('button', { name: 'Approve fullscreen command' }),
    );
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      permission: 'fullscreen-permission',
      option: 'allow',
      session: 'stable-session',
      conversation: 'generation-1',
    });
    await userEvent.click(within(dialog).getByRole('button', { name: 'Hide attention' }));
    expect(document.activeElement).toBe(trigger);
    expect(dialog.open).toBe(true);
    await userEvent.click(within(dialog).getByRole('button', { name: 'Exit fullscreen' }));
    await userEvent.click(screen.getByText('Device', { selector: 'summary' }));
    await userEvent.click(screen.getByRole('checkbox', { name: 'Show Attention in fullscreen' }));
    expect(localStorage.getItem('aero-companion-fullscreen-attention')).toBe('false');
    first.unmount();
    render(<App />);
    connect();
    await open();
    const nextDialog = screen.getByRole<HTMLDialogElement>('dialog', { hidden: true });
    nextDialog.showModal = () => nextDialog.setAttribute('open', '');
    nextDialog.close = () => nextDialog.removeAttribute('open');
    await userEvent.click(screen.getByRole('button', { name: 'Fullscreen logs' }));
    expect(within(nextDialog).queryByRole('button', { name: /^Attention/ })).toBeNull();
  });

  it('requires explicit confirmation to unpair and allows cancelling', async () => {
    const fetch = vi.fn().mockResolvedValue(response({}));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect();
    expect(
      (screen.getByText('Device', { selector: 'summary' }).parentElement as HTMLDetailsElement)
        .open,
    ).toBe(false);
    await userEvent.click(screen.getByText('Device', { selector: 'summary' }));
    await userEvent.click(screen.getByRole('button', { name: 'Unpair' }));
    expect(screen.getByRole('dialog', { name: 'Unpair this device?' })).toBeTruthy();
    expect(fetch).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('dialog', { name: 'Unpair this device?' })).toBeNull();
    expect(fetch).not.toHaveBeenCalled();
    await userEvent.click(screen.getByText('Device', { selector: 'summary' }));
    await userEvent.click(screen.getByRole('button', { name: 'Unpair' }));
    await userEvent.click(
      within(screen.getByRole('dialog', { name: 'Unpair this device?' })).getByRole('button', {
        name: 'Unpair',
      }),
    );
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    expect(fetch.mock.calls[0][0]).toBe('/api/revoke');
    await screen.findByRole('textbox', { name: 'Pairing code' });
  });

  it('answers global attention requests without leaving a transcript or losing its draft', async () => {
    const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    const snapshot: Snapshot = {
      ...initial,
      sessions: [
        initial.sessions[0],
        {
          ...initial.sessions[0],
          id: 'other-session',
          name: 'Other agent',
          conversation: 'other-generation',
          status: 'waiting',
          permission: {
            id: 'other-permission',
            title: 'Allow other command?',
            options: [{ optionId: 'allow', name: 'Approve other command' }],
          },
        },
      ],
      inbox: [
        {
          id: 'attention-event',
          session: 'other-session',
          conversation: 'other-generation',
          kind: 'permission',
          text: 'Approval needed',
        },
      ],
    };
    connect(snapshot);
    await open();
    draft('Keep my draft');
    const trigger = screen.getByRole('button', { name: 'Attention (1)' });
    await userEvent.click(trigger);
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Hide attention' }));
    expect(screen.getByRole('heading', { name: 'Test agent · idle' })).toBeTruthy();
    connect({ ...snapshot, connected: false });
    expect(
      (screen.getByRole('button', { name: 'Approve other command' }) as HTMLButtonElement).disabled,
    ).toBe(true);
    connect(snapshot);
    await userEvent.click(screen.getByRole('button', { name: 'Hide attention' }));
    expect(screen.queryByRole('heading', { name: 'Attention inbox' })).toBeNull();
    expect(document.activeElement).toBe(trigger);
    connect({ ...snapshot, cursor: 'epoch:2' });
    expect(screen.queryByRole('heading', { name: 'Attention inbox' })).toBeNull();
    await userEvent.click(trigger);
    await userEvent.click(screen.getByRole('button', { name: 'Approve other command' }));
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      session: 'other-session',
      conversation: 'other-generation',
      permission: 'other-permission',
      option: 'allow',
    });
    connect({ ...snapshot, inbox: [] });
    expect(screen.getByText('No attention events right now.')).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Hide attention' }));
    expect(document.activeElement).toBe(trigger);
    expect(
      (screen.getByRole('textbox', { name: 'Follow-up prompt' }) as HTMLTextAreaElement).value,
    ).toBe('Keep my draft');
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await userEvent.click(screen.getByRole('button', { name: 'Attention' }));
    await userEvent.keyboard('{Escape}');
    expect(screen.queryByRole('heading', { name: 'Attention inbox' })).toBeNull();
    expect(screen.getByRole('heading', { name: 'Agent sessions' })).toBeTruthy();
  });

  it('sends prompts from fullscreen and preserves drafts when the input is hidden', async () => {
    const fetch = vi.fn().mockResolvedValue(response({ result: { status: 'accepted' } }));
    vi.stubGlobal('fetch', fetch);
    render(<App />);
    connect();
    await open();
    draft('Fullscreen request');
    const dialog = screen.getByRole<HTMLDialogElement>('dialog', { hidden: true });
    dialog.showModal = () => dialog.setAttribute('open', '');
    dialog.close = () => dialog.removeAttribute('open');
    await userEvent.click(screen.getByRole('button', { name: 'Fullscreen logs' }));
    const input = screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' });
    expect(dialog.contains(input)).toBe(true);
    await userEvent.click(screen.getByRole('button', { name: 'Hide input' }));
    expect(screen.queryByRole('textbox', { name: 'Follow-up prompt' })).toBeNull();
    await userEvent.click(screen.getByRole('button', { name: 'Show input' }));
    expect(input.value).toBe('Fullscreen request');
    await userEvent.click(screen.getByRole('button', { name: 'Send prompt' }));
    await waitFor(() => expect(input.value).toBe(''));
    expect(dialog.textContent).not.toContain('Action accepted');
    expect(fetch.mock.calls[0][0]).toBe('/api/prompt');
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      session: 'stable-session',
      conversation: 'generation-1',
      text: 'Fullscreen request',
    });
    draft('Next request');
    await userEvent.click(screen.getByRole('button', { name: 'Hide input' }));
    await userEvent.click(screen.getByRole('button', { name: 'Exit fullscreen' }));
    expect(
      screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Follow-up prompt' }).value,
    ).toBe('Next request');
  });
  it('shows populated media galleries in Artifacts and hides empty galleries', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(new Response(new Uint8Array([0]), { status: 206 })),
    );
    render(<App />);
    connect(initial);
    await open();
    await userEvent.click(screen.getByRole('button', { name: 'Artifacts' }));
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
    expect(screen.queryByRole('textbox', { name: 'Follow-up prompt' })).toBeNull();
    await waitFor(() => expect(screen.getByText('Saved for later')).toBeTruthy());
    connect(initial);
    expect(document.querySelectorAll('.session-screenshots')).toHaveLength(0);
    expect(document.querySelectorAll('#transcript')).toHaveLength(1);
  });
  it('keeps the session screenshot gallery available when reopening Artifacts', async () => {
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
    await userEvent.click(screen.getByRole('button', { name: 'Artifacts' }));
    const summary = screen.getByText('Screenshots (1)');
    await userEvent.click(summary);
    const gallery = screen.getByRole('list', { name: 'Session screenshots' });
    await userEvent.click(gallery.querySelector('a')!);
    expect(screen.getByRole('dialog', { name: 'Screenshot preview' })).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Close' }));
    await userEvent.click(screen.getByRole('button', { name: '← All sessions' }));
    await open();
    await userEvent.click(screen.getByRole('button', { name: 'Artifacts' }));
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
      await userEvent.click(screen.getByRole('button', { name: 'New session' }));
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
      await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
      await userEvent.click(screen.getByText('New session', { selector: 'summary' }));
      const summary = screen.getByText('New AI session', { selector: 'summary' });
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
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
    await userEvent.click(screen.getByText('New session', { selector: 'summary' }));
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
    expect(screen.queryByRole('button', { name: 'completed: Turn completed' })).toBeNull();
    expect(screen.getByText('No attention events right now.')).toBeTruthy();
    expect(fetch).not.toHaveBeenCalled();
    connect({ ...initial, sessions: [{ ...initial.sessions[0], conversation: 'replacement' }] });
    await act(async () => {
      window.history.back();
      await new Promise((resolve) => setTimeout(resolve, 30));
    });
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
      sessions: [
        {
          ...initial.sessions[0],
          permission: {
            id: 'permission',
            title: 'Choose an option',
            options: [{ optionId: 'allow', name: 'Allow once' }],
          },
        },
      ],
      inbox: [
        {
          id: 'event',
          session: 'stable-session',
          conversation: 'generation-1',
          kind: 'permission',
          text: 'Choose an option',
        },
      ],
    });
    await userEvent.click(screen.getByRole('button', { name: 'Inbox (1)' }));
    await userEvent.click(screen.getByRole('button', { name: 'permission: Choose an option' }));
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
