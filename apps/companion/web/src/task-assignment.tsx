import { useState } from 'react';
import { Button } from './components/ui/button';
import { NativeSelect } from './components/ui/native-select';
import { Checkbox } from './components/ui/checkbox';
import { Collapsible, CollapsibleTrigger } from './components/ui/collapsible';
import { Label } from './components/ui/label';
import type { Session, Snapshot } from './types';
import type { LifecycleAction } from './lifecycle-controls';

export function AssignmentStatus({ session }: { session: Session }) {
  const assignment = session.assignment;
  return (
    <div className="my-2 text-sm text-slate-300" aria-label="Task assignment">
      <p>
        Board:{' '}
        {assignment
          ? `${assignment.board_title || assignment.board_id} [${assignment.board_id}]`
          : 'None'}
      </p>
      <p>
        Assigned ticket:{' '}
        {assignment?.ticket_id
          ? `${assignment.ticket_title || assignment.ticket_id} [${assignment.ticket_id}]${assignment.ticket_state ? ` · ${assignment.ticket_state}` : ''}`
          : assignment
            ? 'None (board-only session)'
            : 'None'}
      </p>
      {assignment?.pending && <p>Assigning…</p>}
      {assignment?.error && <p role="alert">Assignment unavailable: {assignment.error}</p>}
    </div>
  );
}

export function BoardAssignment({
  session,
  snapshot,
  disabled,
  onAction,
}: {
  session: Session;
  snapshot: Snapshot;
  disabled: boolean;
  onAction: LifecycleAction;
}) {
  const workspace = snapshot.worktrees.find((wt) => wt.path === session.worktree)?.workspace;
  const boards = (snapshot.boards || []).filter((board) => board.workspace === workspace);
  const [boardID, setBoardID] = useState('');
  const [replace, setReplace] = useState(false);
  const chosen = boards.find((board) => board.id === boardID) || boards[0];
  const replacing =
    !!session.assignment &&
    (session.assignment.board_id !== chosen?.id || !!session.assignment.ticket_id);
  return (
    <Collapsible className="my-2 rounded-lg border border-slate-700 p-2">
      <CollapsibleTrigger className="p-2">Assign board</CollapsibleTrigger>
      <form
        onSubmit={async (event) => {
          event.preventDefault();
          if (!chosen) return;
          if (
            await onAction('session_assign_board', {
              session: session.id,
              target: session.target,
              conversation: session.conversation,
              workspace: chosen.workspace,
              board_id: chosen.id,
              replace: replacing && replace,
            })
          )
            setReplace(false);
        }}
      >
        <Label>
          Board
          <NativeSelect
            value={chosen?.id || ''}
            onChange={(event) => {
              setBoardID(event.target.value);
              setReplace(false);
            }}
          >
            {boards.map((board) => (
              <option key={board.id} value={board.id}>
                {board.title} [{board.id}]
              </option>
            ))}
          </NativeSelect>
        </Label>
        {!boards.length && <p>Create and save a board in Neovim first.</p>}
        {replacing && (
          <Label>
            <Checkbox
              checked={replace}
              onCheckedChange={(checked) => setReplace(checked === true)}
            />{' '}
            Replace current board or ticket assignment
          </Label>
        )}
        <p className="text-sm text-slate-400">
          Assign an idle, resumed ACP session, then ask it to create tickets from your ideas.
        </p>
        <Button
          type="submit"
          disabled={
            disabled ||
            session.status !== 'idle' ||
            !!session.assignment?.pending ||
            !chosen ||
            (replacing && !replace)
          }
        >
          Assign board
        </Button>
      </form>
    </Collapsible>
  );
}
