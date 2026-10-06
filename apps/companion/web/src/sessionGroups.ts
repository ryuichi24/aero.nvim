import type { Session, Snapshot } from './types';

export interface WorktreeGroup {
  path: string;
  label: string;
  branch?: string;
  sessions: Session[];
}

export interface WorkspaceGroup {
  key: string;
  root?: string;
  name: string;
  worktrees: WorktreeGroup[];
}

export function pathName(path: string): string {
  return path.replace(/\/+$/, '').split('/').at(-1) || path;
}

function normalize(path: string): string {
  return path.replace(/\/+$/, '') || '/';
}

// Explicit Git workspace metadata is authoritative, including sibling worktree checkouts.
// Only fall back to a directory-boundary match; never guess by a shared name prefix.
export function groupSessions(snapshot: Snapshot): WorkspaceGroup[] {
  const workspaces = new Map<string, WorkspaceGroup>();
  for (const workspace of snapshot.workspaces) {
    const root = normalize(workspace.root);
    workspaces.set(root, {
      key: root,
      root,
      name: workspace.name || pathName(root),
      worktrees: [],
    });
  }
  const worktrees = new Map<string, WorktreeGroup>();
  const owner = (path: string, explicit?: string): WorkspaceGroup => {
    const root = explicit
      ? normalize(explicit)
      : [...workspaces.keys()]
          .filter((root) => path === root || path.startsWith(root === '/' ? '/' : root + '/'))
          .sort((a, b) => b.length - a.length)[0];
    if (root) {
      if (!workspaces.has(root))
        workspaces.set(root, { key: root, root, name: pathName(root), worktrees: [] });
      return workspaces.get(root)!;
    }
    const key = 'unassigned-worktrees';
    if (!workspaces.has(key)) workspaces.set(key, { key, name: 'Other worktrees', worktrees: [] });
    return workspaces.get(key)!;
  };
  for (const worktree of snapshot.worktrees) {
    const path = normalize(worktree.path);
    if (worktrees.has(path)) continue;
    const workspace = owner(path, worktree.workspace);
    const group = {
      path,
      branch: worktree.branch,
      label: worktree.branch || (path === workspace.root ? 'Main worktree' : pathName(path)),
      sessions: [],
    };
    worktrees.set(path, group);
    workspace.worktrees.push(group);
  }
  for (const session of snapshot.sessions) {
    const path = normalize(session.worktree);
    if (!worktrees.has(path)) {
      const workspace = owner(path);
      const worktree = {
        path,
        label: path === workspace.root ? 'Main worktree' : pathName(path),
        sessions: [],
      };
      worktrees.set(path, worktree);
      workspace.worktrees.push(worktree);
    }
    worktrees.get(path)!.sessions.push(session);
  }
  for (const workspace of workspaces.values()) {
    workspace.worktrees.sort(
      (a, b) =>
        Number(b.path === workspace.root) - Number(a.path === workspace.root) ||
        a.label.localeCompare(b.label) ||
        a.path.localeCompare(b.path),
    );
    for (const worktree of workspace.worktrees) {
      worktree.sessions.sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
    }
  }
  return [...workspaces.values()].sort(
    (a, b) =>
      Number(!a.root) - Number(!b.root) ||
      a.name.localeCompare(b.name) ||
      a.key.localeCompare(b.key),
  );
}

export function filterGroups(groups: WorkspaceGroup[], search: string): WorkspaceGroup[] {
  const query = search.trim().toLocaleLowerCase();
  if (!query) return groups;
  const matches = (...values: (string | undefined)[]) =>
    values.some((value) => value?.toLocaleLowerCase().includes(query));
  return groups.flatMap((workspace) => {
    if (matches(workspace.name, workspace.root)) return [workspace];
    const worktrees = workspace.worktrees.flatMap((worktree) => {
      if (matches(worktree.label, worktree.path, worktree.branch)) return [worktree];
      const sessions = worktree.sessions.filter((session) =>
        matches(session.name, session.agent, session.status),
      );
      return sessions.length ? [{ ...worktree, sessions }] : [];
    });
    return worktrees.length ? [{ ...workspace, worktrees }] : [];
  });
}

export function sessionLocation(
  groups: WorkspaceGroup[],
  selection: { id: string; conversation?: string } | null,
) {
  if (!selection) return undefined;
  for (const workspace of groups) {
    for (const worktree of workspace.worktrees) {
      const session = worktree.sessions.find(
        (item) => item.id === selection.id && item.conversation === selection.conversation,
      );
      if (session) return { workspace, worktree, session };
    }
  }
  return undefined;
}
