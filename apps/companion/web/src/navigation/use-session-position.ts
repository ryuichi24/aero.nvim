import { useLayoutEffect, useRef, type RefObject } from 'react';
import type { Selection } from '../types';
import type { View } from '../companion-state';

export function useSessionPosition(
  view: View,
  selected: Selection | null,
  tab: string,
  title: RefObject<HTMLHeadingElement | null>,
) {
  const positions = useRef(new Map<string, { top: number; left: number }>());
  useLayoutEffect(() => {
    if (view !== 'conversation') return;
    const key = JSON.stringify([selected?.id, selected?.conversation, tab]);
    const position = positions.current.get(key) || { top: 0, left: 0 };
    title.current?.focus({ preventScroll: true });
    if (window.scrollY !== position.top || window.scrollX !== position.left)
      window.scrollTo({ ...position, behavior: 'instant' });
    const remember = () => {
      positions.current.set(key, { top: window.scrollY, left: window.scrollX });
    };
    window.addEventListener('scroll', remember, { passive: true });
    return () => window.removeEventListener('scroll', remember);
  }, [view, selected?.id, selected?.conversation, tab, title]);
}
