import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { operationID, post, RequestError } from './api';
import { Markdown } from './markdown';
import type { LifecycleAction } from './lifecycle-controls';
import type { ActionResponse, PendingAction, Snapshot } from './types';
import { worktreeLabel } from './sessionGroups';

type Entry = { name: string; directory: boolean };
type Transfer = { path: string; action: 'copy' | 'cut' };
type Listing = { entries: Entry[]; content?: string };
type Tree = Snapshot['worktrees'][number];

export function CancelReferenceTransfer({
  pending,
  disabled,
}: {
  pending: PendingAction;
  disabled: boolean;
}) {
  const [busy, setBusy] = useState(false);
  const [requested, setRequested] = useState(false);
  const [message, setMessage] = useState('');
  const request = useRef<Record<string, unknown> | null>(null);
  async function cancel() {
    if (busy) return;
    setBusy(true);
    request.current ||= {
      operation_id: operationID(),
      epoch: pending.data.epoch,
      target: pending.data.target,
      worktree: pending.data.worktree,
      transfer_id: pending.data.operation_id,
    };
    try {
      const response = await post<ActionResponse>('reference_cancel', request.current);
      if (response.result.status !== 'accepted')
        throw new RequestError('Cancellation outcome unknown; retry cancellation.', true);
      setRequested(true);
      setMessage(
        'Cancellation requested. Retry the original action to retrieve its final outcome.',
      );
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Cancellation failed');
      if (error instanceof RequestError && !error.unknownOutcome) request.current = null;
    } finally {
      setBusy(false);
    }
  }
  return (
    <section aria-label="Reference transfer cancellation">
      <button type="button" disabled={disabled || busy || requested} onClick={() => void cancel()}>
        Cancel reference transfer
      </button>
      {message && <p role="status">{message}</p>}
    </section>
  );
}

export function ReferenceItems({
  worktree,
  path = '',
  online,
  onSelect,
}: {
  worktree: string;
  path?: string;
  online: boolean;
  onSelect: (path: string, directory: boolean) => void;
}) {
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const query = useQuery({
    queryKey: ['reference', worktree, path],
    queryFn: () => post<Listing>('reference', { worktree, path }),
    enabled: online,
  });
  return (
    <ul className="source-entries">
      {query.isFetching && <li role="status">Loading references…</li>}
      {query.error && (
        <li role="alert">
          {query.error.message}{' '}
          <button disabled={!online} onClick={() => void query.refetch()}>
            Retry
          </button>
        </li>
      )}
      {query.data?.entries?.map((entry) => {
        const relative = path ? `${path}/${entry.name}` : entry.name;
        const open = !!expanded[relative];
        return (
          <li key={entry.name}>
            <button
              type="button"
              disabled={!online}
              aria-expanded={entry.directory ? open : undefined}
              onClick={() => {
                onSelect(relative, entry.directory);
                if (entry.directory) setExpanded((current) => ({ ...current, [relative]: !open }));
              }}
            >
              {entry.directory ? (open ? '▾ ' : '▸ ') : '· '}
              {entry.name}
              {entry.directory ? '/' : ''}
            </button>
            {entry.directory && open && (
              <ReferenceItems
                worktree={worktree}
                path={relative}
                online={online}
                onSelect={onSelect}
              />
            )}
          </li>
        );
      })}
      {query.data?.entries?.length === 0 && <li>No reference items yet.</li>}
    </ul>
  );
}

