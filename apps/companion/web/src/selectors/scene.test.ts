import { expect, it } from 'vitest';
import { sceneSnapshot } from './workspace-scope';
import type { Snapshot } from '../types';

it('scopes content to the active scene while retaining cross-scene attention', () => {
  const snapshot: Snapshot = {
    connected: true,
    cursor: '1',
    active_scene: 'research',
    workspaces: [
      { root: '/shared', name: 'Shared', in_scene: true },
      { root: '/other', name: 'Other', in_scene: false },
    ],
    worktrees: [
      { path: '/shared', in_scene: true },
      { path: '/other', in_scene: false },
    ],
    sessions: [
      {
        id: 'chat',
        name: 'Research',
        agent: 'acp',
        worktree: '/general',
        scope: 'general',
        status: 'idle',
        in_scene: true,
      },
      {
        id: 'other',
        name: 'Other',
        agent: 'acp',
        worktree: '/other',
        status: 'waiting',
        in_scene: false,
      },
    ],
    inbox: [
      {
        id: 'attention',
        session: 'other',
        conversation: 'c',
        kind: 'permission',
        text: 'Approval',
      },
    ],
  };
  const scoped = sceneSnapshot(snapshot)!;
  expect(scoped.sessions.map((session) => session.id)).toEqual(['chat']);
  expect(scoped.workspaces.map((workspace) => workspace.root)).toEqual(['/shared']);
  expect(scoped.worktrees.map((tree) => tree.path)).toEqual(['/shared']);
  expect(scoped.inbox).toEqual(snapshot.inbox);
  expect(snapshot.sessions).toHaveLength(2);
});
