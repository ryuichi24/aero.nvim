import type { Session, Snapshot } from './types';
import type { LifecycleAction } from './lifecycle-controls';
import { BoardAssignment } from './task-assignment';

const builtins = [
  { name: 'report', description: 'Create or select a worktree report' },
  { name: 'model', description: 'Choose the session model' },
  { name: 'mode', description: 'Choose the session mode' },
  { name: 'cancel', description: 'Cancel the current turn and discard queued prompts' },
  { name: 'export', description: 'Save the conversation as Markdown on the host' },
  { name: 'new-ticket', description: 'Create a ticket on the assigned Aero board' },
];

export function slashPickerOpen(prompt: string) {
  return ['/report', '/model', '/mode'].includes(prompt.trim());
}

export function SlashCommands({
  prompt,
  session,
  snapshot,
  disabled,
  onChoose,
  onAction,
}: {
  prompt: string;
  session: Session;
  snapshot: Snapshot;
  disabled: boolean;
  onChoose: (text: string) => void;
  onAction: LifecycleAction;
}) {
  const text = prompt.trimStart();
  if (!text.startsWith('/')) return null;
  const kind = text.trim() === '/model' ? 'model' : text.trim() === '/mode' ? 'mode' : null;
  if (kind) {
    const options = kind === 'model' ? session.models : session.modes;
    return (
      <section aria-label={`${kind} command`}>
        <p>Choose a {kind}, then send the command.</p>
        {!options?.choices.length && <p>This agent does not expose {kind} selection over ACP.</p>}
        {options?.choices.map((choice) => (
          <button
            type="button"
            key={choice.id}
            disabled={disabled}
            onClick={() => onChoose(`/${kind} ${choice.id}`)}
            aria-pressed={choice.id === options.current}
          >
            {choice.group ? `${choice.group} / ` : ''}
            {choice.name} ({choice.id}){choice.id === options.current ? ' · current' : ''}
            {choice.description ? ` — ${choice.description}` : ''}
          </button>
        ))}
      </section>
    );
  }
  if (/^\/new-ticket(?:\s|$)/.test(text))
    return (
      <section aria-label="New ticket command">
        <p>
          Add the ticket requirements after /new-ticket, then send the prompt. The agent creates it
          through Aero MCP tools.
        </p>
        {!session.assignment && (
          <>
            <p>Assign a board first.</p>
            <BoardAssignment
              session={session}
              snapshot={snapshot}
              disabled={disabled}
              onAction={onAction}
            />
          </>
        )}
      </section>
    );
  if (text.trim() === '/export')
    return (
      <section aria-label="Export command">
        <p>Send to save the original Markdown log on the host.</p>
        <button type="button" disabled={disabled} onClick={() => onChoose('/export readable')}>
          Also create an AI-formatted copy
        </button>
        <p>An AI-formatted copy uses a separate agent conversation and tokens.</p>
      </section>
    );
  if (/\s/.test(text) || text === '/report') return null;
  const commands = [
    ...builtins,
    ...(session.commands || []).filter(
      (command) => !builtins.some((builtin) => builtin.name === command.name),
    ),
  ];
  const matches = commands.filter((command) => `/${command.name}`.startsWith(text));
  return (
    <section aria-label="Slash commands">
      {matches.map((command) => (
        <button
          type="button"
          key={command.name}
          disabled={disabled}
          onClick={() => onChoose(`/${command.name}`)}
        >
          /{command.name} — {command.description}
        </button>
      ))}
    </section>
  );
}
