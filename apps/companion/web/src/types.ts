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
  connected: boolean;
  cursor: string;
  error?: string;
  sessions: Session[];
  inbox: InboxEvent[];
  workspaces: { root: string; name: string; expanded?: boolean }[];
  worktrees: { path: string; workspace?: string; branch?: string }[];
}

export interface Selection {
  id: string;
  conversation?: string;
}

export type ActionPath = 'prompt' | 'cancel' | 'permission';
export interface ActionData {
  operation_id: string;
  session: string;
  conversation: string;
  text?: string;
  permission?: string;
  option?: string;
}
export interface PendingAction {
  path: ActionPath;
  data: ActionData;
}
export interface ActionResponse {
  result: { status: 'accepted' | 'queued' | 'unknown' };
}
