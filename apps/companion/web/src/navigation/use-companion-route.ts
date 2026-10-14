// URL/history synchronization, preserving pending-action recovery on initial load.
import { useEffect, useState, type Dispatch, type RefObject, type SetStateAction } from 'react';
import { useCompanionDispatch } from '../companion-context';
import type { View } from '../companion-state';
import type { PendingAction, Selection } from '../types';
export type SessionTab = 'conversation' | 'artifacts' | 'details';

export function useCompanionRoute(
  view: View,
  selected: Selection | null,
  worktree: string,
  tab: SessionTab,
  pending: RefObject<PendingAction | null>,
  setWorktree: Dispatch<SetStateAction<string>>,
  setTab: Dispatch<SetStateAction<SessionTab>>,
  setWorkspaceView: Dispatch<SetStateAction<'reports' | 'git' | 'source'>>,
) {
  const dispatch = useCompanionDispatch();
  const [ready, setReady] = useState(false);
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
          setTab(['artifacts', 'details'].includes(route.tab) ? route.tab : 'conversation');
          if (typeof route.worktree === 'string') setWorktree(route.worktree);
        } else dispatch({ type: 'navigate', view: 'home' });
      } catch {
        /* Ignore unrelated or obsolete URL fragments. */
      }
    }
    if (!pending.current) restore();
    setReady(true);
    window.addEventListener('popstate', restore);
    return () => window.removeEventListener('popstate', restore);
  }, [dispatch, pending, setTab, setWorktree]);
  useEffect(() => {
    if (ready)
      window.history.replaceState(
        null,
        '',
        `#${encodeURIComponent(JSON.stringify({ view, selection: selected, worktree, tab }))}`,
      );
  }, [ready, view, selected, worktree, tab]);

  function navigate(next: View, nextWorktree = worktree) {
    setWorktree(nextWorktree);
    dispatch({ type: 'navigate', view: next });
    if (next === 'reports' || next === 'git' || next === 'source') setWorkspaceView(next);
    if (!window.location.hash)
      window.history.replaceState(
        null,
        '',
        `#${encodeURIComponent(JSON.stringify({ view, selection: selected, worktree }))}`,
      );
    window.history.pushState(
      null,
      '',
      `#${encodeURIComponent(JSON.stringify({ view: next, selection: selected, worktree: nextWorktree }))}`,
    );
  }
  return navigate;
}
