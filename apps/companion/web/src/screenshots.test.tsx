import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { Screenshots, sessionScreenshots } from './screenshots';
import type { Session } from './types';

afterEach(cleanup);
it('ignores example screenshot paths in source tools and invalid file URI hosts', () => {
  const blocks: Session['blocks'] = [
    {
      kind: 'tool',
      tool_kind: 'read',
      content: [{ text: 'const example = "[Fixture](shot.png)";' }],
      rawOutput: 'shot.png',
    },
    {
      kind: 'tool',
      title: 'functions.apply_patch',
      rawOutput: '[Example](.playwright-mcp/mobile.png)',
    },
    { kind: 'tool', title: 'Read tests', text: '[Example](other.png)' },
    { kind: 'thought', text: '[Proposed](future.png)' },
    { kind: 'agent', text: '[Invalid](file://workspace/.playwright-mcp/mobile.png)' },
    {
      kind: 'tool',
      title: 'playwright_browser_take_screenshot',
      content: [{ text: '[Actual](.playwright-mcp/actual.png)' }],
    },
  ];
  expect(sessionScreenshots({ ...session, blocks }).map((image) => image.label)).toEqual([
    'Actual',
  ]);
});
const session: Session = {
  id: 'one',
  name: 'Agent',
  agent: 'fixture',
  worktree: '/workspace',
  status: 'idle',
  conversation: 'generation',
  blocks: [],
};

it('collects unique screenshot links, markdown images, references, attachments and tool outputs', () => {
  const images = sessionScreenshots({
    ...session,
    blocks: [
      {
        kind: 'agent',
        text: '[Mobile](.playwright-mcp/mobile.png)\n\n![Again](file:///workspace/.playwright-mcp/mobile.png)\n\n[Remote](https://example.com/remote.png)\n\n[Source](main.ts)',
      },
      { kind: 'tool', content: [{ content: { uri: '/workspace/desktop.webp', name: 'Desktop' } }] },
      { kind: 'tool', rawOutput: { content: [{ text: '[Latest](latest.jpg)' }] } },
      {
        kind: 'agent',
        text: '[Reference][shot]\n\n[shot]: referenced.gif\n\n```md\n[Example](fake.png)\n```',
      },
    ],
  });
  expect(images.map((image) => image.label)).toEqual(['Reference', 'Latest', 'Desktop', 'Mobile']);
  expect(images.every((image) => image.href.startsWith('/api/image?session=one&'))).toBe(true);
});

it('updates the list as screenshots arrive and previews them without leaving the session', () => {
  const view = render(<Screenshots session={session} />);
  expect(screen.queryByText('Screenshots (0)')).toBeNull();
  expect(view.container.querySelector('details')).toBeNull();
  view.rerender(
    <Screenshots
      session={{ ...session, blocks: [{ kind: 'agent', text: '[Mobile](mobile.png)' }] }}
    />,
  );
  const summary = screen.getByText('Screenshots (1)');
  fireEvent.click(summary);
  const list = screen.getByRole('list', { name: 'Session screenshots' });
  const link = within(list).getByRole('link', { name: /Mobile/ });
  expect(link.getAttribute('target')).toBeNull();
  fireEvent.click(link);
  expect(screen.getByRole('dialog', { name: 'Screenshot preview' })).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Close' }));
  expect(screen.queryByRole('dialog')).toBeNull();
  view.rerender(<Screenshots session={{ ...session, id: 'other', blocks: [] }} />);
  expect(view.container.querySelector('details')).toBeNull();
  expect(screen.queryByRole('link', { name: /Mobile/ })).toBeNull();
});
