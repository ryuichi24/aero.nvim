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
import { TodoNotifications } from './todo-notifications';
import { actionableAttention } from './attention';
import { ReportCommand } from './report-command';
import { SlashCommands, slashPickerOpen } from './slash-commands';
import { UIZoom } from './ui-zoom';
import { AttentionSurface, FullscreenAttentionContext } from './fullscreen-attention';
import { Screenshots } from './screenshots';
import { Recordings } from './recordings';
import { SessionBrowser } from './session-browser';
import { SessionMetadata } from './session-metadata';
import { CompanionHome } from './companion-home';
import { NavigationIcon } from './navigation-icon';
import type { View } from './companion-state';
import { readStored, store } from './browser-storage';
import { AgentTodos, latestTodos } from './agent-todos';
import { WorkspaceReview } from './workspace-review';
import { formatQuote, type Quote } from './quote';
import { LifecycleForm } from './lifecycle-controls';
import { AssignmentStatus, BoardAssignment } from './task-assignment';
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
  const promptRef = useRef<HTMLTextAreaElement>(null);
  const [quoteRequest, setQuoteRequest] = useState<{ quote: Quote; worktree: string }>();
  const [focusQuote, setFocusQuote] = useState(0);
  useEffect(() => {
    if (focusQuote) promptRef.current?.focus();
  }, [focusQuote]);
  const submittingRef = useRef(false);
  const streamRef = useRef<EventSource | null>(null);
  const resumedRef = useRef<string | null>(null);
  const [sessionTab, setSessionTab] = useState<'conversation' | 'artifacts' | 'details'>(
    'conversation',
  );
  const [routeReady, setRouteReady] = useState(false);
  const [creationRequest, setCreationRequest] = useState(0);
  const [lightTheme, setLightTheme] = useState(() => {
    try {
      return localStorage.getItem('aero-appearance') === 'light';
    } catch {
      return false;
    }
  });
  useEffect(() => {
    document.documentElement.dataset.theme = lightTheme ? 'light' : 'dark';
    try {
      localStorage.setItem('aero-appearance', lightTheme ? 'light' : 'dark');
    } catch {
      /* Optional preference. */
    }
    return () => {
      delete document.documentElement.dataset.theme;
    };
  }, [lightTheme]);
  const [reviewWorktree, setReviewWorktree] = useState(() =>
    readStored<string>(
      'aero-review-worktree',
      readStored<string>('aero-review-worktree', ''),
      'local',
    ),
  );
  const [workspaceScope, setWorkspaceScope] = useState(() =>
    readStored<string>('aero-workspace-scope', '', 'local'),
  );
  const [lastWorkspaceView, setLastWorkspaceView] = useState<'reports' | 'git' | 'source'>(() => {
    const saved = readStored<string>(
      'aero-workspace-view',
      readStored<string>('aero-workspace-view', 'reports'),
      'local',
    );
    return saved === 'source' || saved === 'git' ? saved : 'reports';
  });
  const [contextSearch, setContextSearch] = useState('');
  const [recent, setRecent] = useState<string[]>(() => {
    const value = readStored<unknown>('aero-recent-sessions', []);
    return Array.isArray(value) ? value.filter((id): id is string => typeof id === 'string') : [];
  });
  useEffect(() => store('aero-recent-sessions', recent), [recent]);
  useEffect(() => store('aero-workspace-scope', workspaceScope, 'local'), [workspaceScope]);
  useEffect(() => store('aero-review-worktree', reviewWorktree, 'local'), [reviewWorktree]);
  useEffect(() => store('aero-workspace-view', lastWorkspaceView, 'local'), [lastWorkspaceView]);
  useEffect(() => {
    if (!snapshot?.connected) return;
    if (
      workspaceScope &&
      !snapshot.workspaces.some((workspace) => workspace.root === workspaceScope)
    )
      setWorkspaceScope('');
  }, [snapshot, workspaceScope]);
  const workspaceView = view === 'reports' || view === 'source' || view === 'git';
  const scopedSnapshot =
    snapshot && workspaceScope
      ? {
          ...snapshot,
          workspaces: snapshot.workspaces.filter((workspace) => workspace.root === workspaceScope),
          worktrees: snapshot.worktrees.filter(
            (tree) => tree.workspace === workspaceScope || tree.path === workspaceScope,
          ),
          sessions: snapshot.sessions.filter((session) =>
            snapshot.worktrees.some(
              (tree) =>
                tree.path === session.worktree &&
                (tree.workspace === workspaceScope || tree.path === workspaceScope),
            ),
          ),
        }
      : snapshot;
  const reviewTree = scopedSnapshot?.worktrees.find((tree) => tree.path === reviewWorktree);
  const reviewGroups = scopedSnapshot
    ? groupSessions({ ...scopedSnapshot, sessions: [] })
        .map((workspace) => ({
          ...workspace,
          worktrees: workspace.worktrees.filter((tree) =>
            `${workspace.name} ${workspace.root} ${tree.branch} ${tree.path}`
              .toLowerCase()
              .includes(contextSearch.toLowerCase()),
          ),
        }))
        .filter((workspace) => workspace.worktrees.length > 0)
    : [];
  useEffect(() => {
    function restore() {
      try {
        const route = JSON.parse(decodeURIComponent(window.location.hash.slice(1)) || '{}');
        if (
          ['home', 'sessions', 'inbox', 'conversation', 'reports', 'source', 'git'].includes(
            route.view,
          )
        ) {
          if (route.selection?.id && typeof route.selection.id === 'string')
            dispatch({ type: 'select-session', selection: route.selection });
          dispatch({ type: 'navigate', view: route.view });
          setSessionTab(['artifacts', 'details'].includes(route.tab) ? route.tab : 'conversation');
          if (typeof route.worktree === 'string') setReviewWorktree(route.worktree);
        } else {
          dispatch({ type: 'navigate', view: 'home' });
        }
      } catch {
        /* Ignore unrelated or obsolete URL fragments. */
      }
    }
    if (!pendingRef.current) restore();
    setRouteReady(true);
    window.addEventListener('popstate', restore);
    return () => window.removeEventListener('popstate', restore);
  }, [dispatch]);
  useEffect(() => {
    if (!routeReady) return;
    window.history.replaceState(
      null,
      '',
      `#${encodeURIComponent(JSON.stringify({ view, selection: selected, worktree: reviewWorktree, tab: sessionTab }))}`,
    );
  }, [routeReady, view, selected, reviewWorktree, sessionTab]);

  function navigate(next: View, worktree = reviewWorktree) {
    setReviewWorktree(worktree);
    dispatch({ type: 'navigate', view: next });
    if (next === 'reports' || next === 'git' || next === 'source') setLastWorkspaceView(next);
    // Give browser Back a concrete landing route on its first navigation.
    if (!window.location.hash)
      window.history.replaceState(
        null,
        '',
        `#${encodeURIComponent(JSON.stringify({ view, selection: selected, worktree: reviewWorktree }))}`,
      );
    window.history.pushState(
      null,
      '',
      `#${encodeURIComponent(JSON.stringify({ view: next, selection: selected, worktree }))}`,
    );
  }
  const [attentionOpen, setAttentionOpen] = useState(false);
  const [attentionHost, setAttentionHost] = useState<HTMLElement | null>(null);
  const attentionOrigin = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    if (!attentionHost) return;
    const observer = new MutationObserver(() => {
      if (
        !attentionHost.isConnected ||
        (attentionHost instanceof HTMLDialogElement && !attentionHost.open)
      ) {
        setAttentionOpen(false);
        setAttentionHost(null);
      }
    });
    observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['open'],
    });
    return () => observer.disconnect();
  }, [attentionHost]);
  const [fullscreenAttention, setFullscreenAttention] = useState(() => {
    try {
      return localStorage.getItem('aero-companion-fullscreen-attention') !== 'false';
    } catch {
      return true;
    }
  });
  useEffect(() => {
    try {
      localStorage.setItem('aero-companion-fullscreen-attention', String(fullscreenAttention));
    } catch {
      // The setting remains usable without browser storage.
    }
  }, [fullscreenAttention]);
  const [confirmUnpair, setConfirmUnpair] = useState(false);
  const deviceMenu = useRef<HTMLDetailsElement>(null);
  const reviewMenu = useRef<HTMLDetailsElement>(null);
  const unpairDialog = useRef<HTMLDialogElement>(null);

  function dismissUnpair() {
    setConfirmUnpair(false);
    deviceMenu.current?.querySelector('summary')?.focus();
  }

  useEffect(() => {
    if (!confirmUnpair || !unpairDialog.current) return;
    const dialog = unpairDialog.current;
    if (dialog.showModal) dialog.showModal();
    else dialog.setAttribute('open', '');
  }, [confirmUnpair]);
  const attentionButton = useRef<HTMLButtonElement>(null);
  const attentionClose = useRef<HTMLButtonElement>(null);
  const attentionPanel = useRef<HTMLElement>(null);

  useEffect(() => {
    function dismissOutside(event: PointerEvent) {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (deviceMenu.current?.open && !deviceMenu.current.contains(target))
        deviceMenu.current.open = false;
      if (reviewMenu.current?.open && !reviewMenu.current.contains(target))
        reviewMenu.current.open = false;
      if (
        attentionOpen &&
        !attentionPanel.current?.contains(target) &&
        !attentionButton.current?.contains(target) &&
        !attentionOrigin.current?.contains(target)
      ) {
        setAttentionOpen(false);
        setAttentionHost(null);
      }
    }
    document.addEventListener('pointerdown', dismissOutside, true);
    return () => document.removeEventListener('pointerdown', dismissOutside, true);
  }, [attentionOpen]);

  function closeAttention() {
    setAttentionOpen(false);
    setAttentionHost(null);
    (attentionOrigin.current || attentionButton.current)?.focus();
  }

  useEffect(() => {
    if (attentionOpen) attentionClose.current?.focus();
  }, [attentionOpen]);

  useEffect(() => {
    setAttentionOpen(false);
    setAttentionHost(null);
  }, [view, pairing]);

  const connect = useCallback(() => {
    streamRef.current?.close();
    const stream = new EventSource('/api/events');
    streamRef.current = stream;
    let connectionRevision = 0;
    stream.onmessage = (event) => {
      if (streamRef.current !== stream) return;
      connectionRevision++;
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
      const revision = ++connectionRevision;
      dispatch({
        type: 'connection',
        online: false,
        message: 'Connection interrupted · reconnecting',
      });
      try {
        const response = await fetch('/api/snapshot');
        if (
          streamRef.current === stream &&
          connectionRevision === revision &&
          response.status === 401
        ) {
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
    if (window.scrollY > 0) window.scrollTo({ top: 0 });
  }, [view, selected?.id, selected?.conversation]);

  function openSession(selection: Selection) {
    if (attentionHost instanceof HTMLDialogElement) attentionHost.close();
    setAttentionOpen(false);
    setAttentionHost(null);
    dispatch({ type: 'select-session', selection });
    setSessionTab('conversation');
    setRecent((items) => [selection.id, ...items.filter((id) => id !== selection.id)].slice(0, 10));
    window.history.pushState(
      null,
      '',
      `#${encodeURIComponent(JSON.stringify({ view: 'conversation', selection, worktree: reviewWorktree }))}`,
    );
  }

  function appendQuote(quote: Quote, target: Selection, navigateToSession = true) {
    dispatch({ type: 'append-quote', selection: target, value: formatQuote(quote) });
    if (navigateToSession) openSession(target);
    setQuoteRequest(undefined);
    setFocusQuote((value) => value + 1);
  }

  function quoteFromSource(quote: Quote, worktree: string) {
    const candidates = snapshot?.sessions.filter((item) => item.worktree === worktree) || [];
    if (candidates.length === 1) {
      appendQuote(quote, { id: candidates[0].id, conversation: candidates[0].conversation });
    } else {
      setQuoteRequest({ quote, worktree });
    }
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
      if (response.result.message) dispatch({ type: 'notice', message: response.result.message });
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
    const target = extra.session
      ? { id: extra.session, conversation: extra.conversation }
      : selected;
    if (pendingRef.current || !online || (!lifecycle && !target?.conversation)) return false;
    const action: PendingAction = {
      path,
      data: {
        ...(!lifecycle && target
          ? { session: target.id, conversation: target.conversation }
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
    !!session.assignment?.pending ||
    !!pending;
  const exporting = /^\/export(?: readable)?$/.test(prompt.trim());
  const actionBlockReason = !online
    ? `${connection}. Sending and cancellation are unavailable until the connection returns.`
    : !session?.conversation
      ? 'This conversation is unavailable. Select or resume a session to send a prompt.'
      : pending
        ? retry
          ? 'The previous action has an unknown outcome. Retry the identical action before sending another prompt.'
          : 'Sending is paused while the previous action is being processed.'
        : session.status === 'exited' || session.status === 'stopped'
          ? 'This session is stopped. Resume it to send a prompt.'
          : session.assignment?.pending
            ? 'Sending is paused while the session’s board assignment is being updated.'
            : null;
  const composerBlockReason =
    exporting && online && session?.conversation && !pending ? null : actionBlockReason;
  const composerDisabled = !!composerBlockReason;
  const sendBlockReason =
    composerBlockReason ||
    (slashPickerOpen(prompt)
      ? prompt.trim() === '/report'
        ? 'Select or create a report below to complete this command.'
        : `Choose a ${prompt.trim().slice(1)} below to complete this command.`
      : null);
  const location = useMemo(
    () => (snapshot ? sessionLocation(groupSessions(snapshot), selected) : undefined),
    [snapshot, selected],
  );
  const attentionEntries = actionableAttention(snapshot);
  const visibleAttentionEntries = attentionEntries.filter(
    (entry) =>
      attentionOpen ||
      !workspaceScope ||
      entry.workspace === workspaceScope ||
      scopedSnapshot?.sessions.some((session) => session.id === entry.session),
  );

  return (
    <FullscreenAttentionContext.Provider
      value={
        <>
          <span data-todo-trigger className="todo-control-slot" />
          {fullscreenAttention && (
            <button
              aria-expanded={attentionOpen}
              aria-controls="attention-inbox"
              onClick={(event) => {
                attentionOrigin.current = event.currentTarget;
                setAttentionHost(
                  event.currentTarget.closest<HTMLElement>('dialog, .image-preview'),
                );
                attentionOpen ? closeAttention() : setAttentionOpen(true);
              }}
            >
              Attention{attentionEntries.length ? ` (${attentionEntries.length})` : ''}
            </button>
          )}
        </>
      }
    >
      <header className="sticky top-0 z-20 border-b border-slate-700/60 bg-slate-900/95 px-4 py-3 backdrop-blur sm:px-6">
        <div className="companion-header">
          <h1 className="text-2xl font-bold tracking-tight">
            Aero
            <span className="mt-0.5 block text-xs font-normal tracking-wide text-slate-400">
              Companion
            </span>
          </h1>
          <span
            id="connection"
            role="status"
            className={online ? 'text-green-300' : 'text-red-300'}
          >
            {connection}
          </span>
          <div className="header-actions">
            <button
              ref={attentionButton}
              className="attention-trigger"
              aria-expanded={attentionOpen}
              aria-controls="attention-inbox"
              onClick={() => {
                attentionOrigin.current = attentionButton.current;
                setAttentionHost(null);
                if (deviceMenu.current) deviceMenu.current.open = false;
                attentionOpen ? closeAttention() : setAttentionOpen(true);
              }}
            >
              Attention{attentionEntries.length ? ` (${attentionEntries.length})` : ''}
            </button>
            <span id="todo-controls" className="todo-control-slot" />
            <details
              ref={deviceMenu}
              className="device-menu"
              onToggle={(event) => {
                if (event.currentTarget.open) setAttentionOpen(false);
              }}
              onKeyDown={(event) => {
                if (event.key === 'Escape') {
                  event.currentTarget.open = false;
                  event.currentTarget.querySelector('summary')?.focus();
                }
              }}
            >
              <summary>
                Device <span aria-hidden="true">⌄</span>
              </summary>
              <div className="device-menu-panel">
                <p className="device-menu-label">Display zoom</p>
                <UIZoom />
                <label className="fullscreen-attention-setting">
                  <input
                    type="checkbox"
                    checked={lightTheme}
                    onChange={(event) => setLightTheme(event.target.checked)}
                  />
                  Light appearance
                </label>
                <label className="fullscreen-attention-setting">
                  <input
                    type="checkbox"
                    checked={fullscreenAttention}
                    onChange={(event) => setFullscreenAttention(event.target.checked)}
                  />
                  Show Attention in fullscreen
                </label>
                <div className="device-unpair">
                  <button
                    disabled={pairing || submitting || revokeMutation.isPending}
                    onClick={() => {
                      if (deviceMenu.current) deviceMenu.current.open = false;
                      setConfirmUnpair(true);
                    }}
                  >
                    Unpair
                  </button>
                </div>
              </div>
            </details>
          </div>
        </div>
      </header>
      {confirmUnpair && (
        <dialog
          ref={unpairDialog}
          className="unpair-dialog"
          aria-labelledby="unpair-title"
          aria-describedby="unpair-description"
          onCancel={(event) => {
            event.preventDefault();
            if (!revokeMutation.isPending) dismissUnpair();
          }}
        >
          <h2 id="unpair-title">Unpair this device?</h2>
          <p id="unpair-description" className="text-sm text-slate-400">
            You’ll need a new pairing code to reconnect.
          </p>
          {revokeMutation.isError && <p role="alert">{revokeMutation.error.message}</p>}
          <div className="mt-5 flex justify-end gap-3">
            <button autoFocus onClick={dismissUnpair} disabled={revokeMutation.isPending}>
              Cancel
            </button>
            <button
              className="unpair-confirm"
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
                  dismissUnpair();
                } catch (error) {
                  dispatch({
                    type: 'notice',
                    message: error instanceof Error ? error.message : 'Unpairing failed',
                  });
                }
              }}
            >
              {revokeMutation.isPending ? 'Unpairing…' : 'Unpair'}
            </button>
          </div>
        </dialog>
      )}
      <nav className="primary-nav" aria-label="Companion navigation">
        <button
          aria-current={view === 'home' ? 'page' : undefined}
          onClick={() => navigate('home')}
        >
          <NavigationIcon name="home" />
          Home
        </button>
        <button
          aria-current={view === 'sessions' || view === 'conversation' ? 'page' : undefined}
          onClick={() => navigate('sessions')}
        >
          <NavigationIcon name="sessions" />
          Sessions
        </button>
        <button
          aria-current={view === 'inbox' ? 'page' : undefined}
          onClick={() => navigate('inbox')}
        >
          <NavigationIcon name="inbox" />
          Inbox{attentionEntries.length ? ` (${attentionEntries.length})` : ''}
        </button>
        <button
          aria-current={workspaceView ? 'page' : undefined}
          onClick={() => navigate(lastWorkspaceView)}
        >
          <NavigationIcon name="workspace" />
          Workspace
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
        <p
          id="notice"
          role="status"
          hidden={view === 'conversation' && notice === 'Action accepted'}
        >
          {notice}
        </p>
        {!online && !pairing && (
          <p className="connection-banner" role="status">
            {connection}. Showing last-known data; actions are unavailable until the connection
            returns.
          </p>
        )}
        {!pairing && view !== 'conversation' && (
          <label className="workspace-scope">
            Workspace scope
            <select
              value={workspaceScope}
              onChange={(event) => setWorkspaceScope(event.target.value)}
            >
              <option value="">All workspaces</option>
              {snapshot?.workspaces.map((workspace) => (
                <option key={workspace.root} value={workspace.root}>
                  {workspace.name}
                </option>
              ))}
            </select>
          </label>
        )}
        {!pairing && view === 'home' && (
          <CompanionHome
            snapshot={scopedSnapshot}
            recent={recent}
            onSelect={openSession}
            onNavigate={navigate}
            onCreate={() => {
              setCreationRequest((value) => value + 1);
              navigate('sessions');
            }}
          />
        )}
        {!pairing && workspaceView && (
          <section className="workspace-context" aria-label="Workspace review context">
            <h2>Workspace</h2>
            <details open={!reviewTree}>
              <summary>
                {reviewTree?.branch || reviewTree?.path || 'Choose a worktree'} · Change context
              </summary>
              <label>
                Find a worktree
                <input
                  type="search"
                  value={contextSearch}
                  onChange={(event) => setContextSearch(event.target.value)}
                  placeholder="Workspace, branch, or path"
                />
              </label>
              <div className="context-options">
                {reviewGroups.map((workspace) => {
                  const worktrees = workspace.worktrees.map((tree) => (
                    <button
                      key={tree.path}
                      aria-pressed={tree.path === reviewWorktree}
                      onClick={(event) => {
                        navigate(view, tree.path);
                        setContextSearch('');
                        const details = event.currentTarget.closest('details');
                        if (details) {
                          details.open = false;
                          details.querySelector('summary')?.focus();
                        }
                      }}
                    >
                      {tree.label}
                      <span>{tree.path}</span>
                    </button>
                  ));
                  return workspaceScope ? (
                    <div key={workspace.key}>{worktrees}</div>
                  ) : (
                    <details key={workspace.key} open={contextSearch.trim() ? true : undefined}>
                      <summary>{workspace.name}</summary>
                      {worktrees}
                    </details>
                  );
                })}
                {snapshot && reviewGroups.length === 0 && <p>No matching worktrees.</p>}
              </div>
            </details>
            {reviewTree && (
              <details className="worktree-management">
                <summary>Manage worktree</summary>
                {reviewTree.workspace && (
                  <LifecycleForm
                    title="New worktree"
                    path="worktree_create"
                    data={{ workspace: reviewTree.workspace }}
                    field="branch"
                    disabled={!online || !!pending || !snapshot?.epoch}
                    onAction={act}
                  />
                )}
                {reviewTree.branch && (
                  <LifecycleForm
                    title="Rename worktree branch"
                    path="worktree_rename"
                    data={{
                      workspace: reviewTree.workspace,
                      worktree: reviewTree.path,
                      target: reviewTree.target,
                    }}
                    field="name"
                    initial={reviewTree.branch}
                    disabled={!online || !!pending || !reviewTree.target}
                    onAction={act}
                  />
                )}
                {reviewTree.workspace && reviewTree.path !== reviewTree.workspace && (
                  <LifecycleForm
                    title="Delete worktree"
                    path="worktree_delete"
                    data={{
                      workspace: reviewTree.workspace,
                      worktree: reviewTree.path,
                      target: reviewTree.target,
                    }}
                    destructive
                    force
                    disabled={!online || !!pending || !reviewTree.target}
                    onAction={act}
                  />
                )}
              </details>
            )}
            <nav className="local-nav" aria-label="Workspace tools">
              {(
                [
                  ['reports', 'Reports'],
                  ['git', 'Changes'],
                  ['source', 'Source'],
                ] as const
              ).map(([next, label]) => (
                <button
                  key={next}
                  aria-current={view === next ? 'page' : undefined}
                  onClick={() => navigate(next)}
                >
                  {label}
                </button>
              ))}
            </nav>
            {view === 'reports' && reviewTree && (
              <details className="report-create">
                <summary>Create report with an agent</summary>
                <p>
                  Select a session in this worktree to choose or create a report in its composer.
                </p>
                {snapshot?.sessions
                  .filter((item) => item.worktree === reviewTree.path)
                  .map((item) => (
                    <button
                      key={item.id}
                      onClick={() => {
                        const selection = { id: item.id, conversation: item.conversation };
                        openSession(selection);
                        if (!state.drafts[draftKey(selection)]?.trim())
                          dispatch({ type: 'draft', value: '/report' });
                        else
                          dispatch({
                            type: 'notice',
                            message:
                              'Your existing draft is kept. Clear it and choose Select or create report from Prompt actions.',
                          });
                      }}
                    >
                      Use {item.name}
                    </button>
                  ))}
                {!snapshot?.sessions.some((item) => item.worktree === reviewTree.path) && (
                  <button onClick={() => navigate('sessions')}>Create a session first</button>
                )}
              </details>
            )}
            {!reviewTree && <p>Choose a worktree to review its reports, changes, and source.</p>}
          </section>
        )}
        {retry && pending && (
          <button
            id="retry"
            disabled={submitting || pairing || !online}
            onClick={() => void submitPending(pending)}
          >
            Retry identical action
          </button>
        )}
        <AttentionSurface host={attentionOpen ? attentionHost : null}>
          <section
            id="attention-inbox"
            ref={attentionPanel}
            aria-labelledby="attention-title"
            hidden={view !== 'inbox' && !attentionOpen}
            className={
              attentionOpen
                ? `attention-panel${attentionHost ? ' attention-panel-fullscreen' : ''}`
                : undefined
            }
            onKeyDown={(event) => {
              if (attentionOpen && event.key === 'Escape') {
                event.preventDefault();
                closeAttention();
              }
            }}
          >
            <div className="flex items-center justify-between gap-3">
              <h2 id="attention-title">Attention inbox</h2>
              {attentionOpen && (
                <button ref={attentionClose} onClick={closeAttention}>
                  Hide attention
                </button>
              )}
            </div>
            {attentionOpen && (
              <>
                <p role="status">{notice || connection}</p>
                {retry && pending && (
                  <button
                    disabled={submitting || pairing || !online}
                    onClick={() => void submitPending(pending)}
                  >
                    Retry identical action
                  </button>
                )}
              </>
            )}
            <div id="inbox">
              {visibleAttentionEntries.map((entry) => {
                const owner = snapshot?.sessions.find(
                  (item) => item.id === entry.session && item.conversation === entry.conversation,
                );
                const permission = entry.kind === 'permission' ? owner?.permission : undefined;
                return (
                  <div key={entry.id} className="inbox-entry">
                    <p className="text-sm text-slate-400">
                      {owner?.name || entry.session}
                      {owner?.worktree ? ` · ${owner.worktree}` : ''}
                    </p>
                    <button
                      onClick={() =>
                        openSession({
                          id: entry.session,
                          conversation: entry.conversation,
                        })
                      }
                    >
                      {entry.kind}: {entry.text}
                    </button>
                    {permission && (
                      <div className="inbox-permission" role="group" aria-label={permission.title}>
                        <p>{permission.title}</p>
                        {permission.options.map((option) => (
                          <button
                            key={option.optionId}
                            disabled={
                              !online ||
                              !!pending ||
                              owner?.status === 'exited' ||
                              owner?.status === 'stopped'
                            }
                            onClick={() =>
                              act('permission', {
                                session: entry.session,
                                conversation: entry.conversation,
                                permission: permission.id,
                                option: option.optionId,
                              })
                            }
                          >
                            {option.name || option.optionId}
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
            {snapshot?.connected && visibleAttentionEntries.length === 0 && (
              <p className="navigation-empty">No attention events right now.</p>
            )}
          </section>
        </AttentionSurface>
        <SessionBrowser
          snapshot={scopedSnapshot}
          selected={selected}
          active={view === 'sessions'}
          onSelect={openSession}
          onAction={act}
          actionsDisabled={!online || !!pending || !snapshot?.epoch}
          creationRequest={creationRequest}
        />
        {!pairing && (
          <WorkspaceReview
            snapshot={snapshot ? { ...snapshot, connected: online } : null}
            worktree={reviewTree?.path || ''}
            view={view}
            onQuote={quoteFromSource}
          />
        )}
        {quoteRequest && (
          <section className="quote-destination" aria-label="Quote destination">
            <h2>Quote to agent session</h2>
            {(snapshot?.sessions || [])
              .filter((item) => item.worktree === quoteRequest.worktree)
              .map((item) => (
                <button
                  key={`${item.id}:${item.conversation}`}
                  onClick={() =>
                    appendQuote(quoteRequest.quote, {
                      id: item.id,
                      conversation: item.conversation,
                    })
                  }
                >
                  {item.name} · {item.agent}
                </button>
              ))}
            {!snapshot?.sessions.some((item) => item.worktree === quoteRequest.worktree) && (
              <p>Start an agent session in this worktree before quoting text.</p>
            )}
            <button onClick={() => setQuoteRequest(undefined)}>Cancel quote</button>
          </section>
        )}
        {selected && (
          <section id="conversation" hidden={view !== 'conversation'}>
            <div className="session-heading">
              <button
                className="back-to-sessions"
                aria-label="← All sessions"
                title="All sessions"
                onClick={() => navigate('sessions')}
              >
                ←
              </button>
              <h2 id="title" ref={titleRef} tabIndex={-1}>
                {session
                  ? `${session.name} · ${session.status}`
                  : 'Session or conversation unavailable'}
              </h2>
            </div>
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
                {(['conversation', 'artifacts', 'details'] as const).map((tab) => (
                  <button
                    key={tab}
                    aria-current={sessionTab === tab ? 'page' : undefined}
                    onClick={() => {
                      setSessionTab(tab);
                      window.history.pushState(
                        null,
                        '',
                        `#${encodeURIComponent(JSON.stringify({ view, selection: selected, worktree: reviewWorktree, tab }))}`,
                      );
                    }}
                  >
                    {tab === 'conversation'
                      ? 'Conversation'
                      : tab === 'artifacts'
                        ? 'Artifacts'
                        : 'Details'}
                  </button>
                ))}
              </nav>
              {session && (
                <details ref={reviewMenu} className="session-review-links">
                  <summary aria-label="Review this worktree">Review</summary>
                  <div className="session-review-menu">
                    {(
                      [
                        ['reports', 'Reports'],
                        ['git', 'Changes'],
                        ['source', 'Source'],
                      ] as const
                    ).map(([next, label]) => (
                      <button key={next} onClick={() => navigate(next, session.worktree)}>
                        {label} for this worktree
                      </button>
                    ))}
                  </div>
                </details>
              )}
            </div>
            <div hidden={sessionTab !== 'details'}>
              {session && <SessionMetadata session={session} />}
              {session && <AgentTodos todos={latestTodos(session.blocks || [])} />}
              {session && (
                <div aria-label="Session actions">
                  <AssignmentStatus session={session} />
                  {snapshot && (
                    <BoardAssignment
                      key={session.id}
                      session={session}
                      snapshot={snapshot}
                      disabled={!online || !!pending || !session.target}
                      onAction={act}
                    />
                  )}
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
            </div>
            <div hidden={sessionTab !== 'artifacts'}>
              {session && (
                <Screenshots
                  key={`screenshots:${session.id}:${session.conversation}`}
                  session={session}
                />
              )}
              {session && (
                <Recordings
                  key={`recordings:${session.id}:${session.conversation}`}
                  session={session}
                />
              )}
            </div>
            <div className="session-conversation" hidden={sessionTab !== 'conversation'}>
              {session && (session.status === 'stopped' || session.status === 'exited') && (
                <button
                  disabled={!online || !!pending || !session.target}
                  onClick={() =>
                    act('session_resume', { session: session.id, target: session.target })
                  }
                >
                  Resume session
                </button>
              )}
              <Transcript
                onQuote={(quote) => appendQuote(quote, selected, false)}
                key={`${selected.id}:${selected.conversation}`}
                session={session}
                reportsDirectory={
                  snapshot?.worktrees.find((tree) => tree.path === session?.worktree)
                    ?.reports_directory
                }
                online={!!snapshot?.connected}
                active={view === 'conversation' && sessionTab === 'conversation'}
                composer={
                  <form
                    id="compose"
                    onSubmit={(event) => {
                      event.preventDefault();
                      if (sendBlockReason) return;
                      act('prompt', { text: prompt });
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
                        onChange={(event) => dispatch({ type: 'draft', value: event.target.value })}
                      />
                    </label>
                    {session && snapshot && (
                      <SlashCommands
                        prompt={prompt}
                        session={session}
                        snapshot={snapshot}
                        disabled={composerDisabled}
                        onChoose={(value) => dispatch({ type: 'draft', value })}
                        onAction={act}
                      />
                    )}
                    {session && prompt.trim() === '/report' && (
                      <ReportCommand
                        key={`${session.id}:${session.conversation}`}
                        worktree={session.worktree}
                        online={online && !pending}
                        onChoose={(value) => dispatch({ type: 'draft', value })}
                      />
                    )}
                    <div className="composer-toolbar">
                      <details className="composer-actions">
                        <summary aria-label="Prompt actions">Actions</summary>
                        <div className="quick-actions">
                          {['report', 'model', 'mode', 'export'].map((command) => (
                            <button
                              key={command}
                              type="button"
                              disabled={!!prompt.trim()}
                              onClick={(event) => {
                                dispatch({ type: 'draft', value: `/${command}` });
                                const details = event.currentTarget.closest('details');
                                if (details) details.open = false;
                              }}
                            >
                              {command === 'report'
                                ? 'Select or create report'
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
                        onClick={() => act('cancel')}
                      >
                        Cancel
                      </button>
                    </div>
                    {sendBlockReason && (
                      <p
                        id="send-block-reason"
                        role="status"
                        className="mt-2 text-sm text-amber-300"
                      >
                        {sendBlockReason} Your draft is kept here.
                      </p>
                    )}
                    {disabled && !composerBlockReason && (
                      <p
                        id="cancel-block-reason"
                        role="status"
                        className="mt-2 text-sm text-amber-300"
                      >
                        Cancellation is unavailable. {actionBlockReason}
                      </p>
                    )}
                  </form>
                }
                feedback={
                  <>
                    {notice && notice !== 'Action accepted' && <p role="status">{notice}</p>}
                    {retry && pending && (
                      <button
                        type="button"
                        disabled={submitting || pairing || !online}
                        onClick={() => void submitPending(pending)}
                      >
                        Retry identical action
                      </button>
                    )}
                  </>
                }
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
            </div>
          </section>
        )}
      </main>
      <TodoNotifications snapshot={pairing ? null : snapshot} />
    </FullscreenAttentionContext.Provider>
  );
}
