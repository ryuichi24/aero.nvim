import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { latestTodos } from './agent-todos';
import { Transcript } from './transcript';
import type { Session } from './types';

afterEach(cleanup);

const entries = [
  { content: 'Inspect the code', status: 'completed' },
  { content: 'Implement the feature', status: 'in_progress', priority: 'high' },
  { content: 'Verify the result', status: 'pending' },
];

it('uses the latest plan or todo tool snapshot and respects explicit clearing', () => {
  const plan = { kind: 'plan', entries };
  expect(latestTodos([plan, { kind: 'agent', text: 'Still working' }])).toEqual(entries);
  expect(
    latestTodos([plan, { kind: 'tool', title: 'functions.todowrite', rawInput: { todos: [] } }]),
  ).toEqual([]);
  expect(
    latestTodos([
      plan,
      { kind: 'tool', title: 'todowrite', status: 'failed', rawInput: { todos: [] } },
    ]),
  ).toEqual(entries);
  expect(
    latestTodos([{ kind: 'tool', title: 'todoread', rawOutput: JSON.stringify(entries) }]),
  ).toEqual(entries);
  expect(
    latestTodos([plan, { kind: 'tool', title: 'todowrite', rawInput: '{unfinished' }]),
  ).toEqual(entries);
  expect(
    latestTodos([{ kind: 'tool', title: 'bash', rawOutput: JSON.stringify(entries) }]),
  ).toBeUndefined();
});

it('keeps the live panel outside scrolling logs and updates it in fullscreen', () => {
  const session: Session = {
    id: 'test',
    name: 'Agent',
    agent: 'opencode',
    worktree: '/repo',
    status: 'busy',
    blocks: [{ kind: 'plan', entries }],
  };
  const view = render(<Transcript session={session} />);
  const summary = screen.getByText('Agent todos');
  const panel = summary.closest('details')!;
  expect(within(panel).getByText('1/3 completed')).toBeTruthy();
  expect(within(panel).getByText('Working on: Implement the feature')).toBeTruthy();
  expect(screen.getByRole('region', { name: 'Conversation transcript' }).contains(panel)).toBe(
    false,
  );
  fireEvent.click(summary);
  const dialog = screen.getByRole<HTMLDialogElement>('dialog', { hidden: true });
  dialog.showModal = () => dialog.setAttribute('open', '');
  dialog.close = () => dialog.removeAttribute('open');
  fireEvent.click(screen.getByRole('button', { name: 'Fullscreen logs' }));
  expect(dialog.contains(panel)).toBe(true);
  view.rerender(
    <Transcript
      session={{
        ...session,
        blocks: [
          { kind: 'plan', entries: entries.map((entry) => ({ ...entry, status: 'completed' })) },
        ],
      }}
    />,
  );
  expect(within(panel).getByText('3/3 completed')).toBeTruthy();
  expect(within(panel).queryByText(/Working on:/)).toBeNull();
  view.rerender(<Transcript session={{ ...session, id: 'other', blocks: [] }} />);
  expect(screen.queryByText('Agent todos')).toBeNull();
});
