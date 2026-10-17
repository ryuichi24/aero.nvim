// Own pending-action persistence, receipt handling and identical retries.
// Refs guard same-tick duplicate submissions before reducer updates reach the UI.
import { useRef } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { operationID, post, RequestError, savePending } from '../api';
import { useCompanionDispatch, useCompanionState } from '../companion-context';
import type {
  ActionData,
  ActionPath,
  ActionResponse,
  PendingAction,
  Selection,
  Snapshot,
} from '../types';

export function useCompanionActions(
  snapshot: Snapshot | null,
  openSession: (selection: Selection) => void,
) {
  const { pending, selected, online } = useCompanionState();
  const dispatch = useCompanionDispatch();
  const client = useQueryClient();
  const pendingRef = useRef(pending);
  const submittingRef = useRef(false);
  const resumedRef = useRef<string | null>(null);
  const mutation = useMutation({
    mutationFn: (action: PendingAction) => post<ActionResponse>(action.path, action.data),
  });

  async function submitPending(action: PendingAction) {
    if (submittingRef.current) return false;
    submittingRef.current = true;
    dispatch({ type: 'action-started', action });
    try {
      const response = await mutation.mutateAsync(action);
      const status = response.result?.status;
      if (!['accepted', 'queued', 'unknown'].includes(status))
        throw new RequestError('Invalid action receipt', true);
      if (status === 'unknown') {
        dispatch({
          type: 'action-uncertain',
          message: 'Outcome unknown. Retry the identical action or check the host.',
        });
        return false;
      }
      savePending(null);
      pendingRef.current = null;
      dispatch({ type: 'action-accepted', action, status });
      if (action.path === 'reference_update')
        void client.invalidateQueries({ queryKey: ['reference'] });
      if (response.result.message) dispatch({ type: 'notice', message: response.result.message });
      if (response.result.session) {
        resumedRef.current = response.result.session;
        const session = client
          .getQueryData<Snapshot>(['snapshot'])
          ?.sessions.find((item) => item.id === response.result.session);
        if (session?.conversation && !['starting', 'exited', 'stopped'].includes(session.status)) {
          resumedRef.current = null;
          openSession({ id: session.id, conversation: session.conversation });
        }
      }
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Request interrupted';
      if (!(error instanceof RequestError) || error.unknownOutcome) {
        dispatch({
          type: 'action-uncertain',
          message: 'Outcome unknown. Retry uses the same action ID. ' + message,
        });
      } else {
        savePending(null);
        pendingRef.current = null;
        dispatch({ type: 'action-rejected', message });
      }
      return false;
    } finally {
      submittingRef.current = false;
      dispatch({ type: 'action-finished' });
    }
  }

  async function act(path: ActionPath, extra: Partial<ActionData> = {}) {
    const lifecycle =
      path.startsWith('session_') || path.startsWith('worktree_') || path === 'reference_update';
    const target = extra.session
      ? { id: extra.session, conversation: extra.conversation }
      : selected;
    if (pendingRef.current || !online || (!lifecycle && !target?.conversation)) return false;
    const action: PendingAction = {
      path,
      data: {
        ...(!lifecycle && target
          ? { session: target.id, conversation: target.conversation }
          : { epoch: snapshot?.epoch }),
        operation_id: operationID(),
        ...extra,
      },
    };
    try {
      savePending(action);
    } catch {
      dispatch({ type: 'notice', message: 'Browser storage unavailable; action was not sent.' });
      return false;
    }
    pendingRef.current = action;
    return submitPending(action);
  }
  return { act, submitPending, pendingRef, resumedRef };
}