function ReferenceFinder({
  tree,
  epoch,
  disabled,
  onAction,
  onClose,
}: {
  tree: Tree;
  epoch?: string;
  disabled: boolean;
  onAction: LifecycleAction;
  onClose: () => void;
}) {
  const [path, setPath] = useState('');
  const [marks, setMarks] = useState<Transfer[]>([]);
  const [staged, setStaged] = useState<Transfer[]>([]);
  const [focusPath, setFocusPath] = useState('');
  const list = useRef<HTMLUListElement>(null);
  const query = useQuery({
    queryKey: ['reference-finder', tree.path, epoch, path],
    queryFn: () =>
      post<{
        path: string;
        parent: string;
        entries: (Entry & { path: string })[];
        allow_cut?: boolean;
        roots?: string[];
      }>('reference_browse', {
        epoch,
        target: tree.target,
        worktree: tree.path,
        path,
      }),
    enabled: !disabled,
  });
  useEffect(() => {
    if (!focusPath || !query.data) return;
    list.current?.querySelectorAll<HTMLButtonElement>('[data-finder-path]').forEach((button) => {
      if (button.dataset.finderPath === focusPath) button.focus();
    });
  }, [query.data, focusPath]);
  function mark(itemPath: string, action?: Transfer['action']) {
    setMarks((items) => [
      ...items.filter((item) => item.path !== itemPath),
      ...(action ? [{ path: itemPath, action }] : []),
    ]);
    if (!action) setStaged((items) => items.filter((item) => item.path !== itemPath));
  }
  function save() {
    setStaged((items) => [
      ...items.filter((item) => !marks.some((mark) => mark.path === item.path)),
      ...marks,
    ]);
    setMarks([]);
  }
  async function finish() {
    if (
      !staged.length ||
      (await onAction('reference_update', {
        worktree: tree.path,
        target: tree.target,
        reference_action: 'transfer',
        items: staged,
      }))
    )
      onClose();
  }
  return (
    <section
      className="reference-finder"
      aria-label="Reference finder"
      onKeyDown={(event) => {
        if ((event.ctrlKey || event.metaKey) && event.key === 's') {
          event.preventDefault();
          if (!disabled) save();
        }
      }}
    >
      <h3>Reference finder</h3>
      <p>
        <strong>Target worktree:</strong> {worktreeLabel(tree)} <code>{tree.path}</code>
      </p>
      <p>
        <strong>Reference folder:</strong> <code>{tree.reference_directory}</code>
      </p>
      <p>
        <strong>Browsing host:</strong>{' '}
        <code>{query.data?.path || path || 'Configured home directory'}</code>
      </p>
      {!!query.data?.roots?.length && (
        <label>
          Allowed source root{' '}
          <select
            value={
              query.data.roots.find(
                (root) => query.data!.path === root || query.data!.path.startsWith(`${root}/`),
              ) || query.data.roots[0]
            }
            disabled={disabled}
            onChange={(event) => {
              setFocusPath('');
              setPath(event.target.value);
            }}
          >
            {query.data.roots.map((root) => (
              <option key={root} value={root}>
                {root}
              </option>
            ))}
          </select>
        </label>
      )}
      <button
        type="button"
        disabled={disabled || !query.data}
        onClick={() => {
          setFocusPath(query.data!.path);
          setPath(query.data!.parent);
        }}
      >
        Parent folder
      </button>
      {query.isFetching && <p role="status">Loading host folder…</p>}
      {query.error && (
        <p role="alert">
          {query.error.message}{' '}
          <button type="button" onClick={() => void query.refetch()}>
            Retry
          </button>
        </p>
      )}
      <ul className="source-entries reference-finder-files" ref={list}>
        {query.data?.entries.map((entry) => (
          <li
            key={entry.path}
            onKeyDown={(event) => {
              if (disabled || (event.key === 'd' && query.data?.allow_cut === false)) return;
              if (['y', 'd', 'u'].includes(event.key)) {
                event.preventDefault();
                mark(
                  entry.path,
                  event.key === 'y' ? 'copy' : event.key === 'd' ? 'cut' : undefined,
                );
              }
            }}
          >
            <button
              type="button"
              data-finder-path={entry.path}
              disabled={disabled}
              onClick={() => {
                if (entry.directory) {
                  setFocusPath('');
                  setPath(entry.path);
                }
              }}
            >
              {entry.name}
              {entry.directory ? '/' : ''}
            </button>
            <button
              type="button"
              disabled={disabled}
              aria-pressed={marks.some(
                (item) => item.path === entry.path && item.action === 'copy',
              )}
              onClick={() => mark(entry.path, 'copy')}
            >
              Copy {entry.name}
            </button>
            <button
              type="button"
              disabled={disabled || query.data?.allow_cut === false}
              aria-pressed={marks.some((item) => item.path === entry.path && item.action === 'cut')}
              onClick={() => mark(entry.path, 'cut')}
            >
              Cut {entry.name}
            </button>
            <button type="button" disabled={disabled} onClick={() => mark(entry.path)}>
              Unmark {entry.name}
            </button>
          </li>
        ))}
      </ul>
      <aside className="reference-staging" aria-label="Staged references">
        <h4>Staged for {worktreeLabel(tree)}</h4>
        <p>
          Target: <code>{tree.path}</code>
        </p>
        <p>
          {marks.length} unsaved selection(s). Save before finishing. Unsaved selections are
          discarded on exit.
        </p>
        <ul>
          {staged.map((item) => (
            <li key={item.path}>
              {item.action}: <code>{item.path}</code>{' '}
              <button type="button" disabled={disabled} onClick={() => mark(item.path)}>
                Unstage
              </button>
            </li>
          ))}
        </ul>
        {!staged.length && <p>No staged items.</p>}
        <button type="button" disabled={disabled || !marks.length} onClick={save}>
          Save selections
        </button>
        <button type="button" disabled={disabled} onClick={() => void finish()}>
          Finish finder
        </button>
        <button type="button" disabled={disabled} onClick={onClose}>
          Discard finder
        </button>
      </aside>
    </section>
  );
}

