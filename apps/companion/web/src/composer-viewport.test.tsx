import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Transcript } from './transcript';
import type { Session } from './types';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  document.body.style.overflow = '';
});
const session: Session = {
  id: 'agent',
  name: 'Agent',
  agent: 'fixture',
  worktree: '/repo',
  status: 'idle',
  conversation: 'one',
  blocks: [{ kind: 'agent', text: 'Long conversation' }],
};
function setup() {
  const viewport = Object.assign(new EventTarget(), { height: 800, offsetTop: 0 });
  vi.stubGlobal('visualViewport', viewport);
  vi.stubGlobal('innerHeight', 800);
  vi.stubGlobal('innerWidth', 390);
  render(
    <Transcript
      session={session}
      composer={<textarea aria-label="Prompt" defaultValue="Keep this draft" />}
    />,
  );
  const input = screen.getByRole<HTMLTextAreaElement>('textbox', { name: 'Prompt' });
  fireEvent.pointerDown(input);
  act(() => input.focus());
  return { viewport, input, host: document.querySelector<HTMLElement>('.transcript-inline')! };
}

it('anchors the input frame to a panned keyboard viewport even when innerHeight also shrinks', () => {
  document.body.style.overflow = 'auto';
  const { viewport, input, host } = setup();
  act(() => {
    viewport.height = 340;
    viewport.offsetTop = 130;
    vi.stubGlobal('innerHeight', 340);
    viewport.dispatchEvent(new Event('resize'));
  });
  expect(host.dataset.keyboard).toBe('open');
  expect(host.style.getPropertyValue('--transcript-height')).toBe('340px');
  expect(host.style.getPropertyValue('--transcript-keyboard-top')).toBe('130px');
  expect(document.body.style.overflow).toBe('auto');
  act(() => {
    viewport.offsetTop = 180;
    viewport.dispatchEvent(new Event('scroll'));
  });
  expect(host.style.getPropertyValue('--transcript-keyboard-top')).toBe('180px');
  act(() => {
    viewport.height = 800;
    viewport.offsetTop = 0;
    vi.stubGlobal('innerHeight', 800);
    viewport.dispatchEvent(new Event('resize'));
  });
  expect(host.dataset.keyboard).toBe('closed');
  expect(document.body.style.overflow).toBe('auto');
  expect(input.value).toBe('Keep this draft');
});

it('restores the page position after the browser auto-scrolls during keyboard focus', () => {
  const scroll = vi.spyOn(window, 'scrollTo').mockImplementation(() => {});
  const { viewport, host } = setup();
  act(() => {
    vi.stubGlobal('scrollY', 480);
    viewport.height = 260;
    viewport.offsetTop = 220;
    viewport.dispatchEvent(new Event('resize'));
  });
  expect(host.style.getPropertyValue('--transcript-height')).toBe('260px');
  expect(host.style.getPropertyValue('--transcript-keyboard-top')).toBe('220px');
  act(() => {
    viewport.height = 800;
    viewport.offsetTop = 0;
    viewport.dispatchEvent(new Event('resize'));
  });
  expect(scroll).toHaveBeenCalledWith({ left: 0, top: 0 });
  expect(document.body.style.overflow).toBe('');
});
