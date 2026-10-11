import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { TodoNotifications } from './todo-notifications';
import type { Session, Snapshot } from './types';

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});
const session = (id: string, status?: string): Session => ({
  id,
  name: id,
  agent: 'opencode-acp',
  worktree: '/repo',
  conversation: 'one',
  status: 'busy',
  blocks: status
    ? [
        {
          kind: 'tool',
          title: 'Update task list',
          rawInput: { todos: [{ content: 'Implement feature', status }] },
        },
      ]
    : [],
});
const snapshot = (sessions: Session[], timeout = 15000): Snapshot => ({
  connected: true,
  cursor: '1',
  epoch: 'host',
  sessions,
  inbox: [],
  workspaces: [],
  worktrees: [],
  companion: { ui: { todo_notification_timeout: timeout } },
});

it('places Todos in the shared and fullscreen headers and restores focus after dismissal', async () => {
  render(
    <>
      <header data-testid="app-header">
        <span id="todo-controls" />
      </header>
      <dialog data-testid="fullscreen">
        <header>
          <span data-todo-trigger />
        </header>
      </dialog>
      <TodoNotifications snapshot={snapshot([session('Agent', 'pending')], 0)} />
    </>,
  );
  const header = screen.getByTestId('app-header');
  await waitFor(() =>
    expect(header.contains(screen.getByRole('button', { name: 'Todos' }))).toBe(true),
  );
  const trigger = screen.getByRole('button', { name: 'Todos' });
  expect(trigger.closest('.todo-notifications')).toBeNull();
  fireEvent.click(trigger);
  const card = screen.getByLabelText('Agent todo notification');
  fireEvent.keyDown(card, { key: 'Escape' });
  expect(document.activeElement).toBe(trigger);
  const dialog = screen.getByTestId('fullscreen');
  await act(async () => dialog.setAttribute('open', ''));
  expect(
    dialog.querySelector('header')!.contains(screen.getByRole('button', { name: 'Todos' })),
  ).toBe(true);
  await act(async () => dialog.removeAttribute('open'));
  expect(header.contains(screen.getByRole('button', { name: 'Todos' }))).toBe(true);
  expect(screen.getAllByRole('button', { name: 'Todos' })).toHaveLength(1);
});

it('notifies first creation for every background session without moving focus or replaying history', () => {
  const view = render(
    <TodoNotifications
      snapshot={snapshot([session('Old', 'completed'), session('OpenCode'), session('Claude')])}
    />,
  );
  expect(screen.queryByLabelText('Old todo notification')).toBeNull();
  const focus = document.activeElement;
  view.rerender(
    <TodoNotifications
      snapshot={snapshot([
        session('Old', 'completed'),
        session('OpenCode', 'in_progress'),
        session('Claude', 'pending'),
      ])}
    />,
  );
  expect(screen.getByLabelText('OpenCode todo notification')).toBeTruthy();
  expect(screen.getByLabelText('Claude todo notification')).toBeTruthy();
  expect(document.activeElement).toBe(focus);
  fireEvent.click(screen.getByRole('button', { name: 'Dismiss Claude todos' }));
  view.rerender(
    <TodoNotifications
      snapshot={snapshot([
        session('Old', 'completed'),
        session('OpenCode', 'in_progress'),
        session('Claude', 'pending'),
      ])}
    />,
  );
  expect(screen.queryByLabelText('Claude todo notification')).toBeNull();
  view.rerender(
    <TodoNotifications
      snapshot={snapshot([
        session('Old', 'completed'),
        session('OpenCode', 'completed'),
        session('Claude', 'completed'),
      ])}
    />,
  );
  expect(screen.getByLabelText('Claude todo notification')).toBeTruthy();
  view.rerender(<TodoNotifications snapshot={snapshot([])} />);
  expect(screen.queryByLabelText('Claude todo notification')).toBeNull();
});

