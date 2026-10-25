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

const statusColors: Record<string, string> = {
  M: 'text-amber-300',
  T: 'text-amber-300',
  A: 'text-green-300',
  '?': 'text-green-300',
  D: 'text-red-300',
  U: 'text-red-300',
  R: 'text-violet-300',
  C: 'text-violet-300',
};

interface ChangeFolder {
  folders: Map<string, ChangeFolder>;
  files: GitEntry[];
  count: number;
}

function changeTree(entries: GitEntry[]): ChangeFolder {
  const root: ChangeFolder = { folders: new Map(), files: [], count: 0 };
  for (const entry of entries) {
    let folder = root;
    folder.count++;
    const parts = entry.path.split('/');
    for (const part of parts.slice(0, -1)) {
      let child = folder.folders.get(part);
      if (!child) {
        child = { folders: new Map(), files: [], count: 0 };
        folder.folders.set(part, child);
      }
      folder = child;
      folder.count++;
    }
    folder.files.push(entry);
  }
  return root;
}

function ChangeTree({
  folder,
  staged,
  selectedPath,
  onSelect,
  path = '',
}: {
  folder: ChangeFolder;
  staged: boolean;
  selectedPath?: string;
  onSelect: (entry: GitEntry) => void;
  path?: string;
}) {
  return (
    <ul className="source-entries min-w-0 [&_ul]:ml-2">
      {[...folder.folders]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([name, child]) => {
          const childPath = path ? `${path}/${name}` : name;
          return (
            <li key={`folder:${name}`}>
              <details open>
                <summary
                  className="min-h-11 cursor-pointer rounded-lg px-2 py-2.5 text-sm wrap-anywhere text-slate-200 focus-visible:outline-2 focus-visible:outline-sky-300"
                  title={childPath}
                >
                  <span className="font-semibold">{name}/</span>{' '}
                  <span
                    className="text-xs text-slate-400"
                    aria-label={`${child.count} changed files`}
                  >
                    ({child.count})
                  </span>
                </summary>
                <ChangeTree
                  folder={child}
                  staged={staged}
                  selectedPath={selectedPath}
                  onSelect={onSelect}
                  path={childPath}
                />
              </details>
            </li>
          );
        })}
      {[...folder.files]
        .sort((a, b) => a.path.localeCompare(b.path))
        .map((entry) => (
          <li key={`file:${entry.path}`}>
            <button
              className="min-h-11 wrap-anywhere"
              title={entry.original_path ? `${entry.original_path} → ${entry.path}` : entry.path}
              aria-current={selectedPath === entry.path ? 'true' : undefined}
              onClick={() => onSelect(entry)}
            >
              <code
                className={`font-semibold ${statusColors[staged ? entry.index : entry.worktree] || 'text-slate-400'}`}
              >
                {staged ? entry.index : entry.worktree}
              </code>{' '}
              <span className="font-semibold">{entry.path.split('/').at(-1)}</span>
              {entry.original_path && (
                <span className="text-xs text-slate-400"> ← {entry.original_path}</span>
              )}
              {entry.index === '?' ? ' (untracked)' : ''}
            </button>
          </li>
        ))}
    </ul>
  );
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
  contextControlled = false,
}: {
  snapshot: Snapshot | null;
  selectedWorktree?: string;
  contextControlled?: boolean;
}) {
  const [chosen, setChosen] = useState('');
  const [chosenWorkspace, setChosenWorkspace] = useState('');
  const [readerOpen, setReaderOpen] = useState(true);
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
      {!contextControlled && (
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
      )}
      {!contextControlled && workspace && (
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
          {selected && readerOpen && (
            <button className="mobile-reader-back" onClick={() => setReaderOpen(false)}>
              ← Changed files
            </button>
          )}
          <div className="source-layout" data-reading={!!selected && readerOpen}>
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
                    <ChangeTree
                      key={`${worktree}:${staged}`}
                      folder={changeTree(entries)}
                      staged={staged}
                      selectedPath={selected?.staged === staged ? selected.path : undefined}
                      onSelect={(entry) => {
                        setSelected({ worktree: worktree!, path: entry.path, staged });
                        setReaderOpen(true);
                      }}
                    />
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
                          className={`block min-h-[1em] ${line.startsWith('+') ? 'bg-green-900/30' : line.startsWith('-') ? 'bg-red-900/30' : ''} ${line.startsWith('@@') ? 'text-sky-300' : ''}`}
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
