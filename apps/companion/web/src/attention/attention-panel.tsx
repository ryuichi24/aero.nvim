import type { RefObject } from 'react';
import { Button } from '../components/ui/button';
import { AttentionSurface } from '../fullscreen-attention';
import { useCompanionState } from '../companion-context';
import type {
  ActionData,
  ActionPath,
  InboxEvent,
  PendingAction,
  Selection,
  Snapshot,
} from '../types';

export function AttentionPanel({
  snapshot,
  entries,
  open,
  host,
  panelRef,
  closeRef,
  onClose,
  onSelect,
  onAction,
  onRetry,
}: {
  snapshot: Snapshot | null;
  entries: InboxEvent[];
  open: boolean;
  host: HTMLElement | null;
  panelRef: RefObject<HTMLElement | null>;
  closeRef: RefObject<HTMLButtonElement | null>;
  onClose: () => void;
  onSelect: (selection: Selection) => void;
  onAction: (path: ActionPath, extra?: Partial<ActionData>) => Promise<boolean>;
  onRetry: (action: PendingAction) => Promise<boolean>;
}) {
  const { view, online, pending, notice, connection, retry, submitting, pairing } =
    useCompanionState();
  return (
    <AttentionSurface host={open ? host : null}>
      <section
        id="attention-inbox"
        ref={panelRef}
        aria-labelledby="attention-title"
        hidden={view !== 'inbox' && !open}
        className={open ? `attention-panel${host ? ' attention-panel-fullscreen' : ''}` : undefined}
        onKeyDown={(event) => {
          if (open && event.key === 'Escape') {
            event.preventDefault();
            onClose();
          }
        }}
      >
        <div className="flex items-center justify-between gap-3">
          <h2 id="attention-title">Attention inbox</h2>
          {open && (
            <Button variant="outline" ref={closeRef} onClick={onClose}>
              Hide attention
            </Button>
          )}
        </div>
        {open && (
          <>
            <p role="status">{notice || connection}</p>
            {retry && pending && (
              <Button
                variant="outline"
                disabled={submitting || pairing || !online}
                onClick={() => void onRetry(pending)}
              >
                Retry identical action
              </Button>
            )}
          </>
        )}
        <div id="inbox">
          {entries.map((entry) => {
            const owner = snapshot?.sessions.find(
              (item) => item.id === entry.session && item.conversation === entry.conversation,
            );
            const permission = entry.kind === 'permission' ? owner?.permission : undefined;
            return (
              <div key={entry.id} className="inbox-entry">
                <p className="text-sm text-slate-400">
                  {owner?.name || entry.session}
                  {owner?.worktree ? ` · ${owner.worktree}` : ''}
                </p>
                <Button
                  variant="ghost"
                  className="whitespace-normal text-left"
                  onClick={() => onSelect({ id: entry.session, conversation: entry.conversation })}
                >
                  {entry.kind}: {entry.text}
                </Button>
                {permission && (
                  <div className="inbox-permission" role="group" aria-label={permission.title}>
                    <p>{permission.title}</p>
                    {permission.options.map((option) => (
                      <Button
                        variant="outline"
                        key={option.optionId}
                        disabled={
                          !online ||
                          !!pending ||
                          owner?.status === 'exited' ||
                          owner?.status === 'stopped'
                        }
                        onClick={() =>
                          onAction('permission', {
                            session: entry.session,
                            conversation: entry.conversation,
                            permission: permission.id,
                            option: option.optionId,
                          })
                        }
                      >
                        {option.name || option.optionId}
                      </Button>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
        </div>
        {snapshot?.connected && entries.length === 0 && (
          <p className="navigation-empty">No attention events right now.</p>
        )}
      </section>
    </AttentionSurface>
  );
}
