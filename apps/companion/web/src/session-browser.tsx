import { useEffect, useId, useMemo, useReducer, useRef, useState } from 'react';
import { filterGroups, groupSessions, pathName, sessionLocation } from './sessionGroups';
import { browserReducer, initialBrowserState } from './session-browser-state';
import type { Selection, Session, Snapshot } from './types';
import { LifecycleForm } from './lifecycle-controls';
import type { LifecycleAction } from './lifecycle-controls';
import { SessionCreate } from './session-create';

function countLabel(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? '' : 's'}`;
}

function AttentionCount({ sessions }: { sessions: Session[] }) {
  const waiting = sessions.filter((session) => session.status === 'waiting').length;
  return waiting ? <span className="navigation-attention">{waiting} waiting</span> : null;
}

interface Props {
  snapshot: Snapshot | null;
  selected: Selection | null;
  active: boolean;
  onSelect: (selection: Selection) => void;
  onAction?: LifecycleAction;
  actionsDisabled?: boolean;
  creationRequest?: number;
}

export function SessionBrowser({
  snapshot,
  selected,
  active,
  onSelect,
  onAction,
  actionsDisabled = true,
  creationRequest = 0,
}: Props) {
  const groups = useMemo(() => (snapshot ? groupSessions(snapshot) : []), [snapshot]);
  const [grouped, setGrouped] = useState(false);
  const [filter, setFilter] = useState('all');
  useEffect(() => {
    if (creationRequest) {
      setGrouped(false);
      setFilter('all');
    }
  }, [creationRequest]);
  const id = useId();
  const currentButton = useRef<HTMLButtonElement>(null);
  const location = sessionLocation(groups, selected);
  const workspaceKey = location?.workspace.key;
  const worktreePath = location?.worktree.path;

  const navigationKey = JSON.stringify([
    active,
    workspaceKey,
    worktreePath,
    selected?.id,
    selected?.conversation,
  ]);
  const input = { groups, navigationKey, active, workspaceKey, worktreePath };
  const [state, dispatch] = useReducer(browserReducer, input, initialBrowserState);
  // Adjust this component's state before committing children, rather than
  // committing stale disclosures and fixing them in an effect. The guard
  // converges on the next render and ignores status-only navigation changes.
  if (state.input.groups !== groups || state.input.navigationKey !== navigationKey) {
    dispatch({ type: 'reconcile', input });
  }
  const { query, openWorkspaces, openWorktrees } = state;

  // Returning from a transcript/inbox reveals its exact location. Status-only SSE
  // updates must not undo the user's disclosure choices or change search text.
  useEffect(() => {
    if (!active || !workspaceKey || !worktreePath) return;
    const timer = window.setTimeout(() => {
      currentButton.current?.scrollIntoView?.({ block: 'nearest' });
      currentButton.current?.focus({ preventScroll: true });
    }, 0);
    return () => window.clearTimeout(timer);
  }, [active, workspaceKey, worktreePath, selected?.id, selected?.conversation, grouped]);

  const matchesStatus = (session: Session) =>
    filter === 'all' ||
    (filter === 'running' && ['busy', 'starting'].includes(session.status)) ||
    (filter === 'attention' && session.status === 'waiting') ||
    (filter === 'stopped' && ['stopped', 'exited'].includes(session.status));
  const filtered = filterGroups(groups, query)
    .map((workspace) => ({
      ...workspace,
      worktrees: workspace.worktrees
        .map((tree) => ({ ...tree, sessions: tree.sessions.filter(matchesStatus) }))
        .filter((tree) => filter === 'all' || tree.sessions.length > 0),
    }))
    .filter((workspace) => filter === 'all' || workspace.worktrees.length > 0);
  const searching = !!query.trim();
  return (
    <section id="sessions" hidden={!active} aria-labelledby="sessions-title">
      <h2 id="sessions-title">Agent sessions</h2>
      <p className="navigation-help">Find your agents or manage workspaces and worktrees.</p>
      {onAction && !grouped && (
        <SessionCreate
          snapshot={snapshot}
          disabled={actionsDisabled}
          onAction={onAction}
          request={creationRequest}
        />
      )}
      <div className="local-nav" aria-label="Session filters">
        {[
          ['all', 'All'],
          ['running', 'Running'],
          ['attention', 'Needs attention'],
          ['stopped', 'Stopped'],
        ].map(([value, label]) => (
          <button key={value} aria-pressed={filter === value} onClick={() => setFilter(value)}>
            {label}
          </button>
        ))}
      </div>
      <button aria-pressed={grouped} onClick={() => setGrouped(!grouped)}>
        {grouped ? 'Show flat session list' : 'Group by workspace/worktree'}
      </button>
      <label className="session-search">
        Search sessions, worktrees, or workspaces
        <input
          type="search"
          value={query}
          placeholder="Name, branch, agent, or status"
          onChange={(event) => dispatch({ type: 'search', query: event.target.value })}
        />
      </label>
      {query && (
        <button className="clear-search" onClick={() => dispatch({ type: 'search', query: '' })}>
          Clear search
        </button>
      )}
      {!snapshot && <p className="navigation-empty">Pair your device to browse sessions.</p>}
      {snapshot && !snapshot.connected && (
        <p className="navigation-empty">
          Neovim unavailable. Sessions will return when it reconnects.
        </p>
      )}
      {snapshot?.connected && filtered.length === 0 && (
        <p className="navigation-empty">
          {searching || filter !== 'all'
            ? 'No matching sessions or worktrees.'
            : 'No workspaces or ACP sessions available.'}
        </p>
      )}
      {!grouped && (
        <div className="home-session-list">
          {filtered.flatMap((workspace) =>
            workspace.worktrees.flatMap((tree) =>
              tree.sessions
                .filter(
                  (session) =>
                    filter === 'all' ||
                    (filter === 'running' && ['busy', 'starting'].includes(session.status)) ||
                    (filter === 'attention' && session.status === 'waiting') ||
                    (filter === 'stopped' && ['stopped', 'exited'].includes(session.status)),
                )
                .map((session) => (
                  <button
                    key={session.id}
                    ref={
                      selected?.id === session.id && selected.conversation === session.conversation
                        ? currentButton
                        : undefined
                    }
                    aria-current={
                      selected?.id === session.id && selected.conversation === session.conversation
                        ? 'page'
                        : undefined
                    }
                    className="session-button"
                    aria-label={`${session.name} · ${session.status} · ${session.agent}`}
                    onClick={() => onSelect({ id: session.id, conversation: session.conversation })}
                  >
                    <span className="session-line">
                      <strong>{session.name}</strong>
                      <span className={`status-badge status-${session.status}`}>
                        {session.status}
                      </span>
                    </span>
                    <span className="session-agent">
                      {workspace.name} · {tree.label} · {session.activity || session.agent}
                    </span>
                    {session.assignment && (
                      <span>
                        {session.assignment.ticket_title || session.assignment.board_title}
                      </span>
                    )}
                  </button>
                )),
            ),
          )}
        </div>
      )}
      {grouped && (
        <div className="workspace-list">
          {filtered.map((workspace) => {
            const allSessions = workspace.worktrees.flatMap((worktree) => worktree.sessions);
            const stateKey = searching
              ? JSON.stringify([query.trim().toLocaleLowerCase(), workspace.key])
              : workspace.key;
            const expanded = openWorkspaces[stateKey] ?? (searching || groups.length === 1);
            const panelID = `${id}-workspace-${encodeURIComponent(workspace.key)}`;
            return (
              <div
                className="workspace-group"
                key={workspace.key}
                role="group"
                aria-label={`Workspace ${workspace.name}`}
              >
                <h3>
                  <button
                    className="workspace-toggle"
                    aria-expanded={expanded}
                    aria-controls={panelID}
                    onClick={() =>
                      dispatch({ type: 'workspace', key: stateKey, expanded: !expanded })
                    }
                  >
                    <span className="navigation-chevron" aria-hidden="true">
                      {expanded ? '▾' : '▸'}
                    </span>
                    <span className="navigation-label">
                      <span className="workspace-name">{workspace.name}</span>
                      {workspace.root && <span className="navigation-path">{workspace.root}</span>}
                      <span className="navigation-count">
                        {countLabel(workspace.worktrees.length, 'worktree')} ·{' '}
                        {countLabel(allSessions.length, 'session')}
                      </span>
                    </span>
                    <AttentionCount sessions={allSessions} />
                  </button>
                </h3>
                <div className="workspace-worktrees" id={panelID} hidden={!expanded}>
                  {onAction && workspace.root && (
                    <LifecycleForm
                      title="New worktree"
                      path="worktree_create"
                      data={{ workspace: workspace.root }}
                      field="branch"
                      disabled={actionsDisabled}
                      onAction={onAction}
                    />
                  )}
                  {workspace.worktrees.length === 0 && (
                    <p className="navigation-empty">No worktrees available.</p>
                  )}
                  {workspace.worktrees.map((worktree) => {
                    const worktreeStateKey = searching
                      ? JSON.stringify([query.trim().toLocaleLowerCase(), worktree.path])
                      : worktree.path;
                    const worktreeExpanded =
                      openWorktrees[worktreeStateKey] ??
                      (searching || workspace.worktrees.length === 1);
                    const worktreeID = `${id}-worktree-${encodeURIComponent(worktree.path)}`;
                    return (
                      <div
                        className="worktree-group"
                        key={worktree.path}
                        role="group"
                        aria-label={`Worktree ${worktree.label}`}
                      >
                        <h4>
                          <button
                            className="worktree-toggle"
                            aria-expanded={worktreeExpanded}
                            aria-controls={worktreeID}
                            onClick={() =>
                              dispatch({
                                type: 'worktree',
                                key: worktreeStateKey,
                                expanded: !worktreeExpanded,
                              })
                            }
                          >
                            <span className="navigation-chevron" aria-hidden="true">
                              {worktreeExpanded ? '▾' : '▸'}
                            </span>
                            <span className="navigation-label">
                              <span className="worktree-name">
                                {pathName(worktree.path)}{' '}
                                <span className="text-slate-400 font-normal">
                                  ({worktree.branch || 'detached'})
                                </span>
                              </span>
                              <span className="navigation-path">{worktree.path}</span>
                              <span className="navigation-count">
                                {countLabel(worktree.sessions.length, 'session')}
                              </span>
                            </span>
                            <AttentionCount sessions={worktree.sessions} />
                          </button>
                        </h4>
                        <div
                          className="worktree-sessions"
                          id={worktreeID}
                          hidden={!worktreeExpanded}
                        >
                          {onAction && workspace.root && (
                            <>
                              <LifecycleForm
                                title="New AI session"
                                path="session_create"
                                data={{ workspace: workspace.root, worktree: worktree.path }}
                                agents={snapshot?.agents || []}
                                field="name"
                                disabled={actionsDisabled}
                                onAction={onAction}
                              />
                              {worktree.branch && (
                                <LifecycleForm
                                  title="Rename worktree branch"
                                  path="worktree_rename"
                                  data={{
                                    workspace: workspace.root,
                                    worktree: worktree.path,
                                    target: worktree.target,
                                  }}
                                  field="name"
                                  initial={worktree.branch}
                                  disabled={actionsDisabled}
                                  onAction={onAction}
                                />
                              )}
                              {worktree.path !== workspace.root && (
                                <LifecycleForm
                                  title="Delete worktree"
                                  path="worktree_delete"
                                  data={{
                                    workspace: workspace.root,
                                    worktree: worktree.path,
                                    target: worktree.target,
                                  }}
                                  destructive
                                  force
                                  disabled={actionsDisabled}
                                  onAction={onAction}
                                />
                              )}
                            </>
                          )}
                          {worktree.sessions.length === 0 && (
                            <p className="navigation-empty">No ACP sessions in this worktree.</p>
                          )}
                          {worktree.sessions.map((session) => {
                            const current =
                              selected?.id === session.id &&
                              selected.conversation === session.conversation;
                            return (
                              <button
                                className="session-button"
                                key={session.id}
                                ref={current ? currentButton : undefined}
                                aria-current={current ? 'page' : undefined}
                                aria-label={`${session.name} · ${session.status} · ${session.agent}${current ? ' · current' : ''}`}
                                onClick={() =>
                                  onSelect({ id: session.id, conversation: session.conversation })
                                }
                              >
                                <span className="session-line">
                                  <span className="session-name">{session.name}</span>
                                  <span className={`status-badge status-${session.status}`}>
                                    {session.status}
                                  </span>
                                </span>
                                <span className="navigation-path">
                                  Board:{' '}
                                  {session.assignment?.board_title ||
                                    session.assignment?.board_id ||
                                    'None'}{' '}
                                  · Ticket:{' '}
                                  {session.assignment?.ticket_title ||
                                    session.assignment?.ticket_id ||
                                    'None'}
                                  {session.assignment?.ticket_state &&
                                    ` · ${session.assignment.ticket_state}`}
                                </span>
                                <span className="session-agent">
                                  {session.agent}
                                  {current ? ' · Selected' : ''}
                                </span>
                              </button>
                            );
                          })}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
