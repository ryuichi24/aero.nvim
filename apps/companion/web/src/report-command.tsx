import { useQuery } from '@tanstack/react-query';
import { Button } from './components/ui/button';
import { Input } from './components/ui/input';
import { Label } from './components/ui/label';
import { useState } from 'react';
import { post } from './api';

export function ReportCommand({
  worktree,
  online,
  onChoose,
}: {
  worktree: string;
  online: boolean;
  onChoose: (command: string) => void;
}) {
  const [name, setName] = useState('');
  const query = useQuery({
    queryKey: ['reports', worktree, ''],
    queryFn: () =>
      post<{ entries: { name: string; directory: boolean }[] }>('reports', { worktree, path: '' }),
    enabled: online,
  });
  return (
    <section aria-label="Report command">
      <p>Select a report or create one, then send the prompt to give the agent its context.</p>
      {query.isFetching && <p role="status">Loading reports…</p>}
      {query.error && (
        <p role="alert">
          {query.error.message}{' '}
          <Button
            variant="outline"
            type="button"
            disabled={!online}
            onClick={() => void query.refetch()}
          >
            Retry
          </Button>
        </p>
      )}
      {query.data?.entries
        .filter((entry) => !entry.directory)
        .map((entry) => (
          <Button
            variant="outline"
            key={entry.name}
            type="button"
            disabled={!online}
            onClick={() => onChoose(`/report select ${entry.name}`)}
          >
            {entry.name}
          </Button>
        ))}
      {query.data?.entries.length === 0 && <p>No reports created yet.</p>}
      <Label>
        New report name
        <Input value={name} onChange={(event) => setName(event.target.value)} />
      </Label>
      <Button
        type="button"
        disabled={!online || !name.trim() || /[/\\\r\n]/.test(name)}
        onClick={() => onChoose(`/report new ${name.trim()}`)}
      >
        Use new report
      </Button>
    </section>
  );
}
