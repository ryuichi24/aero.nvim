import type { Selection, Snapshot } from './types';
import { Collapsible, CollapsibleTrigger } from './components/ui/collapsible';
import { StatusBadge } from './components/ui/status-badge';
import type { View } from './companion-state';
import { useState } from 'react';
import { readStored, store } from './browser-storage';
import { actionableAttention } from './attention';
import { Button } from './components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from './components/ui/card';
import {
  ArrowRightIcon,
  BookOpenIcon,
  FileTextIcon,
  FolderCodeIcon,
  GitBranchIcon,
  InboxIcon,
  PlusIcon,
  RadioIcon,
} from 'lucide-react';

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
      <p className="mb-2 text-xs font-medium tracking-widest text-muted-foreground uppercase">
        Overview
      </p>
      <h2 id="home-title" className="mb-2 text-2xl font-semibold tracking-tight sm:text-3xl">
        Your workspace, at a glance
      </h2>
      <p className="text-sm text-muted-foreground">
        Review requests, follow your agents, and pick up where you left off.
      </p>
      <div className="my-6 grid gap-4 sm:grid-cols-2">
        <Card>
          <CardHeader className="flex-row items-center justify-between gap-3">
            <CardTitle>Needs attention</CardTitle>
            <InboxIcon aria-hidden="true" className="size-5 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <strong className="my-2 block text-5xl font-semibold tracking-tight tabular-nums">
              {permissions}
            </strong>
            <p className="text-sm text-muted-foreground">
              {permissions
                ? `${permissions} permission${permissions === 1 ? ' requires' : 's require'} a response`
                : snapshot?.connected
                  ? 'You’re all caught up'
                  : 'Connect to see your agents’ latest updates'}
            </p>
            <Button
              variant={permissions ? 'default' : 'outline'}
              className="mt-4"
              onClick={() => onNavigate('inbox')}
            >
              Review inbox <ArrowRightIcon aria-hidden="true" />
            </Button>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex-row items-center justify-between gap-3">
            <CardTitle>Running sessions</CardTitle>
            <RadioIcon aria-hidden="true" className="size-5 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <strong className="my-2 block text-5xl font-semibold tracking-tight tabular-nums">
              {running}
            </strong>
            <p className="text-sm text-muted-foreground">
              {running} {running === 1 ? 'agent' : 'agents'} working
            </p>
            <Button variant="outline" className="mt-4" onClick={() => onNavigate('sessions')}>
              Browse sessions <ArrowRightIcon aria-hidden="true" />
            </Button>
          </CardContent>
        </Card>
      </div>
      <div
        className="my-4 grid grid-cols-2 gap-2 sm:grid-cols-3 xl:grid-cols-5"
        aria-label="Quick actions"
      >
        {(
          [
            ['sessions', 'New session', PlusIcon],
            ['reports', 'Reports', FileTextIcon],
            ['reference', 'References', BookOpenIcon],
            ['git', 'Changes', GitBranchIcon],
            ['source', 'Source', FolderCodeIcon],
          ] as const
        ).map(([view, label, Icon]) => (
          <Button
            variant={view === 'sessions' ? 'default' : 'outline'}
            className="min-h-14"
            key={view}
            onClick={() => (view === 'sessions' ? onCreate() : onNavigate(view))}
          >
            <Icon aria-hidden="true" /> {label}
          </Button>
        ))}
      </div>
      <div className="mt-7 mb-3 flex items-center justify-between gap-3">
        <h3 className="m-0 text-lg font-semibold">Continue working</h3>
        <Button variant="ghost" onClick={() => onNavigate('sessions')}>
          See all sessions
        </Button>
      </div>
      <div className="my-4 grid gap-3">
        {ordered.slice(0, 5).map((session) => (
          <Button
            variant="outline"
            key={session.id}
            className="h-auto min-w-0 flex-col items-stretch gap-2 whitespace-normal rounded-xl p-4 text-left"
            aria-label={`${session.name} · ${session.status} · ${session.agent}`}
            onClick={() => onSelect({ id: session.id, conversation: session.conversation })}
          >
            <span className="flex min-w-0 items-center justify-between gap-3">
              <strong className="min-w-0 wrap-anywhere">{session.name}</strong>
              <StatusBadge status={session.status} />
            </span>
            <span className="break-all text-sm font-normal text-muted-foreground">
              {session.activity || session.agent} ·{' '}
              {session.worktree.split('/').filter(Boolean).at(-1)}
            </span>
            {pins.includes(session.id) && <span className="text-xs text-sky-300">Pinned</span>}
          </Button>
        ))}
      </div>
      {sessions.length > 0 && (
        <Collapsible className="my-3 rounded-2xl bg-raised p-3">
          <CollapsibleTrigger>Customize pinned sessions</CollapsibleTrigger>
          {sessions.map((session) => (
            <Button
              variant={pins.includes(session.id) ? 'secondary' : 'outline'}
              className="m-1"
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
            </Button>
          ))}
        </Collapsible>
      )}
      {!sessions.length && (
        <Card className="border-dashed text-center">
          <CardContent className="flex flex-col items-center gap-3 py-8">
            <FolderCodeIcon aria-hidden="true" className="size-8 text-muted-foreground" />
            <h3 className="font-semibold">Start your first session</h3>
            <p className="max-w-sm text-sm text-muted-foreground">
              Choose an agent to start working. Your recent and pinned sessions will appear here.
            </p>
            <Button onClick={onCreate}>
              <PlusIcon aria-hidden="true" /> Create your first session
            </Button>
          </CardContent>
        </Card>
      )}
    </section>
  );
}
