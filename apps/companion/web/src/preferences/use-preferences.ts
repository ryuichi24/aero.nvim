// Optional preferences are independent of snapshots and action receipts.
import { useEffect, useState } from 'react';
import { readStored, store } from '../browser-storage';

export function useDisplayPreferences() {
  const [lightTheme, setLightTheme] = useState(() => {
    try {
      return localStorage.getItem('aero-appearance') === 'light';
    } catch {
      return false;
    }
  });
  const [fullscreenAttention, setFullscreenAttention] = useState(() => {
    try {
      return localStorage.getItem('aero-companion-fullscreen-attention') !== 'false';
    } catch {
      return true;
    }
  });
  useEffect(() => {
    document.documentElement.dataset.theme = lightTheme ? 'light' : 'dark';
    try {
      localStorage.setItem('aero-appearance', lightTheme ? 'light' : 'dark');
    } catch {
      /* Optional preference. */
    }
    return () => {
      delete document.documentElement.dataset.theme;
    };
  }, [lightTheme]);
  useEffect(() => {
    try {
      localStorage.setItem('aero-companion-fullscreen-attention', String(fullscreenAttention));
    } catch {
      /* Optional preference. */
    }
  }, [fullscreenAttention]);
  return { lightTheme, setLightTheme, fullscreenAttention, setFullscreenAttention };
}

export function useWorkspacePreferences() {
  const [reviewWorktree, setReviewWorktree] = useState(() =>
    readStored<string>(
      'aero-review-worktree',
      readStored<string>('aero-review-worktree', ''),
      'local',
    ),
  );
  const [workspaceScope, setWorkspaceScope] = useState(() =>
    readStored<string>('aero-workspace-scope', '', 'local'),
  );
  const [lastWorkspaceView, setLastWorkspaceView] = useState<
    'reports' | 'git' | 'source' | 'reference'
  >(() => {
    const value = readStored<string>(
      'aero-workspace-view',
      readStored<string>('aero-workspace-view', 'reports'),
      'local',
    );
    if (value === 'context') return 'reference'; // legacy workspace-view preference
    return value === 'source' || value === 'git' || value === 'reference' ? value : 'reports';
  });
  const [recent, setRecent] = useState<string[]>(() => {
    const value = readStored<unknown>('aero-recent-sessions', []);
    return Array.isArray(value) ? value.filter((id): id is string => typeof id === 'string') : [];
  });
  useEffect(() => store('aero-recent-sessions', recent), [recent]);
  useEffect(() => store('aero-workspace-scope', workspaceScope, 'local'), [workspaceScope]);
  useEffect(() => store('aero-review-worktree', reviewWorktree, 'local'), [reviewWorktree]);
  useEffect(() => store('aero-workspace-view', lastWorkspaceView, 'local'), [lastWorkspaceView]);
  return {
    reviewWorktree,
    setReviewWorktree,
    workspaceScope,
    setWorkspaceScope,
    lastWorkspaceView,
    setLastWorkspaceView,
    recent,
    setRecent,
  };
}
