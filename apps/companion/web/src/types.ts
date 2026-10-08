export interface PermissionOption {
  optionId: string;
  name?: string;
  kind?: string;
}

export interface Permission {
  id: string;
  title: string;
  options: PermissionOption[];
}

export interface TranscriptBlock {
  kind: string;
  timestamp?: number;
  id?: string;
  status?: string;
  meta_kind?: string;
  tool_kind?: string;
  text?: string;
  title?: string;
  entries?: { status: string; content: string }[];
  content?: {
    type?: string;
    content?: { type?: string; text?: string; uri?: string; name?: string };
    text?: string;
    path?: string;
    oldText?: string;
    newText?: string;
    [key: string]: unknown;
  }[];
  rawInput?: unknown;
  rawOutput?: unknown;
  answer?: string;
}

export interface Session {
  usage?: {
    tokens?: {
      responses?: number;
      totalTokens?: number;
      inputTokens?: number;
      outputTokens?: number;
      thoughtTokens?: number;
      cachedReadTokens?: number;
      cachedWriteTokens?: number;
    };
    context?: { used: number; size: number };
    cost?: { amount: number; currency: string };
  };
  commands?: { name: string; description?: string; input?: { hint?: string } }[];
  models?: SessionChoices;
  modes?: SessionChoices;
  assignment?: {
    workspace_root: string;
    board_id: string;
    board_title?: string;
    ticket_id?: string;
    ticket_title?: string;
    ticket_state?: string;
    pending?: boolean;
    error?: string;
  };
  id: string;
  name: string;
  agent: string;
  worktree: string;
  status: 'idle' | 'busy' | 'waiting' | 'starting' | 'stopped' | 'exited';
  conversation?: string;
  acp_session_id?: string;
  blocks?: TranscriptBlock[];
  queue?: string[];
  permission?: Permission;
  target?: string;
}

export interface SessionChoices {
  current?: string;
  choices: { id: string; name: string; description?: string; group?: string }[];
}

export interface InboxEvent {
  id: string;
  session: string;
  conversation: string;
  kind: string;
  text: string;
  workspace?: string;
  ticket?: string;
}

export interface Snapshot {
  boards?: { workspace: string; id: string; title: string }[];
  connected: boolean;
  cursor: string;
  error?: string;
  sessions: Session[];
  inbox: InboxEvent[];
  workspaces: { root: string; name: string; expanded?: boolean }[];
  worktrees: {
    path: string;
    workspace?: string;
    branch?: string;
    target?: string;
    reports_directory?: string;
  }[];
  epoch?: string;
  agents?: string[];
}

export interface Selection {
  id: string;
  conversation?: string;
}

export type ActionPath =
  | 'session_assign_board'
  | 'prompt'
  | 'cancel'
  | 'permission'
  | 'session_create'
  | 'session_resume'
  | 'session_rename'
  | 'session_delete'
  | 'worktree_create'
  | 'worktree_rename'
  | 'worktree_delete';
export interface ActionData {
  board_id?: string;
  replace?: boolean;
  operation_id: string;
  session?: string;
  conversation?: string;
  text?: string;
  permission?: string;
  option?: string;
  epoch?: string;
  target?: string;
  workspace?: string;
  worktree?: string;
  agent?: string;
  name?: string;
  branch?: string;
  force?: boolean;
}
export interface PendingAction {
  path: ActionPath;
  data: ActionData;
}
export interface ActionResponse {
  result: { status: 'accepted' | 'queued' | 'unknown'; session?: string; message?: string };
}
