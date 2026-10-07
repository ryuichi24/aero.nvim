import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Transcript } from './transcript';
import type { Session } from './types';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { attachedReports } from './report-preview';

afterEach(cleanup);
it('recognizes quoted report paths and resource attachments only in the report directory', () => {
  expect(
    attachedReports(
      {
        kind: 'user',
        text: 'Report file: "/data/reports/design notes.md"\nRead it.',
        content: [
          { content: { uri: 'file:///data/reports/design%20notes.md' } },
          { content: { uri: 'file:///data/reports/other.md' } },
          { content: { uri: 'file:///elsewhere/private.md' } },
          { content: { uri: 'file:///data/reports/../private.md' } },
        ],
      },
      '/data/reports',
    ),
  ).toEqual(['design notes.md', 'other.md']);
});
it('previews an attached report in Transcript and refreshes it while keeping the composer available', async () => {
  const fetch = vi
    .spyOn(globalThis, 'fetch')
    .mockResolvedValue(
      new Response(JSON.stringify({ content: '# Findings\n\nInitial report' }), { status: 200 }),
    );
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  try {
    render(
      <QueryClientProvider client={client}>
        <Transcript
          session={{
            ...session,
            blocks: [{ kind: 'user', text: 'Report file: "/data/reports/review.md"' }],
          }}
          reportsDirectory="/data/reports"
          online
          composer={<textarea aria-label="Feedback" />}
        />
      </QueryClientProvider>,
    );
    expect(screen.getByRole('button', { name: 'Show report' }).getAttribute('aria-expanded')).toBe(
      'false',
    );
    expect(screen.queryByRole('heading', { name: 'Findings' })).toBeNull();
    expect(fetch).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Show report' }));
    expect(await screen.findByRole('heading', { name: 'Findings' })).toBeTruthy();
    expect(fetch).toHaveBeenCalledWith(
      '/api/reports',
      expect.objectContaining({
        body: JSON.stringify({ worktree: '/workspace', path: 'review.md' }),
      }),
    );
    expect(screen.getByRole('textbox', { name: 'Feedback' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Show source' }));
    expect(screen.getByText('# Findings Initial report').textContent).toBe(
      '# Findings\n\nInitial report',
    );
    fetch.mockResolvedValue(
      new Response(JSON.stringify({ content: '# Updated findings' }), { status: 200 }),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Refresh report' }));
    fireEvent.click(screen.getByRole('button', { name: 'Show preview' }));
    expect(await screen.findByRole('heading', { name: 'Updated findings' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Hide report' }));
    expect(screen.queryByRole('heading', { name: 'Updated findings' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Show report' }).getAttribute('aria-expanded')).toBe(
      'false',
    );
  } finally {
    client.clear();
    fetch.mockRestore();
  }
});
it.each([false, true])(
  'navigates prompt history with fullscreen=%s and pauses live following',
  (fullscreen) => {
    const blocks = [
      { kind: 'user', text: 'First question\nwith context' },
      { kind: 'agent', text: 'Response' },
      { kind: 'user', text: 'Second question' },
    ];
    const view = render(<Transcript session={{ ...session, blocks, queue: ['Unsent prompt'] }} />);
    if (fullscreen) {
      const dialog = screen.getByRole<HTMLDialogElement>('dialog', { hidden: true });
      dialog.showModal = () => dialog.setAttribute('open', '');
      dialog.close = () => dialog.removeAttribute('open');
      fireEvent.click(screen.getByRole('button', { name: 'Fullscreen logs' }));
    }
    const region = screen.getByRole('region', { name: 'Conversation transcript' });
    Object.defineProperties(region, {
      scrollHeight: { configurable: true, value: 1000 },
      clientHeight: { configurable: true, value: 200 },
    });
    region.scrollTop = 0;
    const target = screen.getAllByRole('article', { name: 'You message' })[1].parentElement!;
    vi.spyOn(region, 'getBoundingClientRect').mockReturnValue({ top: 100 } as DOMRect);
    vi.spyOn(target, 'getBoundingClientRect').mockReturnValue({ top: 400 } as DOMRect);
    fireEvent.click(screen.getByRole('button', { name: 'Prompts (2)' }));
    expect(screen.getByRole('button', { name: '1. First question with context' })).toBeTruthy();
    fireEvent.change(screen.getByRole('textbox', { name: 'Search prompts' }), {
      target: { value: 'SECOND' },
    });
    expect(screen.queryByRole('button', { name: '1. First question with context' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '2. Second question' }));
    expect(region.scrollTop).toBe(300);
    expect(document.activeElement).toBe(target);
    expect(screen.queryByRole('navigation', { name: 'Prompt history' })).toBeNull();
    view.rerender(
      <Transcript
        session={{ ...session, blocks: [...blocks, { kind: 'agent', text: 'Live output' }] }}
      />,
    );
    expect(region.scrollTop).toBe(300);
    view.rerender(<Transcript session={{ ...session, id: 'two' }} />);
    fireEvent.click(screen.getByRole('button', { name: 'Prompts (0)' }));
    expect(screen.getByText('No prompts yet.')).toBeTruthy();
    expect(screen.getByRole<HTMLInputElement>('textbox', { name: 'Search prompts' }).value).toBe(
      '',
    );
  },
);
it('keeps log state and live updates in fullscreen and restores focus on exit', () => {
  const { rerender } = render(
    <Transcript session={{ ...session, blocks: [{ kind: 'tool', title: 'Read file' }] }} />,
  );
  const dialog = screen.getByRole<HTMLDialogElement>('dialog', { hidden: true });
  dialog.showModal = () => dialog.setAttribute('open', '');
  dialog.close = () => dialog.removeAttribute('open');
  const transcript = screen.getByRole('region', { name: 'Conversation transcript' });
  Object.defineProperties(transcript, {
    scrollHeight: { configurable: true, value: 1000 },
    clientHeight: { configurable: true, value: 200 },
  });
  const tool = screen.getByText('Read file').closest('details')!;
  tool.open = true;
  transcript.scrollTop = 120;
  fireEvent.scroll(transcript);
  const button = screen.getByRole('button', { name: 'Fullscreen logs' });
  fireEvent.click(button);
  expect(dialog.contains(transcript)).toBe(true);
  expect(tool.open).toBe(true);
  expect(transcript.scrollTop).toBe(1000);
  expect(document.body.style.overflow).toBe('hidden');
  Object.defineProperty(transcript, 'scrollHeight', { configurable: true, value: 1200 });
  rerender(
    <Transcript
      session={{
        ...session,
        blocks: [
          { kind: 'tool', title: 'Read file' },
          { kind: 'agent', text: 'Live update' },
        ],
      }}
    />,
  );
  expect(dialog.textContent).toContain('Live update');
  expect(transcript.scrollTop).toBe(1200);
  fireEvent(dialog, new Event('cancel', { bubbles: true }));
  expect(dialog.hasAttribute('open')).toBe(false);
  expect(dialog.contains(transcript)).toBe(false);
  expect(tool.open).toBe(true);
  expect(document.body.style.overflow).toBe('');
  expect(document.activeElement).toBe(button);
  fireEvent.click(button);
  fireEvent.click(screen.getByRole('button', { name: 'Exit fullscreen' }));
  expect(dialog.hasAttribute('open')).toBe(false);
});
it('previews screenshots inside the app and restores focus when closed', () => {
  render(
    <Transcript
      session={{ ...session, blocks: [{ kind: 'agent', text: '[Screenshot](shot.png)' }] }}
    />,
  );
  const link = screen.getByRole('link', { name: 'Screenshot' });
  expect(link.getAttribute('target')).toBeNull();
  expect(screen.queryByRole('dialog')).toBeNull();
  fireEvent.click(link);
  const dialog = screen.getByRole('dialog', { name: 'Screenshot preview' });
  expect(screen.getByRole('img', { name: 'Screenshot' }).getAttribute('src')).toBe(
    link.getAttribute('href'),
  );
  expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' }));
  fireEvent.keyDown(dialog, { key: 'Escape' });
  expect(screen.queryByRole('dialog')).toBeNull();
  expect(document.activeElement).toBe(link);
  fireEvent.click(link);
  fireEvent.error(screen.getByRole('img', { name: 'Screenshot' }));
  expect(screen.getByRole('alert').textContent).toContain('Unable to load');
  fireEvent.click(screen.getByRole('button', { name: 'Close' }));
  expect(screen.queryByRole('dialog')).toBeNull();
});
it('opens local screenshot links and image attachments through the paired companion', () => {
  render(
    <Transcript
      session={{
        ...session,
        blocks: [
          {
            kind: 'agent',
            text: '[Screenshot](.playwright-mcp/mobile.png)\n\n![Preview](file:///workspace/preview.png)',
          },
          {
            kind: 'tool',
            content: [
              { content: { uri: 'file:///tmp/browser/result.png', name: 'Browser image' } },
            ],
          },
        ],
      }}
    />,
  );
  for (const [label, path] of [
    ['Screenshot', '.playwright-mcp/mobile.png'],
    ['[Image: Preview]', '/api/image?session=one&path=file%3A%2F%2F%2Fworkspace%2Fpreview.png'],
    ['Browser image', 'file:///tmp/browser/result.png'],
  ]) {
    const link = screen.getByRole('link', { name: label, hidden: true });
    const href = link.getAttribute('href')!;
    expect(href.startsWith('/api/image?')).toBe(true);
    if (label === '[Image: Preview]') expect(href).toBe(path);
    else expect(new URL(href, 'http://localhost').searchParams.get('path')).toBe(path);
  }
});
const session: Session = {
  id: 'one',
  conversation: 'generation',
  name: 'Agent',
  agent: 'fixture',
  worktree: '/workspace',
  status: 'idle',
  blocks: [],
  queue: [],
};

it('renders markdown, highlighted code, tables, plans, tools, permissions, and queued prompts', () => {
  render(
    <Transcript
      session={{
        ...session,
        blocks: [
          { kind: 'user', text: '**Follow up**' },
          {
            kind: 'agent',
            text: '```js\nconst value = 1;\n```\n\n| Name | Value |\n| --- | --- |\n| item | 1 |',
          },
          { kind: 'thought', text: 'Considering options' },
          { kind: 'plan', entries: [{ content: 'Implement feature', status: 'in_progress' }] },
          {
            kind: 'tool',
            title: 'Read file',
            status: 'completed',
            rawInput: { path: 'file.ts' },
            rawOutput: 'File contents',
            content: [{ type: 'diff', path: 'file.ts', oldText: 'old', newText: 'new' }],
          },
          { kind: 'permission', text: 'Allow read?' },
          { kind: 'info', meta_kind: 'error', text: 'Agent failed' },
        ],
        queue: ['Next prompt'],
      }}
    />,
  );
  expect(screen.getByText('Follow up').tagName).toBe('STRONG');
  expect(screen.getByRole('table')).toBeTruthy();
  expect(document.querySelector('code.hljs')).toBeTruthy();
  expect(screen.getByRole('article', { name: 'Agent plan' })).toBeTruthy();
  expect(screen.getByText('Read file')).toBeTruthy();
  expect(screen.getByRole('group', { name: 'Input', hidden: true })).toBeTruthy();
  expect(screen.getByText('Awaiting your permission choice')).toBeTruthy();
  expect(screen.getByRole('article', { name: 'Error message' })).toBeTruthy();
  expect(screen.getByRole('complementary', { name: 'Queued prompts' })).toBeTruthy();
});

it('keeps external links safe and describes images without loading them or raw HTML', () => {
  render(
    <Transcript
      session={{
        ...session,
        blocks: [
          {
            kind: 'agent',
            text: '[Docs](https://example.com)\n\n![Screenshot](https://example.com/image.png)\n\n<script>alert(1)</script>',
          },
        ],
      }}
    />,
  );
  const link = screen.getByRole('link', { name: 'Docs' });
  expect(link.getAttribute('rel')).toBe('noopener noreferrer');
  expect(link.getAttribute('target')).toBe('_blank');
  expect(screen.getByText('[Image: Screenshot]')).toBeTruthy();
  expect(document.querySelector('img, script')).toBeNull();
});

it('follows new output only when the reader remains near the bottom', () => {
  const view = render(<Transcript session={session} />);
  const region = screen.getByRole('region', { name: 'Conversation transcript' });
  Object.defineProperties(region, {
    scrollHeight: { configurable: true, value: 1000 },
    clientHeight: { configurable: true, value: 200 },
  });
  region.scrollTop = 100;
  fireEvent.scroll(region);
  view.rerender(
    <Transcript session={{ ...session, blocks: [{ kind: 'agent', text: 'New output' }] }} />,
  );
  expect(region.scrollTop).toBe(100);
  region.scrollTop = 800;
  fireEvent.scroll(region);
  view.rerender(<Transcript session={{ ...session, queue: ['Next'] }} />);
  expect(region.scrollTop).toBe(1000);
});
