import { useLayoutEffect, useRef } from 'react';
import type { RefObject } from 'react';

export function useComposerViewport({
  active,
  fullscreen,
  inline,
  dialog,
  container,
}: {
  active: boolean;
  fullscreen: boolean;
  inline: RefObject<HTMLDivElement | null>;
  dialog: RefObject<HTMLDialogElement | null>;
  container: HTMLElement;
}) {
  const baseline = useRef({ height: window.innerHeight, width: window.innerWidth });
  const keyboard = useRef(false);
  const beforeFocus = useRef<{ x: number; y: number } | null>(null);

  useLayoutEffect(() => {
    if (!active) {
      keyboard.current = false;
      beforeFocus.current = null;
      return;
    }
    if (!inline.current) return;
    const host = inline.current;
    const modal = dialog.current;
    const viewport = window.visualViewport;

    function isComposerField(node: EventTarget | null): node is HTMLElement {
      return (
        node instanceof HTMLElement &&
        container.contains(node) &&
        (node.tagName === 'TEXTAREA' || node.tagName === 'INPUT')
      );
    }
    function captureFocus(event: Event) {
      if (!isComposerField(event.target) || keyboard.current) return;
      baseline.current = {
        height: Math.max(baseline.current.height, window.innerHeight, viewport?.height || 0),
        width: window.innerWidth,
      };
      if (event.type === 'pointerdown' || !beforeFocus.current)
        beforeFocus.current = { x: window.scrollX, y: window.scrollY };
      resize();
    }
    function resize() {
      const height = viewport?.height || window.innerHeight;
      const offset = viewport?.offsetTop || 0;
      const focused = isComposerField(document.activeElement);
      if ((!focused && !keyboard.current) || baseline.current.width !== window.innerWidth) {
        baseline.current = {
          height: Math.max(window.innerHeight, height),
          width: window.innerWidth,
        };
      }
      const wasOpen = keyboard.current;
      keyboard.current =
        window.innerWidth < 1100 && (focused || wasOpen) && height < baseline.current.height * 0.8;
      document.documentElement.dataset.composerKeyboard = keyboard.current ? 'open' : 'closed';
      host.dataset.keyboard = keyboard.current && !fullscreen ? 'open' : 'closed';

      if (keyboard.current && !fullscreen) {
        // Fixed to the *visual* viewport, including Safari's keyboard-induced pan.
        // No document scroll or minimum height can push this dock below the keyboard.
        host.style.setProperty('--transcript-keyboard-top', `${offset}px`);
        host.style.setProperty('--transcript-height', `${height}px`);
      } else {
        if (wasOpen && !keyboard.current && beforeFocus.current) {
          const position = beforeFocus.current;
          beforeFocus.current = null;
          if (window.scrollX !== position.x || window.scrollY !== position.y)
            window.scrollTo({ left: position.x, top: position.y });
        }
        if (!fullscreen) {
          const nav = document.querySelector<HTMLElement>('.primary-nav')?.getBoundingClientRect();
          const bottom =
            window.innerWidth < 1100 && nav?.height
              ? Math.min(height + offset, nav.top)
              : height + offset;
          const top = Math.max(host.getBoundingClientRect().top, offset);
          host.style.setProperty('--transcript-height', `${Math.max(180, bottom - top - 12)}px`);
        }
      }
      if (fullscreen && dialog.current) {
        dialog.current.style.height = `${height}px`;
        dialog.current.style.top = `${offset}px`;
        dialog.current.style.bottom = 'auto';
      }
      const composer = container.querySelector<HTMLElement>('.log-composer');
      if (keyboard.current && focused && composer) {
        const field = document.activeElement as HTMLElement;
        const fieldRect = field.getBoundingClientRect();
        const panel = composer.getBoundingClientRect();
        if (fieldRect.top < panel.top) composer.scrollTop += fieldRect.top - panel.top;
        else if (fieldRect.bottom > panel.bottom)
          composer.scrollTop += fieldRect.bottom - panel.bottom;
      }
      document.documentElement.style.setProperty(
        '--companion-composer-height',
        `${composer?.getBoundingClientRect().height || 0}px`,
      );
    }
    resize();
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(resize);
    observer?.observe(document.querySelector('main') || host);
    const composer = container.querySelector('.log-composer');
    if (composer) observer?.observe(composer);
    document.addEventListener('pointerdown', captureFocus, true);
    document.addEventListener('focusin', captureFocus);
    window.addEventListener('resize', resize);
    window.addEventListener('scroll', resize, { passive: true });
    viewport?.addEventListener('resize', resize);
    viewport?.addEventListener('scroll', resize);
    return () => {
      observer?.disconnect();
      document.removeEventListener('pointerdown', captureFocus, true);
      document.removeEventListener('focusin', captureFocus);
      window.removeEventListener('resize', resize);
      window.removeEventListener('scroll', resize);
      viewport?.removeEventListener('resize', resize);
      viewport?.removeEventListener('scroll', resize);
      document.documentElement.style.removeProperty('--companion-composer-height');
      delete document.documentElement.dataset.composerKeyboard;
      delete host.dataset.keyboard;
      host.style.removeProperty('--transcript-keyboard-top');
      modal?.style.removeProperty('height');
      modal?.style.removeProperty('top');
      modal?.style.removeProperty('bottom');
    };
  }, [active, fullscreen, inline, dialog, container]);
}
