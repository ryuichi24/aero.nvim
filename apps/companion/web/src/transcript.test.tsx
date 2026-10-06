import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { Transcript } from './transcript';
import type { Session } from './types';

afterEach(cleanup);
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
