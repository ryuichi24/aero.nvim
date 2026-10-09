import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { AgentTodos, latestTodos } from './agent-todos';
import type { Todo } from './agent-todos';
import type { Snapshot } from './types';

interface Card {
  key: string;
  name: string;
  todos: Todo[];
  revision: number;
}

function Notification({
  card,
  timeout,
  dismiss,
  focus,
}: {
  card: Card;
  timeout: number;
  dismiss: () => void;
  focus: boolean;
}) {
  const element = useRef<HTMLElement>(null);
  const dismissRef = useRef(dismiss);
  dismissRef.current = dismiss;
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (focus) element.current?.focus();
  }, [focus, card.revision]);
  useEffect(() => {
    if (timeout <= 0 || hovered || focused) return;
    const timer = window.setTimeout(() => dismissRef.current(), timeout);
    return () => window.clearTimeout(timer);
  }, [timeout, hovered, focused, card.revision]);
  return (
    <section
      ref={element}
      tabIndex={-1}
      className="todo-notification"
      aria-label={`${card.name} todo notification`}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setFocused(false);
      }}
      onKeyDown={(event) => {
        if (event.key === 'Escape') {
          event.stopPropagation();
          dismiss();
        }
      }}
    >
      <header>
        <strong>{card.name}</strong>
        <button aria-label={`Dismiss ${card.name} todos`} onClick={dismiss}>
          ×
        </button>
      </header>
      <AgentTodos todos={card.todos} />
    </section>
  );
}

export function TodoNotifications({ snapshot }: { snapshot: Snapshot | null }) {
  const baseline = useRef<Map<string, string> | null>(null);
  const epoch = useRef<string | undefined>(undefined);
  const recent = useRef<Card[]>([]);
  const revision = useRef(0);
  const [cards, setCards] = useState<Card[]>([]);
  const [focusKey, setFocusKey] = useState<string>();
  const [host, setHost] = useState<HTMLElement>(document.body);
  const enabled = snapshot?.companion?.ui?.todo_notifications !== false;
  const timeout = snapshot?.companion?.ui?.todo_notification_timeout ?? 15000;

  useEffect(() => {
    const locate = () =>
      setHost(document.querySelector<HTMLElement>('dialog[open], .image-preview') || document.body);
    const observer = new MutationObserver(locate);
    observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['open', 'class'],
    });
    locate();
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!snapshot) {
      baseline.current = null;
      recent.current = [];
      setCards([]);
      return;
    }
    if (!snapshot.connected) return;
    const reset = baseline.current === null || epoch.current !== snapshot.epoch;
    epoch.current = snapshot.epoch;
    const previous = reset ? new Map<string, string>() : baseline.current!;
    const next = new Map<string, string>();
    const updates: Card[] = [];
    for (const session of snapshot.sessions) {
      const key = JSON.stringify([session.id, session.conversation]);
      const todos = latestTodos(session.blocks || []);
      const signature = JSON.stringify(todos) || '';
      next.set(key, signature);
      if (todos !== undefined && (reset || previous.get(key) !== signature)) {
        updates.push({ key, name: session.name, todos, revision: ++revision.current });
      }
    }
    baseline.current = next;
    if (reset) recent.current = [];
    recent.current = [
      ...updates,
      ...recent.current.filter(
        (card) => next.has(card.key) && !updates.some((item) => item.key === card.key),
      ),
    ].map((card) => ({
      ...card,
      name:
        snapshot.sessions.find(
          (session) => JSON.stringify([session.id, session.conversation]) === card.key,
        )?.name || card.name,
    }));
    setCards((current) =>
      !enabled || reset
        ? []
        : [
            ...updates,
            ...current
              .filter(
                (card) => next.has(card.key) && !updates.some((item) => item.key === card.key),
              )
              .map((card) => recent.current.find((item) => item.key === card.key) || card),
          ],
    );
  }, [snapshot, enabled]);

  if (!snapshot || !enabled) return null;
  return createPortal(
    <aside className="todo-notifications" aria-label="Agent todo notifications">
      <button
        className="todo-notifications-trigger"
        disabled={!recent.current.length && !cards.length}
        onClick={() => {
          const card = cards[0] || recent.current[0];
          if (!card) return;
          setFocusKey(card.key);
          setCards((current) => [
            { ...card, revision: ++revision.current },
            ...current.filter((item) => item.key !== card.key),
          ]);
        }}
      >
        Todos
      </button>
      <div className="todo-notifications-stack" aria-live="polite" aria-relevant="additions text">
        {cards.map((card) => (
          <Notification
            key={card.key}
            card={card}
            timeout={timeout}
            focus={focusKey === card.key}
            dismiss={() => {
              setCards((current) => current.filter((item) => item.key !== card.key));
              setFocusKey(undefined);
            }}
          />
        ))}
      </div>
    </aside>,
    host,
  );
}