export function ReferenceBrowser({
  snapshot,
  worktree,
  onAction,
  disabled = false,
}: {
  snapshot: Snapshot;
  worktree: string;
  onAction?: LifecycleAction;
  disabled?: boolean;
}) {
  const tree = snapshot.worktrees.find((item) => item.path === worktree)!;
  const [finder, setFinder] = useState(false);
  const [selected, setSelected] = useState<{ path: string; directory: boolean }>();
  const [rename, setRename] = useState('');
  const client = useQueryClient();
  const blocked = disabled || !snapshot.connected || !tree?.target || !snapshot.epoch || !onAction;
  const file = useQuery({
    queryKey: ['reference', worktree, selected?.path],
    queryFn: () => post<Listing>('reference', { worktree, path: selected!.path }),
    enabled: snapshot.connected && !!selected && !selected.directory,
  });
  async function update(action: 'rename' | 'delete') {
    if (!selected || !onAction) return;
    if (
      await onAction('reference_update', {
        target: tree.target,
        worktree,
        reference_action: action,
        path: selected.path,
        ...(action === 'rename' ? { name: rename } : {}),
      })
    ) {
      setSelected(undefined);
      void client.invalidateQueries({ queryKey: ['reference', worktree] });
    }
  }
  return (
    <section className="reference-browser" aria-label="Reference browser">
      <h2>References</h2>
      <p>
        Worktree: <code>{worktree}</code>
      </p>
      <p>
        Storage: <code>{tree.reference_directory}</code>
      </p>
      <button type="button" disabled={blocked || finder} onClick={() => setFinder(true)}>
        Add reference
      </button>
      <button
        type="button"
        disabled={!snapshot.connected}
        onClick={() => void client.invalidateQueries({ queryKey: ['reference', worktree] })}
      >
        Refresh references
      </button>
      {finder && onAction && (
        <ReferenceFinder
          tree={tree}
          epoch={snapshot.epoch}
          disabled={blocked}
          onAction={onAction}
          onClose={() => {
            setFinder(false);
            void client.invalidateQueries({ queryKey: ['reference', worktree] });
          }}
        />
      )}
      <ReferenceItems
        worktree={worktree}
        online={snapshot.connected}
        onSelect={(path, directory) => {
          setSelected({ path, directory });
          setRename(path.split('/').at(-1) || '');
        }}
      />
      {selected && (
        <section aria-label="Selected reference item">
          <h3>{selected.path}</h3>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              void update('rename');
            }}
          >
            <label>
              Reference item name{' '}
              <input
                value={rename}
                disabled={blocked}
                onChange={(event) => setRename(event.target.value)}
                onFocus={(event) => {
                  const dot = selected.directory ? -1 : event.target.value.lastIndexOf('.');
                  event.target.setSelectionRange(0, dot > 0 ? dot : event.target.value.length);
                }}
              />
            </label>
            <button disabled={blocked || !rename.trim()}>Rename reference item</button>
          </form>
          <button
            type="button"
            disabled={blocked}
            onClick={() => {
              if (
                window.confirm(
                  `Delete ${selected.path}${selected.directory ? ' and all its contents' : ''}?`,
                )
              )
                void update('delete');
            }}
          >
            Delete reference item
          </button>
          {!selected.directory && (
            <>
              {file.isFetching && <p role="status">Loading reference file…</p>}
              {file.error && <p role="alert">{file.error.message}</p>}
              {file.data?.content !== undefined &&
                (/\.md$/i.test(selected.path) ? (
                  <Markdown text={file.data.content} />
                ) : (
                  <pre className="source-code">{file.data.content}</pre>
                ))}
            </>
          )}
        </section>
      )}
    </section>
  );
}

export function ReferenceCommand({
  worktree,
  online,
  onChoose,
}: {
  worktree: string;
  online: boolean;
  onChoose: (text: string) => void;
}) {
  return (
    <section aria-label="Reference command">
      <p>Choose a reference file or folder, then send the draft when ready.</p>
      <ReferenceItems
        worktree={worktree}
        online={online}
        onSelect={(path) => onChoose(`/reference select ${path}`)}
      />
    </section>
  );
}
