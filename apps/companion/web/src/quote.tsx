import { useEffect, useRef, useState, type ReactNode } from 'react';

export interface Quote {
  text: string;
  source: string;
  language?: string;
  first?: number;
  last?: number;
}

export function formatQuote(quote: Quote): string {
  const ticks = quote.text.match(/`+/g) || [];
  const fence = '`'.repeat(Math.max(3, ...ticks.map((value) => value.length + 1)));
  const lines = quote.first !== undefined ? ` (lines ${quote.first}-${quote.last})` : '';
  return `Quoted from ${quote.source}${lines}:\n\n${fence}${(quote.language || 'text').replace(/[^\w-]/g, '')}\n${quote.text}\n${fence}`;
}

// Store the text rather than a live Range: iOS can collapse the native selection
// when the user touches the action, and streamed transcript nodes can change.
export function QuoteSelection({
  source,
  language,
  onQuote,
  children,
}: {
  source: string;
  language?: string;
  onQuote?: (quote: Quote) => void;
  children: ReactNode;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [quote, setQuote] = useState<Quote>();
  const enabled = !!onQuote;
  useEffect(() => {
    setQuote(undefined);
    if (!enabled) return;
    const capture = () => {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || !selection.rangeCount) return;
      const range = selection.getRangeAt(0);
      if (
        !root.current?.contains(range.startContainer) ||
        !root.current.contains(range.endContainer)
      ) {
        setQuote(undefined);
        return;
      }
      const element = (node: Node) => (node instanceof Element ? node : node.parentElement);
      const first = element(range.startContainer)?.closest<HTMLElement>('[data-source-line]');
      const last = element(range.endContainer)?.closest<HTMLElement>('[data-source-line]');
      let text = selection.toString();
      if (first && last) {
        // Clone just the selected code fragments, omitting gutters and folding UI.
        const codes = range.cloneContents().querySelectorAll('code');
        text = codes.length ? Array.from(codes, (code) => code.textContent || '').join('\n') : text;
      }
      if (text.trim())
        setQuote({
          text,
          source,
          language,
          ...(first && last
            ? { first: Number(first.dataset.sourceLine), last: Number(last.dataset.sourceLine) }
            : {}),
        });
    };
    document.addEventListener('selectionchange', capture);
    return () => document.removeEventListener('selectionchange', capture);
  }, [source, language, enabled]);
  return (
    <div ref={root} className="quote-selection">
      {onQuote && (
        <div className="quote-toolbar">
          <button
            type="button"
            disabled={!quote}
            onPointerDown={(event) => event.preventDefault()}
            onClick={() => {
              if (!quote) return;
              onQuote(quote);
              setQuote(undefined);
              window.getSelection()?.removeAllRanges();
            }}
          >
            Quote to prompt
          </button>
          {quote && (
            <button
              type="button"
              onClick={() => {
                setQuote(undefined);
                window.getSelection()?.removeAllRanges();
              }}
            >
              Clear selection
            </button>
          )}
        </div>
      )}
      {children}
    </div>
  );
}
