import { useState } from 'react';
import { Button } from './components/ui/button';
import { Input } from './components/ui/input';
import { Collapsible, CollapsibleTrigger } from './components/ui/collapsible';
import { Label } from './components/ui/label';
import { StatusBadge } from './components/ui/status-badge';
import { LifecycleForm, type LifecycleAction } from './lifecycle-controls';
import type { Selection, Session, Snapshot } from './types';
import { useSessionSnapshot } from './connection/use-session-snapshot';

function HistoryPreviewContent({
  session,
  epoch,
  online,
}: {
  session: Session;
  epoch?: string;
  online: boolean;
}) {
  const history = useSessionSnapshot(session, epoch, online);
  if (history.isLoading) return <p role="status">Loading saved conversation…</p>;
  if (history.isError)
    return <p role="alert">Could not load history. Open the session to retry.</p>;
  if (!online && !history.data) return <p role="status">Connect to load saved history.</p>;
  return (
    <pre className="max-h-80 overflow-auto whitespace-pre-wrap">
      {history.session?.blocks
        ?.filter((block) => block.text)
        .map((block) => block.text)
        .join('\n\n') || 'No saved messages.'}
    </pre>
  );
}

function LazyHistoryPreview({
  session,
  epoch,
  online,
  active,
}: {
  session: Session;
  epoch?: string;
  online: boolean;
  active: boolean;
}) {
  const [open, setOpen] = useState(false);
  return (
    <Collapsible
      onToggle={(event) => {
        if (event.target === event.currentTarget) setOpen(event.currentTarget.open);
      }}
    >
      <CollapsibleTrigger>Preview history</CollapsibleTrigger>
      {open && active && <HistoryPreviewContent session={session} epoch={epoch} online={online} />}
    </Collapsible>
  );
}

export function GeneralBrowser({
  snapshot,
  onSelect,
  onAction,
  disabled,
  active = true,
}: {
  snapshot: Snapshot | null;
  onSelect: (selection: Selection) => void;
  onAction?: LifecycleAction;
  disabled: boolean;
  active?: boolean;
}) {
  const [query, setQuery] = useState('');
  const [archived, setArchived] = useState(false);
  const words = query.trim().toLocaleLowerCase().split(/\s+/);
  const sessions = (snapshot?.sessions || [])
    .filter((session) => session.scope === 'general' && !!session.archived === archived)
    .filter((session) => {
      const text = [
        session.name,
        session.agent,
        ...(session.blocks || []).map((block) => block.text || ''),
      ]
        .join(' ')
        .toLocaleLowerCase();
      return words.every((word) => text.includes(word));
    })
    .sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned) || a.name.localeCompare(b.name));
  return (
    <section aria-label="General conversations">
      <h3>General</h3>
      <p className="navigation-help">
        Workspace-independent chats. Read history without resuming an agent.
      </p>
      {onAction && (
        <LifecycleForm
          key={JSON.stringify([snapshot?.agents, snapshot?.default_agent])}
          title="New general chat"
          path="session_create"
          data={{ scope: 'general' }}
          agents={snapshot?.agents || []}
          defaultAgent={snapshot?.default_agent}
          field="name"
          disabled={disabled}
          onAction={onAction}
        />
      )}
      <Label className="session-search">
        Search general history
        <Input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={
            snapshot?.sessions.some((session) => session.transcript_lazy)
              ? 'Conversation name or agent'
              : 'Conversation name or message text'
          }
        />
      </Label>
      <Button variant="outline" aria-pressed={archived} onClick={() => setArchived(!archived)}>
        {archived ? 'Show current chats' : 'Show archived chats'}
      </Button>
      {sessions.length === 0 && (
        <p className="navigation-empty">No matching general conversations.</p>
      )}
      <div className="home-session-list">
        {sessions.map((session) => (
          <div key={session.id}>
            <Button
              variant="ghost"
              className="session-button"
              onClick={() => onSelect({ id: session.id, conversation: session.conversation })}
            >
              <span className="session-line">
                <strong>
                  {session.pinned ? '★ ' : ''}
                  {session.name}
                </strong>
                <StatusBadge status={session.status} />
              </span>
              <span className="session-agent">General · {session.agent}</span>
            </Button>
            {session.transcript_lazy ? (
              <LazyHistoryPreview
                session={session}
                epoch={snapshot?.epoch}
                online={snapshot?.connected === true}
                active={active}
              />
            ) : (
              <Collapsible>
                <CollapsibleTrigger>Preview history</CollapsibleTrigger>
                <pre className="whitespace-pre-wrap">
                  {(session.blocks || [])
                    .filter((block) => block.text)
                    .map((block) => block.text)
                    .join('\n\n') || 'No saved messages.'}
                </pre>
              </Collapsible>
            )}
            {onAction && (
              <div className="local-nav" aria-label={`Manage ${session.name}`}>
                <Button
                  variant="outline"
                  disabled={disabled || !session.target}
                  onClick={() =>
                    onAction('session_update', {
                      session: session.id,
                      target: session.target,
                      field: 'pinned',
                      value: !session.pinned,
                    })
                  }
                >
                  {session.pinned ? 'Unpin' : 'Pin'}
                </Button>
                <Button
                  variant="outline"
                  disabled={disabled || !session.target}
                  onClick={() =>
                    onAction('session_update', {
                      session: session.id,
                      target: session.target,
                      field: 'archived',
                      value: !session.archived,
                    })
                  }
                >
                  {session.archived ? 'Restore' : 'Archive'}
                </Button>
              </div>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}
