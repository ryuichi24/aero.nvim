import { cleanup, render, screen } from '@testing-library/react';
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

it('keeps checklists in history without the legacy pinned panel', () => {
  const session: Session = {
    id: 'test',
    name: 'Agent',
    agent: 'opencode',
    worktree: '/repo',
    status: 'busy',
    blocks: [{ kind: 'plan', entries }],
  };
  render(<Transcript session={session} />);
  expect(screen.getByRole('article', { name: 'Agent plan' })).toBeTruthy();
  expect(screen.queryByText('Agent todos')).toBeNull();
});
