import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { formatQuote, QuoteSelection } from './quote';
import { SourceCode } from './source-code';
import { companionReducer, draftKey, initialState } from './companion-state';

afterEach(() => {
  cleanup();
  window.getSelection()?.removeAllRanges();
});

it('captures partial code across highlighted lines without gutters and retains it after selection collapse', () => {
  const onQuote = vi.fn();
  render(
    <QuoteSelection source="file.ts" language="typescript" onQuote={onQuote}>
      <div data-source-line="2">
        <button>2</button>
        <code>
          <span>const </span>
          <span>first = 1;</span>
        </code>
      </div>
      <div data-source-line="3">
        <button>3</button>
        <code>
          <span>{'  second();'}</span>
        </code>
        <button>Collapse</button>
      </div>
    </QuoteSelection>,
  );
  const codes = document.querySelectorAll('code');
  const range = document.createRange();
  range.setStart(codes[0].lastChild!.firstChild!, 0);
  range.setEnd(codes[1].firstChild!.firstChild!, 8);
  window.getSelection()!.addRange(range);
  fireEvent(document, new Event('selectionchange'));
  window.getSelection()!.removeAllRanges();
  fireEvent(document, new Event('selectionchange'));
  fireEvent.click(screen.getByRole('button', { name: 'Quote to prompt' }));
  expect(onQuote).toHaveBeenCalledWith({
    source: 'file.ts',
    language: 'typescript',
    first: 2,
    last: 3,
    text: 'first = 1;\n  second',
  });
});

it('quotes a reversed line range including folded lines with original indentation', () => {
  const onQuote = vi.fn();
  render(
    <SourceCode
      content={'start\n  hidden\nend'}
      path="file.txt"
      language="text"
      ranges={[{ start: 0, end: 1 }]}
      collapsed={new Set([0])}
      onToggle={() => {}}
      onQuote={onQuote}
    />,
  );
  fireEvent.click(screen.getByRole('button', { name: 'Select line 3' }));
  fireEvent.click(screen.getByRole('button', { name: 'Select line 1' }));
  fireEvent.click(screen.getByRole('button', { name: 'Quote selected lines' }));
  expect(onQuote).toHaveBeenCalledWith({
    source: 'file.txt',
    language: 'text',
    first: 1,
    last: 3,
    text: 'start\n  hidden\nend',
  });
});

it('uses a fence that can contain quoted markdown fences', () => {
  expect(formatQuote({ source: 'report.md', text: '```js\ncode\n```', language: 'markdown' })).toBe(
    'Quoted from report.md:\n\n````markdown\n```js\ncode\n```\n````',
  );
});

it('appends to the destination draft without changing another conversation draft', () => {
  const selected = { id: 'one', conversation: 'a' };
  const target = { id: 'two', conversation: 'b' };
  const state = {
    ...initialState(null),
    selected,
    drafts: { [draftKey(selected)]: 'Keep me', [draftKey(target)]: 'Existing request' },
  };
  const result = companionReducer(state, {
    type: 'append-quote',
    selection: target,
    value: 'Quote',
  });
  expect(result.drafts[draftKey(selected)]).toBe('Keep me');
  expect(result.drafts[draftKey(target)]).toBe('Existing request\n\nQuote');
  expect(result.pending).toBeNull();
});
