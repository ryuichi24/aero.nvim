import { useRef, useState } from 'react';
import { NativeSelect } from './components/ui/native-select';
import { Checkbox } from './components/ui/checkbox';
import { Collapsible, CollapsibleTrigger } from './components/ui/collapsible';
import { Label } from './components/ui/label';
import type { ActionData, ActionPath } from './types';
import { Button } from './components/ui/button';
import { Input } from './components/ui/input';

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
  defaultAgent,
  destructive = false,
  force = false,
  initiallyOpen = false,
}: {
  title: string;
  path: ActionPath;
  data: Partial<ActionData>;
  disabled: boolean;
  onAction: LifecycleAction;
  field?: 'name' | 'branch';
  initial?: string;
  agents?: string[];
  defaultAgent?: string;
  destructive?: boolean;
  force?: boolean;
  initiallyOpen?: boolean;
}) {
  const [value, setValue] = useState(initial);
  const initialAgent =
    defaultAgent && agents?.includes(defaultAgent) ? 'default' : agents?.[0] || '';
  const [agent, setAgent] = useState(initialAgent);
  const [forceRemoval, setForceRemoval] = useState(false);
  const detailsRef = useRef<HTMLDetailsElement>(null);
  return (
    <Collapsible
      ref={detailsRef}
      open={initiallyOpen || undefined}
      className="my-2 rounded-lg border border-slate-700 p-2"
    >
      <CollapsibleTrigger className="p-2">{title}</CollapsibleTrigger>
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
            setAgent(initialAgent);
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
          <Label>
            Agent
            <NativeSelect value={agent} onChange={(event) => setAgent(event.target.value)} required>
              {defaultAgent && agents.includes(defaultAgent) && (
                <option value="default">default ({defaultAgent})</option>
              )}
              {agents.map((id) => (
                <option key={id} value={id}>
                  {id}
                </option>
              ))}
            </NativeSelect>
          </Label>
        )}
        {field && (
          <Label>
            {field === 'branch' ? 'Branch' : agents ? 'Session name (optional)' : 'New name'}
            <Input
              value={value}
              maxLength={256}
              required={!agents}
              onChange={(event) => setValue(event.target.value)}
            />
          </Label>
        )}
        {force && (
          <Label>
            <Checkbox
              checked={forceRemoval}
              onCheckedChange={(checked) => setForceRemoval(checked === true)}
            />{' '}
            Force removal (discard uncommitted files)
          </Label>
        )}
        <Button
          type="submit"
          variant={destructive ? 'destructive' : 'default'}
          disabled={disabled || (agents !== undefined && !agent)}
        >
          {destructive ? 'Confirm delete' : title}
        </Button>
      </form>
    </Collapsible>
  );
}
