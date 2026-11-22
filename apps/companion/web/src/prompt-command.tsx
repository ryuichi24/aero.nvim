import { useQuery } from '@tanstack/react-query';
import { Button } from './components/ui/button';
import { Input } from './components/ui/input';
import { Textarea } from './components/ui/textarea';
import { Label } from './components/ui/label';
import { useState } from 'react';
import { post } from './api';
import type { Session } from './types';

type Snippet = { key: string; name: string; description: string; prompt: string; scope: string };
type Collection = { items: Snippet[]; errors: string[]; context: Record<string, string> };
const variables = /{{\s*([A-Za-z_][A-Za-z0-9_]*)\s*}}/g;

function render(template: string, values: Record<string, string>) {
  return template.replace(variables, (token, name: string) =>
    Object.hasOwn(values, name) ? values[name] : token,
  );
}

export function PromptCommand({
  session,
  epoch,
  online,
  onChoose,
}: {
  session: Session;
  epoch: string | undefined;
  online: boolean;
  onChoose: (text: string) => void;
}) {
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState<Snippet | null>(null);
  const [values, setValues] = useState<Record<string, string>>({});
  const query = useQuery({
    queryKey: ['prompt-snippets', epoch, session.id, session.conversation],
    queryFn: () =>
      post<Collection>('prompt_snippets', {
        epoch,
        session: session.id,
        conversation: session.conversation,
      }),
    enabled: online,
    staleTime: 0,
    refetchOnWindowFocus: false,
  });
  const context = query.data?.context || {};
  const inputs = selected
    ? [...new Set([...selected.prompt.matchAll(variables)].map((match) => match[1]))].filter(
        (name) => !Object.hasOwn(context, name),
      )
    : [];
  const previewValues = { ...context, ...values };
  return (
    <section aria-label="Prompt snippets">
      <p>Select a snippet, fill in any variables, then insert it into your draft for review.</p>
      {query.isFetching && <p role="status">Loading prompt snippets…</p>}
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
      {query.data?.errors.map((error) => (
        <p role="alert" key={error}>
          {error}
        </p>
      ))}
      <Label>
        Search prompt snippets
        <Input value={search} onChange={(event) => setSearch(event.target.value)} />
      </Label>
      {query.data?.items
        .filter((item) =>
          search
            .toLowerCase()
            .split(/\s+/)
            .every((word) =>
              `${item.name} ${item.description} ${item.prompt}`.toLowerCase().includes(word),
            ),
        )
        .map((item) => (
          <Button
            variant="outline"
            className="whitespace-normal text-left"
            type="button"
            key={item.key}
            disabled={!online || !!query.error}
            aria-pressed={selected?.key === item.key}
            onClick={() => {
              setSelected(item);
              setValues({});
            }}
          >
            {item.name} [{item.scope}]{item.description ? ` — ${item.description}` : ''}
          </Button>
        ))}
      {query.data?.items.length === 0 && (
        <p>No prompt snippets yet. Create one with :Aero snippet in Neovim.</p>
      )}
      {selected && (
        <>
          {inputs.map((name) => (
            <Label key={name}>
              {name}
              <Textarea
                rows={4}
                value={Object.hasOwn(values, name) ? values[name] : ''}
                onChange={(event) =>
                  setValues((current) => ({ ...current, [name]: event.target.value }))
                }
              />
            </Label>
          ))}
          <pre
            aria-label="Prompt preview"
            className="max-h-64 overflow-auto whitespace-pre-wrap break-words"
          >
            {render(selected.prompt, previewValues)}
          </pre>
          <Button
            type="button"
            disabled={!online || !!query.error || query.isFetching}
            onClick={() =>
              onChoose(
                render(selected.prompt, {
                  ...context,
                  ...Object.fromEntries(inputs.map((name) => [name, ''])),
                  ...values,
                }),
              )
            }
          >
            Insert prompt
          </Button>
          <Button
            variant="outline"
            type="button"
            onClick={() => {
              setSelected(null);
              setValues({});
            }}
          >
            Cancel selection
          </Button>
        </>
      )}
    </section>
  );
}
