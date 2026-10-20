// Shared integration boundary: fake SSE, isolated storage and user-level navigation.
import { act, cleanup, fireEvent, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, vi } from 'vitest';
import type { Snapshot } from '../types';

export class FakeEvents {
  static instances: FakeEvents[] = [];
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => unknown) | null = null;
  onopen: (() => void) | null = null;
  addEventListener = vi.fn();
  close = vi.fn();
  constructor() {
    FakeEvents.instances.push(this);
  }
  static emit(snapshot: Snapshot) {
    FakeEvents.instances
      .at(-1)
      ?.onmessage?.(new MessageEvent('message', { data: JSON.stringify(snapshot) }));
  }
}
export const initial: Snapshot = {
  connected: true,
  cursor: 'epoch:1',
  workspaces: [],
  worktrees: [],
  inbox: [],
  sessions: [
    {
      id: 'stable-session',
      conversation: 'generation-1',
      name: 'Test agent',
      agent: 'fixture',
      worktree: '/workspace',
      status: 'idle',
      blocks: [{ kind: 'agent', text: 'Existing transcript' }],
      queue: [],
    },
  ],
};
export function response(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
export function connect(snapshot = initial) {
  act(() => FakeEvents.emit(snapshot));
}
export async function open() {
  if (!screen.queryByRole('button', { name: /Test agent ·/ }))
    await userEvent.click(screen.getByRole('button', { name: 'Sessions' }));
  await userEvent.click(screen.getByRole('button', { name: /Test agent ·/ }));
}
export function draft(text: string) {
  fireEvent.change(screen.getByRole('textbox', { name: 'Follow-up prompt' }), {
    target: { value: text },
  });
}
beforeEach(() => {
  window.history.replaceState(null, '', '/');
  sessionStorage.clear();
  const storage = new Map<string, string>();
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => storage.set(key, value),
  });
  FakeEvents.instances = [];
  vi.stubGlobal('EventSource', FakeEvents);
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
