import { FolderIcon, HouseIcon, InboxIcon, MessageSquareIcon } from 'lucide-react';

export function NavigationIcon({ name }: { name: 'home' | 'sessions' | 'inbox' | 'workspace' }) {
  const icons = {
    home: HouseIcon,
    sessions: MessageSquareIcon,
    inbox: InboxIcon,
    workspace: FolderIcon,
  };
  const Icon = icons[name];
  return <Icon className="size-5" strokeWidth={1.7} aria-hidden="true" />;
}
