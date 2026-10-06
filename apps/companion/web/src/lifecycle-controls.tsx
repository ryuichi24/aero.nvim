import { useRef, useState } from 'react';
import type { ActionData, ActionPath } from './types';

export type LifecycleAction = (path: ActionPath, data: Partial<ActionData>) => Promise<boolean>;

export function LifecycleForm({
  title,
  path,
  data,
  disabled,
  onAction,
  field,
  initial = '',
  agents,
  destructive = false,
  force = false,
}: {
  title: string;
  path: ActionPath;
  data: Partial<ActionData>;
  disabled: boolean;
  onAction: LifecycleAction;
  field?: 'name' | 'branch';
  initial?: string;
  agents?: string[];
  destructive?: boolean;
  force?: boolean;
}) {
  const [value, setValue] = useState(initial);
  const [agent, setAgent] = useState(agents?.[0] || '');
  const [forceRemoval, setForceRemoval] = useState(false);
  const detailsRef = useRef<HTMLDetailsElement>(null);
  return (
    <details ref={detailsRef} className="my-2 rounded-lg border border-slate-700 p-2">
      <summary className="cursor-pointer p-2">{title}</summary>
      <form
        onSubmit={async (event) => {
          event.preventDefault();
          const accepted = await onAction(path, {
            ...data,
            ...(field && value.trim() ? { [field]: value.trim() } : {}),
            ...(agents ? { agent } : {}),
            ...(force ? { force: forceRemoval } : {}),
          });
          if (accepted) {
            setValue(initial);
            setAgent(agents?.[0] || '');
            setForceRemoval(false);
            if (detailsRef.current) detailsRef.current.open = false;
          }
        }}
      >
        {destructive && (
          <p className="text-sm text-amber-300">
            {force
              ? 'Remove this checkout and delete its Aero sessions and history. Force also discards uncommitted files.'
              : 'Stop this agent and delete its Aero session and saved history.'}
          </p>
        )}
        {agents && (
          <label>
            Agent
            <select value={agent} onChange={(event) => setAgent(event.target.value)} required>
              {agents.map((id) => (
                <option key={id} value={id}>
                  {id}
                </option>
              ))}
            </select>
          </label>
        )}
        {field && (
          <label>
            {field === 'branch' ? 'Branch' : agents ? 'Session name (optional)' : 'New name'}
            <input
              value={value}
              maxLength={256}
              required={!agents}
              onChange={(event) => setValue(event.target.value)}
            />
          </label>
        )}
        {force && (
          <label>
            <input
              type="checkbox"
              checked={forceRemoval}
              onChange={(event) => setForceRemoval(event.target.checked)}
            />{' '}
            Force removal (discard uncommitted files)
          </label>
        )}
        <button disabled={disabled || (agents !== undefined && !agent)}>
          {destructive ? 'Confirm delete' : title}
        </button>
      </form>
    </details>
  );
}
