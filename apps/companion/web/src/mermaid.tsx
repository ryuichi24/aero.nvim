import { useEffect, useState } from 'react';

const loadMermaid = () =>
  (mermaidPromise ??= import('mermaid').then(({ default: mermaid }) => {
    mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' });
    return mermaid;
  }));
let mermaidPromise: Promise<(typeof import('mermaid'))['default']> | undefined;
let nextId = 0;

export function Mermaid({ source }: { source: string }) {
  const [result, setResult] = useState<{ source: string; svg?: string; error?: string }>();

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
  return current?.svg ? (
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
}
