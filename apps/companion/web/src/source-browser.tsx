import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import hljs from 'highlight.js/lib/common';
import { post } from './api';
import { Markdown } from './markdown';
import type { Snapshot } from './types';

interface SourceResponse {
  entries?: { name: string; directory: boolean }[];
  content?: string;
}

function SourceFolder({
  worktree,
  path,
  selected,
  online,
  onSelect,
  mode,
}: {
  worktree: string;
  path: string;
  selected: string;
  online: boolean;
  onSelect: (path: string) => void;
  mode: 'source' | 'reports';
}) {
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const query = useQuery({
    queryKey: [mode, worktree, path],
    queryFn: () => post<SourceResponse>(mode, { worktree, path }),
    enabled: online,
  });
  return (
    <ul className="source-entries">
      {query.isFetching && <li role="status">Loading folder…</li>}
      {query.error && (
        <li role="alert">
          {query.error.message}{' '}
          <button disabled={!online} onClick={() => void query.refetch()}>
            Retry
          </button>
        </li>
      )}
      {query.data?.entries?.map((entry) => {
        const entryPath = path ? `${path}/${entry.name}` : entry.name;
        const open = expanded[entryPath] ?? selected.startsWith(`${entryPath}/`);
        return (
          <li key={entry.name}>
            <button
              aria-expanded={entry.directory ? open : undefined}
              aria-current={!entry.directory && selected === entryPath ? 'true' : undefined}
              onClick={() =>
                entry.directory
                  ? setExpanded((current) => ({ ...current, [entryPath]: !open }))
                  : onSelect(entryPath)
              }
            >
              <span aria-hidden="true">{entry.directory ? (open ? '▾ ' : '▸ ') : '· '}</span>
              {entry.name}
              {entry.directory ? '/' : ''}
            </button>
            {entry.directory && open && (
              <SourceFolder
                worktree={worktree}
                path={entryPath}
                selected={selected}
                online={online}
                onSelect={onSelect}
                mode={mode}
              />
            )}
          </li>
        );
      })}
      {query.data?.entries?.length === 0 && (
        <li className="navigation-empty">
          {mode === 'reports' ? 'No reports created yet.' : 'Empty directory.'}
        </li>
      )}
    </ul>
  );
}

