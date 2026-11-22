// Conversation screen composition; server state, routing and action recovery are external.
import { useMemo, type RefObject } from 'react';
import { Button } from '../components/ui/button';
import { Collapsible, CollapsibleTrigger } from '../components/ui/collapsible';
import { useCompanionState } from '../companion-context';
import { groupSessions, sessionLocation } from '../sessionGroups';
import { Transcript } from '../transcript';
import { useSessionSnapshot } from '../connection/use-session-snapshot';
import { PromptComposer } from './prompt-composer';
import { SessionMetadata } from '../session-metadata';
import { AgentTodos, latestTodos } from '../agent-todos';
import { AssignmentStatus, BoardAssignment } from '../task-assignment';
import { LifecycleForm } from '../lifecycle-controls';
import { Screenshots } from '../screenshots';
import { Recordings } from '../recordings';
import type { Quote } from '../quote';
import type { View } from '../companion-state';
import type { SessionTab } from '../navigation/use-companion-route';
import type { ActionData, ActionPath, PendingAction, Snapshot } from '../types';

export function ConversationScreen({
  snapshot,
  tab,
  onTab,
  titleRef,
  reviewMenu,
  promptRef,
  navigate,
  onQuote,
  onAction,
  onRetry,
}: {
  snapshot: Snapshot | null;
  tab: SessionTab;
  onTab: (tab: SessionTab) => void;
  titleRef: RefObject<HTMLHeadingElement | null>;
  reviewMenu: RefObject<HTMLDetailsElement | null>;
  promptRef: RefObject<HTMLTextAreaElement | null>;
  navigate: (view: View, worktree?: string) => void;
  onQuote: (quote: Quote) => void;
  onAction: (path: ActionPath, extra?: Partial<ActionData>) => Promise<boolean>;
  onRetry: (action: PendingAction) => Promise<boolean>;
}) {
  const { selected, view, online, pending, notice, retry, submitting, pairing } =
    useCompanionState();
  const summary = snapshot?.sessions.find(
    (item) => item.id === selected?.id && item.conversation === selected?.conversation,
  );
  const history = useSessionSnapshot(summary, snapshot?.epoch, view === 'conversation' && online);
  const session = history.session;
  const location = useMemo(
    () => (snapshot ? sessionLocation(groupSessions(snapshot), selected) : undefined),
    [snapshot, selected],
  );
  if (!selected) return null;
  const disabled =
    !online ||
    !session?.conversation ||
    ['exited', 'stopped'].includes(session.status) ||
    !!session.assignment?.pending ||
    !!pending;
  const lifecycleDisabled = !online || !!pending || !session?.target;
  const resume = session && ['stopped', 'exited'].includes(session.status) && (
    <Button
      className="my-3 mr-3"
      disabled={lifecycleDisabled}
      onClick={() => onAction('session_resume', { session: session.id, target: session.target })}
    >
      Resume session
    </Button>
  );
  return (
    <section id="conversation" hidden={view !== 'conversation'}>
      <div className="session-heading">
        <Button
          variant="ghost"
          className="back-to-sessions"
          aria-label="← All sessions"
          title="All sessions"
          onClick={() => navigate('sessions')}
        >
          ←
        </Button>
        <h2 id="title" ref={titleRef} tabIndex={-1}>
          {session ? `${session.name} · ${session.status}` : 'Session or conversation unavailable'}
        </h2>
      </div>
      {session?.scope === 'general' && (
        <nav className="session-breadcrumb" aria-label="Current session location">
          <span>General</span>
          <span aria-hidden="true">/</span>
          <strong>{session.name}</strong>
        </nav>
      )}
      {location && (
        <nav className="session-breadcrumb" aria-label="Current session location">
          <span>{location.workspace.name}</span>
          <span aria-hidden="true">/</span>
          <span title={location.worktree.path}>{location.worktree.label}</span>
          <span aria-hidden="true">/</span>
          <strong>{location.session.name}</strong>
        </nav>
      )}
      <div className="session-navigation">
        <nav className="local-nav" aria-label="Session views">
          {(['conversation', 'artifacts', 'details'] as const).map((next) => (
            <Button
              variant="outline"
              key={next}
              aria-current={tab === next ? 'page' : undefined}
              onClick={() => onTab(next)}
            >
              {next === 'conversation'
                ? 'Conversation'
                : next === 'artifacts'
                  ? 'Artifacts'
                  : 'Details'}
            </Button>
          ))}
        </nav>
        {session && session.scope !== 'general' && (
          <Collapsible ref={reviewMenu} className="session-review-links">
            <CollapsibleTrigger aria-label="Review this worktree">Review</CollapsibleTrigger>
            <div className="session-review-menu">
              {(
                [
                  ['reports', 'Reports'],
                  ['reference', 'References'],
                  ['git', 'Changes'],
                  ['source', 'Source'],
                ] as const
              ).map(([next, label]) => (
                <Button variant="ghost" key={next} onClick={() => navigate(next, session.worktree)}>
                  {label} for this worktree
                </Button>
              ))}
            </div>
          </Collapsible>
        )}
      </div>
      <div hidden={tab !== 'details'}>
        {session && (
          <>
            <SessionMetadata session={session} />
            <AgentTodos todos={latestTodos(session.blocks || [])} />
            <div aria-label="Session actions">
              <AssignmentStatus session={session} />
              {snapshot && session.scope !== 'general' && (
                <BoardAssignment
                  key={session.id}
                  session={session}
                  snapshot={snapshot}
                  disabled={lifecycleDisabled}
                  onAction={onAction}
                />
              )}
              {resume}
              <LifecycleForm
                key={`rename:${session.id}`}
                title="Rename session"
                path="session_rename"
                data={{ session: session.id, target: session.target }}
                field="name"
                initial={session.name}
                disabled={lifecycleDisabled}
                onAction={onAction}
              />
              <LifecycleForm
                title="Delete session"
                path="session_delete"
                data={{ session: session.id, target: session.target }}
                destructive
                disabled={lifecycleDisabled}
                onAction={onAction}
              />
            </div>
          </>
        )}
      </div>
      <div hidden={tab !== 'artifacts'}>
        {session && (
          <>
            <Screenshots
              key={`screenshots:${session.id}:${session.conversation}`}
              session={session}
            />
            <Recordings
              key={`recordings:${session.id}:${session.conversation}`}
              session={session}
            />
          </>
        )}
      </div>
      <div className="session-conversation" hidden={tab !== 'conversation'}>
        {resume}
        {summary?.transcript_lazy && history.isLoading && (
          <p role="status">Loading saved conversation…</p>
        )}
        {summary?.transcript_lazy && history.isError && (
          <div role="alert" className="my-3 flex flex-wrap items-center gap-3">
            <span>Could not load conversation: {history.error.message}</span>
            <Button variant="outline" onClick={() => void history.refetch()}>
              Retry loading logs
            </Button>
          </div>
        )}
        <Transcript
          key={`${selected.id}:${selected.conversation}`}
          onQuote={onQuote}
          session={session}
          reportsDirectory={
            snapshot?.worktrees.find((tree) => tree.path === session?.worktree)?.reports_directory
          }
          online={!!snapshot?.connected}
          active={view === 'conversation' && tab === 'conversation'}
          composer={
            <PromptComposer
              session={session}
              snapshot={snapshot}
              promptRef={promptRef}
              onAction={onAction}
            />
          }
          feedback={
            <>
              {notice && notice !== 'Action accepted' && <p role="status">{notice}</p>}
              {retry && pending && (
                <Button
                  variant="outline"
                  type="button"
                  disabled={submitting || pairing || !online}
                  onClick={() => void onRetry(pending)}
                >
                  Retry identical action
                </Button>
              )}
            </>
          }
        />
        {session?.permission && (
          <div id="permission">
            <p>{session.permission.title}</p>
            {session.permission.options.map((option) => (
              <Button
                variant="outline"
                key={option.optionId}
                disabled={disabled}
                onClick={() =>
                  onAction('permission', {
                    permission: session.permission?.id,
                    option: option.optionId,
                  })
                }
              >
                {option.name || option.optionId}
              </Button>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
