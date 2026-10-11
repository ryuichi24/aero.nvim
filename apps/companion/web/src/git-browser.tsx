import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { post } from './api';
import type { Snapshot } from './types';
import { groupSessions, type WorktreeGroup } from './sessionGroups';
import './git-browser.css';

interface GitEntry {
  path: string;
  original_path?: string;
  index: string;
  worktree: string;
}

function GitWorktree({
  tree,
  active,
  online,
  onSelect,
}: {
  tree: WorktreeGroup;
  active: boolean;
  online: boolean;
  onSelect: () => void;
}) {
  const status = useQuery({
    queryKey: ['git', tree.path, 'status'],
    queryFn: () => post<{ entries: GitEntry[] }>('git/status', { worktree: tree.path }),
    enabled: online,
    refetchInterval: 5000,
  });
  const entries = status.data?.entries;
  return (
    <button className="git-worktree" aria-pressed={active} onClick={onSelect}>
      <strong>{tree.label}</strong>
      <span className="git-worktree-path">{tree.path}</span>
      <span>
        {status.error
          ? 'Status unavailable'
          : !online
            ? 'Offline'
            : !entries
              ? 'Loading status…'
              : !entries.length
                ? 'Working tree clean'
                : `${entries.filter((entry) => ![' ', '?'].includes(entry.index)).length} staged · ${entries.filter((entry) => entry.worktree !== ' ').length} unstaged`}
      </span>
    </button>
  );
}

export function GitBrowser({
  snapshot,
  selectedWorktree,
}: {
  snapshot: Snapshot | null;
  selectedWorktree?: string;
}) {
  const [chosen, setChosen] = useState('');
  const [chosenWorkspace, setChosenWorkspace] = useState('');
  const [fileSelection, setSelected] = useState<{
    worktree: string;
    path: string;
    staged: boolean;
  }>();
  const client = useQueryClient();
  const groups = snapshot
    ? groupSessions({ ...snapshot, workspaces: snapshot.workspaces || [], sessions: [] })
    : [];
  const workspace =
    groups.find((group) => group.key === chosenWorkspace) ||
    groups.find((group) =>
      group.worktrees.some((tree) => tree.path === (chosen || selectedWorktree)),
    ) ||
    groups[0];
  const trees = workspace?.worktrees || [];
  const worktree =
    trees.find((tree) => tree.path === chosen)?.path ||
    trees.find((tree) => tree.path === selectedWorktree)?.path ||
    trees[0]?.path;
  const selected = fileSelection?.worktree === worktree ? fileSelection : undefined;
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
        Workspace
        <select
          value={workspace?.key || ''}
          onChange={(event) => {
            setChosenWorkspace(event.target.value);
            setChosen('');
            setSelected(undefined);
          }}
        >
          {groups.map((group) => (
            <option key={group.key} value={group.key}>
              {group.name}
              {group.root ? ` · ${group.root}` : ''}
            </option>
          ))}
        </select>
      </label>
      {workspace && (
        <nav className="git-worktrees" aria-label={`${workspace.name} worktrees`}>
          {trees.map((tree) => (
            <GitWorktree
              key={tree.path}
              tree={tree}
              active={tree.path === worktree}
              online={!!snapshot?.connected}
              onSelect={() => {
                setChosen(tree.path);
                setSelected(undefined);
              }}
            />
          ))}
        </nav>
      )}
      {!worktree && <p>No worktrees available.</p>}
      {!snapshot?.connected && <p role="status">Connect to Neovim to browse Git changes.</p>}
      <button
        disabled={!online || status.isFetching || diff.isFetching}
        onClick={() => {
          for (const tree of trees) void client.invalidateQueries({ queryKey: ['git', tree.path] });
        }}
      >
        Refresh
      </button>
      {worktree && (
        <h3>
          {workspace?.name} / {trees.find((tree) => tree.path === worktree)?.label}
        </h3>
      )}
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
                            onClick={() =>
                              setSelected({ worktree: worktree!, path: entry.path, staged })
                            }
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
