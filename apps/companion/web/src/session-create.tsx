import { useState, useEffect, useRef } from 'react';
import { LifecycleForm } from './lifecycle-controls';
import type { LifecycleAction } from './lifecycle-controls';
import type { Snapshot } from './types';
import { worktreeLabel } from './sessionGroups';

export function SessionCreate({
  snapshot,
  disabled,
  onAction,
  request = 0,
}: {
  snapshot: Snapshot | null;
  disabled: boolean;
  onAction: LifecycleAction;
  request?: number;
}) {
  const [chosen, setChosen] = useState('');
  const details = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    if (request && details.current) details.current.open = true;
  }, [request]);
  const trees = snapshot?.worktrees || [];
  const tree = trees.find((item) => item.path === chosen) || trees[0];
  const workspace =
    tree?.workspace || snapshot?.workspaces.find((item) => tree?.path === item.root)?.root;
  return (
    <details ref={details} className="session-create">
      <summary>New session</summary>
      <label>
        Session worktree
        <select value={tree?.path || ''} onChange={(event) => setChosen(event.target.value)}>
          {trees.map((item) => (
            <option key={item.path} value={item.path}>
              {worktreeLabel(item)} · {item.workspace || item.path}
            </option>
          ))}
        </select>
      </label>
      {tree && workspace ? (
        <LifecycleForm
          key={tree.path}
          title="New AI session"
          path="session_create"
          data={{ workspace, worktree: tree.path }}
          agents={snapshot?.agents || []}
          field="name"
          disabled={disabled}
          onAction={onAction}
          initiallyOpen
        />
      ) : (
        <p>No worktrees available. Use the grouped workspace view to create a worktree.</p>
      )}
    </details>
  );
}