export function SourceBrowser({
  snapshot,
  selectedWorktree,
  mode = 'source',
}: {
  snapshot: Snapshot | null;
  selectedWorktree?: string;
  mode?: 'source' | 'reports';
}) {
  const [chosen, setChosen] = useState<string>();
  const [path, setPath] = useState('');
  const [preview, setPreview] = useState(true);
  const [fullscreen, setFullscreen] = useState(false);
  const fullscreenDialog = useRef<HTMLDialogElement>(null);
  const fullscreenButton = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!fullscreen) return;
    const dialog = fullscreenDialog.current!;
    const overflow = document.body.style.overflow;
    dialog.showModal();
    document.body.style.overflow = 'hidden';
    return () => {
      dialog.close();
      document.body.style.overflow = overflow;
      fullscreenButton.current?.focus();
    };
  }, [fullscreen]);
  const client = useQueryClient();
  const trees = snapshot?.worktrees || [];
  const worktree =
    trees.find((tree) => tree.path === chosen)?.path ||
    trees.find((tree) => tree.path === selectedWorktree)?.path ||
    trees[0]?.path;
  const query = useQuery({
    queryKey: [mode, worktree, path],
    queryFn: () => post<SourceResponse>(mode, { worktree, path }),
    enabled: !!worktree && !!snapshot?.connected,
    gcTime: 0,
  });
  const parts = path.split('/').filter(Boolean);
  const content = query.data?.content;
  const extension = parts.at(-1)?.split('.').at(-1)?.toLowerCase() || '';
  const markdown = ['md', 'markdown', 'mdown', 'mkd'].includes(extension);
  const languages: Record<string, string> = {
    ts: 'typescript',
    tsx: 'typescript',
    js: 'javascript',
    jsx: 'javascript',
    py: 'python',
    sh: 'bash',
    yml: 'yaml',
    md: 'markdown',
  };
  const language = languages[extension] || extension;
  const highlighted =
    content !== undefined && !(markdown && preview) && hljs.getLanguage(language)
      ? hljs.highlight(content, { language }).value
      : undefined;

  const reader = content !== undefined && (
    <>
      <div className="source-reader-toolbar">
        {fullscreen && <strong className="source-reader-path">{path}</strong>}
        {markdown && (
          <button aria-pressed={preview} onClick={() => setPreview((value) => !value)}>
            {preview ? 'Show source' : 'Show preview'}
          </button>
        )}
        <button
          ref={!fullscreen ? fullscreenButton : undefined}
          onClick={() => setFullscreen((value) => !value)}
        >
          {fullscreen ? 'Exit fullscreen' : 'Fullscreen'}
        </button>
      </div>
      {markdown && preview ? (
        <div className="source-preview" aria-label={`${path} preview`}>
          <Markdown text={content} />
        </div>
      ) : (
        <div className="source-code" aria-label={path}>
          <pre className="source-lines" aria-hidden="true">
            {content
              .split('\n')
              .map((_, index) => index + 1)
              .join('\n')}
          </pre>
          <pre>
            <code
              className="hljs"
              {...(highlighted !== undefined
                ? { dangerouslySetInnerHTML: { __html: highlighted } }
                : { children: content })}
            />
          </pre>
        </div>
      )}
    </>
  );

  return (
    <section aria-label={mode === 'reports' ? 'Report browser' : 'Source browser'}>
      <h2>{mode === 'reports' ? 'Reports' : 'Source code'}</h2>
      <label>
        Worktree
        <select
          value={worktree || ''}
          onChange={(event) => {
            setChosen(event.target.value);
            setPath('');
          }}
        >
          {trees.map((tree) => (
            <option key={tree.path} value={tree.path}>
              {tree.branch || tree.path} · {tree.path}
            </option>
          ))}
        </select>
      </label>
      {!worktree && <p className="navigation-empty">No worktrees available.</p>}
      {worktree && (
        <>
          <nav className="session-breadcrumb" aria-label="Source path">
            <button onClick={() => setPath('')}>Root</button>
            {parts.map((part, index) => (
              <button key={index} onClick={() => setPath(parts.slice(0, index + 1).join('/'))}>
                {part}
              </button>
            ))}
          </nav>
          <div className="flex gap-2 my-3">
            <button disabled={!path} onClick={() => setPath(parts.slice(0, -1).join('/'))}>
              ← Parent
            </button>
            <button
              disabled={query.isFetching || !snapshot?.connected}
              onClick={() => void client.invalidateQueries({ queryKey: [mode, worktree] })}
            >
              Refresh
            </button>
          </div>
          {query.isFetching && <p role="status">Loading {mode}…</p>}
          {query.error && <p role="alert">{query.error.message}</p>}
          {!snapshot?.connected && <p role="status">Connect to Neovim to browse {mode}.</p>}
          <div className="source-layout">
            <nav className="source-tree" aria-label="File tree">
              <SourceFolder
                key={worktree}
                worktree={worktree}
                path=""
                selected={path}
                online={!!snapshot?.connected}
                onSelect={setPath}
                mode={mode}
              />
            </nav>
            <div className="source-reader">
              {content === undefined && !query.error && (
                <p className="navigation-empty">
                  {mode === 'reports'
                    ? 'Select a report to preview its Markdown.'
                    : 'Select a file from the tree to read its source.'}
                </p>
              )}
              {!fullscreen && reader}
              <dialog
                ref={fullscreenDialog}
                className="source-fullscreen"
                aria-label="Fullscreen source reader"
                onCancel={() => setFullscreen(false)}
                onClose={() => setFullscreen(false)}
              >
                {fullscreen && reader}
              </dialog>
            </div>
          </div>
        </>
      )}
    </section>
  );
}
