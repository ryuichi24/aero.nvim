import type { groupSessions } from './sessionGroups';

type Groups = ReturnType<typeof groupSessions>;
export interface BrowserInput {
  groups: Groups;
  navigationKey: string;
  active: boolean;
  workspaceKey?: string;
  worktreePath?: string;
}

interface BrowserState {
  input: BrowserInput;
  query: string;
  openWorkspaces: Record<string, boolean>;
  openWorktrees: Record<string, boolean>;
}

type BrowserAction =
  | { type: 'reconcile'; input: BrowserInput }
  | { type: 'search'; query: string }
  | { type: 'workspace'; key: string; expanded: boolean }
  | { type: 'worktree'; key: string; expanded: boolean };

function reconcile(state: BrowserState, input: BrowserInput): BrowserState {
  const openWorkspaces = { ...state.openWorkspaces };
  const openWorktrees = { ...state.openWorktrees };
  // Capture each group's first disclosure default; later discovery must not
  // collapse existing groups or override the user's explicit choices.
  for (const workspace of input.groups) {
    if (!(workspace.key in openWorkspaces))
      openWorkspaces[workspace.key] = input.groups.length === 1;
    for (const worktree of workspace.worktrees) {
      if (!(worktree.path in openWorktrees))
        openWorktrees[worktree.path] = workspace.worktrees.length === 1;
    }
  }
  const reveal =
    input.navigationKey !== state.input.navigationKey &&
    input.active &&
    !!input.workspaceKey &&
    !!input.worktreePath;
  if (reveal && input.workspaceKey && input.worktreePath) {
    openWorkspaces[input.workspaceKey] = true;
    openWorktrees[input.worktreePath] = true;
  }
  return { input, query: reveal ? '' : state.query, openWorkspaces, openWorktrees };
}

export function initialBrowserState(input: BrowserInput): BrowserState {
  return reconcile(
    { input: { ...input, navigationKey: '' }, query: '', openWorkspaces: {}, openWorktrees: {} },
    input,
  );
}

export function browserReducer(state: BrowserState, action: BrowserAction): BrowserState {
  switch (action.type) {
    case 'reconcile':
      return reconcile(state, action.input);
    case 'search':
      return { ...state, query: action.query };
    case 'workspace':
      return {
        ...state,
        openWorkspaces: { ...state.openWorkspaces, [action.key]: action.expanded },
      };
    case 'worktree':
      return { ...state, openWorktrees: { ...state.openWorktrees, [action.key]: action.expanded } };
  }
}
