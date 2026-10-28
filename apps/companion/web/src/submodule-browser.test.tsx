import { cleanup, render, screen, within, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { SubmoduleBrowser } from './submodule-browser';
import { SessionCreate } from './session-create';
import type { Snapshot } from './types';

const parent = { path: '/project', workspace: '/project', branch: 'main', target: 'parent-target' };
const root = '/project/libs/core';
const external = '/checkouts/core-fix';
const children = [
  { path: root, workspace: root, branch: 'main', target: 'child-main' },
  { path: external, workspace: root, branch: 'fix', target: 'child-fix' },
];
const snapshot: Snapshot = {
  connected: true,
  cursor: 'epoch:1',
  epoch: 'epoch',
  sessions: [],
  inbox: [],
  agents: ['fixture'],
  workspaces: [{ root: '/project', name: 'Project' }],
  worktrees: [parent],
};
const entries = [
  { name: 'libs/core', path: root, initialized: true },
  { name: 'libs/missing', path: '/project/libs/missing', initialized: false },
];

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function setup() {
  const fetch = vi.fn(async (_url: unknown, init?: RequestInit) => {
    const request = JSON.parse(String(init?.body));
    return new Response(
      JSON.stringify(
        request.path === root
          ? { loading: false, entries, workspace: root, worktrees: children }
          : { loading: false, entries },
      ),
    );
  });
  vi.stubGlobal('fetch', fetch);
  const onAction = vi.fn(async () => true);
  const onOpen = vi.fn();
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const view = render(
    <QueryClientProvider client={client}>
      <SubmoduleBrowser
        tree={parent}
        snapshot={snapshot}
        online
        disabled={false}
        onAction={onAction}
        onOpen={onOpen}
      />
    </QueryClientProvider>,
  );
  return { fetch, onAction, onOpen, client, view };
}

it('discovers each level only on expansion and shows uninitialized entries', async () => {
  const { fetch } = setup();
  expect(fetch).not.toHaveBeenCalled();
  await userEvent.click(screen.getByRole('button', { name: 'Submodules' }));
  const core = await screen.findByRole('group', { name: 'Submodule libs/core' });
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(screen.getByRole('button', { name: /libs\/missing/ }).hasAttribute('disabled')).toBe(true);
  await userEvent.click(within(core).getByRole('button', { name: /libs\/core/ }));
  expect(
    await screen.findByRole('group', { name: 'Submodule worktree core-fix (fix)' }),
  ).toBeTruthy();
  expect(screen.getByText(/in parent/)).toBeTruthy();
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(JSON.parse(fetch.mock.calls[1][1]?.body as string)).toMatchObject({
    epoch: 'epoch',
    target: 'parent-target',
    worktree: '/project',
    path: root,
  });
});

it('targets child repositories for lifecycle actions and external worktrees for browsing', async () => {
  const { onAction, onOpen } = setup();
  await userEvent.click(screen.getByRole('button', { name: 'Submodules' }));
  await userEvent.click(await screen.findByRole('button', { name: /libs\/core/ }));
  const externalTree = await screen.findByRole('group', {
    name: 'Submodule worktree core-fix (fix)',
  });
  await userEvent.click(within(externalTree).getByRole('button', { name: 'Browse checkout' }));
  expect(onOpen).toHaveBeenCalledWith(external);
  await userEvent.click(within(externalTree).getByText('New AI session', { selector: 'summary' }));
  await userEvent.type(
    within(externalTree).getByRole('textbox', { name: 'Session name (optional)' }),
    'Investigate',
  );
  await userEvent.click(within(externalTree).getByRole('button', { name: 'New AI session' }));
  expect(onAction).toHaveBeenCalledWith('session_create', {
    workspace: root,
    worktree: external,
    agent: 'fixture',
    name: 'Investigate',
  });
  await userEvent.click(
    within(externalTree).getByText('Rename worktree branch', { selector: 'summary' }),
  );
  const name = within(externalTree).getByRole('textbox', { name: 'New name' });
  await userEvent.clear(name);
  await userEvent.type(name, 'review');
  await userEvent.click(
    within(externalTree).getByRole('button', { name: 'Rename worktree branch' }),
  );
  expect(onAction).toHaveBeenCalledWith('worktree_rename', {
    workspace: root,
    worktree: external,
    target: 'child-fix',
    name: 'review',
  });
  const main = screen.getByRole('group', { name: 'Submodule worktree core (main)' });
  expect(within(main).queryByText('Delete worktree')).toBeNull();
});

it('retries failed discovery through explicit cache revalidation', async () => {
  const { fetch } = setup();
  fetch.mockResolvedValueOnce(
    new Response(JSON.stringify({ entries: [], loading: false, error: 'fixture failure' })),
  );
  await userEvent.click(screen.getByRole('button', { name: 'Submodules' }));
  expect(await screen.findByRole('alert')).toBeTruthy();
  await userEvent.click(screen.getByRole('button', { name: 'Refresh submodules' }));
  await screen.findByRole('group', { name: 'Submodule libs/core' });
  expect(JSON.parse(fetch.mock.calls[1][1]?.body as string).refresh).toBe(true);
});

it('keeps explicit submodule ownership in the flat new-session selector', async () => {
  const onAction = vi.fn(async () => true);
  render(
    <SessionCreate
      snapshot={{ ...snapshot, worktrees: [parent, ...children] }}
      disabled={false}
      onAction={onAction}
    />,
  );
  await userEvent.click(screen.getByText('New session', { selector: 'summary' }));
  await userEvent.selectOptions(
    screen.getByRole('combobox', { name: 'Session worktree' }),
    external,
  );
  await userEvent.click(screen.getByRole('button', { name: 'New AI session' }));
  await waitFor(() =>
    expect(onAction).toHaveBeenCalledWith('session_create', {
      workspace: root,
      worktree: external,
      agent: 'fixture',
    }),
  );
});

it('stops discovery polling when its section is collapsed', async () => {
  const { fetch } = setup();
  fetch.mockImplementation(
    async () => new Response(JSON.stringify({ entries: [], loading: true })),
  );
  await userEvent.click(screen.getByRole('button', { name: 'Submodules' }));
  await screen.findByRole('status');
  await userEvent.click(screen.getByRole('button', { name: 'Submodules' }));
  await new Promise((resolve) => setTimeout(resolve, 500));
  expect(fetch).toHaveBeenCalledTimes(1);
});
