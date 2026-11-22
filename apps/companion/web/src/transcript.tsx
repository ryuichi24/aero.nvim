import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Button } from './components/ui/button';
import { Input } from './components/ui/input';
import { Dialog } from './components/ui/dialog';
import { Collapsible, CollapsibleTrigger } from './components/ui/collapsible';
import { StatusBadge } from './components/ui/status-badge';
import { createPortal } from 'react-dom';
import { Markdown } from './markdown';
import { QuoteSelection } from './quote';
import { attachedReports, ReportPreview } from './report-preview';
import { FullscreenAttention } from './fullscreen-attention';
import type { Session, TranscriptBlock } from './types';
import { ImageLink, ImageSession, useImageLink, useVideoLink } from './image-link';
import { blockTodos, TodoList } from './agent-todos';
import { useComposerViewport } from './composer-viewport';

function readableStatus(status: string): string {
  return status.replaceAll('_', ' ');
}

const toolNames: Record<string, string> = {
  read: 'Read',
  edit: 'Edit',
  delete: 'Delete',
  search: 'Search',
  execute: 'Command',
  fetch: 'Fetch',
  think: 'Thinking',
};
const toolIcons: Record<string, string> = {
  pending: '…',
  in_progress: '◐',
  completed: '✓',
  failed: '✗',
};
function activeTool(block: TranscriptBlock) {
  return block.status === 'pending' || block.status === 'in_progress';
}
function transcriptEntries(blocks: TranscriptBlock[]) {
  const entries: { index: number; blocks: TranscriptBlock[] }[] = [];
  for (const [index, block] of blocks.entries()) {
    const previous = entries.at(-1);
    if (block.kind === 'tool' && previous?.blocks[0].kind === 'tool') {
      previous.blocks.push(block);
    } else entries.push({ index, blocks: [block] });
  }
  return entries;
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
const Block = memo(function Block({ block }: { block: TranscriptBlock }) {
  const reveal = activeTool(block) || block.status === 'failed';
  const [expanded, setExpanded] = useState(reveal);
  useEffect(() => setExpanded(reveal), [reveal]);
  if (block.kind === 'tool')
    return (
      <Collapsible
        className="transcript-card tool-card"
        open={expanded}
        onToggle={(event) => {
          if (event.target === event.currentTarget) setExpanded(event.currentTarget.open);
        }}
      >
        <CollapsibleTrigger>
          <span className="message-label">
            <span aria-hidden="true">{toolIcons[block.status || 'pending'] || '•'} </span>
            {toolNames[block.tool_kind || ''] || 'Tool call'}
          </span>
          <span className="tool-title">{block.title || block.tool_kind || 'Tool call'}</span>
          {block.status && (
            <StatusBadge status={block.status}>{readableStatus(block.status)}</StatusBadge>
          )}
          <Timestamp block={block} />
        </CollapsibleTrigger>
        {expanded && <ToolContent block={block} />}
      </Collapsible>
    );
  if (block.kind === 'thought')
    return (
      <Collapsible
        className="transcript-card thought-card"
        open={expanded}
        onToggle={(event) => {
          if (event.target === event.currentTarget) setExpanded(event.currentTarget.open);
        }}
      >
        <CollapsibleTrigger>
          Thinking <Timestamp block={block} />
        </CollapsibleTrigger>
        {expanded && <Markdown text={block.text || ''} />}
      </Collapsible>
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
});

const BlockContent = memo(function BlockContent({
  block,
  worktree,
  reportsDirectory,
  online,
}: {
  block: TranscriptBlock;
  worktree?: string;
  reportsDirectory?: string;
  online: boolean;
}) {
  return (
    <>
      <Block block={block} />
      {worktree &&
        reportsDirectory &&
        attachedReports(block, reportsDirectory).map((name) => (
          <ReportPreview
            key={name}
            worktree={worktree}
            name={name}
            online={online}
            directory={reportsDirectory}
          />
        ))}
    </>
  );
});

const ToolGroup = memo(function ToolGroup({
  blocks,
  worktree,
  reportsDirectory,
  online,
}: {
  blocks: TranscriptBlock[];
  worktree?: string;
  reportsDirectory?: string;
  online: boolean;
}) {
  const running = blocks.filter(activeTool).length;
  const failed = blocks.filter((block) => block.status === 'failed').length;
  const reveal = running > 0 || failed > 0;
  const [expanded, setExpanded] = useState(reveal);
  useEffect(() => setExpanded(reveal), [reveal]);
  const counts = new Map<string, number>();
  for (const block of blocks) {
    const kind = toolNames[block.tool_kind || ''] || 'Tool';
    counts.set(kind, (counts.get(kind) || 0) + 1);
  }
  return (
    <Collapsible
      className="transcript-card tool-group"
      open={expanded}
      onToggle={(event) => {
        if (event.target === event.currentTarget) setExpanded(event.currentTarget.open);
      }}
    >
      <CollapsibleTrigger>
        <span className="tool-title">
          Tools · {blocks.length} {blocks.length === 1 ? 'call' : 'calls'}
        </span>
        <span className="tool-group-counts">
          {' · '}
          {[...counts].map(([kind, count]) => `${count} ${kind}`).join(', ')}
        </span>
        {running > 0 && <StatusBadge status="in_progress">{running} running</StatusBadge>}
        {failed > 0 && <StatusBadge status="failed">{failed} failed</StatusBadge>}
      </CollapsibleTrigger>
      <div className="tool-group-calls">
        {blocks.map((block, index) => (
          <BlockContent
            key={block.id || index}
            block={block}
            worktree={worktree}
            reportsDirectory={reportsDirectory}
            online={online}
          />
        ))}
      </div>
    </Collapsible>
  );
});

export const Transcript = memo(
  function Transcript({
    session,
    active = true,
    composer,
    feedback,
    reportsDirectory,
    online = false,
    onQuote,
  }: {
    session?: Session;
    active?: boolean;
    composer?: ReactNode;
    feedback?: ReactNode;
    reportsDirectory?: string;
    online?: boolean;
    onQuote?: (quote: import('./quote').Quote) => void;
  }) {
    const [fullscreen, setFullscreen] = useState(false);
    const [inputVisible, setInputVisible] = useState(true);
    const [promptsVisible, setPromptsVisible] = useState(false);
    const [promptSearch, setPromptSearch] = useState('');
    const promptTargets = useRef(new Map<number, HTMLDivElement>());
    const prompts = useMemo(
      () =>
        (session?.blocks || []).flatMap((block, index) =>
          block.kind === 'user' ? [{ text: block.text || '', index }] : [],
        ),
      [session?.blocks],
    );
    const entries = useMemo(() => transcriptEntries(session?.blocks || []), [session?.blocks]);
    const [container] = useState(() => {
      const node = document.createElement('div');
      node.className = 'transcript-content';
      return node;
    });
    const inline = useRef<HTMLDivElement>(null);
    const dialog = useRef<HTMLDialogElement>(null);
    const button = useRef<HTMLButtonElement>(null);
    const element = useRef<HTMLDivElement>(null);
    const follow = useRef(true);
    const wasFullscreen = useRef(false);
    useComposerViewport({ active, fullscreen, inline, dialog, container });
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
      if (!fullscreen) {
        if (wasFullscreen.current) {
          setInputVisible(true);
          button.current?.focus();
        }
        wasFullscreen.current = false;
        return;
      }
      wasFullscreen.current = true;
      follow.current = true;
      if (element.current) element.current.scrollTop = element.current.scrollHeight;
    }, [container, fullscreen]);
    useLayoutEffect(() => {
      if (!active) setFullscreen(false);
    }, [active]);
    useLayoutEffect(() => {
      if (active && element.current && follow.current)
        element.current.scrollTop = element.current.scrollHeight;
    }, [active, session?.blocks, session?.queue]);
    return (
      <FileContext.Provider value={{ worktree: session?.worktree || '', online }}>
        <ImageSession.Provider value={session?.id || ''}>
          <div ref={inline} className="transcript-inline" />
          <Dialog
            open={fullscreen}
            onOpenChange={setFullscreen}
            onRestoreFocus={() => button.current?.focus()}
            ref={dialog}
            className="transcript-fullscreen"
            aria-label="Fullscreen agent logs"
            onCancel={() => setFullscreen(false)}
            onClose={() => setFullscreen(false)}
          >
            <header className="transcript-toolbar">
              <strong>{session?.name || 'Agent'} · Logs</strong>
              {fullscreen && <FullscreenAttention />}
              <Button variant="outline" onClick={() => setFullscreen(false)}>
                Exit fullscreen
              </Button>
            </header>
          </Dialog>
          {createPortal(
            <>
              <div className="transcript-controls">
                <strong className="sr-only">Agent logs</strong>
                <Button
                  variant="outline"
                  aria-controls="transcript"
                  onClick={() => {
                    follow.current = true;
                    setPromptsVisible(false);
                    if (element.current) element.current.scrollTop = element.current.scrollHeight;
                  }}
                >
                  Scroll to end
                </Button>
                <Button
                  variant="outline"
                  aria-expanded={promptsVisible}
                  aria-controls="transcript-prompts"
                  onClick={() => setPromptsVisible((value) => !value)}
                >
                  Prompts ({prompts.length})
                </Button>
                <Button
                  variant="outline"
                  hidden={fullscreen}
                  ref={button}
                  aria-label="Fullscreen logs"
                  onClick={() => setFullscreen(true)}
                >
                  Fullscreen
                </Button>
                {composer && (
                  <Button
                    variant="outline"
                    aria-expanded={inputVisible}
                    aria-controls="log-composer"
                    onClick={() => setInputVisible((value) => !value)}
                  >
                    {inputVisible ? 'Hide input' : 'Show input'}
                  </Button>
                )}
              </div>
              {session?.activity && (
                <div
                  className="transcript-activity"
                  role="status"
                  aria-label="Current agent action"
                >
                  <StatusBadge status="in_progress">Working</StatusBadge>
                  <span>{session.activity}</span>
                </div>
              )}
              {promptsVisible && (
                <nav
                  id="transcript-prompts"
                  className="transcript-prompts"
                  aria-label="Prompt history"
                >
                  <Input
                    aria-label="Search prompts"
                    placeholder="Search prompts…"
                    value={promptSearch}
                    onChange={(event) => setPromptSearch(event.target.value)}
                  />
                  <ol>
                    {prompts.map((prompt, number) =>
                      prompt.text.toLowerCase().includes(promptSearch.toLowerCase()) ? (
                        <li key={prompt.index}>
                          <Button
                            variant="ghost"
                            className="whitespace-normal text-left"
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
                            {number + 1}.{' '}
                            {prompt.text.replace(/\s+/g, ' ').trim() || '(Empty prompt)'}
                          </Button>
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
              <QuoteSelection
                source={`agent log: ${session?.name || 'Agent'}`}
                onQuote={
                  onQuote
                    ? (quote) => {
                        setInputVisible(true);
                        onQuote(quote);
                      }
                    : undefined
                }
              >
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
                  {!session?.blocks?.length && (
                    <p className="navigation-empty">
                      No logs yet. Send a prompt to start the conversation.
                    </p>
                  )}
                  {entries.map(({ blocks, index }) => {
                    const block = blocks[0];
                    return (
                      <div
                        key={`${block.kind}:${block.id || index}`}
                        tabIndex={block.kind === 'user' ? -1 : undefined}
                        ref={(node) => {
                          if (node && block.kind === 'user') promptTargets.current.set(index, node);
                          else promptTargets.current.delete(index);
                        }}
                      >
                        {block.kind === 'tool' ? (
                          <ToolGroup
                            blocks={blocks}
                            worktree={session?.worktree}
                            reportsDirectory={reportsDirectory}
                            online={online && active}
                          />
                        ) : (
                          <BlockContent
                            block={block}
                            worktree={session?.worktree}
                            reportsDirectory={reportsDirectory}
                            online={online && active}
                          />
                        )}
                      </div>
                    );
                  })}
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
              </QuoteSelection>
              {composer && (
                <div id="log-composer" className="log-composer" hidden={!inputVisible}>
                  {composer}
                  {fullscreen && feedback}
                </div>
              )}
            </>,
            container,
          )}
        </ImageSession.Provider>
      </FileContext.Provider>
    );
  },
  (previous, next) =>
    previous.active === false &&
    next.active === false &&
    previous.session?.id === next.session?.id &&
    previous.session?.conversation === next.session?.conversation &&
    previous.online === next.online &&
    previous.reportsDirectory === next.reportsDirectory,
);
import { FileContext } from './file-preview';
