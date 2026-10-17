// Draft editing and local command pickers; submission delegates to the action owner.
import type { RefObject } from 'react';
import { useCompanionDispatch, useCompanionState } from '../companion-context';
import { draftKey } from '../companion-state';
import { ReportCommand } from '../report-command';
import { PromptCommand } from '../prompt-command';
import { ReferenceCommand } from '../reference-browser';
import { SlashCommands, slashPickerOpen } from '../slash-commands';
import type { ActionData, ActionPath, Session, Snapshot } from '../types';

export function PromptComposer({
  session,
  snapshot,
  promptRef,
  onAction,
}: {
  session: Session | undefined;
  snapshot: Snapshot | null;
  promptRef: RefObject<HTMLTextAreaElement | null>;
  onAction: (path: ActionPath, extra?: Partial<ActionData>) => Promise<boolean>;
}) {
  const { selected, drafts, online, connection, pending, retry } = useCompanionState();
  const dispatch = useCompanionDispatch();
  const prompt = drafts[draftKey(selected)] || '';
  const disabled =
    !online ||
    !session?.conversation ||
    ['exited', 'stopped'].includes(session.status) ||
    !!session.assignment?.pending ||
    !!pending;
  const actionBlockReason = !online
    ? `${connection}. Sending and cancellation are unavailable until the connection returns.`
    : !session?.conversation
      ? 'This conversation is unavailable. Select or resume a session to send a prompt.'
      : pending
        ? retry
          ? 'The previous action has an unknown outcome. Retry the identical action before sending another prompt.'
          : 'Sending is paused while the previous action is being processed.'
        : ['exited', 'stopped'].includes(session.status)
          ? 'This session is stopped. Resume it to send a prompt.'
          : session.assignment?.pending
            ? 'Sending is paused while the session’s board assignment is being updated.'
            : null;
  const exporting = /^\/export(?: readable)?$/.test(prompt.trim());
  const composerBlockReason =
    exporting && online && session?.conversation && !pending ? null : actionBlockReason;
  const sendBlockReason =
    composerBlockReason ||
    (slashPickerOpen(prompt)
      ? prompt.trim() === '/report'
        ? 'Select or create a report below to complete this command.'
        : `Choose a ${prompt.trim().slice(1)} below to complete this command.`
      : null);
  const choose = (value: string) => dispatch({ type: 'draft', value });

  return (
    <form
      id="compose"
      onSubmit={(event) => {
        event.preventDefault();
        if (!sendBlockReason) onAction('prompt', { text: prompt });
      }}
    >
      <label>
        <span className="sr-only">Follow-up prompt</span>
        <textarea
          ref={promptRef}
          rows={2}
          placeholder="What should the agent do next? Type / for commands."
          required
          value={prompt}
          onChange={(event) => choose(event.target.value)}
        />
      </label>
      {session && snapshot && (
        <SlashCommands
          prompt={prompt}
          session={session}
          snapshot={snapshot}
          disabled={!!composerBlockReason}
          onChoose={choose}
          onAction={onAction}
        />
      )}
      {session && prompt.trim() === '/prompt' && (
        <PromptCommand
          key={`${snapshot?.epoch}:${session.id}:${session.conversation}`}
          session={session}
          epoch={snapshot?.epoch}
          online={online && !pending}
          onChoose={choose}
        />
      )}
      {session && prompt.trim() === '/report' && (
        <ReportCommand
          key={`${session.id}:${session.conversation}`}
          worktree={session.worktree}
          online={online && !pending}
          onChoose={choose}
        />
      )}
      {session && ['/reference', '/context'].includes(prompt.trim()) && (
        <ReferenceCommand
          worktree={session.worktree}
          online={online && !pending}
          onChoose={choose}
        />
      )}
      <div className="composer-toolbar">
        <details className="composer-actions">
          <summary aria-label="Prompt actions">Actions</summary>
          <div className="quick-actions">
            {['report', 'reference', 'model', 'mode', 'export'].map((command) => (
              <button
                key={command}
                type="button"
                disabled={!!prompt.trim()}
                onClick={(event) => {
                  choose(`/${command}`);
                  const details = event.currentTarget.closest('details');
                  if (details) details.open = false;
                }}
              >
                {command === 'report'
                  ? 'Select or create report'
                  : command === 'reference'
                    ? 'Select reference'
                    : command === 'export'
                      ? 'Export transcript'
                      : `Change ${command}`}
              </button>
            ))}
          </div>
          {!!prompt.trim() && (
            <p className="text-sm text-slate-400">
              Your draft is kept. Clear it before choosing a different prompt action.
            </p>
          )}
        </details>
        <button
          className="primary-action"
          id="send"
          aria-label="Send prompt"
          disabled={!!sendBlockReason}
          aria-describedby={sendBlockReason ? 'send-block-reason' : undefined}
        >
          Send
        </button>
        <button
          id="cancel"
          type="button"
          aria-label="Cancel turn & queue"
          title="Cancel the current turn and queued prompts"
          disabled={disabled}
          aria-describedby={
            disabled
              ? composerBlockReason
                ? 'send-block-reason'
                : 'cancel-block-reason'
              : undefined
          }
          onClick={() => onAction('cancel')}
        >
          Cancel
        </button>
      </div>
      {sendBlockReason && (
        <p id="send-block-reason" role="status" className="mt-2 text-sm text-amber-300">
          {sendBlockReason} Your draft is kept here.
        </p>
      )}
      {disabled && !composerBlockReason && (
        <p id="cancel-block-reason" role="status" className="mt-2 text-sm text-amber-300">
          Cancellation is unavailable. {actionBlockReason}
        </p>
      )}
    </form>
  );
}
