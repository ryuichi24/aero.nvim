import { memo, useContext, useState } from 'react';
import ReactMarkdown, { defaultUrlTransform } from 'react-markdown';
import rehypeHighlight from 'rehype-highlight';
import remarkGfm from 'remark-gfm';
import 'highlight.js/styles/github-dark.css';
import { ImageLink, InlineImage, useImageLink, useVideoLink } from './image-link';
import { Mermaid } from './mermaid';
import { MarkdownMermaidPreview } from './markdown-mermaid-preview';
import { FileContext, FilePreview, fileReference, remarkFileReferences } from './file-preview';

interface CodeNode {
  value?: string;
  children?: CodeNode[];
}

function codeText(node: CodeNode): string {
  return node.value || node.children?.map(codeText).join('') || '';
}

export const Markdown = memo(function Markdown({ text }: { text: string }) {
  const imageLink = useImageLink();
  const videoLink = useVideoLink();
  const { worktree } = useContext(FileContext);
  const [reference, setReference] = useState<ReturnType<typeof fileReference>>();
  return (
    <div className="markdown-body">
      <ReactMarkdown
        remarkPlugins={worktree ? [remarkGfm, remarkFileReferences] : [remarkGfm]}
        rehypePlugins={[[rehypeHighlight, { detect: false }]]}
        skipHtml
        urlTransform={(url) =>
          fileReference(url, worktree)
            ? url
            : url.startsWith('file://')
              ? imageLink(url) || videoLink(url)
                ? url
                : ''
              : defaultUrlTransform(url)
        }
        components={{
          pre: ({ node, children }) => {
            const code = node?.children[0];
            if (
              code?.type === 'element' &&
              code.tagName === 'code' &&
              Array.isArray(code.properties.className)
            ) {
              const source = codeText(code);
              if (code.properties.className.includes('language-mermaid')) {
                return <Mermaid source={source} />;
              }
              if (
                code.properties.className.some(
                  (name) => name === 'language-markdown' || name === 'language-md',
                )
              ) {
                return (
                  <MarkdownMermaidPreview key={source} source={source}>
                    {children}
                  </MarkdownMermaidPreview>
                );
              }
            }
            return <pre>{children}</pre>;
          },
          a: ({ href, children, title }) =>
            imageLink(href) ? (
              <ImageLink href={imageLink(href)!} title={title}>
                {children}
              </ImageLink>
            ) : videoLink(href) ? (
              <ImageLink href={videoLink(href)!} title={title} media="video">
                {children}
              </ImageLink>
            ) : href && fileReference(href, worktree) ? (
              <a
                href={href}
                title="Preview source code"
                onClick={(event) => {
                  event.preventDefault();
                  setReference(fileReference(href, worktree));
                }}
              >
                {children}
              </a>
            ) : href ? (
              <a
                href={imageLink(href) || href}
                title={title}
                target="_blank"
                rel="noopener noreferrer"
              >
                {children}
              </a>
            ) : (
              <span>{children}</span>
            ),
          img: ({ alt, src, title }) =>
            imageLink(src) ? (
              <InlineImage key={imageLink(src)} href={imageLink(src)!} alt={alt} title={title} />
            ) : (
              <span className="markdown-image">[Image: {alt || 'attachment'}]</span>
            ),
          table: ({ children }) => (
            <div className="markdown-table-scroll">
              <table>{children}</table>
            </div>
          ),
        }}
      >
        {text}
      </ReactMarkdown>
      {reference && (
        <FilePreview
          key={`${reference.path}:${reference.line}`}
          reference={reference}
          onClose={() => setReference(undefined)}
        />
      )}
    </div>
  );
});
