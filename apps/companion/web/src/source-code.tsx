import { useMemo, useState } from 'react';
import type { Quote } from './quote';
import hljs from 'highlight.js/lib/common';
import { splitHighlightedLines, visibleSourceLines, type FoldRange } from './source-folds';

export function SourceCode({
  content,
  path,
  language,
  ranges,
  collapsed,
  onToggle,
  onQuote,
}: {
  content: string;
  path: string;
  language: string;
  ranges: FoldRange[];
  collapsed: Set<number>;
  onToggle: (line: number) => void;
  onQuote?: (quote: Quote) => void;
}) {
  const [selection, setSelection] = useState<{ start: number; end?: number }>();
  const lines = useMemo(
    () =>
      hljs.getLanguage(language)
        ? splitHighlightedLines(hljs.highlight(content, { language }).value)
        : undefined,
    [content, language],
  );
  const plain = useMemo(() => content.split('\n'), [content]);
  return (
    <div className="source-code source-foldable" aria-label={path}>
      {onQuote && (
        <div className="quote-toolbar">
          <span>
            {selection
              ? `Lines ${Math.min(selection.start, selection.end ?? selection.start) + 1}–${Math.max(selection.start, selection.end ?? selection.start) + 1}. Tap another line to ${selection.end === undefined ? 'extend' : 'start a new selection'}.`
              : 'Tap line numbers to select a code range.'}
          </span>
          <button
            type="button"
            disabled={!selection}
            onClick={() => {
              if (!selection) return;
              const first = Math.min(selection.start, selection.end ?? selection.start);
              const last = Math.max(selection.start, selection.end ?? selection.start);
              onQuote({
                source: path,
                language,
                first: first + 1,
                last: last + 1,
                text: plain.slice(first, last + 1).join('\n'),
              });
              setSelection(undefined);
            }}
          >
            Quote selected lines
          </button>
          {selection && (
            <button type="button" onClick={() => setSelection(undefined)}>
              Clear line range
            </button>
          )}
        </div>
      )}
      <div className="source-code-rows">
        {visibleSourceLines(plain.length, ranges, collapsed).map(({ line, fold, hidden }) => (
          <div
            className="source-code-row"
            key={line}
            data-source-line={line + 1}
            data-quote-selected={
              selection &&
              line >= Math.min(selection.start, selection.end ?? selection.start) &&
              line <= Math.max(selection.start, selection.end ?? selection.start)
                ? true
                : undefined
            }
          >
            <span className="source-gutter">
              {onQuote ? (
                <button
                  type="button"
                  className="source-line-select"
                  aria-label={`Select line ${line + 1}`}
                  onClick={() =>
                    setSelection((current) =>
                      current && current.end === undefined
                        ? { ...current, end: line }
                        : { start: line },
                    )
                  }
                >
                  {line + 1}
                </button>
              ) : (
                <span aria-hidden="true">{line + 1}</span>
              )}
              {fold ? (
                <button
                  aria-label={`${hidden ? 'Expand' : 'Collapse'} lines ${line + 1}–${fold.end + 1}`}
                  aria-expanded={!hidden}
                  onClick={() => onToggle(line)}
                >
                  {hidden ? '▸' : '▾'}
                </button>
              ) : (
                <span className="source-fold-spacer" />
              )}
            </span>
            <code
              className="hljs"
              {...(lines
                ? { dangerouslySetInnerHTML: { __html: lines[line] || ' ' } }
                : { children: plain[line] || ' ' })}
            />
            {!!hidden && (
              <button className="source-fold-placeholder" onClick={() => onToggle(line)}>
                … {hidden} {hidden === 1 ? 'line' : 'lines'}
              </button>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
