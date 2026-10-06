import { useLayoutEffect, useRef } from 'react';
import { Markdown } from './markdown';
import type { Session, TranscriptBlock } from './types';

function readableStatus(status: string): string {
  return status.replaceAll('_', ' ');
}

function RawOutput({ label, value }: { label: string; value: unknown }) {
  if (value === undefined || value === null || value === '') return null;
  return (
    <div className="tool-data" role="group" aria-label={label}>
      <div className="tool-data-label">{label}</div>
      <pre>
        <code>{typeof value === 'string' ? value : JSON.stringify(value, null, 2)}</code>
      </pre>
    </div>
  );
}
function ToolContent({ block }: { block: TranscriptBlock }) {
  return (
    <div className="tool-content">
      {block.text && <Markdown text={block.text} />}
      {block.content?.map((content, index) => {
        if (content.type === 'diff')
          return (
            <div className="tool-diff" key={index}>
              {content.path && <div className="tool-data-label">{content.path}</div>}
              <RawOutput label="Before" value={content.oldText} />
              <RawOutput label="After" value={content.newText} />
            </div>
          );
        const text = content.content?.text ?? content.text;
        if (text !== undefined) return <Markdown key={index} text={text} />;
        if (content.content?.uri)
          return (
            <p key={index} className="resource-label">
              {content.content.name || content.content.uri}
            </p>
          );
        return <RawOutput key={index} label="Attachment" value={content} />;
      })}
      <RawOutput label="Input" value={block.rawInput} />
      <RawOutput label="Output" value={block.rawOutput} />
    </div>
  );
}
function Block({ block }: { block: TranscriptBlock }) {
  if (block.kind === 'tool')
    return (
      <details className="transcript-card tool-card">
        <summary>
          <span className="message-label">Tool</span>
          <span className="tool-title">{block.title || block.tool_kind || 'Tool call'}</span>
          {block.status && (
            <span className={`status-badge status-${block.status}`}>
              {readableStatus(block.status)}
            </span>
          )}
        </summary>
        <ToolContent block={block} />
      </details>
    );
  if (block.kind === 'thought')
    return (
      <details className="transcript-card thought-card">
        <summary>Thinking</summary>
        <Markdown text={block.text || ''} />
      </details>
    );
  if (block.kind === 'plan')
    return (
      <article className="transcript-card plan-card" aria-label="Agent plan">
        <div className="message-label">Plan</div>
        <ul className="plan-list">
          {block.entries?.map((entry, index) => (
            <li key={index}>
              <span className={`status-badge status-${entry.status}`}>
                {readableStatus(entry.status)}
              </span>
              <Markdown text={entry.content} />
            </li>
          ))}
        </ul>
      </article>
    );
  const label =
    block.kind === 'user'
      ? 'You'
      : block.kind === 'agent'
        ? 'Agent'
        : block.kind === 'permission'
          ? 'Permission'
          : block.meta_kind === 'error'
            ? 'Error'
            : 'Session';
  return (
    <article
      className={`transcript-card message-${block.kind}${block.meta_kind === 'error' ? ' message-error' : ''}`}
      aria-label={`${label} message`}
    >
      <div className="message-label">{label}</div>
      <Markdown text={block.text || block.title || ''} />
      {block.kind === 'permission' && (
        <p className="permission-answer">
          {block.answer ? `Answer: ${block.answer}` : 'Awaiting your permission choice'}
        </p>
      )}
      {block.kind !== 'permission' && <ToolContent block={{ ...block, text: undefined }} />}
    </article>
  );
}
export function Transcript({ session, active = true }: { session?: Session; active?: boolean }) {
  const element = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  useLayoutEffect(() => {
    if (active && element.current && follow.current)
      element.current.scrollTop = element.current.scrollHeight;
  }, [active, session?.blocks, session?.queue]);
  return (
    <div
      id="transcript"
      role="region"
      aria-label="Conversation transcript"
      tabIndex={0}
      ref={element}
      onScroll={() => {
        const node = element.current;
        if (node) follow.current = node.scrollHeight - node.scrollTop - node.clientHeight < 40;
      }}
    >
      {session?.blocks?.map((block, index) => (
        <Block key={`${block.kind}:${block.id || index}`} block={block} />
      ))}
      {!!session?.queue?.length && (
        <aside className="transcript-card queued-card" aria-label="Queued prompts">
          <div className="message-label">Queued prompts</div>
          {session.queue.map((text, index) => (
            <div className="queued-prompt" key={index}>
              <Markdown text={text} />
            </div>
          ))}
        </aside>
      )}
    </div>
  );
}
