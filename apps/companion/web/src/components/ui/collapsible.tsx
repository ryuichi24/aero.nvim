import * as CollapsiblePrimitive from '@radix-ui/react-collapsible';
import {
  Children,
  createContext,
  useContext,
  useEffect,
  useState,
  type ComponentProps,
} from 'react';
import { cn } from '../../lib/utils';

const DisclosureContext = createContext({ open: false, toggle: () => {} });

// Native hosts preserve browser find-in-page and the existing imperative closing
// API. Radix supplies the shared trigger/content state and accessibility wiring.
export function Collapsible({
  open = false,
  children,
  className,
  onToggle,
  ...props
}: ComponentProps<'details'>) {
  const [expanded, setExpanded] = useState(open);
  useEffect(() => setExpanded(open), [open]);
  const [trigger, ...content] = Children.toArray(children);
  return (
    <DisclosureContext.Provider
      value={{ open: expanded, toggle: () => setExpanded((value) => !value) }}
    >
      <CollapsiblePrimitive.Root open={expanded} onOpenChange={setExpanded} asChild>
        <details
          {...props}
          data-slot="collapsible"
          open={expanded}
          className={cn(
            'my-3 min-w-0 rounded-lg border border-border bg-card p-3 text-card-foreground',
            className,
          )}
          onToggle={(event) => {
            if (event.target === event.currentTarget) setExpanded(event.currentTarget.open);
            onToggle?.(event);
          }}
        >
          {trigger}
          <CollapsiblePrimitive.Content forceMount className="min-w-0">
            {content}
          </CollapsiblePrimitive.Content>
        </details>
      </CollapsiblePrimitive.Root>
    </DisclosureContext.Provider>
  );
}

export function CollapsibleTrigger({ className, onClick, ...props }: ComponentProps<'summary'>) {
  const disclosure = useContext(DisclosureContext);
  return (
    <CollapsiblePrimitive.Trigger asChild>
      <summary
        {...props}
        data-slot="collapsible-trigger"
        className={cn(
          'min-h-11 cursor-pointer rounded-md py-2 text-sm font-medium outline-none hover:text-primary focus-visible:ring-2 focus-visible:ring-ring',
          className,
        )}
        onClick={(event) => {
          onClick?.(event);
          if (!event.defaultPrevented) {
            event.preventDefault();
            disclosure.toggle();
          }
        }}
      />
    </CollapsiblePrimitive.Trigger>
  );
}
