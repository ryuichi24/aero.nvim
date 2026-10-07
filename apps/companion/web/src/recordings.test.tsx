import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Recordings } from './recordings';
import { Transcript } from './transcript';
import { sessionRecordings } from './screenshots';
import type { Session } from './types';

const session: Session = {
  id: 'one',
  name: 'Agent',
  agent: 'fixture',
  worktree: '/workspace',
  status: 'idle',
  blocks: [{ kind: 'agent', text: '[Browser test](.playwright-mcp/test.webm)' }],
};
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it('hides the recordings section when the session has no videos', () => {
  const fetch = vi.fn();
  vi.stubGlobal('fetch', fetch);
  const view = render(<Recordings session={{ ...session, blocks: [] }} />);
  expect(view.container.querySelector('details')).toBeNull();
  expect(fetch).not.toHaveBeenCalled();
});

it('collects recordings separately from screenshots and ignores source-code examples', () => {
  const recordings = sessionRecordings({
    ...session,
    blocks: [
      ...session.blocks!,
      {
        kind: 'agent',
        text: '[Duplicate](file:///workspace/.playwright-mcp/test.webm)\n\n[Image](shot.png)\n\n[External](https://example.com/demo.mp4)',
      },
      { kind: 'tool', content: [{ content: { uri: '/workspace/demo.mp4', name: 'Demo' } }] },
      { kind: 'tool', tool_kind: 'read', rawOutput: '[Fixture](fake.webm)' },
    ],
  });
  expect(recordings.map((recording) => recording.label)).toEqual(['Demo', 'Browser test']);
});

it('preserves recordings on discovery and opens a controlled inline video player', async () => {
  const fetch = vi.fn().mockResolvedValue(new Response(new Uint8Array([0]), { status: 206 }));
  vi.stubGlobal('fetch', fetch);
  render(<Recordings session={session} />);
  await waitFor(() => expect(screen.getByText('Saved for later')).toBeTruthy());
  expect(fetch.mock.calls[0][1].headers.Range).toBe('bytes=0-0');
  fireEvent.click(screen.getByText('Recordings (1)'));
  fireEvent.click(screen.getByRole('link', { name: /Browser test/ }));
  const dialog = screen.getByRole('dialog', { name: 'Recording preview' });
  const video = dialog.querySelector('video')!;
  expect(video.controls).toBe(true);
  expect(video.playsInline).toBe(true);
  expect(video.getAttribute('src')).toContain('/api/video?session=one');
  expect(video.autoplay).toBe(false);
  fireEvent.click(screen.getByRole('button', { name: 'Close' }));
  expect(document.querySelector('video')).toBeNull();
});

it('shows preservation errors and previews video links and resource attachments from the transcript', async () => {
  vi.stubGlobal(
    'fetch',
    vi
      .fn()
      .mockResolvedValue(
        new Response(JSON.stringify({ error: 'recording file unavailable' }), { status: 404 }),
      ),
  );
  const view = render(<Recordings session={session} />);
  await waitFor(() => expect(screen.getByText('recording file unavailable')).toBeTruthy());
  view.unmount();
  render(
    <Transcript
      session={{
        ...session,
        blocks: [
          { kind: 'agent', text: '[Replay](file:///workspace/demo.mp4)' },
          {
            kind: 'tool',
            content: [{ content: { uri: 'file:///workspace/tool.webm', name: 'Tool recording' } }],
          },
        ],
      }}
    />,
  );
  fireEvent.click(screen.getByRole('link', { name: 'Replay' }));
  expect(screen.getByRole('dialog', { name: 'Recording preview' })).toBeTruthy();
  fireEvent.error(document.querySelector('video')!);
  expect(screen.getByRole('alert').textContent).toContain('Unable to load this recording');
  fireEvent.click(screen.getByRole('button', { name: 'Close' }));
  fireEvent.click(screen.getByRole('link', { name: 'Tool recording', hidden: true }));
  expect(screen.getByRole('dialog', { name: 'Recording preview' })).toBeTruthy();
});
