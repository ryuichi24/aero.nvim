import { useEffect, useRef, useState } from 'react';
import { FullscreenAttention } from './fullscreen-attention';

const loadMermaid = () =>
  (mermaidPromise ??= import('mermaid').then(({ default: mermaid }) => {
    mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' });
    return mermaid;
  }));
let mermaidPromise: Promise<(typeof import('mermaid'))['default']> | undefined;
let nextId = 0;

export function Mermaid({ source }: { source: string }) {
  const [result, setResult] = useState<{ source: string; svg?: string; error?: string }>();
  const [fullscreen, setFullscreen] = useState(false);
  const [zoom, setZoom] = useState(1);
  const dialog = useRef<HTMLDialogElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!fullscreen) return;
    const modal = dialog.current!;
    const overflow = document.body.style.overflow;
    modal.showModal();
    document.body.style.overflow = 'hidden';
    return () => {
      modal.close();
      document.body.style.overflow = overflow;
      trigger.current?.focus();
    };
  }, [fullscreen]);

  useEffect(() => {
    let cancelled = false;
    async function render() {
      const container = document.createElement('div');
      container.style.cssText = 'position:absolute;left:-100000px;top:0;visibility:hidden';
      try {
        const mermaid = await loadMermaid();
        if (cancelled) return;
        document.body.append(container);
        const { svg } = await mermaid.render(`aero-mermaid-${++nextId}`, source, container);
        if (!cancelled) setResult({ source, svg });
      } catch (error) {
        if (!cancelled) {
          setResult({ source, error: error instanceof Error ? error.message : String(error) });
        }
      } finally {
        container.remove();
      }
    }
    void render();
    return () => {
      cancelled = true;
    };
  }, [source]);

  const current = result?.source === source ? result : undefined;
  const diagram = current?.svg ? (
    <div
      className="markdown-mermaid"
      role="img"
      aria-label="Mermaid diagram"
      dangerouslySetInnerHTML={{ __html: current.svg }}
    />
  ) : (
    <div className="markdown-mermaid-fallback">
      {current?.error && <p role="status">Unable to render Mermaid diagram: {current.error}</p>}
      <pre>
        <code className="language-mermaid">{source}</code>
      </pre>
    </div>
  );
  return (
    <div className="mermaid-preview">
      {current?.svg && (
        <div className="mermaid-preview-controls" hidden={fullscreen}>
          <button
            ref={trigger}
            type="button"
            aria-label="Fullscreen diagram"
            title="Fullscreen diagram"
            onClick={() => {
              setZoom(1);
              setFullscreen(true);
            }}
          >
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
              focusable="false"
            >
              <path d="M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5" />
            </svg>
          </button>
        </div>
      )}
      {!fullscreen && diagram}
      <dialog
        ref={dialog}
        className="mermaid-fullscreen"
        aria-label="Fullscreen Mermaid diagram"
        onCancel={() => setFullscreen(false)}
        onClose={() => setFullscreen(false)}
      >
        {fullscreen && (
          <>
            <header className="source-reader-toolbar">
              <strong>Mermaid diagram</strong>
              <button
                type="button"
                disabled={zoom <= 1}
                onClick={() => setZoom((value) => Math.max(1, value - 0.5))}
              >
                Zoom out
              </button>
              <output aria-label="Diagram zoom">{Math.round(zoom * 100)}%</output>
              <button
                type="button"
                disabled={zoom >= 5}
                onClick={() => setZoom((value) => Math.min(5, value + 0.5))}
              >
                Zoom in
              </button>
              <button type="button" onClick={() => setZoom(1)}>
                Reset zoom
              </button>
              <FullscreenAttention />
              <button type="button" autoFocus onClick={() => setFullscreen(false)}>
                Exit fullscreen diagram
              </button>
            </header>
            <div className="mermaid-fullscreen-content">
              <div style={{ width: `${zoom * 100}%` }}>{diagram}</div>
            </div>
          </>
        )}
      </dialog>
    </div>
  );
}
