import { useMemo } from 'react';
import remarkParse from 'remark-parse';
import { unified } from 'unified';
import { ImageLink, imageURL, videoURL } from './image-link';
import type { Session } from './types';

interface MarkdownNode {
  type: string;
  url?: string;
  alt?: string | null;
  value?: string;
  identifier?: string;
  children?: MarkdownNode[];
}

interface Screenshot {
  path: string;
  label: string;
  href: string;
}

const parser = unified().use(remarkParse);

function walk(node: MarkdownNode, visit: (node: MarkdownNode) => void) {
  visit(node);
  node.children?.forEach((child) => walk(child, visit));
}

function nodeText(node: MarkdownNode): string {
  return node.value || node.children?.map(nodeText).join('') || '';
}

export function sessionScreenshots(session: Session): Screenshot[] {
  return sessionMedia(session, 'image');
}

export function sessionRecordings(session: Session): Screenshot[] {
  return sessionMedia(session, 'video');
}

function sessionMedia(session: Session, type: 'image' | 'video'): Screenshot[] {
  const images = new Map<string, Screenshot>();
  function add(path: string, label?: string) {
    const href = type === 'video' ? videoURL(session.id, path) : imageURL(session.id, path);
    if (!href) return;
    // Treat file URIs, absolute paths and worktree-relative links to the same
    // screenshot as one entry, even when the agent mentions it repeatedly.
    let key: string;
    try {
      key = new URL(path, `file://${session.worktree.replace(/\/$/, '')}/`).href;
    } catch {
      key = path;
    }
    if (!images.has(key))
      images.set(key, {
        path,
        label: label || path.split('/').pop() || (type === 'video' ? 'Recording' : 'Screenshot'),
        href,
      });
  }
  function markdown(text: string) {
    const tree = parser.parse(text);
    const definitions = new Map<string, string>();
    walk(tree, (node) => {
      if (node.type === 'definition' && node.identifier && node.url)
        definitions.set(node.identifier, node.url);
    });
    walk(tree, (node) => {
      if ((node.type === 'link' || node.type === 'image') && node.url)
        add(node.url, node.alt || nodeText(node));
      if ((node.type === 'linkReference' || node.type === 'imageReference') && node.identifier) {
        const path = definitions.get(node.identifier);
        if (path) add(path, node.alt || nodeText(node));
      }
    });
  }
  function output(value: unknown, field?: string) {
    if (typeof value === 'string') {
      if (field === 'path' || field === 'uri' || field === 'filename' || !/\s/.test(value))
        add(value);
      markdown(value);
    } else if (Array.isArray(value)) value.forEach((item) => output(item));
    else if (value && typeof value === 'object')
      Object.entries(value).forEach(([key, item]) => output(item, key));
  }
  for (const block of session.blocks || []) {
    // File reads, searches and edits often contain image links from fixtures or
    // source code. They are not evidence that the agent took a screenshot.
    const sourceTool =
      block.kind === 'tool' &&
      !/browser[_ .]take[_ ]screenshot/i.test(block.title || '') &&
      (/^(read|edit|search|delete|move)$/.test(block.tool_kind || '') ||
        /^(read|edit|write|search|grep|glob|apply[_ ]patch|functions\.(read|grep|glob|apply_patch))\b/i.test(
          block.title || '',
        ));
    const collectText = !sourceTool && (block.kind === 'agent' || block.kind === 'tool');
    if (collectText && block.text) markdown(block.text);
    for (const content of block.content || []) {
      if (content.type === 'diff') continue;
      const text = content.content?.text ?? content.text;
      if (collectText && text) markdown(text);
      if (content.content?.uri) add(content.content.uri, content.content.name);
    }
    if (collectText) output(block.rawOutput);
  }
  return [...images.values()].reverse();
}

export function Screenshots({ session }: { session: Session }) {
  const screenshots = useMemo(() => sessionScreenshots(session), [session]);
  if (!screenshots.length) return null;
  return (
    <details className="session-screenshots">
      <summary>Screenshots ({screenshots.length})</summary>
      <ul className="screenshot-list" aria-label="Session screenshots">
        {screenshots.map((screenshot) => (
          <li key={screenshot.href}>
            <ImageLink href={screenshot.href} title={screenshot.path}>
              <strong>{screenshot.label}</strong>
              <span>{screenshot.path}</span>
            </ImageLink>
          </li>
        ))}
      </ul>
    </details>
  );
}
