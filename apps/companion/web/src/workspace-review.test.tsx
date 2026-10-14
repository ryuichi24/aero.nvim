import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render } from '@testing-library/react';
import { WorkspaceReview } from './workspace-review';
import type { Snapshot } from './types';

vi.mock('./source-browser', () => ({ SourceBrowser: () => <div>Source reader</div> }));
vi.mock('./git-browser', () => ({ GitBrowser: () => <div>Git reader</div> }));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

it('restores independent reading positions across reader tabs, worktrees, and other views', () => {
  let top = 0;
  let left = 0;
  vi.spyOn(window, 'scrollY', 'get').mockImplementation(() => top);
  vi.spyOn(window, 'scrollX', 'get').mockImplementation(() => left);
  const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation((options) => {
    top = (options as ScrollToOptions).top || 0;
    left = (options as ScrollToOptions).left || 0;
  });
  const snapshot = {
    connected: true,
    worktrees: [{ path: '/alpha' }, { path: '/beta' }],
  } as Snapshot;
  const { rerender } = render(
    <WorkspaceReview snapshot={snapshot} worktree="/alpha" view="reports" />,
  );
  function navigate(worktree: string, view: string) {
    rerender(<WorkspaceReview snapshot={snapshot} worktree={worktree} view={view} />);
  }
  function scroll(y: number, x = 0) {
    top = y;
    left = x;
    fireEvent.scroll(window);
  }

  scroll(1200);
  navigate('/alpha', 'source');
  expect(top).toBe(0);
  scroll(800, 40);
  navigate('/alpha', 'git');
  expect(top).toBe(0);
  scroll(600);
  navigate('/beta', 'reports');
  expect(top).toBe(0);
  scroll(300);
  navigate('/alpha', 'reports');
  expect(top).toBe(1200);
  navigate('/alpha', 'conversation');
  scroll(0);
  navigate('/alpha', 'source');
  expect(top).toBe(800);
  expect(left).toBe(40);
  navigate('/alpha', 'git');
  expect(top).toBe(600);
  navigate('/beta', 'reports');
  expect(top).toBe(300);
  expect(scrollTo).toHaveBeenLastCalledWith({ top: 300, left: 0, behavior: 'instant' });
});
