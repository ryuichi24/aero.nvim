import { memo } from 'react';
import ReactMarkdown, { defaultUrlTransform } from 'react-markdown';
import rehypeHighlight from 'rehype-highlight';
import remarkGfm from 'remark-gfm';
import 'highlight.js/styles/github-dark.css';
import { ImageLink, useImageLink, useVideoLink } from './image-link';

export const Markdown = memo(function Markdown({ text }: { text: string }) {
  const imageLink = useImageLink();
  const videoLink = useVideoLink();
  return (
    <div className="markdown-body">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[[rehypeHighlight, { detect: false }]]}
        skipHtml
        urlTransform={(url) =>
          url.startsWith('file://')
            ? imageLink(url) || videoLink(url)
              ? url
              : ''
            : defaultUrlTransform(url)
        }
        components={{
          a: ({ href, children, title }) =>
            imageLink(href) ? (
              <ImageLink href={imageLink(href)!} title={title}>
                {children}
              </ImageLink>
            ) : videoLink(href) ? (
              <ImageLink href={videoLink(href)!} title={title} media="video">
                {children}
              </ImageLink>
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
          // Describe images without fetching external content while browsing.
          img: ({ alt, src }) =>
            imageLink(src) ? (
              <ImageLink href={imageLink(src)!}>[Image: {alt || 'attachment'}]</ImageLink>
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
    </div>
  );
});
