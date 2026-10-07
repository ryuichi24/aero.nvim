import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Markdown } from './markdown';
import { FullscreenAttention } from './fullscreen-attention';
import type { Session, TranscriptBlock } from './types';
import { ImageLink, ImageSession, useImageLink, useVideoLink } from './image-link';

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
  const imageLink = useImageLink();
  const videoLink = useVideoLink();
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
              {imageLink(content.content.uri) ? (
                <ImageLink href={imageLink(content.content.uri)!}>
                  {content.content.name || content.content.uri}
                </ImageLink>
              ) : videoLink(content.content.uri) ? (
                <ImageLink href={videoLink(content.content.uri)!} media="video">
                  {content.content.name || content.content.uri}
                </ImageLink>
              ) : (
                content.content.name || content.content.uri
              )}
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
export function Transcript({
  session,
  active = true,
  composer,
  feedback,
}: {
  session?: Session;
  active?: boolean;
  composer?: ReactNode;
  feedback?: ReactNode;
}) {
  const [fullscreen, setFullscreen] = useState(false);
  const [inputVisible, setInputVisible] = useState(true);
  const [container] = useState(() => document.createElement('div'));
  const inline = useRef<HTMLDivElement>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const element = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  useLayoutEffect(() => {
    const scrollTop = element.current?.scrollTop || 0;
    const host = fullscreen ? dialog.current! : inline.current!;
    host.appendChild(container);
    if (element.current) element.current.scrollTop = scrollTop;
    if (!fullscreen) return;
    const modal = dialog.current!;
    const overflow = document.body.style.overflow;
    modal.showModal();
    document.body.style.overflow = 'hidden';
    return () => {
      modal.close();
      document.body.style.overflow = overflow;
      button.current?.focus();
    };
  }, [container, fullscreen]);
  useLayoutEffect(() => {
    if (!active) setFullscreen(false);
  }, [active]);
  useLayoutEffect(() => {
    if (active && element.current && follow.current)
      element.current.scrollTop = element.current.scrollHeight;
  }, [active, session?.blocks, session?.queue]);
  return (
    <ImageSession.Provider value={session?.id || ''}>
      <div className="transcript-toolbar">
        <button ref={button} onClick={() => setFullscreen(true)}>
          Fullscreen logs
        </button>
      </div>
      <div ref={inline} />
      <dialog
        ref={dialog}
        className="transcript-fullscreen"
        aria-label="Fullscreen agent logs"
        onCancel={() => setFullscreen(false)}
        onClose={() => setFullscreen(false)}
      >
        <header className="transcript-toolbar">
          <strong>{session?.name || 'Agent'} · Logs</strong>
          {fullscreen && <FullscreenAttention />}
          {composer && (
            <button
              aria-expanded={inputVisible}
              aria-controls="log-composer"
              onClick={() => setInputVisible((value) => !value)}
            >
              {inputVisible ? 'Hide input' : 'Show input'}
            </button>
          )}
          <button onClick={() => setFullscreen(false)}>Exit fullscreen</button>
        </header>
      </dialog>
      {createPortal(
        <>
          <div
            id="transcript"
            role="region"
            aria-label="Conversation transcript"
            tabIndex={0}
            ref={element}
            onScroll={() => {
              const node = element.current;
              if (node)
                follow.current = node.scrollHeight - node.scrollTop - node.clientHeight < 40;
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
          {composer && (
            <div id="log-composer" className="log-composer" hidden={fullscreen && !inputVisible}>
              {composer}
              {fullscreen && feedback}
            </div>
          )}
        </>,
        container,
      )}
    </ImageSession.Provider>
  );
}
