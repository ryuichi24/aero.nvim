import { useEffect, useRef, useState } from 'react';
import { Button } from './components/ui/button';
import { Input } from './components/ui/input';
import { NativeSelect } from './components/ui/native-select';
import { Dialog } from './components/ui/dialog';
import { Collapsible, CollapsibleTrigger } from './components/ui/collapsible';
import { Label } from './components/ui/label';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { SourceCode } from './source-code';
import { QuoteSelection, type Quote } from './quote';
import type { FoldRange } from './source-folds';
import { post } from './api';
import { Markdown } from './markdown';
import { ImageDirectory, ImageSession } from './image-link';
import { FullscreenAttention } from './fullscreen-attention';
import type { Snapshot } from './types';
import { worktreeLabel } from './sessionGroups';

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
  filter = '',
}: {
  worktree: string;
  path: string;
  selected: string;
  online: boolean;
  onSelect: (path: string) => void;
  mode: 'source' | 'reports';
  filter?: string;
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
          <Button variant="outline" disabled={!online} onClick={() => void query.refetch()}>
            Retry
          </Button>
        </li>
      )}
      {query.data?.entries
        ?.filter(
          (entry) =>
            entry.directory || entry.name.toLowerCase().includes(filter.trim().toLowerCase()),
        )
        .map((entry) => {
          const entryPath = path ? `${path}/${entry.name}` : entry.name;
          const open = expanded[entryPath] ?? selected.startsWith(`${entryPath}/`);
          return (
            <li key={entry.name}>
              <Button
                variant="ghost"
                className="h-auto min-w-0 items-start justify-start whitespace-normal leading-snug"
                aria-expanded={entry.directory ? open : undefined}
                aria-current={!entry.directory && selected === entryPath ? 'true' : undefined}
                onClick={() =>
                  entry.directory
                    ? setExpanded((current) => ({ ...current, [entryPath]: !open }))
                    : onSelect(entryPath)
                }
              >
                <span className="w-3 shrink-0" aria-hidden="true">
                  {entry.directory ? (open ? '▾' : '▸') : '·'}
                </span>
                <span className="min-w-0 wrap-anywhere">
                  {entry.name}
                  {entry.directory ? '/' : ''}
                </span>
              </Button>
              {entry.directory && open && (
                <SourceFolder
                  worktree={worktree}
                  path={entryPath}
                  selected={selected}
                  online={online}
                  onSelect={onSelect}
                  mode={mode}
                  filter={filter}
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
      {!!filter.trim() &&
        !!query.data?.entries?.length &&
        !query.data.entries.some(
          (entry) =>
            entry.directory || entry.name.toLowerCase().includes(filter.trim().toLowerCase()),
        ) && <li className="navigation-empty">No matching reports in this folder.</li>}
    </ul>
  );
}

export function SourceBrowser({
  snapshot,
  selectedWorktree,
  mode = 'source',
  contextControlled = false,
  onQuote,
}: {
  snapshot: Snapshot | null;
  selectedWorktree?: string;
  mode?: 'source' | 'reports';
  contextControlled?: boolean;
  onQuote?: (quote: Quote, worktree: string) => void;
}) {
  const [chosen, setChosen] = useState<string>();
  const [worktreeSearch, setWorktreeSearch] = useState('');
  const [path, setPath] = useState('');
  const [readerOpen, setReaderOpen] = useState(true);
  const [reportSearch, setReportSearch] = useState('');
  const [preview, setPreview] = useState(true);
  const [fullscreen, setFullscreen] = useState(false);
  const fullscreenDialog = useRef<HTMLDialogElement>(null);
  const fullscreenButton = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!fullscreen) return;
    return () => {
      // The toolbar remounts when fullscreen closes; focus its current button.
      // eslint-disable-next-line react-hooks/exhaustive-deps
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
  const [folds, setFolds] = useState<{ key: string; ranges: FoldRange[]; error?: boolean }>();
  const [collapsed, setCollapsed] = useState<Set<number>>(new Set());
  const foldKey = JSON.stringify([worktree, path, content]);
  const ranges = folds?.key === foldKey ? folds.ranges : [];
  const collapsedByDefault = snapshot?.companion?.ui?.source_collapsed_by_default === true;
  useEffect(() => {
    setCollapsed(new Set());
    if (content === undefined || typeof Worker === 'undefined') return;
    const worker = new Worker(new URL('./source-folds.worker.ts', import.meta.url), {
      type: 'module',
    });
    worker.onmessage = (event: MessageEvent<{ ranges: FoldRange[]; error?: boolean }>) => {
      setFolds({ key: foldKey, ...event.data });
      if (collapsedByDefault) {
        setCollapsed(new Set(event.data.ranges.map((range) => range.start)));
      }
    };
    worker.onerror = () => setFolds({ key: foldKey, ranges: [], error: true });
    worker.postMessage({ id: 1, content, extension });
    return () => worker.terminate();
  }, [foldKey, content, extension, collapsedByDefault]);
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
  function quoteToPrompt(quote: Quote) {
    setFullscreen(false);
    if (worktree) onQuote?.(quote, worktree);
  }

  const reader = content !== undefined && (
    <>
      <div className="source-reader-toolbar">
        {!(markdown && preview) && ranges.length > 0 && (
          <>
            <Button
              variant="outline"
              onClick={() => setCollapsed(new Set(ranges.map((range) => range.start)))}
            >
              Collapse all
            </Button>
            <Button
              variant="outline"
              disabled={!collapsed.size}
              onClick={() => setCollapsed(new Set())}
            >
              Expand all
            </Button>
          </>
        )}
        {fullscreen && <strong className="source-reader-path">{path}</strong>}
        {markdown && (
          <Button
            variant="outline"
            aria-pressed={preview}
            onClick={() => setPreview((value) => !value)}
          >
            {preview ? 'Show source' : 'Show preview'}
          </Button>
        )}
        <Button
          variant="outline"
          ref={!fullscreen ? fullscreenButton : undefined}
          onClick={() => setFullscreen((value) => !value)}
        >
          {fullscreen ? 'Exit fullscreen' : 'Fullscreen'}
        </Button>
        {fullscreen && <FullscreenAttention />}
      </div>
      <QuoteSelection
        key={`${worktree}:${path}:${preview}`}
        source={path}
        language={language}
        onQuote={onQuote ? quoteToPrompt : undefined}
      >
        {markdown && preview ? (
          <div className="source-preview" aria-label={`${path} preview`}>
            <ImageSession.Provider
              value={snapshot?.sessions.find((session) => session.worktree === worktree)?.id || ''}
            >
              <ImageDirectory.Provider
                value={
                  mode === 'reports'
                    ? trees.find((tree) => tree.path === worktree)?.reports_directory || ''
                    : `${worktree}/${parts.slice(0, -1).join('/')}`
                }
              >
                <Markdown text={content} />
              </ImageDirectory.Provider>
            </ImageSession.Provider>
          </div>
        ) : (
          <>
            {folds?.key === foldKey && folds.error && (
              <p role="status">Folding unavailable for this file.</p>
            )}
            <SourceCode
              key={`${worktree}:${path}:${content}`}
              onQuote={onQuote ? quoteToPrompt : undefined}
              content={content}
              path={path}
              language={language}
              ranges={ranges}
              collapsed={collapsed}
              onToggle={(line) =>
                setCollapsed((current) => {
                  const next = new Set(current);
                  if (next.has(line)) next.delete(line);
                  else next.add(line);
                  return next;
                })
              }
            />
          </>
        )}
      </QuoteSelection>
    </>
  );

  return (
    <section
      className={mode === 'reports' ? 'report-browser' : undefined}
      aria-label={mode === 'reports' ? 'Report browser' : 'Source browser'}
    >
      <h2>{mode === 'reports' ? 'Reports' : 'Source code'}</h2>
      {mode === 'reports' && (
        <Label>
          Search report names
          <Input
            type="search"
            value={reportSearch}
            onChange={(event) => {
              setReportSearch(event.target.value);
              setReaderOpen(false);
            }}
            placeholder="Find a report in this worktree"
          />
        </Label>
      )}
      {!contextControlled && mode === 'reports' && trees.length > 0 ? (
        <Collapsible className="report-worktree-picker" open={!chosen && trees.length > 1}>
          <CollapsibleTrigger>
            <span className="report-worktree-summary">
              <span className="report-worktree-hint">Reports from</span>
              <strong>
                {trees.find((tree) => tree.path === worktree)?.branch ||
                  worktree?.split('/').filter(Boolean).at(-1)}
              </strong>
              <span className="report-worktree-hint">
                {worktree?.split('/').filter(Boolean).slice(-2).join('/')}
              </span>
            </span>
            <span className="report-worktree-change">Change</span>
          </CollapsibleTrigger>
          <Label>
            Find a worktree
            <Input
              type="search"
              value={worktreeSearch}
              placeholder="Search branch or folder…"
              onChange={(event) => setWorktreeSearch(event.target.value)}
            />
          </Label>
          <div className="report-worktree-options" role="group" aria-label="Report worktrees">
            {trees
              .filter((tree) =>
                `${tree.branch || ''} ${tree.path}`
                  .toLowerCase()
                  .includes(worktreeSearch.trim().toLowerCase()),
              )
              .map((tree) => (
                <div className="report-worktree-card" key={tree.path}>
                  <Button
                    variant="ghost"
                    aria-pressed={tree.path === worktree}
                    onClick={(event) => {
                      setChosen(tree.path);
                      setPath('');
                      setWorktreeSearch('');
                      const picker = event.currentTarget.closest(
                        '.report-worktree-picker',
                      ) as HTMLDetailsElement;
                      picker.open = false;
                      picker.querySelector('summary')?.focus();
                    }}
                  >
                    <strong>{worktreeLabel(tree)}</strong>
                    <span className="report-worktree-hint">
                      {tree.path.split('/').filter(Boolean).slice(-2).join('/')}
                    </span>
                    {tree.path === worktree && (
                      <span className="report-worktree-selected">Selected</span>
                    )}
                  </Button>
                  <Collapsible className="report-worktree-path">
                    <CollapsibleTrigger>Full path</CollapsibleTrigger>
                    <code>{tree.path}</code>
                  </Collapsible>
                </div>
              ))}
            {!trees.some((tree) =>
              `${tree.branch || ''} ${tree.path}`
                .toLowerCase()
                .includes(worktreeSearch.trim().toLowerCase()),
            ) && <p role="status">No matching worktrees.</p>}
          </div>
        </Collapsible>
      ) : !contextControlled && mode === 'source' ? (
        <Label>
          Worktree
          <NativeSelect
            value={worktree || ''}
            onChange={(event) => {
              setChosen(event.target.value);
              setPath('');
            }}
          >
            {trees.map((tree) => (
              <option key={tree.path} value={tree.path}>
                {worktreeLabel(tree)} · {tree.path}
              </option>
            ))}
          </NativeSelect>
        </Label>
      ) : null}
      {!worktree && <p className="navigation-empty">No worktrees available.</p>}
      {worktree && (
        <>
          <nav className="session-breadcrumb" aria-label="Source path">
            <Button variant="ghost" onClick={() => setPath('')}>
              Root
            </Button>
            {parts.map((part, index) => (
              <Button
                variant="ghost"
                key={index}
                onClick={() => setPath(parts.slice(0, index + 1).join('/'))}
              >
                {part}
              </Button>
            ))}
          </nav>
          <div className="flex gap-2 my-3">
            <Button
              variant="outline"
              disabled={!path}
              onClick={() => setPath(parts.slice(0, -1).join('/'))}
            >
              ← Parent
            </Button>
            <Button
              variant="outline"
              disabled={query.isFetching || !snapshot?.connected}
              onClick={() => void client.invalidateQueries({ queryKey: [mode, worktree] })}
            >
              Refresh
            </Button>
          </div>
          {query.isFetching && <p role="status">Loading {mode}…</p>}
          {query.error && <p role="alert">{query.error.message}</p>}
          {!snapshot?.connected && <p role="status">Connect to Neovim to browse {mode}.</p>}
          {content !== undefined && readerOpen && (
            <Button
              variant="outline"
              className="mobile-reader-back"
              onClick={() => setReaderOpen(false)}
            >
              ← {mode === 'reports' ? 'All reports' : 'File tree'}
            </Button>
          )}
          <div className="source-layout" data-reading={content !== undefined && readerOpen}>
            <nav className="source-tree" aria-label="File tree">
              <SourceFolder
                key={worktree}
                worktree={worktree}
                path=""
                selected={path}
                online={!!snapshot?.connected}
                onSelect={(value) => {
                  setPath(value);
                  setReaderOpen(true);
                }}
                mode={mode}
                filter={mode === 'reports' ? reportSearch : ''}
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
              <Dialog
                open={fullscreen}
                onOpenChange={setFullscreen}
                ref={fullscreenDialog}
                className="source-fullscreen"
                aria-label="Fullscreen source reader"
                onCancel={() => setFullscreen(false)}
                onClose={() => setFullscreen(false)}
              >
                {fullscreen && reader}
              </Dialog>
            </div>
          </div>
        </>
      )}
    </section>
  );
}
