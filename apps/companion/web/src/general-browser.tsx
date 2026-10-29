import { useState } from 'react';
import { LifecycleForm, type LifecycleAction } from './lifecycle-controls';
import type { Selection, Snapshot } from './types';

export function GeneralBrowser({
  snapshot,
  onSelect,
  onAction,
  disabled,
}: {
  snapshot: Snapshot | null;
  onSelect: (selection: Selection) => void;
  onAction?: LifecycleAction;
  disabled: boolean;
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
      <label className="session-search">
        Search general history
        <input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Conversation name or message text"
        />
      </label>
      <button aria-pressed={archived} onClick={() => setArchived(!archived)}>
        {archived ? 'Show current chats' : 'Show archived chats'}
      </button>
      {sessions.length === 0 && (
        <p className="navigation-empty">No matching general conversations.</p>
      )}
      <div className="home-session-list">
        {sessions.map((session) => (
          <div key={session.id}>
            <button
              className="session-button"
              onClick={() => onSelect({ id: session.id, conversation: session.conversation })}
            >
              <span className="session-line">
                <strong>
                  {session.pinned ? '★ ' : ''}
                  {session.name}
                </strong>
                <span className={`status-badge status-${session.status}`}>{session.status}</span>
              </span>
              <span className="session-agent">General · {session.agent}</span>
            </button>
            <details>
              <summary>Preview history</summary>
              <pre className="whitespace-pre-wrap">
                {(session.blocks || [])
                  .filter((block) => block.text)
                  .map((block) => block.text)
                  .join('\n\n') || 'No saved messages.'}
              </pre>
            </details>
            {onAction && (
              <div className="local-nav" aria-label={`Manage ${session.name}`}>
                <button
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
                </button>
                <button
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
                </button>
              </div>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}
