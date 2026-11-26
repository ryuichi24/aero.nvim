import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { post } from './api';
import { Button } from './components/ui/button';
import { Markdown } from './markdown';
import type { Session } from './types';

export function ArticleBrowser({
  session,
  epoch,
  online,
  active = true,
}: {
  session: Session;
  epoch?: string;
  online: boolean;
  active?: boolean;
}) {
  const [selected, setSelected] = useState<string>();
  const [source, setSource] = useState(false);
  const scope = { epoch, session: session.id, conversation: session.conversation };
  const enabled = online && active && !!epoch && !!session.conversation;
  const library = useQuery({
    queryKey: ['articles', epoch, session.id, session.conversation],
    queryFn: ({ signal }) =>
      post<{ entries: { name: string }[]; active?: string }>('articles', scope, signal),
    enabled,
    refetchInterval: enabled ? 5000 : false,
  });
  const name = selected || library.data?.active || library.data?.entries[0]?.name;
  const article = useQuery({
    queryKey: ['article', epoch, session.id, session.conversation, name],
    queryFn: ({ signal }) =>
      post<{ name: string; content: string }>('articles', { ...scope, path: name }, signal),
    enabled: enabled && !!name,
    refetchInterval: enabled && name ? 5000 : false,
  });
  return (
    <section aria-label="Articles" className="my-4">
      <div className="source-reader-toolbar">
        <h3>Articles</h3>
        <Button
          variant="outline"
          type="button"
          disabled={!enabled || library.isFetching || article.isFetching}
          onClick={() => {
            void library.refetch();
            if (name) void article.refetch();
          }}
        >
          Refresh articles
        </Button>
      </div>
      <p>Review saved articles from the shared host library. Create one with /to-article.</p>
      {!online && <p role="status">Connect to Neovim to refresh articles.</p>}
      {library.isPending && enabled && <p role="status">Loading articles…</p>}
      {library.error && <p role="alert">{library.error.message}</p>}
      {library.data?.entries.length === 0 && (
        <p>No saved articles yet. Files will appear when the agent saves them.</p>
      )}
      <div className="flex flex-wrap gap-2" aria-label="Saved articles">
        {library.data?.entries.map((entry) => (
          <Button
            variant="outline"
            className="max-w-full whitespace-normal break-all text-left"
            type="button"
            key={entry.name}
            aria-pressed={name === entry.name}
            onClick={() => setSelected(entry.name)}
          >
            {entry.name}
            {entry.name === library.data.active ? ' · active' : ''}
          </Button>
        ))}
      </div>
      {name && (
        <section aria-label={`Article preview: ${name}`} className="transcript-card my-4">
          <div className="source-reader-toolbar">
            <strong>{name}</strong>
            <Button
              variant="outline"
              type="button"
              aria-pressed={source}
              onClick={() => setSource(!source)}
            >
              {source ? 'Show preview' : 'Show source'}
            </Button>
          </div>
          {name.endsWith('.mdx') && (
            <p>MDX is shown as Markdown; custom components are available in source view.</p>
          )}
          {article.isPending && enabled && <p role="status">Loading article…</p>}
          {article.error && <p role="alert">{article.error.message}</p>}
          {article.data &&
            (source ? (
              <pre className="overflow-auto">
                <code>{article.data.content}</code>
              </pre>
            ) : article.data.content ? (
              <Markdown
                text={article.data.content.replace(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/, '')}
              />
            ) : (
              <p>This article is empty. Refresh after the agent saves it.</p>
            ))}
          <p>
            Previewing a file does not change the session’s active article. Ask the agent for
            revisions in the conversation.
          </p>
        </section>
      )}
    </section>
  );
}
