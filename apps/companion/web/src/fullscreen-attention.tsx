import { createContext, useContext, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

export const FullscreenAttentionContext = createContext<ReactNode>(null);

export function FullscreenAttention() {
  return useContext(FullscreenAttentionContext);
}

export function AttentionSurface({
  host,
  children,
}: {
  host: HTMLElement | null;
  children: ReactNode;
}) {
  return host ? createPortal(children, host) : children;
}
