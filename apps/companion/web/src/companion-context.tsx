import { createContext, useContext, useReducer } from 'react';
import type { Dispatch, ReactNode } from 'react';
import { readPending } from './api';
import { companionReducer, initialState } from './companion-state';
import type { CompanionAction, CompanionState } from './companion-state';

const StateContext = createContext<CompanionState | null>(null);
const DispatchContext = createContext<Dispatch<CompanionAction> | null>(null);

export function CompanionProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(companionReducer, undefined, () =>
    initialState(readPending()),
  );
  return (
    <StateContext.Provider value={state}>
      <DispatchContext.Provider value={dispatch}>{children}</DispatchContext.Provider>
    </StateContext.Provider>
  );
}

export function useCompanionState() {
  const state = useContext(StateContext);
  if (!state) throw new Error('useCompanionState must be used within CompanionProvider');
  return state;
}

export function useCompanionDispatch() {
  const dispatch = useContext(DispatchContext);
  if (!dispatch) throw new Error('useCompanionDispatch must be used within CompanionProvider');
  return dispatch;
}