it.each([
  {
    name: 'starting snapshots',
    starting: true,
    status: 'stopped' as const,
    conversation: undefined,
  },
  { name: 'unobserved startup', starting: false, status: 'stopped' as const, conversation: 'one' },
  {
    name: 'conversation replacement',
    starting: false,
    status: 'busy' as const,
    conversation: 'one',
  },
])(
  'does not notify restored todos on resume with $name, but still notifies live changes',
  ({ starting, status, conversation }) => {
    const view = render(
      <TodoNotifications
        snapshot={snapshot([{ ...session('Agent', 'pending'), status, conversation }], 0)}
      />,
    );
    if (starting) {
      view.rerender(
        <TodoNotifications
          snapshot={snapshot(
            [{ ...session('Agent', 'pending'), conversation: 'resumed', status: 'starting' }],
            0,
          )}
        />,
      );
      expect(screen.queryByLabelText('Agent todo notification')).toBeNull();
    }
    view.rerender(
      <TodoNotifications
        snapshot={snapshot(
          [{ ...session('Agent', 'in_progress'), conversation: 'resumed', status: 'idle' }],
          0,
        )}
      />,
    );
    expect(screen.queryByLabelText('Agent todo notification')).toBeNull();
    // Restored history remains available on demand.
    fireEvent.click(screen.getByRole('button', { name: 'Todos' }));
    expect(screen.getByLabelText('Agent todo notification')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss Agent todos' }));
    view.rerender(
      <TodoNotifications
        snapshot={snapshot([{ ...session('Agent', 'completed'), conversation: 'resumed' }], 0)}
      />,
    );
    expect(screen.getByLabelText('Agent todo notification')).toBeTruthy();
  },
);

it('expires, resets only on todo changes, reopens, and pauses while focused', () => {
  vi.useFakeTimers();
  const view = render(<TodoNotifications snapshot={snapshot([session('Agent')], 1000)} />);
  view.rerender(<TodoNotifications snapshot={snapshot([session('Agent', 'pending')], 1000)} />);
  act(() => vi.advanceTimersByTime(700));
  view.rerender(<TodoNotifications snapshot={snapshot([session('Agent', 'in_progress')], 1000)} />);
  act(() => vi.advanceTimersByTime(700));
  expect(screen.getByLabelText('Agent todo notification')).toBeTruthy();
  view.rerender(<TodoNotifications snapshot={snapshot([session('Agent', 'in_progress')], 1000)} />);
  act(() => vi.advanceTimersByTime(400));
  expect(screen.queryByLabelText('Agent todo notification')).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Todos' }));
  const card = screen.getByLabelText('Agent todo notification');
  expect(document.activeElement).toBe(card);
  act(() => vi.advanceTimersByTime(2000));
  expect(card.isConnected).toBe(true);
  fireEvent.blur(card, { relatedTarget: document.body });
  act(() => vi.advanceTimersByTime(1000));
  expect(screen.queryByLabelText('Agent todo notification')).toBeNull();
});

it('supports persistent popups, disabling, fullscreen portals, and conversation replacement', async () => {
  const view = render(<TodoNotifications snapshot={snapshot([session('Agent')], 0)} />);
  view.rerender(<TodoNotifications snapshot={snapshot([session('Agent', 'pending')], 0)} />);
  const dialog = document.createElement('dialog');
  dialog.setAttribute('open', '');
  await act(async () => {
    document.body.append(dialog);
  });
  expect(dialog.contains(screen.getByLabelText('Agent todo notification'))).toBe(true);
  view.rerender(
    <TodoNotifications snapshot={snapshot([{ ...session('Agent'), conversation: 'two' }], 0)} />,
  );
  expect(screen.queryByLabelText('Agent todo notification')).toBeNull();
  view.rerender(
    <TodoNotifications
      snapshot={{
        ...snapshot([session('Agent', 'pending')]),
        companion: { ui: { todo_notifications: false } },
      }}
    />,
  );
  expect(screen.queryByRole('button', { name: 'Todos' })).toBeNull();
  await act(async () => {
    dialog.remove();
  });
});
