import type { ComponentProps } from 'react';
import { ChevronDownIcon } from 'lucide-react';
import { cn } from '../../lib/utils';

export function NativeSelect({
  className,
  wrapperClassName,
  children,
  ...props
}: ComponentProps<'select'> & { wrapperClassName?: string }) {
  return (
    <div
      data-slot="native-select-wrapper"
      className={cn('relative mt-2 w-full min-w-0', wrapperClassName)}
    >
      <select
        data-slot="native-select"
        className={cn(
          'min-h-11 w-full appearance-none rounded-md border border-input bg-background py-2 pr-9 pl-3 text-base text-foreground shadow-sm outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 [&::picker-icon]:hidden',
          className,
        )}
        {...props}
      >
        {children}
      </select>
      <ChevronDownIcon
        aria-hidden="true"
        className="pointer-events-none absolute top-1/2 right-3 size-4 -translate-y-1/2 text-muted-foreground"
      />
    </div>
  );
}
