import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import { AssignmentStatus, BoardAssignment } from './task-assignment';
import type { Session, Snapshot } from './types';

afterEach(cleanup);
const session: Session = {
  id: 'agent',
  name: 'Brainstorm',
  agent: 'fixture',
  status: 'idle',
  worktree: '/repo',
  conversation: 'conversation',
  target: 'target',
};
const snapshot: Snapshot = {
  connected: true,
  cursor: '1',
  epoch: 'epoch',
  sessions: [session],
  inbox: [],
  workspaces: [{ root: '/repo', name: 'Repo' }],
  worktrees: [{ path: '/repo', workspace: '/repo' }],
  boards: [
    { workspace: '/repo', id: 'ideas', title: 'Ideas' },
    { workspace: '/outside', id: 'outside', title: 'Outside' },
  ],
};

it('assigns a workspace board and requires explicit replacement of a ticket binding', async () => {
  const onAction = vi.fn().mockResolvedValue(true);
  const assigned = {
    ...session,
    assignment: { workspace_root: '/repo', board_id: 'ideas', ticket_id: 'ticket-1' },
  };
  render(
    <BoardAssignment session={assigned} snapshot={snapshot} disabled={false} onAction={onAction} />,
  );
  await userEvent.click(screen.getByText('Assign board', { selector: 'summary' }));
  expect(screen.queryByRole('option', { name: /Outside/ })).toBeNull();
  const button = screen.getByRole('button', { name: 'Assign board' });
  expect((button as HTMLButtonElement).disabled).toBe(true);
  await userEvent.click(screen.getByRole('checkbox'));
  await userEvent.click(button);
  expect(onAction).toHaveBeenCalledWith('session_assign_board', {
    session: 'agent',
    conversation: 'conversation',
    target: 'target',
    workspace: '/repo',
    board_id: 'ideas',
    replace: true,
  });
});

it('shows assigned ticket state and updates to board-only status', () => {
  const { rerender } = render(
    <AssignmentStatus
      session={{
        ...session,
        assignment: {
          workspace_root: '/repo',
          board_id: 'ideas',
          board_title: 'Ideas',
          ticket_id: 'ticket-1',
          ticket_title: 'Design flow',
          ticket_state: 'review',
        },
      }}
    />,
  );
  expect(screen.getByText('Board: Ideas [ideas]')).toBeTruthy();
  expect(screen.getByText('Assigned ticket: Design flow [ticket-1] · review')).toBeTruthy();
  rerender(
    <AssignmentStatus
      session={{ ...session, assignment: { workspace_root: '/repo', board_id: 'ideas' } }}
    />,
  );
  expect(screen.getByText('Assigned ticket: None (board-only session)')).toBeTruthy();
});
