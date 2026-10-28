import { useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { post } from './api';
import { LifecycleForm, type LifecycleAction } from './lifecycle-controls';
import { worktreeLabel } from './sessionGroups';
import type { Snapshot } from './types';

type Tree = Snapshot['worktrees'][number];
interface Entry {
  name: string;
  path: string;
  initialized: boolean;
}
interface Listing {
  entries: Entry[];
  loading: boolean;
  error?: string;
  workspace?: string;
  worktrees?: Tree[];
}
interface Props {
  tree: Tree;
  snapshot: Snapshot;
  online: boolean;
  disabled: boolean;
  onAction?: LifecycleAction;
  onOpen?: (path: string) => void;
  ancestors?: string[];
}

function Discovery({
  tree,
  snapshot,
  online,
  disabled,
  onAction,
  onOpen,
  ancestors = [],
  path,
}: Props & { path?: string }) {
  const refresh = useRef(false);
  const query = useQuery({
    queryKey: ['submodules', snapshot.epoch, tree.path, tree.target, path || ''],
    queryFn: () => {
      const revalidate = refresh.current;
      refresh.current = false;
      return post<Listing>('submodule_browse', {
        epoch: snapshot.epoch,
        target: tree.target,
        worktree: tree.path,
        path,
        refresh: revalidate,
      });
    },
    enabled: online,
    refetchInterval: (state) => (state.state.data?.loading ? 400 : false),
  });
  const listing = query.data;
  const act: LifecycleAction = async (method, data) => {
    if (!onAction) return false;
    const accepted = await onAction(method, data);
    if (accepted) await query.refetch();
    return accepted;
  };
  return (
    <div className="workspace-worktrees">
      <button
        disabled={!online || query.isFetching || listing?.loading}
        onClick={() => {
          refresh.current = true;
          void query.refetch();
        }}
      >
        Refresh submodules
      </button>
      {(query.isPending || listing?.loading) && <p role="status">Loading submodules…</p>}
      {(query.error || listing?.error) && (
        <p role="alert">{query.error?.message || listing?.error} </p>
      )}
      {listing && !listing.loading && !listing.error && !path && listing.entries.length === 0 && (
        <p>No submodules in this checkout.</p>
      )}
      {!path &&
        listing?.entries.map((entry) => (
          <Submodule
            key={entry.path}
            entry={entry}
            tree={tree}
            snapshot={snapshot}
            online={online}
            disabled={disabled}
            onAction={onAction ? act : undefined}
            onOpen={onOpen}
            ancestors={ancestors}
          />
        ))}
      {path && listing?.workspace && (
        <>
          <p className="navigation-path">Repository: {listing.workspace}</p>
          {onAction && (
            <LifecycleForm
              title="New worktree"
              path="worktree_create"
              data={{ workspace: listing.workspace }}
              field="branch"
              disabled={disabled}
              onAction={act}
            />
          )}
          {listing.worktrees?.map((child) => (
            <div
              key={child.path}
              role="group"
              aria-label={`Submodule worktree ${worktreeLabel(child)}`}
            >
              <p>
                <strong>{worktreeLabel(child)}</strong>
                {child.path === path && ' · in parent'}
              </p>
              <p className="navigation-path">{child.path}</p>
              {onOpen && (
                <button disabled={!online} onClick={() => onOpen(child.path)}>
                  Browse checkout
                </button>
              )}
              {onAction && (
                <LifecycleForm
                  title="New AI session"
                  path="session_create"
                  data={{ workspace: listing.workspace, worktree: child.path }}
                  agents={snapshot.agents || []}
                  field="name"
                  disabled={disabled}
                  onAction={act}
                />
              )}
              {onAction && child.branch && (
                <LifecycleForm
                  title="Rename worktree branch"
                  path="worktree_rename"
                  data={{
                    workspace: listing.workspace,
                    worktree: child.path,
                    target: child.target,
                  }}
                  initial={child.branch}
                  field="name"
                  disabled={disabled || !child.target}
                  onAction={act}
                />
              )}
              {onAction && child.path !== listing.workspace && (
                <LifecycleForm
                  title="Delete worktree"
                  path="worktree_delete"
                  data={{
                    workspace: listing.workspace,
                    worktree: child.path,
                    target: child.target,
                  }}
                  destructive
                  force
                  disabled={disabled || !child.target}
                  onAction={act}
                />
              )}
              {!ancestors.includes(child.path) && (
                <SubmoduleBrowser
                  tree={child}
                  snapshot={snapshot}
                  online={online}
                  disabled={disabled}
                  onAction={onAction ? act : undefined}
                  onOpen={onOpen}
                  ancestors={ancestors}
                />
              )}
            </div>
          ))}
        </>
      )}
    </div>
  );
}

function Submodule({ entry, ...props }: Props & { entry: Entry }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div role="group" aria-label={`Submodule ${entry.name}`}>
      <button
        disabled={!entry.initialized || !props.online}
        aria-expanded={expanded}
        onClick={() => setExpanded(!expanded)}
      >
        <span aria-hidden="true">{expanded ? '▾' : '▸'}</span> {entry.name}
        {!entry.initialized && ' · not initialized'}
      </button>
      <span className="navigation-path">{entry.path}</span>
      {expanded && <Discovery {...props} path={entry.path} />}
    </div>
  );
}

export function SubmoduleBrowser(props: Props) {
  const [expanded, setExpanded] = useState(false);
  if (!props.snapshot.epoch || !props.tree.target) return null;
  return (
    <div className="submodule-browser">
      <button
        aria-expanded={expanded}
        disabled={!props.online}
        onClick={() => setExpanded(!expanded)}
      >
        <span aria-hidden="true">{expanded ? '▾' : '▸'}</span> Submodules
      </button>
      {expanded && (
        <Discovery {...props} ancestors={[...(props.ancestors || []), props.tree.path]} />
      )}
    </div>
  );
}
