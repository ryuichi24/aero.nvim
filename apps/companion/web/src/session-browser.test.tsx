import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { SessionBrowser } from './session-browser';
import { filterGroups, groupSessions } from './sessionGroups';
import type { Snapshot } from './types';

const snapshot: Snapshot = {
  connected: true,
  cursor: 'epoch:1',
  inbox: [],
  workspaces: [
    { root: '/repos/aero', name: 'Aero' },
    { root: '/repos/blog', name: 'Blog' },
  ],
  worktrees: [
    { path: '/repos/aero', workspace: '/repos/aero', branch: 'main' },
    { path: '/checkouts/aero/mobile', workspace: '/repos/aero', branch: 'mobile-ui' },
    { path: '/checkouts/aero/docs', workspace: '/repos/aero', branch: 'docs' },
    { path: '/repos/blog', workspace: '/repos/blog', branch: 'main' },
  ],
  sessions: [
    {
      id: 'aero-main',
      conversation: 'conv-a',
      name: 'Shared name',
      agent: 'codex-acp',
      worktree: '/repos/aero',
      status: 'busy',
    },
    {
      id: 'mobile-review',
      conversation: 'conv-r',
      name: 'Review',
      agent: 'opencode-acp',
      worktree: '/checkouts/aero/mobile',
      status: 'waiting',
    },
    {
      id: 'mobile-build',
      conversation: 'conv-b',
      name: 'Build',
      agent: 'claude-agent-acp',
      worktree: '/checkouts/aero/mobile',
      status: 'idle',
    },
    {
      id: 'blog-main',
      conversation: 'conv-c',
      name: 'Shared name',
      agent: 'codex-acp',
      worktree: '/repos/blog',
      status: 'exited',
    },
    {
      id: 'unassigned',
      name: 'Unassigned',
      agent: 'fixture',
      worktree: '/repos/aero-extra',
      status: 'stopped',
    },
  ],
};

afterEach(cleanup);

