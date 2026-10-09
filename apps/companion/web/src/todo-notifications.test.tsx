import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
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
