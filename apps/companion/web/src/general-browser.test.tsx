import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import { SessionBrowser } from './session-browser';
import type { Snapshot } from './types';

afterEach(cleanup);

const snapshot: Snapshot = {
  connected: true,
  cursor: '1',
  epoch: 'host',
  inbox: [],
  workspaces: [],
  worktrees: [],
  agents: ['fixture'],
  default_agent: 'fixture',
  sessions: [
    {
      id: 'general',
      name: 'Personal notes',
      agent: 'fixture',
      worktree: '/state/general',
      scope: 'general',
      status: 'stopped',
      target: 'target',
      blocks: [{ kind: 'message', text: 'Remember refresh tokens' }],
    },
    {
      id: 'old',
      name: 'Old chat',
      agent: 'fixture',
      worktree: '/state/general',
      scope: 'general',
      status: 'stopped',
      archived: true,
      target: 'old-target',
    },
  ],
};

it('finds and opens general history without resuming, and manages pin/archive state', async () => {
  const user = userEvent.setup();
  const onSelect = vi.fn();
  const onAction = vi.fn().mockResolvedValue(true);
  render(
    <SessionBrowser
      snapshot={snapshot}
      selected={null}
      active
      onSelect={onSelect}
      onAction={onAction}
      actionsDisabled={false}
    />,
  );
  expect(screen.queryByRole('button', { name: /Personal notes/ })).toBeNull();
  await user.click(screen.getByRole('button', { name: 'General' }));
  await user.type(
    screen.getByRole('searchbox', { name: 'Search general history' }),
    'refresh tokens',
  );
  await user.click(screen.getByRole('button', { name: /Personal notes/ }));
  expect(onSelect).toHaveBeenCalledWith({ id: 'general', conversation: undefined });
  expect(onAction).not.toHaveBeenCalled();
  await user.click(screen.getByText('Preview history'));
  expect(screen.getByText('Remember refresh tokens')).toBeTruthy();
  await user.click(screen.getByRole('button', { name: 'Pin' }));
  expect(onAction).toHaveBeenLastCalledWith('session_update', {
    session: 'general',
    target: 'target',
    field: 'pinned',
    value: true,
  });
  await user.click(screen.getByRole('button', { name: 'Archive' }));
  expect(onAction).toHaveBeenLastCalledWith('session_update', {
    session: 'general',
    target: 'target',
    field: 'archived',
    value: true,
  });
  await user.clear(screen.getByRole('searchbox', { name: 'Search general history' }));
  await user.click(screen.getByRole('button', { name: 'Show archived chats' }));
  expect(screen.getByRole('button', { name: /Old chat/ })).toBeTruthy();
  await user.click(screen.getByRole('button', { name: 'Restore' }));
  expect(onAction).toHaveBeenLastCalledWith('session_update', {
    session: 'old',
    target: 'old-target',
    field: 'archived',
    value: false,
  });
});

it('creates general chats without a workspace and offers the default agent', async () => {
  const user = userEvent.setup();
  const onAction = vi.fn().mockResolvedValue(true);
  render(
    <SessionBrowser
      snapshot={snapshot}
      selected={null}
      active
      onSelect={vi.fn()}
      onAction={onAction}
      actionsDisabled={false}
    />,
  );
  await user.click(screen.getByRole('button', { name: 'General' }));
  await user.click(screen.getByText('New general chat', { selector: 'summary' }));
  const region = screen.getByRole('region', { name: 'General conversations' });
  expect((within(region).getByRole('combobox', { name: 'Agent' }) as HTMLSelectElement).value).toBe(
    'default',
  );
  await user.type(
    within(region).getByRole('textbox', { name: 'Session name (optional)' }),
    'My question',
  );
  await user.click(within(region).getByRole('button', { name: 'New general chat' }));
  expect(onAction).toHaveBeenCalledWith('session_create', {
    scope: 'general',
    agent: 'default',
    name: 'My question',
  });
});
