export function NavigationIcon({ name }: { name: 'home' | 'sessions' | 'inbox' | 'workspace' }) {
  const paths = {
    home: 'M3 10 12 3l9 7v11h-6v-7H9v7H3Z',
    sessions: 'M4 4h16v12H8l-4 4V4Zm4 4h8M8 12h5',
    inbox: 'M4 4h16l2 12v4H2v-4L4 4Zm-2 12h6l2 3h4l2-3h6',
    workspace: 'M3 7V4h7l3 3h8v13H3V7Z',
  };
  return (
    <svg
      width="22"
      height="22"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[name]} />
    </svg>
  );
}
