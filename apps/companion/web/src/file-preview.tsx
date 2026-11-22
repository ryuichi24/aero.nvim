import { createContext, useContext, useState } from 'react';
import { Button } from './components/ui/button';
import { useQuery } from '@tanstack/react-query';
import { post } from './api';

export const FileContext = createContext({ worktree: '', online: false });

export function fileReference(value: string, worktree: string) {
  if (!worktree || value.startsWith('//')) return;
  let path = value;
  if (path.startsWith('file://')) {
    try {
      const url = new URL(path);
      if (url.hostname && url.hostname !== 'localhost') return;
      path = decodeURIComponent(url.pathname) + url.hash;
    } catch {
      return;
    }
  } else if (/^[a-z][a-z\d+.-]*:/i.test(path) && !/:\d+(?::\d+)?$/.test(path)) return;
  const match = path.match(/(?::(\d+)(?::\d+)?|#L(\d+)(?:-L?(\d+))?)$/);
  const line = match ? Number(match[1] || match[2]) : undefined;
  const end = match?.[3] ? Number(match[3]) : line;
  if (match) path = path.slice(0, match.index);
  if (path.startsWith('/')) {
    const root = worktree.replace(/\/$/, '') + '/';
    if (!path.startsWith(root)) return;
    path = path.slice(root.length);
  }
  path = path.replace(/^\.\//, '');
  if (!path || path.split('/').includes('..') || /[?#]/.test(path)) return;
  if (!/(?:\/|\.[a-z\d]+$)/i.test(path)) return;
  return { path, line, end };
}

interface Node {
  type: string;
  value?: string;
  url?: string;
  children?: Node[];
}

// Only prose and inline code are linkified; fenced code and existing links stay intact.
export function remarkFileReferences() {
  return (tree: Node) => {
    function walk(node: Node) {
      if (['link', 'image', 'code'].includes(node.type) || !node.children) return;
      node.children = node.children.flatMap((child) => {
        if (
          child.type === 'inlineCode' &&
          child.value &&
          /^(?:[^\s]+\/[^\s]+|[^\s]+\.[a-z\d]+)(?::\d+(?::\d+)?|#L\d+(?:-L?\d+)?)?$/i.test(
            child.value,
          )
        ) {
          return [{ type: 'link', url: child.value, children: [child] }];
        }
        if (child.type === 'text' && child.value) {
          const result: Node[] = [];
          const pattern =
            /(?<![\w/@])(?:file:\/\/\/|\.?\.?\/|\/)?(?:(?:[\w.@-]+\/)+[\w@-]+(?:\.[a-zA-Z\d]+)*|[\w@-]+\.[a-zA-Z\d]+)(?::\d+(?::\d+)?|#L\d+(?:-L?\d+)?)?/g;
          let offset = 0;
          for (const match of child.value.matchAll(pattern)) {
            if (match.index > offset)
              result.push({ type: 'text', value: child.value.slice(offset, match.index) });
            result.push({
              type: 'link',
              url: match[0],
              children: [{ type: 'text', value: match[0] }],
            });
            offset = match.index + match[0].length;
          }
          if (offset < child.value.length)
            result.push({ type: 'text', value: child.value.slice(offset) });
          return result;
        }
        walk(child);
        return [child];
      });
    }
    walk(tree);
  };
}

export function FilePreview({
  reference,
  onClose,
}: {
  reference: NonNullable<ReturnType<typeof fileReference>>;
  onClose: () => void;
}) {
  const { worktree, online } = useContext(FileContext);
  const [all, setAll] = useState(false);
  const query = useQuery({
    queryKey: ['source', worktree, reference.path],
    queryFn: () => post<{ content?: string }>('source', { worktree, path: reference.path }),
    enabled: online,
    retry: false,
  });
  const lines = query.data?.content?.split('\n');
  const start = all || !reference.line ? 0 : Math.max(0, reference.line - 7);
  const end = all || !reference.line ? lines?.length : (reference.end || reference.line) + 6;
  return (
    <section
      className="file-inline-preview my-3 min-w-0 rounded-lg border border-border p-3"
      aria-label={`Code preview: ${reference.path}`}
    >
      <header className="flex items-center justify-between gap-2">
        <strong className="wrap-anywhere">
          {reference.path}
          {reference.line ? `:${reference.line}` : ''}
        </strong>
        <Button variant="outline" onClick={onClose}>
          Close preview
        </Button>
      </header>
      {!online && <p role="status">Connect to the host to preview this file.</p>}
      {query.isFetching && <p role="status">Loading code…</p>}
      {query.error && (
        <p role="alert">
          {query.error.message}{' '}
          <Button variant="outline" onClick={() => void query.refetch()}>
            Retry
          </Button>
        </p>
      )}
      {query.data && !lines && <p role="status">This path is a directory, not a source file.</p>}
      {lines && (
        <pre className="max-h-112 overflow-auto">
          <code>
            {lines.slice(start, end).map((text, index) => {
              const number = start + index + 1;
              return (
                <span
                  className={
                    number >= (reference.line || Infinity) &&
                    number <= (reference.end || reference.line || 0)
                      ? 'file-preview-line referenced block bg-accent'
                      : 'file-preview-line block'
                  }
                  key={number}
                >
                  <span className="file-preview-number inline-block w-16 pr-4 text-right text-muted-foreground select-none">
                    {number}
                  </span>
                  {text || ' '}
                  {'\n'}
                </span>
              );
            })}
          </code>
        </pre>
      )}
      {lines && reference.line && (
        <Button variant="outline" onClick={() => setAll((value) => !value)}>
          {all ? 'Show surrounding lines' : 'Show full file'}
        </Button>
      )}
    </section>
  );
}
