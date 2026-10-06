import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  QueryClient,
  QueryClientProvider,
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query';
import { operationID, parseSnapshot, post, RequestError, savePending } from './api';
import { CompanionProvider, useCompanionDispatch, useCompanionState } from './companion-context';
import { draftKey } from './companion-state';
import { Transcript } from './transcript';
import { SessionBrowser } from './session-browser';
import { SourceBrowser } from './source-browser';
import { LifecycleForm } from './lifecycle-controls';
import { groupSessions, sessionLocation } from './sessionGroups';
import type {
  ActionData,
  ActionPath,
  ActionResponse,
  PendingAction,
  Selection,
  Snapshot,
} from './types';

export function App() {
  const [client] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: { retry: false },
          mutations: { retry: false },
        },
      }),
  );
  return (
    <QueryClientProvider client={client}>
      <CompanionProvider>
        <Companion />
      </CompanionProvider>
    </QueryClientProvider>
  );
}

function Companion() {
  const client = useQueryClient();
  // SSE is authoritative; subscribe without issuing competing snapshot fetches.
  const { data: snapshot = null } = useQuery<Snapshot>({
    queryKey: ['snapshot'],
    enabled: false,
    staleTime: Infinity,
  });
  const actionMutation = useMutation({
    mutationFn: (action: PendingAction) => post<ActionResponse>(action.path, action.data),
  });
  const pairMutation = useMutation({
    mutationFn: (data: { code: string; name: string }) => post('pair', data),
  });
  const revokeMutation = useMutation({ mutationFn: () => post('revoke', {}) });
  const state = useCompanionState();
  const dispatch = useCompanionDispatch();
  const {
    pending,
    selected,
    view,
    online,
    connection,
    pairing,
    pairCode,
    deviceName,
    notice,
    retry,
    submitting,
  } = state;
  const pendingRef = useRef(pending);
  const titleRef = useRef<HTMLHeadingElement>(null);
  const prompt = state.drafts[draftKey(selected)] || '';
  const submittingRef = useRef(false);
  const streamRef = useRef<EventSource | null>(null);
  const resumedRef = useRef<string | null>(null);
  const [sourceVisited, setSourceVisited] = useState(false);

  useEffect(() => {
    if (view === 'source') setSourceVisited(true);
  }, [view]);

  const connect = useCallback(() => {
    streamRef.current?.close();
    const stream = new EventSource('/api/events');
    streamRef.current = stream;
    stream.onmessage = (event) => {
      if (streamRef.current !== stream) return;
      try {
        const value = parseSnapshot(event.data);
        client.setQueryData(['snapshot'], value);
        const resumed = value.sessions.find((item) => item.id === resumedRef.current);
        if (
          resumed?.conversation &&
          resumed.status !== 'starting' &&
          resumed.status !== 'exited' &&
          resumed.status !== 'stopped'
        ) {
          resumedRef.current = null;
          dispatch({
            type: 'select-session',
            selection: { id: resumed.id, conversation: resumed.conversation },
          });
        }
        dispatch({
          type: 'connection',
          online: value.connected,
          pairing: false,
          message: value.connected ? 'Connected · live' : 'Neovim unavailable',
        });
      } catch {
        dispatch({
          type: 'connection',
          online: false,
          message: 'Invalid stream data · actions disabled',
        });
      }
    };
    stream.onerror = async () => {
      if (streamRef.current !== stream) return;
      dispatch({
        type: 'connection',
        online: false,
        message: 'Connection interrupted · reconnecting',
      });
      try {
        const response = await fetch('/api/snapshot');
        if (streamRef.current === stream && response.status === 401) {
          stream.close();
          dispatch({
            type: 'connection',
            online: false,
            pairing: true,
            message: 'Pairing required',
          });
        }
      } catch {
        /* EventSource resynchronizes when the network recovers. */
      }
    };
  }, [client, dispatch]);

  useEffect(() => {
    connect();
    return () => {
      streamRef.current?.close();
      streamRef.current = null;
    };
  }, [connect]);

  useEffect(() => {
    if (view !== 'conversation') return;
    titleRef.current?.focus({ preventScroll: true });
    titleRef.current?.scrollIntoView?.({ block: 'start' });
  }, [view, selected?.id, selected?.conversation]);

  function openSession(selection: Selection) {
    dispatch({ type: 'select-session', selection });
  }

  async function submitPending(action: PendingAction) {
    if (submittingRef.current) return false;
    submittingRef.current = true;
    dispatch({ type: 'action-started', action });
    try {
      const response = await actionMutation.mutateAsync(action);
      const status = response.result?.status;
      if (!['accepted', 'queued', 'unknown'].includes(status))
        throw new RequestError('Invalid action receipt', true);
      if (status === 'unknown') {
        dispatch({
          type: 'action-uncertain',
          message: 'Outcome unknown. Retry the identical action or check the host.',
        });
        return false;
      }
      savePending(null);
      pendingRef.current = null;
      dispatch({ type: 'action-accepted', action, status });
      if (response.result.session) {
        resumedRef.current = response.result.session;
        const current = client
          .getQueryData<Snapshot>(['snapshot'])
          ?.sessions.find((item) => item.id === response.result.session);
        if (
          current?.conversation &&
          current.status !== 'starting' &&
          current.status !== 'exited' &&
          current.status !== 'stopped'
        ) {
          resumedRef.current = null;
          openSession({ id: current.id, conversation: current.conversation });
        }
      }
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Request interrupted';
      if (!(error instanceof RequestError) || error.unknownOutcome) {
        dispatch({
          type: 'action-uncertain',
          message: 'Outcome unknown. Retry uses the same action ID. ' + message,
        });
      } else {
        savePending(null);
        pendingRef.current = null;
        dispatch({ type: 'action-rejected', message });
      }
      return false;
    } finally {
      submittingRef.current = false;
      dispatch({ type: 'action-finished' });
    }
  }

  async function act(path: ActionPath, extra: Partial<ActionData> = {}) {
    const lifecycle = path.startsWith('session_') || path.startsWith('worktree_');
    if (pendingRef.current || !online || (!lifecycle && !selected?.conversation)) return false;
    const action: PendingAction = {
      path,
      data: {
        ...(!lifecycle && selected
          ? { session: selected.id, conversation: selected.conversation }
          : { epoch: snapshot?.epoch }),
        operation_id: operationID(),
        ...extra,
      },
    };
    // Persist before sending so interrupted actions remain recoverable.
    try {
      savePending(action);
    } catch {
      dispatch({
        type: 'notice',
        message: 'Browser storage unavailable; action was not sent.',
      });
      return false;
    }
    pendingRef.current = action;
    return submitPending(action);
  }
  const session = snapshot?.sessions.find(
    (item) => item.id === selected?.id && item.conversation === selected?.conversation,
  );
  const disabled =
    !online ||
    !session?.conversation ||
    session.status === 'exited' ||
    session.status === 'stopped' ||
    !!pending;
  const location = useMemo(
    () => (snapshot ? sessionLocation(groupSessions(snapshot), selected) : undefined),
    [snapshot, selected],
  );

  return (
    <>
      <header className="sticky top-0 z-20 border-b border-slate-700/60 bg-slate-900/95 px-4 py-3 backdrop-blur sm:px-6">
        <div className="mx-auto flex max-w-4xl items-center gap-3">
          <h1 className="text-2xl font-bold tracking-tight">
            Aero
            <span className="mt-0.5 block text-xs font-normal tracking-wide text-slate-400">
              Companion
            </span>
          </h1>
          <span id="connection" role="status">
            {connection}
          </span>
          <button
            className="ml-auto shrink-0"
            disabled={pairing || submitting || revokeMutation.isPending}
            onClick={async () => {
              try {
                await revokeMutation.mutateAsync();
                streamRef.current?.close();
                streamRef.current = null;
                dispatch({
                  type: 'connection',
                  online: false,
                  pairing: true,
                  message: 'Unpaired',
                });
                client.setQueryData(['snapshot'], null);
              } catch (error) {
                dispatch({
                  type: 'notice',
                  message: error instanceof Error ? error.message : 'Unpairing failed',
                });
              }
            }}
          >
            Unpair
          </button>
        </div>
      </header>
      <nav className="primary-nav" aria-label="Companion navigation">
        <button
          aria-current={view === 'sessions' ? 'page' : undefined}
          onClick={() => dispatch({ type: 'navigate', view: 'sessions' })}
        >
          <span className="nav-icon" aria-hidden="true">
            ▦
          </span>
          Sessions
        </button>
        <button
          aria-current={view === 'inbox' ? 'page' : undefined}
          onClick={() => dispatch({ type: 'navigate', view: 'inbox' })}
        >
          <span className="nav-icon" aria-hidden="true">
            ◇
          </span>
          Inbox{snapshot?.inbox.length ? ` (${snapshot.inbox.length})` : ''}
        </button>
        <button
          disabled={!selected}
          aria-current={view === 'conversation' ? 'page' : undefined}
          onClick={() => dispatch({ type: 'navigate', view: 'conversation' })}
        >
          <span className="nav-icon" aria-hidden="true">
            ≡
          </span>
          Transcript
        </button>
        <button
          aria-current={view === 'source' ? 'page' : undefined}
          onClick={() => dispatch({ type: 'navigate', view: 'source' })}
        >
          <span className="nav-icon" aria-hidden="true">
            ⌘
          </span>
          Source
        </button>
      </nav>
      <main className="mx-auto w-full max-w-4xl px-3 pt-4 pb-[calc(6rem+env(safe-area-inset-bottom))] sm:px-6 sm:pt-6">
        {pairing && (
          <form
            id="pair"
            onSubmit={async (event) => {
              event.preventDefault();
              try {
                await pairMutation.mutateAsync({
                  code: pairCode,
                  name: deviceName,
                });
                dispatch({ type: 'paired' });
                connect();
              } catch (error) {
                dispatch({
                  type: 'notice',
                  message: error instanceof Error ? error.message : 'Pairing failed',
                });
              }
            }}
          >
            <h2>Connect this phone</h2>
            <p className="text-sm leading-relaxed text-slate-400">
              Enter the pairing code from Neovim to follow your agents and respond on the go.
            </p>
            <label>
              Pairing code
              <input
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                minLength={6}
                maxLength={6}
                placeholder="6-digit code"
                required
                value={pairCode}
                onChange={(event) => dispatch({ type: 'pair-code', value: event.target.value })}
              />
            </label>
            <label>
              Device name
              <input
                maxLength={80}
                value={deviceName}
                onChange={(event) => dispatch({ type: 'device-name', value: event.target.value })}
              />
            </label>
            <button className="primary-action w-full sm:w-auto" disabled={pairMutation.isPending}>
              {pairMutation.isPending ? 'Pairing…' : 'Pair device'}
            </button>
          </form>
        )}
        <p id="notice" role="status">
          {notice}
        </p>
        {retry && pending && (
          <button
            id="retry"
            disabled={submitting || pairing || !online}
            onClick={() => void submitPending(pending)}
          >
            Retry identical action
          </button>
        )}
        <section hidden={view !== 'inbox'}>
          <h2>Attention inbox</h2>
          <div id="inbox">
            {snapshot?.inbox.map((entry) => (
              <button
                key={entry.id}
                onClick={() =>
                  openSession({
                    id: entry.session,
                    conversation: entry.conversation,
                  })
                }
              >
                {entry.kind}: {entry.text}
              </button>
            ))}
          </div>
          {snapshot?.connected && snapshot.inbox.length === 0 && (
            <p className="navigation-empty">No attention events right now.</p>
          )}
        </section>
        <SessionBrowser
          snapshot={snapshot}
          selected={selected}
          active={view === 'sessions'}
          onSelect={openSession}
          onAction={act}
          actionsDisabled={!online || !!pending || !snapshot?.epoch}
        />
        {!pairing && sourceVisited && (
          <div hidden={view !== 'source'}>
            <SourceBrowser snapshot={snapshot} selectedWorktree={session?.worktree} />
          </div>
        )}
        {selected && (
          <section id="conversation" hidden={view !== 'conversation'}>
            <button
              className="back-to-sessions"
              onClick={() => dispatch({ type: 'navigate', view: 'sessions' })}
            >
              ← All sessions
            </button>
            {location && (
              <nav className="session-breadcrumb" aria-label="Current session location">
                <span>{location.workspace.name}</span>
                <span aria-hidden="true">/</span>
                <span title={location.worktree.path}>{location.worktree.label}</span>
                <span aria-hidden="true">/</span>
                <strong>{location.session.name}</strong>
              </nav>
            )}
            <h2 id="title" ref={titleRef} tabIndex={-1}>
              {session
                ? `${session.name} · ${session.status}`
                : 'Session or conversation unavailable'}
            </h2>
            {session && (
              <div aria-label="Session actions">
                {(session.status === 'stopped' || session.status === 'exited') && (
                  <button
                    disabled={!online || !!pending || !session.target}
                    onClick={() =>
                      act('session_resume', { session: session.id, target: session.target })
                    }
                  >
                    Resume session
                  </button>
                )}
                <LifecycleForm
                  key={`rename:${session.id}`}
                  title="Rename session"
                  path="session_rename"
                  data={{ session: session.id, target: session.target }}
                  field="name"
                  initial={session.name}
                  disabled={!online || !!pending || !session.target}
                  onAction={act}
                />
                <LifecycleForm
                  title="Delete session"
                  path="session_delete"
                  data={{ session: session.id, target: session.target }}
                  destructive
                  disabled={!online || !!pending || !session.target}
                  onAction={act}
                />
              </div>
            )}
            <Transcript
              key={`${selected.id}:${selected.conversation}`}
              session={session}
              active={view === 'conversation'}
            />
            {session?.permission && (
              <div id="permission">
                <p>{session.permission.title}</p>
                {session.permission.options.map((option) => (
                  <button
                    key={option.optionId}
                    disabled={disabled}
                    onClick={() =>
                      act('permission', {
                        permission: session.permission?.id,
                        option: option.optionId,
                      })
                    }
                  >
                    {option.name || option.optionId}
                  </button>
                ))}
              </div>
            )}
            <form
              id="compose"
              onSubmit={(event) => {
                event.preventDefault();
                act('prompt', { text: prompt });
              }}
            >
              <label>
                Follow-up prompt
                <textarea
                  rows={3}
                  placeholder="What should the agent do next?"
                  required
                  value={prompt}
                  onChange={(event) => dispatch({ type: 'draft', value: event.target.value })}
                />
              </label>
              <button className="primary-action" id="send" disabled={disabled}>
                Send prompt
              </button>
              <button id="cancel" type="button" disabled={disabled} onClick={() => act('cancel')}>
                Cancel turn &amp; queue
              </button>
            </form>
          </section>
        )}
      </main>
    </>
  );
}
