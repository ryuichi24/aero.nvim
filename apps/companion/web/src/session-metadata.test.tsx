import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { SessionMetadata } from './session-metadata';
import type { Session } from './types';

afterEach(cleanup);
const session: Session = {
  id: 'one',
  name: 'Agent',
  agent: 'opencode',
  worktree: '/repo',
  status: 'idle',
};

it('shows the selected model and distinguishes cumulative tokens from live context usage', () => {
  const { rerender } = render(
    <SessionMetadata
      session={{
        ...session,
        models: { current: 'model', choices: [{ id: 'model', name: 'My model' }] },
        usage: {
          tokens: { totalTokens: 300000, inputTokens: 250000, outputTokens: 50000, responses: 3 },
          context: { used: 25000, size: 100000 },
        },
      }}
    />,
  );
  expect(screen.getByText('My model')).toBeTruthy();
  expect(screen.getByText('300,000')).toBeTruthy();
  expect(screen.getByText('25,000 / 100,000 tokens (25.0%)')).toBeTruthy();
  expect((screen.getByRole('progressbar') as HTMLProgressElement).value).toBe(25);
  rerender(
    <SessionMetadata session={{ ...session, usage: { context: { used: 0, size: 100000 } } }} />,
  );
  expect(screen.getByText('0 / 100,000 tokens (0.0%)')).toBeTruthy();
  expect(screen.queryByText('300,000')).toBeNull();
});

it('handles unreported usage and a zero context capacity without inventing a percentage', () => {
  const { rerender } = render(<SessionMetadata session={session} />);
  expect(screen.getAllByText('Not reported').length).toBe(5);
  expect(screen.queryByRole('progressbar')).toBeNull();
  rerender(
    <SessionMetadata
      session={{
        ...session,
        models: { current: 'unknown-model', choices: [] },
        usage: { context: { used: 0, size: 0 } },
      }}
    />,
  );
  expect(screen.getByText('unknown-model')).toBeTruthy();
  expect(screen.getByText('0 / 0 tokens')).toBeTruthy();
  expect(screen.queryByRole('progressbar')).toBeNull();
});
