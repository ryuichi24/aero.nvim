import { groupSessions } from '../sessionGroups';
import type { Snapshot } from '../types';

export function scopeSnapshot(snapshot: Snapshot | null, workspace: string): Snapshot | null {
  if (!snapshot || !workspace) return snapshot;
  const worktrees = snapshot.worktrees.filter(
    (tree) => tree.workspace === workspace || tree.path === workspace,
  );
  const paths = new Set(worktrees.map((tree) => tree.path));
  return {
    ...snapshot,
    workspaces: snapshot.workspaces.filter((item) => item.root === workspace),
    worktrees,
    sessions: snapshot.sessions.filter((session) => paths.has(session.worktree)),
  };
}

export function reviewGroups(snapshot: Snapshot | null, search: string) {
  if (!snapshot) return [];
  return groupSessions({ ...snapshot, sessions: [] })
    .map((workspace) => ({
      ...workspace,
      worktrees: workspace.worktrees.filter((tree) =>
        `${workspace.name} ${workspace.root} ${tree.branch} ${tree.path}`
          .toLowerCase()
          .includes(search.toLowerCase()),
      ),
    }))
    .filter((workspace) => workspace.worktrees.length > 0);
}
