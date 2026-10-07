import { useId, useMemo, useState, type ReactNode } from 'react';
import remarkParse from 'remark-parse';
import { unified } from 'unified';
import { Mermaid } from './mermaid';

const parser = unified().use(remarkParse);

interface MarkdownNode {
  type: string;
  lang?: string | null;
  value?: string;
  children?: MarkdownNode[];
}

function diagramsIn(node: MarkdownNode): string[] {
  if (node.type === 'code' && node.lang === 'mermaid') return [node.value || ''];
  return node.children?.flatMap(diagramsIn) || [];
}

export function MarkdownMermaidPreview({
  source,
  children,
}: {
  source: string;
  children: ReactNode;
}) {
  const { diagrams, automatic } = useMemo(() => {
    const tree = parser.parse(source);
    const diagrams = diagramsIn(tree);
    return {
      diagrams,
      automatic:
        tree.children.length === 1 &&
        tree.children[0].type === 'code' &&
        tree.children[0].lang === 'mermaid',
    };
  }, [source]);
  const [preview, setPreview] = useState(automatic);
  const id = useId();

  if (!diagrams.length) return <pre>{children}</pre>;
  return (
    <div className="markdown-mermaid-example">
      <button
        type="button"
        aria-expanded={preview}
        aria-controls={id}
        onClick={() => setPreview(!preview)}
      >
        {preview
          ? automatic
            ? 'View source'
            : 'Hide preview'
          : diagrams.length === 1
            ? 'Preview diagram'
            : 'Preview diagrams'}
      </button>
      {(!automatic || !preview) && <pre>{children}</pre>}
      <div id={id} hidden={!preview}>
        {preview && diagrams.map((diagram, index) => <Mermaid key={index} source={diagram} />)}
      </div>
    </div>
  );
}
