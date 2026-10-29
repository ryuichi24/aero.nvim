import { groupSessions } from '../sessionGroups';
import type { Snapshot } from '../types';

export function scopeSnapshot(snapshot: Snapshot | null, workspace: string): Snapshot | null {
  if (!snapshot || !workspace) return snapshot;
  const roots = new Set([workspace]);
  const owners = new Map(snapshot.worktrees.map((tree) => [tree.path, tree.workspace]));
  const children = new Map<string, string[]>();
  for (const entry of snapshot.submodules || []) {
    const owner = owners.get(entry.worktree);
    if (owner) children.set(owner, [...(children.get(owner) || []), entry.workspace]);
  }
  const pending = [workspace];
  for (let index = 0; index < pending.length; index++) {
    for (const child of children.get(pending[index]) || []) {
      if (!roots.has(child)) {
        roots.add(child);
        pending.push(child);
      }
    }
  }
  const worktrees = snapshot.worktrees.filter(
    (tree) => roots.has(tree.workspace || '') || roots.has(tree.path),
  );
  const paths = new Set(worktrees.map((tree) => tree.path));
  const sessions = snapshot.sessions.filter(
    (session) => session.scope === 'general' || paths.has(session.worktree),
  );
  const sessionIDs = new Set(sessions.map((session) => session.id));
  return {
    ...snapshot,
    workspaces: snapshot.workspaces.filter((item) => roots.has(item.root)),
    worktrees,
    sessions,
    inbox: snapshot.inbox.filter(
      (entry) => roots.has(entry.workspace || '') || sessionIDs.has(entry.session),
    ),
    submodules: snapshot.submodules?.filter((entry) => paths.has(entry.worktree)),
    boards: snapshot.boards?.filter((board) => roots.has(board.workspace)),
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
