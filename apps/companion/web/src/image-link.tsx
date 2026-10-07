import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { FullscreenAttention } from './fullscreen-attention';

export const ImageSession = createContext('');

export function ImageLink({
  href,
  children,
  title,
  media = 'image',
}: {
  href: string;
  children: ReactNode;
  title?: string;
  media?: 'image' | 'video';
}) {
  const [open, setOpen] = useState(false);
  const [failed, setFailed] = useState(false);
  const trigger = useRef<HTMLAnchorElement>(null);
  const close = useRef<HTMLButtonElement>(null);
  const dialog = useRef<HTMLElement>(null);
  const label = media === 'video' ? 'Recording' : 'Screenshot';
  useEffect(() => {
    if (!open) return;
    close.current?.focus();
    const overflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = overflow;
      trigger.current?.focus();
    };
  }, [open]);
  return (
    <>
      <a
        ref={trigger}
        href={href}
        title={title}
        onClick={(event) => {
          event.preventDefault();
          setFailed(false);
          setOpen(true);
        }}
      >
        {children}
      </a>
      {open &&
        createPortal(
          <div
            className="image-preview-backdrop"
            onClick={(event) => {
              if (event.target === event.currentTarget) setOpen(false);
            }}
          >
            <section
              className="image-preview"
              ref={dialog}
              role="dialog"
              aria-modal="true"
              aria-label={`${label} preview`}
              onKeyDown={(event) => {
                if (event.key === 'Escape') setOpen(false);
                if (event.key === 'Tab') {
                  const targets = dialog.current?.querySelectorAll<HTMLElement>('button, video');
                  const first = targets?.[0];
                  const last = targets?.[targets.length - 1];
                  if (event.shiftKey && document.activeElement === first) {
                    event.preventDefault();
                    last?.focus();
                  } else if (!event.shiftKey && document.activeElement === last) {
                    event.preventDefault();
                    first?.focus();
                  }
                }
              }}
            >
              <header>
                <h2>{label} preview</h2>
                <FullscreenAttention />
                <button ref={close} type="button" onClick={() => setOpen(false)}>
                  Close
                </button>
              </header>
              <div className="image-preview-content">
                {failed ? (
                  <p role="alert">
                    Unable to load this{' '}
                    {media === 'video'
                      ? 'recording. The file may be unavailable or its video codec unsupported by this browser.'
                      : 'screenshot. The file may no longer be available.'}
                  </p>
                ) : media === 'video' ? (
                  <video
                    src={href}
                    controls
                    playsInline
                    preload="metadata"
                    tabIndex={0}
                    aria-label="Session recording"
                    onError={() => setFailed(true)}
                  />
                ) : (
                  <img src={href} alt="Screenshot" onError={() => setFailed(true)} />
                )}
              </div>
            </section>
          </div>,
          document.body,
        )}
    </>
  );
}

export function useImageLink() {
  const session = useContext(ImageSession);
  return (href?: string) => imageURL(session, href);
}

export function useVideoLink() {
  const session = useContext(ImageSession);
  return (href?: string) => videoURL(session, href);
}

export function imageURL(session: string, href?: string) {
  return mediaURL(session, href, 'image');
}

export function videoURL(session: string, href?: string) {
  return mediaURL(session, href, 'video');
}

function mediaURL(session: string, href: string | undefined, type: 'image' | 'video') {
  if (
    !href ||
    !session ||
    !(type === 'image' ? /\.(png|jpe?g|webp|gif)$/i : /\.(webm|mp4)$/i).test(href)
  )
    return undefined;
  if (href.startsWith('//')) return undefined;
  if (/^[a-z][a-z\d+.-]*:/i.test(href) && !href.startsWith('file://')) return undefined;
  if (href.startsWith('file://')) {
    try {
      const url = new URL(href);
      if (url.hostname && url.hostname !== 'localhost') return undefined;
    } catch {
      return undefined;
    }
  }
  return `/api/${type}?${new URLSearchParams({ session, path: href })}`;
}
