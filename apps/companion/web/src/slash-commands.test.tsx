import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import { SlashCommands, slashPickerOpen } from './slash-commands';
import type { Session, Snapshot } from './types';

afterEach(cleanup);
const session: Session = {
  id: 'session',
  name: 'Agent',
  agent: 'fixture',
  worktree: '/workspace',
  status: 'idle',
  commands: [
    { name: 'compact', description: 'Compact context' },
    { name: 'model', description: 'Provider model' },
  ],
  models: {
    current: 'first',
    choices: [
      { id: 'first', name: 'First' },
      { id: 'second', name: 'Second' },
    ],
  },
  modes: {
    current: 'plan',
    choices: [
      { id: 'plan', name: 'Plan' },
      { id: 'build', name: 'Build' },
    ],
  },
};
const snapshot: Snapshot = {
  connected: true,
  cursor: '1',
  sessions: [session],
  workspaces: [],
  worktrees: [],
  inbox: [],
};
function menu(prompt: string, disabled = false) {
  const choose = vi.fn();
  render(
    <SlashCommands
      prompt={prompt}
      session={session}
      snapshot={snapshot}
      disabled={disabled}
      onChoose={choose}
      onAction={vi.fn()}
    />,
  );
  return choose;
}

it('offers built-in and advertised commands and selects drafts', async () => {
  const choose = menu('/');
  expect(screen.getAllByRole('button')).toHaveLength(7);
  await userEvent.click(screen.getByRole('button', { name: '/compact — Compact context' }));
  expect(choose).toHaveBeenCalledWith('/compact');
});

it.each([
  ['model', 'Second (second)', '/model second'],
  ['mode', 'Build (build)', '/mode build'],
])('selects %s IDs without sending', async (kind, name, command) => {
  const choose = menu(`/${kind}`);
  await userEvent.click(screen.getByRole('button', { name }));
  expect(choose).toHaveBeenCalledWith(command);
  expect(slashPickerOpen(`/${kind}`)).toBe(true);
  expect(slashPickerOpen(command)).toBe(false);
});

it('requires a board for new tickets and exposes assignment controls', () => {
  menu('/new-ticket requirements');
  expect(screen.getByText('Assign a board first.')).toBeTruthy();
  expect(screen.getByText('Assign board', { selector: 'summary' })).toBeTruthy();
});

it('offers readable exports and disables commands offline', async () => {
  const choose = menu('/export', true);
  await userEvent.click(screen.getByRole('button', { name: 'Also create an AI-formatted copy' }));
  expect(choose).not.toHaveBeenCalled();
});
