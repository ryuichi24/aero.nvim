import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Markdown } from './markdown';
import { attachedReports, ReportPreview } from './report-preview';
import { FullscreenAttention } from './fullscreen-attention';
import type { Session, TranscriptBlock } from './types';
import { ImageLink, ImageSession, useImageLink, useVideoLink } from './image-link';
import { blockTodos, TodoList } from './agent-todos';

function readableStatus(status: string): string {
  return status.replaceAll('_', ' ');
}

function Timestamp({ block }: { block: TranscriptBlock }) {
  if (typeof block.timestamp !== 'number' || !Number.isFinite(block.timestamp)) return null;
  const date = new Date(block.timestamp * 1000);
  if (Number.isNaN(date.getTime())) return null;
  const pad = (value: number) => String(value).padStart(2, '0');
  const text = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  return (
    <time className="transcript-timestamp" dateTime={date.toISOString()} title={date.toString()}>
      {text}
    </time>
  );
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
  const todos = blockTodos(block);
  if (todos !== undefined) return <TodoList todos={todos} />;
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
      <details
        className="transcript-card tool-card"
        open={block.status === 'pending' || block.status === 'in_progress'}
      >
        <summary>
          <span className="message-label">Tool</span>
          <span className="tool-title">{block.title || block.tool_kind || 'Tool call'}</span>
          {block.status && (
            <span className={`status-badge status-${block.status}`}>
              {readableStatus(block.status)}
            </span>
          )}
          <Timestamp block={block} />
        </summary>
        <ToolContent block={block} />
      </details>
    );
  if (block.kind === 'thought')
    return (
      <details className="transcript-card thought-card">
        <summary>
          Thinking <Timestamp block={block} />
        </summary>
        <Markdown text={block.text || ''} />
      </details>
    );
  if (block.kind === 'plan')
    return (
      <article className="transcript-card plan-card" aria-label="Agent plan">
        <div className="message-label">
          Plan <Timestamp block={block} />
        </div>
        <TodoList todos={blockTodos(block) || []} />
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
      <div className="message-label">
        {label} <Timestamp block={block} />
      </div>
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
  reportsDirectory,
  online = false,
}: {
  session?: Session;
  active?: boolean;
  composer?: ReactNode;
  feedback?: ReactNode;
  reportsDirectory?: string;
  online?: boolean;
}) {
  const [fullscreen, setFullscreen] = useState(false);
  const [inputVisible, setInputVisible] = useState(true);
  const [promptsVisible, setPromptsVisible] = useState(false);
  const [promptSearch, setPromptSearch] = useState('');
  const promptTargets = useRef(new Map<number, HTMLDivElement>());
  const prompts = (session?.blocks || []).flatMap((block, index) =>
    block.kind === 'user' ? [{ text: block.text || '', index }] : [],
  );
  const [container] = useState(() => document.createElement('div'));
  const inline = useRef<HTMLDivElement>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const element = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  useLayoutEffect(() => {
    setPromptsVisible(false);
    setPromptSearch('');
    follow.current = true;
  }, [session?.id, session?.conversation]);
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
    follow.current = true;
    if (element.current) element.current.scrollTop = element.current.scrollHeight;
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
          {session?.activity && (
            <div className="transcript-toolbar" role="status" aria-label="Current agent action">
              <span className="status-badge status-in_progress">In progress</span>
              <span>{session.activity}</span>
            </div>
          )}
          <div className="transcript-toolbar">
            <button
              aria-expanded={promptsVisible}
              aria-controls="transcript-prompts"
              onClick={() => setPromptsVisible((value) => !value)}
            >
              Prompts ({prompts.length})
            </button>
          </div>
          {promptsVisible && (
            <nav id="transcript-prompts" className="transcript-prompts" aria-label="Prompt history">
              <input
                aria-label="Search prompts"
                placeholder="Search prompts…"
                value={promptSearch}
                onChange={(event) => setPromptSearch(event.target.value)}
              />
              <ol>
                {prompts.map((prompt, number) =>
                  prompt.text.toLowerCase().includes(promptSearch.toLowerCase()) ? (
                    <li key={prompt.index}>
                      <button
                        onClick={() => {
                          const target = promptTargets.current.get(prompt.index);
                          if (!target || !element.current) return;
                          follow.current = false;
                          setPromptsVisible(false);
                          target.focus({ preventScroll: true });
                          element.current.scrollTop +=
                            target.getBoundingClientRect().top -
                            element.current.getBoundingClientRect().top;
                        }}
                      >
                        {number + 1}. {prompt.text.replace(/\s+/g, ' ').trim() || '(Empty prompt)'}
                      </button>
                    </li>
                  ) : null,
                )}
              </ol>
              {!prompts.length && <p>No prompts yet.</p>}
              {!!prompts.length &&
                !prompts.some((prompt) =>
                  prompt.text.toLowerCase().includes(promptSearch.toLowerCase()),
                ) && <p>No matching prompts.</p>}
            </nav>
          )}
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
              <div
                key={`${block.kind}:${block.id || index}`}
                tabIndex={block.kind === 'user' ? -1 : undefined}
                ref={(node) => {
                  if (node && block.kind === 'user') promptTargets.current.set(index, node);
                  else promptTargets.current.delete(index);
                }}
              >
                <Block block={block} />
                {session &&
                  reportsDirectory &&
                  attachedReports(block, reportsDirectory).map((name) => (
                    <ReportPreview
                      key={name}
                      worktree={session.worktree}
                      name={name}
                      online={online}
                    />
                  ))}
              </div>
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
