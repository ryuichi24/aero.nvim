import type { ComponentProps } from 'react';
import { Badge } from './badge';
import { cn } from '../../lib/utils';

const colors: Record<string, string> = {
  waiting: 'text-amber-300',
  busy: 'text-amber-300',
  starting: 'text-amber-300',
  pending: 'text-amber-300',
  in_progress: 'text-amber-300',
  idle: 'text-green-300',
  completed: 'text-green-300',
  failed: 'text-red-300',
  stopped: 'text-muted-foreground',
  exited: 'text-muted-foreground',
};
export function StatusBadge({
  status,
  className,
  children,
  ...props
}: ComponentProps<typeof Badge> & { status: string }) {
  return (
    <Badge className={cn(colors[status], className)} {...props}>
      {children ?? status.replaceAll('_', ' ')}
    </Badge>
  );
}
