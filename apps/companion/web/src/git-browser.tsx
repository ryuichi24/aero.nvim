import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { post } from './api';
import type { Snapshot } from './types';
import './git-browser.css';

interface GitEntry {
  path: string;
  original_path?: string;
  index: string;
  worktree: string;
}

export function GitBrowser({
  snapshot,
  selectedWorktree,
}: {
  snapshot: Snapshot | null;
  selectedWorktree?: string;
}) {
  const [chosen, setChosen] = useState('');
  const [selected, setSelected] = useState<{ path: string; staged: boolean }>();
  const client = useQueryClient();
  const trees = snapshot?.worktrees || [];
  const worktree =
    trees.find((tree) => tree.path === chosen)?.path ||
    trees.find((tree) => tree.path === selectedWorktree)?.path ||
    trees[0]?.path;
  const online = !!snapshot?.connected && !!worktree;
  const status = useQuery({
    queryKey: ['git', worktree, 'status'],
    queryFn: () => post<{ entries: GitEntry[] }>('git/status', { worktree }),
    enabled: online,
    refetchInterval: 5000,
  });
  const diff = useQuery({
    queryKey: ['git', worktree, 'diff', selected],
    queryFn: () => post<{ content: string }>('git/diff', { worktree, ...selected }),
    enabled: online && !!selected,
    refetchInterval: 5000,
    gcTime: 0,
  });
  return (
    <section aria-label="Git browser">
      <h2>Git changes</h2>
      <label>
        Worktree
        <select
          value={worktree || ''}
          onChange={(event) => {
            setChosen(event.target.value);
            setSelected(undefined);
          }}
        >
          {trees.map((tree) => (
            <option key={tree.path} value={tree.path}>
              {tree.branch || tree.path} · {tree.path}
            </option>
          ))}
        </select>
      </label>
      {!worktree && <p>No worktrees available.</p>}
      {!snapshot?.connected && <p role="status">Connect to Neovim to browse Git changes.</p>}
      <button
        disabled={!online || status.isFetching || diff.isFetching}
        onClick={() => void client.invalidateQueries({ queryKey: ['git', worktree] })}
      >
        Refresh
      </button>
      {status.isLoading && <p role="status">Loading Git status…</p>}
      {status.error && <p role="alert">{status.error.message}</p>}
      {status.data && (
        <>
          {status.data.entries.length === 0 && <p role="status">Working tree clean.</p>}
          <div className="source-layout">
            <nav className="source-tree" aria-label="Changed files">
              {[true, false].map((staged) => {
                const entries = status.data.entries.filter((entry) =>
                  staged ? ![' ', '?'].includes(entry.index) : entry.worktree !== ' ',
                );
                return (
                  <div key={String(staged)}>
                    <h3>
                      {staged ? 'Staged' : 'Unstaged'} ({entries.length})
                    </h3>
                    <ul className="source-entries">
                      {entries.map((entry) => (
                        <li key={entry.path}>
                          <button
                            aria-current={
                              selected?.path === entry.path && selected.staged === staged
                                ? 'true'
                                : undefined
                            }
                            onClick={() => setSelected({ path: entry.path, staged })}
                          >
                            <code>{staged ? entry.index : entry.worktree}</code>{' '}
                            {entry.original_path ? `${entry.original_path} → ` : ''}
                            {entry.path}
                            {entry.index === '?' ? ' (untracked)' : ''}
                          </button>
                        </li>
                      ))}
                    </ul>
                    {!entries.length && (
                      <p className="navigation-empty">
                        No {staged ? 'staged' : 'unstaged'} changes.
                      </p>
                    )}
                  </div>
                );
              })}
            </nav>
            <div className="source-reader">
              {!selected && <p>Select a changed file to view its diff.</p>}
              {selected && (
                <h3>
                  {selected.path} · {selected.staged ? 'Staged' : 'Unstaged'}
                </h3>
              )}
              {diff.isLoading && <p role="status">Loading diff…</p>}
              {diff.error && <p role="alert">{diff.error.message}</p>}
              {diff.data &&
                (diff.data.content ? (
                  <pre className="git-diff" aria-label="File diff">
                    <code>
                      {diff.data.content.split('\n').map((line, index) => (
                        <span
                          key={index}
                          style={{
                            display: 'block',
                            minHeight: '1em',
                            background: line.startsWith('+')
                              ? '#14532d55'
                              : line.startsWith('-')
                                ? '#7f1d1d55'
                                : undefined,
                            color: line.startsWith('@@') ? '#7dd3fc' : undefined,
                          }}
                        >
                          {line}
                        </span>
                      ))}
                    </code>
                  </pre>
                ) : (
                  <p>
                    No textual changes to display (the file may be empty or have only metadata
                    changes).
                  </p>
                ))}
            </div>
          </div>
        </>
      )}
    </section>
  );
}
