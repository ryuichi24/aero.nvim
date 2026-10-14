import type { PendingAction } from './types';
export { parseSnapshot } from './connection/snapshot';

export class RequestError extends Error {
  constructor(
    message: string,
    public readonly unknownOutcome: boolean,
  ) {
    super(message);
  }
}

export async function post<T>(path: string, data: unknown): Promise<T> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const response = await fetch(`/api/${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
      signal: controller.signal,
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
  } catch (error) {
    if (controller.signal.aborted) {
      throw new RequestError(
        'Request timed out. Check the host or retry the identical action.',
        true,
      );
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
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
      ![
        'prompt',
        'cancel',
        'permission',
        'session_create',
        'session_assign_board',
        'session_resume',
        'session_rename',
        'session_delete',
        'worktree_create',
        'worktree_rename',
        'worktree_delete',
      ].includes(action.path || '') ||
      !data ||
      typeof data.operation_id !== 'string'
    )
      return null;
    if (
      ['prompt', 'cancel', 'permission'].includes(action.path || '') &&
      (typeof data.session !== 'string' || typeof data.conversation !== 'string')
    )
      return null;
    if (action.path?.startsWith('session_') || action.path?.startsWith('worktree_')) {
      if (typeof data.epoch !== 'string') return null;
    }
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
