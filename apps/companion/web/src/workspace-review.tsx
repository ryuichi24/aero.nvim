import { useEffect, useState } from 'react';
import type { Snapshot } from './types';
import { SourceBrowser } from './source-browser';
import { GitBrowser } from './git-browser';
import type { Quote } from './quote';

// Keep visited readers mounted so each context retains its tree, file, and scroll position.
export function WorkspaceReview({
  snapshot,
  worktree,
  view,
  onQuote,
}: {
  snapshot: Snapshot | null;
  worktree: string;
  view: string;
  onQuote?: (quote: Quote, worktree: string) => void;
}) {
  const [visited, setVisited] = useState<Record<string, string[]>>({});
  useEffect(() => {
    if (!worktree || !['reports', 'source', 'git'].includes(view)) return;
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
                {tool === 'git' ? (
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
