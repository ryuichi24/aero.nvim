import type { PendingAction, Snapshot } from './types';

export class RequestError extends Error {
  constructor(
    message: string,
    public readonly unknownOutcome: boolean,
  ) {
    super(message);
  }
}

export async function post<T>(path: string, data: unknown): Promise<T> {
  const response = await fetch(`/api/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
  let body: T & { error?: string };
  try {
    body = await response.json();
  } catch {
    throw new RequestError('Invalid or interrupted server response', true);
  }
  if (!response.ok) {
    throw new RequestError(
      body.error || 'Request rejected',
      response.status >= 500 || response.status === 401,
    );
  }
  return body;
}

const pendingKey = 'aero_pending';

// getRandomValues is available on HTTP private-network origins too; randomUUID is HTTPS-only.
export function operationID(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('');
}

export function readPending(): PendingAction | null {
  try {
    const value: unknown = JSON.parse(sessionStorage.getItem(pendingKey) || 'null');
    if (!value || typeof value !== 'object') return null;
    const action = value as Partial<PendingAction>;
    const data = action.data;
    if (
      !['prompt', 'cancel', 'permission'].includes(action.path || '') ||
      !data ||
      typeof data.operation_id !== 'string' ||
      typeof data.session !== 'string' ||
      typeof data.conversation !== 'string'
    )
      return null;
    if (action.path === 'prompt' && typeof data.text !== 'string') return null;
    if (
      action.path === 'permission' &&
      (typeof data.permission !== 'string' || typeof data.option !== 'string')
    )
      return null;
    return action as PendingAction;
  } catch {
    return null;
  }
}

export function savePending(action: PendingAction | null): void {
  if (action) sessionStorage.setItem(pendingKey, JSON.stringify(action));
  else sessionStorage.removeItem(pendingKey);
}

export function parseSnapshot(text: string): Snapshot {
  const value = JSON.parse(text) as Snapshot;
  if (
    typeof value.connected !== 'boolean' ||
    typeof value.cursor !== 'string' ||
    !Array.isArray(value.sessions) ||
    !Array.isArray(value.inbox) ||
    !Array.isArray(value.workspaces) ||
    !Array.isArray(value.worktrees)
  ) {
    throw new Error('Invalid stream snapshot');
  }
  return value;
}
