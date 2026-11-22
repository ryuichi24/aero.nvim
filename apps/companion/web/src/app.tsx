import { useEffect, useRef, useState } from 'react';
import { Button } from './components/ui/button';
import { Input } from './components/ui/input';
import { NativeSelect } from './components/ui/native-select';
import { Checkbox } from './components/ui/checkbox';
import { Label } from './components/ui/label';
import { Dialog } from './components/ui/dialog';
import { Collapsible, CollapsibleTrigger } from './components/ui/collapsible';
import {
  QueryClient,
  QueryClientProvider,
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query';
import { post } from './api';
import { useSnapshotStream } from './connection/use-snapshot-stream';
import { useCompanionActions } from './actions/use-companion-actions';
import { useCompanionRoute } from './navigation/use-companion-route';
import { useSessionPosition } from './navigation/use-session-position';
import {
  sceneSnapshot,
  scopeSnapshot,
  reviewGroups as selectReviewGroups,
} from './selectors/workspace-scope';
import { SubmoduleBrowser } from './submodule-browser';
import { CompanionProvider, useCompanionDispatch, useCompanionState } from './companion-context';
import { draftKey } from './companion-state';
import { TodoNotifications } from './todo-notifications';
import { actionableAttention } from './attention';
import { ConversationScreen } from './conversation/conversation-screen';
import { UIZoom } from './ui-zoom';
import { FullscreenAttentionContext } from './fullscreen-attention';
import { AttentionPanel } from './attention/attention-panel';
import { SessionBrowser } from './session-browser';
import { CompanionHome } from './companion-home';
import { NavigationIcon } from './navigation-icon';
import { useDisplayPreferences, useWorkspacePreferences } from './preferences/use-preferences';
import { WorkspaceReview } from './workspace-review';
import { CancelReferenceTransfer } from './reference-browser';
import { formatQuote, type Quote } from './quote';
import { LifecycleForm } from './lifecycle-controls';
import type { Selection, Snapshot } from './types';

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
  const { act, submitPending, pendingRef, resumedRef } = useCompanionActions(snapshot, openSession);
  const { connect, disconnect } = useSnapshotStream(resumedRef);
  const titleRef = useRef<HTMLHeadingElement>(null);
  const promptRef = useRef<HTMLTextAreaElement>(null);
  const [quoteRequest, setQuoteRequest] = useState<{ quote: Quote; worktree: string }>();
  const [focusQuote, setFocusQuote] = useState(0);
  useEffect(() => {
    if (focusQuote) promptRef.current?.focus();
  }, [focusQuote]);
  const [sessionTab, setSessionTab] = useState<'conversation' | 'artifacts' | 'details'>(
    'conversation',
  );
  const lastSessionsView = useRef<'sessions' | 'conversation'>('sessions');
  useEffect(() => {
    if (view === 'sessions' || view === 'conversation') lastSessionsView.current = view;
  }, [view]);
  useSessionPosition(view, selected, sessionTab, titleRef);
  const [creationRequest, setCreationRequest] = useState(0);
  const { lightTheme, setLightTheme, fullscreenAttention, setFullscreenAttention } =
    useDisplayPreferences();
  const {
    reviewWorktree,
    setReviewWorktree,
    workspaceScope,
    setWorkspaceScope,
    lastWorkspaceView,
    setLastWorkspaceView,
    recent,
    setRecent,
  } = useWorkspacePreferences();
  const [contextSearch, setContextSearch] = useState('');
  const activeSnapshot = sceneSnapshot(snapshot);
  useEffect(() => {
    if (!snapshot?.connected) return;
    if (
      workspaceScope &&
      !snapshot.workspaces.some(
        (workspace) => workspace.root === workspaceScope && workspace.in_scene !== false,
      )
    )
      setWorkspaceScope('');
  }, [snapshot, workspaceScope, setWorkspaceScope]);
  const workspaceView =
    view === 'reports' || view === 'source' || view === 'git' || view === 'reference';
  const scopedSnapshot = scopeSnapshot(activeSnapshot, workspaceScope);
  const reviewTree = scopedSnapshot?.worktrees.find((tree) => tree.path === reviewWorktree);
  const reviewGroups = selectReviewGroups(scopedSnapshot, contextSearch);
  const navigate = useCompanionRoute(
    view,
    selected,
    reviewWorktree,
    sessionTab,
    pendingRef,
    setReviewWorktree,
    setSessionTab,
    setLastWorkspaceView,
  );
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
  const [confirmUnpair, setConfirmUnpair] = useState(false);
  const deviceMenu = useRef<HTMLDetailsElement>(null);
  const reviewMenu = useRef<HTMLDetailsElement>(null);
  const unpairDialog = useRef<HTMLDialogElement>(null);

  function dismissUnpair() {
    setConfirmUnpair(false);
    deviceMenu.current?.querySelector('summary')?.focus();
  }

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
            <Button
              variant="outline"
              aria-expanded={attentionOpen}
              aria-controls="attention-inbox"
              onClick={(event) => {
                attentionOrigin.current = event.currentTarget;
                setAttentionHost(
                  event.currentTarget.closest<HTMLElement>('dialog, .image-preview'),
                );
                if (attentionOpen) closeAttention();
                else setAttentionOpen(true);
              }}
            >
              Attention{attentionEntries.length ? ` (${attentionEntries.length})` : ''}
            </Button>
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
            {!!snapshot?.scenes?.length && (
              <Label className="scene-picker">
                Scene
                <NativeSelect
                  wrapperClassName="m-0 min-w-0 flex-1 sm:w-36 sm:flex-none"
                  className="h-11 truncate py-0 text-sm"
                  aria-label="Scene"
                  value={snapshot.active_scene || ''}
                  disabled={!online || submitting || !!pending}
                  onChange={(event) => void act('scene_switch', { scene_id: event.target.value })}
                >
                  {snapshot.scenes.map((scene) => (
                    <option key={scene.id} value={scene.id}>
                      {scene.name}
                    </option>
                  ))}
                </NativeSelect>
              </Label>
            )}
            <Button
              variant="outline"
              ref={attentionButton}
              className="attention-trigger"
              aria-expanded={attentionOpen}
              aria-controls="attention-inbox"
              onClick={() => {
                attentionOrigin.current = attentionButton.current;
                setAttentionHost(null);
                if (deviceMenu.current) deviceMenu.current.open = false;
                if (attentionOpen) closeAttention();
                else setAttentionOpen(true);
              }}
            >
              Attention{attentionEntries.length ? ` (${attentionEntries.length})` : ''}
            </Button>
            <span id="todo-controls" className="todo-control-slot" />
            <Collapsible
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
              <CollapsibleTrigger>
                Device <span aria-hidden="true">⌄</span>
              </CollapsibleTrigger>
              <div className="device-menu-panel">
                <p className="device-menu-label">Display zoom</p>
                <UIZoom />
                <Label className="fullscreen-attention-setting">
                  <Checkbox
                    checked={lightTheme}
                    onCheckedChange={(checked) => setLightTheme(checked === true)}
                  />
                  Light appearance
                </Label>
                <Label className="fullscreen-attention-setting">
                  <Checkbox
                    checked={fullscreenAttention}
                    onCheckedChange={(checked) => setFullscreenAttention(checked === true)}
                  />
                  Show Attention in fullscreen
                </Label>
                <div className="device-unpair">
                  <Button
                    variant="outline"
                    disabled={pairing || submitting || revokeMutation.isPending}
                    onClick={() => {
                      if (deviceMenu.current) deviceMenu.current.open = false;
                      setConfirmUnpair(true);
                    }}
                  >
                    Unpair
                  </Button>
                </div>
              </div>
            </Collapsible>
          </div>
        </div>
      </header>
      {confirmUnpair && (
        <Dialog
          open={confirmUnpair}
          onOpenChange={(open) => {
            if (!open && !revokeMutation.isPending) dismissUnpair();
          }}
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
            <Button
              variant="outline"
              autoFocus
              onClick={dismissUnpair}
              disabled={revokeMutation.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              disabled={pairing || submitting || revokeMutation.isPending}
              onClick={async () => {
                try {
                  await revokeMutation.mutateAsync();
                  disconnect();
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
            </Button>
          </div>
        </Dialog>
      )}
      <nav className="primary-nav" aria-label="Companion navigation">
        <Button
          variant="ghost"
          aria-current={view === 'home' ? 'page' : undefined}
          onClick={() => navigate('home')}
        >
          <NavigationIcon name="home" />
          Home
        </Button>
        <Button
          variant="ghost"
          aria-current={view === 'sessions' || view === 'conversation' ? 'page' : undefined}
          onClick={() =>
            navigate(view === 'conversation' || !selected ? 'sessions' : lastSessionsView.current)
          }
        >
          <NavigationIcon name="sessions" />
          Sessions
        </Button>
        <Button
          variant="ghost"
          aria-current={view === 'inbox' ? 'page' : undefined}
          onClick={() => navigate('inbox')}
        >
          <NavigationIcon name="inbox" />
          Inbox{attentionEntries.length ? ` (${attentionEntries.length})` : ''}
        </Button>
        <Button
          variant="ghost"
          aria-current={workspaceView ? 'page' : undefined}
          onClick={() => navigate(lastWorkspaceView)}
        >
          <NavigationIcon name="workspace" />
          Workspace
        </Button>
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
            <Label>
              Pairing code
              <Input
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
            </Label>
            <Label>
              Device name
              <Input
                maxLength={80}
                value={deviceName}
                onChange={(event) => dispatch({ type: 'device-name', value: event.target.value })}
              />
            </Label>
            <Button type="submit" className="w-full sm:w-auto" disabled={pairMutation.isPending}>
              {pairMutation.isPending ? 'Pairing…' : 'Pair device'}
            </Button>
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
          <Label className="workspace-scope">
            Workspace scope
            <NativeSelect
              value={workspaceScope}
              onChange={(event) => setWorkspaceScope(event.target.value)}
            >
              <option value="">All workspaces</option>
              {activeSnapshot?.workspaces.map((workspace) => (
                <option key={workspace.root} value={workspace.root}>
                  {workspace.name}
                </option>
              ))}
            </NativeSelect>
          </Label>
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
            <Collapsible open={!reviewTree}>
              <CollapsibleTrigger>
                {reviewTree?.branch || reviewTree?.path || 'Choose a worktree'} · Change context
              </CollapsibleTrigger>
              <Label>
                Find a worktree
                <Input
                  type="search"
                  value={contextSearch}
                  onChange={(event) => setContextSearch(event.target.value)}
                  placeholder="Workspace, branch, or path"
                />
              </Label>
              <div className="context-options">
                {reviewGroups.map((workspace) => {
                  const worktrees = workspace.worktrees.map((tree) => (
                    <Button
                      variant="ghost"
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
                    </Button>
                  ));
                  return workspaceScope && reviewGroups.length === 1 ? (
                    <div key={workspace.key}>{worktrees}</div>
                  ) : (
                    <Collapsible key={workspace.key} open={contextSearch.trim() ? true : undefined}>
                      <CollapsibleTrigger>{workspace.name}</CollapsibleTrigger>
                      {worktrees}
                    </Collapsible>
                  );
                })}
                {snapshot && reviewGroups.length === 0 && <p>No matching worktrees.</p>}
              </div>
            </Collapsible>
            {reviewTree && (
              <Collapsible className="worktree-management">
                <CollapsibleTrigger>Manage worktree</CollapsibleTrigger>
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
              </Collapsible>
            )}
            {reviewTree && snapshot && (
              <SubmoduleBrowser
                tree={reviewTree}
                snapshot={snapshot}
                online={online}
                disabled={!online || !!pending || !snapshot.epoch}
                onAction={act}
                onOpen={(path) => navigate(view, path)}
              />
            )}
            <nav className="local-nav" aria-label="Workspace tools">
              {(
                [
                  ['reports', 'Reports'],
                  ['reference', 'References'],
                  ['git', 'Changes'],
                  ['source', 'Source'],
                ] as const
              ).map(([next, label]) => (
                <Button
                  variant="outline"
                  key={next}
                  aria-current={view === next ? 'page' : undefined}
                  onClick={() => navigate(next)}
                >
                  {label}
                </Button>
              ))}
            </nav>
            {view === 'reports' && reviewTree && (
              <Collapsible className="report-create">
                <CollapsibleTrigger>Create report with an agent</CollapsibleTrigger>
                <p>
                  Select a session in this worktree to choose or create a report in its composer.
                </p>
                {snapshot?.sessions
                  .filter((item) => item.worktree === reviewTree.path)
                  .map((item) => (
                    <Button
                      variant="outline"
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
                    </Button>
                  ))}
                {!snapshot?.sessions.some((item) => item.worktree === reviewTree.path) && (
                  <Button onClick={() => navigate('sessions')}>Create a session first</Button>
                )}
              </Collapsible>
            )}
            {!reviewTree && (
              <p>Choose a worktree to review its reports, references, changes, and source.</p>
            )}
          </section>
        )}
        {pending?.path === 'reference_update' && pending.data.reference_action === 'transfer' && (
          <CancelReferenceTransfer
            key={pending.data.operation_id}
            pending={pending}
            disabled={!online || pairing}
          />
        )}
        {retry && pending && (
          <Button
            variant="outline"
            id="retry"
            disabled={submitting || pairing || !online}
            onClick={() => void submitPending(pending)}
          >
            Retry identical action
          </Button>
        )}
        <AttentionPanel
          snapshot={snapshot}
          entries={visibleAttentionEntries}
          open={attentionOpen}
          host={attentionHost}
          panelRef={attentionPanel}
          closeRef={attentionClose}
          onClose={closeAttention}
          onSelect={openSession}
          onAction={act}
          onRetry={submitPending}
        />
        <SessionBrowser
          snapshot={scopedSnapshot}
          selected={selected}
          active={view === 'sessions'}
          onSelect={openSession}
          onAction={act}
          actionsDisabled={!online || !!pending || !snapshot?.epoch}
          creationRequest={creationRequest}
          onOpenWorktree={(path) => navigate('source', path)}
        />
        {!pairing && (
          <WorkspaceReview
            snapshot={snapshot ? { ...snapshot, connected: online } : null}
            worktree={reviewTree?.path || ''}
            view={view}
            onQuote={quoteFromSource}
            onAction={act}
            actionsDisabled={!online || !!pending}
          />
        )}
        {quoteRequest && (
          <section className="quote-destination" aria-label="Quote destination">
            <h2>Quote to agent session</h2>
            {(snapshot?.sessions || [])
              .filter((item) => item.worktree === quoteRequest.worktree)
              .map((item) => (
                <Button
                  variant="outline"
                  key={`${item.id}:${item.conversation}`}
                  onClick={() =>
                    appendQuote(quoteRequest.quote, {
                      id: item.id,
                      conversation: item.conversation,
                    })
                  }
                >
                  {item.name} · {item.agent}
                </Button>
              ))}
            {!snapshot?.sessions.some((item) => item.worktree === quoteRequest.worktree) && (
              <p>Start an agent session in this worktree before quoting text.</p>
            )}
            <Button variant="outline" onClick={() => setQuoteRequest(undefined)}>
              Cancel quote
            </Button>
          </section>
        )}
        {selected && (
          <ConversationScreen
            snapshot={snapshot}
            tab={sessionTab}
            titleRef={titleRef}
            reviewMenu={reviewMenu}
            promptRef={promptRef}
            navigate={navigate}
            onQuote={(quote) => appendQuote(quote, selected, false)}
            onAction={act}
            onRetry={submitPending}
            onTab={(tab) => {
              setSessionTab(tab);
              window.history.pushState(
                null,
                '',
                `#${encodeURIComponent(JSON.stringify({ view, selection: selected, worktree: reviewWorktree, tab }))}`,
              );
            }}
          />
        )}
      </main>
      <TodoNotifications snapshot={pairing ? null : snapshot} />
    </FullscreenAttentionContext.Provider>
  );
}
