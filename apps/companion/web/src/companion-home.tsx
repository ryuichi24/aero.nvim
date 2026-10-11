import type { Selection, Snapshot } from './types';
import type { View } from './companion-state';
import { useState } from 'react';
import { readStored, store } from './browser-storage';
import { actionableAttention } from './attention';

export function CompanionHome({
  snapshot,
  recent,
  onSelect,
  onNavigate,
  onCreate,
}: {
  snapshot: Snapshot | null;
  recent: string[];
  onSelect: (selection: Selection) => void;
  onNavigate: (view: View) => void;
  onCreate: () => void;
}) {
  const sessions = snapshot?.sessions || [];
  const running = sessions.filter(
    (session) => session.status === 'busy' || session.status === 'starting',
  ).length;
  const [pins, setPins] = useState<string[]>(() => {
    const saved = readStored<unknown>('aero-pinned-sessions', []);
    return Array.isArray(saved) ? saved.filter((id): id is string => typeof id === 'string') : [];
  });
  const ordered = [...sessions].sort((a, b) => {
    const rank = (id: string) => (recent.includes(id) ? recent.indexOf(id) : recent.length);
    if (pins.includes(a.id) !== pins.includes(b.id)) return pins.includes(a.id) ? -1 : 1;
    return rank(a.id) - rank(b.id);
  });
  const permissions = actionableAttention(snapshot).length;
  return (
    <section className="companion-home border-0 bg-transparent p-0" aria-labelledby="home-title">
      <h2 id="home-title" className="mb-6 text-3xl font-semibold tracking-tight">
        Your workspace, at a glance
      </h2>
      <div className="my-5 rounded-3xl bg-raised/70 p-6">
        <p className="text-sm font-medium text-slate-300">Needs attention</p>
        <strong className="my-2 block text-6xl font-semibold tracking-tight">{permissions}</strong>
        <p className="text-slate-300">
          {permissions
            ? `${permissions} permission${permissions === 1 ? ' requires' : 's require'} a response`
            : snapshot?.connected
              ? 'You’re all caught up'
              : 'Connect to see your agents’ latest updates'}
        </p>
        <button onClick={() => onNavigate('inbox')}>Review inbox →</button>
      </div>
      <div className="quick-actions" aria-label="Quick actions">
        {(
          [
            ['sessions', 'New session'],
            ['reports', 'Reports'],
            ['git', 'Changes'],
            ['source', 'Source'],
          ] as const
        ).map(([view, label]) => (
          <button key={view} onClick={() => (view === 'sessions' ? onCreate() : onNavigate(view))}>
            {label}
          </button>
        ))}
      </div>
      <div className="mt-7 mb-3 flex items-center justify-between gap-3">
        <h3 className="m-0 text-xl">Continue working</h3>
        <button
          className="m-0 border-0 bg-transparent text-sky-300"
          onClick={() => onNavigate('sessions')}
        >
          See all sessions
        </button>
      </div>
      <div className="home-session-list">
        {ordered.slice(0, 5).map((session) => (
          <button
            key={session.id}
            className="session-button"
            aria-label={`${session.name} · ${session.status} · ${session.agent}`}
            onClick={() => onSelect({ id: session.id, conversation: session.conversation })}
          >
            <span className="session-line">
              <strong>{session.name}</strong>
              <span className={`status-badge status-${session.status}`}>{session.status}</span>
            </span>
            <span className="session-agent">
              {session.activity || session.agent} ·{' '}
              {session.worktree.split('/').filter(Boolean).at(-1)}
            </span>
            {pins.includes(session.id) && <span className="text-xs text-sky-300">Pinned</span>}
          </button>
        ))}
      </div>
      {sessions.length > 0 && (
        <details className="my-3 rounded-2xl bg-raised p-3">
          <summary className="min-h-11 cursor-pointer py-2">Customize pinned sessions</summary>
          {sessions.map((session) => (
            <button
              key={session.id}
              aria-pressed={pins.includes(session.id)}
              onClick={() => {
                const next = pins.includes(session.id)
                  ? pins.filter((id) => id !== session.id)
                  : [...pins, session.id];
                setPins(next);
                store('aero-pinned-sessions', next);
              }}
            >
              {pins.includes(session.id) ? 'Unpin' : 'Pin'} {session.name}
            </button>
          ))}
        </details>
      )}
      {!sessions.length && (
        <p className="navigation-empty">
          No sessions yet. Open Sessions to create your first agent session.
        </p>
      )}
      <div className="my-5 rounded-3xl bg-raised/70 p-6">
        <h3>Running sessions</h3>
        <p className="text-slate-300">
          {running} {running === 1 ? 'agent' : 'agents'} working
        </p>
        <button onClick={() => onNavigate('sessions')}>Browse sessions →</button>
      </div>
    </section>
  );
}
