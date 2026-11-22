import * as DialogPrimitive from '@radix-ui/react-dialog';
import type { ComponentProps } from 'react';
import { cn } from '../../lib/utils';

// Keep a native dialog host for the transcript/composer's persistent DOM portals.
// Radix owns modality, focus trapping, outside dismissal and Escape handling.
export function Dialog({
  open,
  onOpenChange,
  onInitialFocus,
  onRestoreFocus,
  children,
  className,
  ...props
}: Omit<ComponentProps<'dialog'>, 'open'> & {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onInitialFocus?: () => void;
  onRestoreFocus?: () => void;
}) {
  const content = (
    <dialog
      {...props}
      open={open}
      hidden={!open}
      data-slot="dialog-content"
      className={cn(
        'fixed top-1/2 left-1/2 z-50 m-0 max-h-[90dvh] w-[calc(100%-2rem)] max-w-lg -translate-x-1/2 -translate-y-1/2 overflow-auto rounded-xl border border-border bg-background p-6 text-foreground shadow-lg outline-none',
        className?.includes('fullscreen') &&
          'inset-0 h-dvh max-h-none w-screen max-w-none translate-x-0 translate-y-0 rounded-none',
        className,
      )}
    >
      {open && (
        <DialogPrimitive.Title className="sr-only">
          {props['aria-label'] || 'Dialog'}
        </DialogPrimitive.Title>
      )}
      {children}
    </dialog>
  );
  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      {open ? (
        <DialogPrimitive.Portal container={document.body}>
          <DialogPrimitive.Overlay
            data-slot="dialog-overlay"
            className="fixed inset-0 z-50 bg-black/70"
          />
          <DialogPrimitive.Content
            asChild
            aria-describedby={undefined}
            onOpenAutoFocus={(event) => {
              if (onInitialFocus) {
                event.preventDefault();
                onInitialFocus();
              }
            }}
            onCloseAutoFocus={(event) => {
              event.preventDefault();
              onRestoreFocus?.();
            }}
          >
            {content}
          </DialogPrimitive.Content>
        </DialogPrimitive.Portal>
      ) : (
        content
      )}
    </DialogPrimitive.Root>
  );
}