describe('workspace session browser', () => {
  it('uses explicit Git ownership for sibling worktrees and retains unmapped/empty worktrees', () => {
    const groups = groupSessions(snapshot);
    const aero = groups.find((group) => group.name === 'Aero')!;
    expect(aero.worktrees.map((worktree) => worktree.path)).toEqual([
      '/repos/aero',
      '/checkouts/aero/docs',
      '/checkouts/aero/mobile',
    ]);
    expect(
      aero.worktrees
        .find((worktree) => worktree.branch === 'mobile-ui')
        ?.sessions.map((session) => session.id),
    ).toEqual(['mobile-build', 'mobile-review']);
    expect(aero.worktrees.find((worktree) => worktree.branch === 'docs')?.sessions).toEqual([]);
    const other = groups.find((group) => group.name === 'Other worktrees')!;
    expect(other.worktrees[0].sessions[0].id).toBe('unassigned');
    expect(
      groups.flatMap((group) => group.worktrees.flatMap((worktree) => worktree.sessions)),
    ).toHaveLength(5);
    const filtered = filterGroups(groups, 'opencode');
    expect(filtered).toHaveLength(1);
    expect(filtered[0].worktrees[0].sessions.map((session) => session.id)).toEqual([
      'mobile-review',
    ]);
    expect(filterGroups(groups, 'docs')[0].worktrees[0].sessions).toEqual([]);
  });

  it('navigates workspace → worktree → exact session with touch-friendly disclosures', async () => {
    const onSelect = vi.fn();
    render(<SessionBrowser snapshot={snapshot} selected={null} active onSelect={onSelect} />);
    const aero = screen.getByRole('group', { name: 'Workspace Aero' });
    const workspaceButton = within(aero).getByRole('button', { name: /^Aero/ });
    expect(workspaceButton.getAttribute('aria-expanded')).toBe('false');
    expect(screen.queryByRole('button', { name: /^Review ·/ })).toBeNull();
    await userEvent.click(workspaceButton);
    const mobile = within(aero).getByRole('group', { name: 'Worktree mobile-ui' });
    await userEvent.click(within(mobile).getByRole('button', { name: /^mobile-ui/ }));
    await userEvent.click(within(mobile).getByRole('button', { name: /^Review · waiting/ }));
    expect(onSelect).toHaveBeenCalledExactlyOnceWith({
      id: 'mobile-review',
      conversation: 'conv-r',
    });
    const docs = within(aero).getByRole('group', { name: 'Worktree docs' });
    await userEvent.click(within(docs).getByRole('button', { name: /^docs/ }));
    expect(within(docs).getByText('No ACP sessions in this worktree.')).toBeTruthy();
    // The same session name in another workspace cannot redirect this action.
    expect(screen.queryByRole('button', { name: /^Shared name · exited/ })).toBeNull();
  });

  it('searches across hierarchy and automatically exposes matches without losing their workspace', async () => {
    render(<SessionBrowser snapshot={snapshot} selected={null} active onSelect={vi.fn()} />);
    const search = screen.getByRole('searchbox');
    await userEvent.type(search, 'Review');
    expect(screen.getByRole('group', { name: 'Workspace Aero' })).toBeTruthy();
    expect(screen.getByRole('group', { name: 'Worktree mobile-ui' })).toBeTruthy();
    expect(screen.getByRole('button', { name: /^Review ·/ })).toBeTruthy();
    expect(screen.queryByRole('group', { name: 'Workspace Blog' })).toBeNull();
    await userEvent.clear(search);
    await userEvent.type(search, 'not-a-session');
    expect(screen.getByText('No matching sessions or worktrees.')).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Clear search' }));
    expect(screen.getByRole('group', { name: 'Workspace Blog' })).toBeTruthy();
  });

  it('reveals an inbox-selected session on return and preserves manual collapse across status updates', async () => {
    const selected = { id: 'mobile-review', conversation: 'conv-r' };
    const view = render(
      <SessionBrowser snapshot={snapshot} selected={selected} active={false} onSelect={vi.fn()} />,
    );
    view.rerender(
      <SessionBrowser snapshot={snapshot} selected={selected} active onSelect={vi.fn()} />,
    );
    const current = screen.getByRole('button', { name: /^Review · waiting/ });
    expect(current.getAttribute('aria-current')).toBe('page');
    const mobile = screen.getByRole('group', { name: 'Worktree mobile-ui' });
    const toggle = within(mobile).getByRole('button', { name: /^mobile-ui/ });
    await userEvent.click(toggle);
    const updated: Snapshot = {
      ...snapshot,
      cursor: 'epoch:2',
      sessions: snapshot.sessions.map((session) =>
        session.id === selected.id ? { ...session, status: 'idle' } : session,
      ),
    };
    view.rerender(
      <SessionBrowser snapshot={updated} selected={selected} active onSelect={vi.fn()} />,
    );
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(screen.queryByRole('button', { name: /^Review ·/ })).toBeNull();
    await userEvent.click(toggle);
    expect(
      screen.getByRole('button', { name: /^Review · idle/ }).getAttribute('aria-current'),
    ).toBe('page');
  });

  it('keeps existing groups open when another workspace is discovered', () => {
    const initial = {
      ...snapshot,
      workspaces: [snapshot.workspaces[0]],
      worktrees: [snapshot.worktrees[0]],
      sessions: [snapshot.sessions[0]],
    };
    const view = render(
      <SessionBrowser snapshot={initial} selected={null} active onSelect={vi.fn()} />,
    );
    expect(screen.getByRole('button', { name: /^Shared name · busy/ })).toBeTruthy();
    view.rerender(<SessionBrowser snapshot={snapshot} selected={null} active onSelect={vi.fn()} />);
    expect(screen.getByRole('button', { name: /^Shared name · busy/ })).toBeTruthy();
    expect(screen.getByRole('group', { name: 'Workspace Blog' })).toBeTruthy();
  });

  it('preserves search during live updates and clears it when returning to a selected session', async () => {
    const selected = { id: 'mobile-review', conversation: 'conv-r' };
    const onSelect = vi.fn();
    const view = render(
      <SessionBrowser snapshot={snapshot} selected={selected} active onSelect={onSelect} />,
    );
    await userEvent.type(screen.getByRole('searchbox'), 'Build');
    const updated = { ...snapshot, cursor: 'epoch:2' };
    view.rerender(
      <SessionBrowser snapshot={updated} selected={selected} active onSelect={onSelect} />,
    );
    expect((screen.getByRole('searchbox') as HTMLInputElement).value).toBe('Build');
    expect(screen.getByRole('button', { name: /^Build ·/ })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /^Review ·/ })).toBeNull();
    view.rerender(
      <SessionBrowser snapshot={updated} selected={selected} active={false} onSelect={onSelect} />,
    );
    view.rerender(
      <SessionBrowser snapshot={updated} selected={selected} active onSelect={onSelect} />,
    );
    expect((screen.getByRole('searchbox') as HTMLInputElement).value).toBe('');
    expect(screen.getByRole('button', { name: /^Review ·/ })).toBeTruthy();
  });
});
