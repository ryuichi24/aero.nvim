import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { Snapshot } from './types';
import { SourceBrowser } from './source-browser';
import { GitBrowser } from './git-browser';
import type { Quote } from './quote';
import { ReferenceBrowser } from './reference-browser';
import type { LifecycleAction } from './lifecycle-controls';

// Keep visited readers mounted so each context retains its tree, file, and scroll position.
export function WorkspaceReview({
  snapshot,
  worktree,
  view,
  onQuote,
  onAction,
  actionsDisabled,
}: {
  snapshot: Snapshot | null;
  worktree: string;
  view: string;
  onQuote?: (quote: Quote, worktree: string) => void;
  onAction?: LifecycleAction;
  actionsDisabled?: boolean;
}) {
  const [visited, setVisited] = useState<Record<string, string[]>>({});
  const positions = useRef(new Map<string, { top: number; left: number }>());
  const active = !!worktree && ['reports', 'source', 'git', 'reference'].includes(view);
  const mounted = visited[worktree]?.includes(view) === true;
  useLayoutEffect(() => {
    if (!active || !mounted) return;
    const key = JSON.stringify([worktree, view]);
    const position = positions.current.get(key) || { top: 0, left: 0 };
    // These readers scroll with the page, whose position is otherwise shared by all tabs.
    if (window.scrollY !== position.top || window.scrollX !== position.left) {
      window.scrollTo({ ...position, behavior: 'instant' });
    }
    const remember = () => {
      positions.current.set(key, { top: window.scrollY, left: window.scrollX });
    };
    window.addEventListener('scroll', remember, { passive: true });
    return () => window.removeEventListener('scroll', remember);
  }, [active, mounted, worktree, view]);
  useEffect(() => {
    if (!worktree || !['reports', 'source', 'git', 'reference'].includes(view)) return;
    setVisited((previous) =>
      previous[worktree]?.includes(view)
        ? previous
        : { ...previous, [worktree]: [...(previous[worktree] || []), view] },
    );
  }, [worktree, view]);
  return (
    <>
      {Object.entries(visited).map(([path, views]) => {
        const tree = snapshot?.worktrees.find((item) => item.path === path);
        if (!tree || !snapshot) return null;
        const context = { ...snapshot, worktrees: [tree] };
        return (
          <div key={path} hidden={path !== worktree}>
            {views.map((tool) => (
              <div key={tool} hidden={view !== tool}>
                {tool === 'reference' ? (
                  <ReferenceBrowser
                    snapshot={{
                      ...context,
                      connected: context.connected && path === worktree && view === tool,
                    }}
                    worktree={path}
                    onAction={onAction}
                    disabled={actionsDisabled}
                  />
                ) : tool === 'git' ? (
                  <GitBrowser
                    snapshot={{
                      ...context,
                      connected: context.connected && path === worktree && view === tool,
                    }}
                    selectedWorktree={path}
                    contextControlled
                  />
                ) : (
                  <SourceBrowser
                    onQuote={onQuote}
                    snapshot={{
                      ...context,
                      connected: context.connected && path === worktree && view === tool,
                    }}
                    selectedWorktree={path}
                    mode={tool === 'reports' ? 'reports' : 'source'}
                    contextControlled
                  />
                )}
              </div>
            ))}
          </div>
        );
      })}
    </>
  );
}
