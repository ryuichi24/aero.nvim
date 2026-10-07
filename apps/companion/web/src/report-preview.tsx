import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { post } from './api';
import { Markdown } from './markdown';
import type { TranscriptBlock } from './types';

export function attachedReports(block: TranscriptBlock, directory: string): string[] {
  const paths = new Set<string>();
  const prefix = `${directory.replace(/\/$/, '')}/`;
  const add = (value: string) => {
    if (value.startsWith('file://')) {
      try {
        value = decodeURIComponent(new URL(value).pathname);
      } catch {
        return;
      }
    }
    if (!value.startsWith(prefix)) return;
    const name = value.slice(prefix.length);
    if (name.endsWith('.md') && !/[/\\\r\n]/.test(name)) paths.add(name);
  };
  const scan = (text: string) => {
    for (const match of text.matchAll(/"(?:[^"\\]|\\.)*"/g)) {
      try {
        add(JSON.parse(match[0]) as string);
      } catch {
        // Other quoted text is not necessarily a JSON path.
      }
    }
    for (const match of text.matchAll(/(?:file:\/\/)?\/[^\s"'`<>()[\]]+\.md\b/g)) add(match[0]);
  };
  scan(block.text || '');
  for (const item of block.content || []) {
    if (item.content?.uri) add(item.content.uri);
    if (item.path) add(item.path);
    scan(item.content?.text || item.text || '');
  }
  return [...paths];
}

export function ReportPreview({
  worktree,
  name,
  online,
}: {
  worktree: string;
  name: string;
  online: boolean;
}) {
  const [source, setSource] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const query = useQuery({
    queryKey: ['reports', worktree, name],
    queryFn: () => post<{ content: string }>('reports', { worktree, path: name }),
    enabled: online && expanded,
    refetchInterval: online && expanded ? 5000 : false,
  });
  return (
    <section className="transcript-card report-preview" aria-label={`Report preview: ${name}`}>
      <div className="source-reader-toolbar">
        <strong>{name}</strong>
        <button aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
          {expanded ? 'Hide report' : 'Show report'}
        </button>
      </div>
      {expanded && (
        <>
          <div className="source-reader-toolbar">
            <button aria-pressed={source} onClick={() => setSource((value) => !value)}>
              {source ? 'Show preview' : 'Show source'}
            </button>
            <button disabled={!online || query.isFetching} onClick={() => void query.refetch()}>
              Refresh report
            </button>
          </div>
          {query.isPending && online && <p role="status">Loading report…</p>}
          {!online && <p role="status">Connect to Neovim to refresh this report.</p>}
          {query.error && <p role="alert">{query.error.message}</p>}
          {query.data &&
            (source ? (
              <pre>
                <code>{query.data.content}</code>
              </pre>
            ) : query.data.content ? (
              <Markdown text={query.data.content} />
            ) : (
              <p>This report is empty. Its contents will appear here when the agent updates it.</p>
            ))}
        </>
      )}
    </section>
  );
}
