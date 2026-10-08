import { useMemo } from 'react';
import hljs from 'highlight.js/lib/common';
import { splitHighlightedLines, visibleSourceLines, type FoldRange } from './source-folds';

export function SourceCode({
  content,
  path,
  language,
  ranges,
  collapsed,
  onToggle,
}: {
  content: string;
  path: string;
  language: string;
  ranges: FoldRange[];
  collapsed: Set<number>;
  onToggle: (line: number) => void;
}) {
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
      <div className="source-code-rows">
        {visibleSourceLines(plain.length, ranges, collapsed).map(({ line, fold, hidden }) => (
          <div className="source-code-row" key={line}>
            <span className="source-gutter">
              <span aria-hidden="true">{line + 1}</span>
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
