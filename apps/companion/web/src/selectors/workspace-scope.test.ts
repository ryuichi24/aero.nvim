import { expect, it } from 'vitest';
import { scopeSnapshot } from './workspace-scope';
import type { Snapshot } from '../types';

it('includes nested submodule repositories and external worktrees without inferring ownership from paths', () => {
  const snapshot: Snapshot = {
    connected: true,
    cursor: 'epoch:1',
    workspaces: ['/parent', '/parent/libs/core', '/parser', '/other'].map((root) => ({
      root,
      name: root,
    })),
    worktrees: [
      { path: '/parent', workspace: '/parent' },
      { path: '/parent/libs/core', workspace: '/parent/libs/core' },
      { path: '/external/core', workspace: '/parent/libs/core' },
      { path: '/parser', workspace: '/parser' },
      { path: '/parent/unrelated', workspace: '/other' },
    ],
    submodules: [
      {
        worktree: '/parent',
        path: '/parent/libs/core',
        name: 'libs/core',
        workspace: '/parent/libs/core',
      },
      {
        worktree: '/external/core',
        path: '/external/core/parser',
        name: 'parser',
        workspace: '/parser',
      },
      { worktree: '/parser', path: '/parser/cycle', name: 'cycle', workspace: '/parent' },
    ],
    sessions: [
      { id: 'child', worktree: '/external/core', name: 'Child', agent: 'fixture', status: 'idle' },
      {
        id: 'other',
        worktree: '/parent/unrelated',
        name: 'Other',
        agent: 'fixture',
        status: 'idle',
      },
    ],
    inbox: [
      { id: 'one', session: 'child', conversation: 'c', kind: 'error', text: 'child' },
      { id: 'two', session: 'other', conversation: 'c', kind: 'error', text: 'other' },
    ],
    boards: [
      { workspace: '/parser', id: 'one', title: 'Nested' },
      { workspace: '/other', id: 'two', title: 'Other' },
    ],
  };
  const scoped = scopeSnapshot(snapshot, '/parent')!;
  expect(scoped.worktrees.map((tree) => tree.path)).toEqual([
    '/parent',
    '/parent/libs/core',
    '/external/core',
    '/parser',
  ]);
  expect(scoped.sessions.map((session) => session.id)).toEqual(['child']);
  expect(scoped.inbox.map((entry) => entry.id)).toEqual(['one']);
  expect(scoped.boards?.map((board) => board.id)).toEqual(['one']);
  expect(scopeSnapshot(snapshot, '')).toBe(snapshot);
});
