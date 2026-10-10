import type { PendingAction, Selection } from './types';

export type View = 'sessions' | 'inbox' | 'conversation' | 'source' | 'reports' | 'git';
export interface CompanionState {
  pending: PendingAction | null;
  selected: Selection | null;
  view: View;
  online: boolean;
  connection: string;
  pairing: boolean;
  pairCode: string;
  deviceName: string;
  drafts: Record<string, string>;
  notice: string;
  retry: boolean;
  submitting: boolean;
}

export function draftKey(selection: Selection | null): string {
  return JSON.stringify([selection?.id, selection?.conversation]);
}

export function initialState(pending: PendingAction | null): CompanionState {
  const selected = pending?.data.session
    ? { id: pending.data.session, conversation: pending.data.conversation }
    : null;
  return {
    pending,
    selected,
    view: selected ? 'conversation' : 'sessions',
    online: false,
    connection: 'Disconnected',
    pairing: true,
    pairCode: '',
    deviceName: 'Phone',
    drafts: pending?.path === 'prompt' ? { [draftKey(selected)]: pending.data.text || '' } : {},
    notice: pending
      ? 'An earlier action has an unknown outcome. Retry the identical action to recover its receipt.'
      : '',
    retry: !!pending,
    submitting: false,
  };
}

export type CompanionAction =
  | { type: 'navigate'; view: View }
  | { type: 'select-session'; selection: Selection }
  | { type: 'connection'; online: boolean; message: string; pairing?: boolean }
  | { type: 'pair-code'; value: string }
  | { type: 'device-name'; value: string }
  | { type: 'paired' }
  | { type: 'draft'; value: string }
  | { type: 'notice'; message: string }
  | { type: 'action-started'; action: PendingAction }
  | { type: 'action-uncertain'; message: string }
  | { type: 'action-accepted'; action: PendingAction; status: string }
  | { type: 'action-rejected'; message: string }
  | { type: 'action-finished' };

export function companionReducer(state: CompanionState, action: CompanionAction): CompanionState {
  switch (action.type) {
    case 'navigate':
      return { ...state, view: action.view };
    case 'select-session':
      return { ...state, selected: action.selection, view: 'conversation' };
    case 'connection':
      return {
        ...state,
        online: action.online,
        connection: action.message,
        pairing: action.pairing ?? state.pairing,
      };
    case 'pair-code':
      return { ...state, pairCode: action.value.replace(/\D/g, '').slice(0, 6) };
    case 'device-name':
      return { ...state, deviceName: action.value };
    case 'paired':
      return { ...state, pairCode: '', notice: 'Paired' };
    case 'draft':
      return { ...state, drafts: { ...state.drafts, [draftKey(state.selected)]: action.value } };
    case 'notice':
      return { ...state, notice: action.message };
    case 'action-started':
      return { ...state, pending: action.action, submitting: true, retry: false };
    case 'action-uncertain':
      return { ...state, notice: action.message, retry: true };
    case 'action-accepted': {
      const selection = {
        id: action.action.data.session || '',
        conversation: action.action.data.conversation,
      };
      return {
        ...state,
        pending: null,
        retry: false,
        notice: 'Action ' + action.status,
        ...(action.action.path === 'session_delete' &&
        state.selected?.id === action.action.data.session
          ? { selected: null, view: 'sessions' as const }
          : {}),
        ...(action.action.path === 'worktree_delete'
          ? { selected: null, view: 'sessions' as const }
          : {}),
        drafts:
          action.action.path === 'prompt'
            ? { ...state.drafts, [draftKey(selection)]: '' }
            : state.drafts,
      };
    }
    case 'action-rejected':
      return {
        ...state,
        pending: null,
        retry: false,
        notice: 'Action rejected: ' + action.message,
      };
    case 'action-finished':
      return { ...state, submitting: false };
  }
}
