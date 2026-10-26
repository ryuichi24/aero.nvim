import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { PromptCommand } from './prompt-command';
import type { Session } from './types';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});
const session: Session = {
  id: 'agent',
  conversation: 'generation',
  name: 'Agent',
  agent: 'fixture',
  worktree: '/repo',
  status: 'idle',
};
function mount(online = true) {
  const choose = vi.fn();
  render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <PromptCommand session={session} epoch="host" online={online} onChoose={choose} />
    </QueryClientProvider>,
  );
  return choose;
}
function collection() {
  const fetch = vi.fn().mockResolvedValue(
    new Response(
      JSON.stringify({
        items: [
          {
            key: 'Review',
            name: 'Review',
            scope: 'workspace',
            description: 'Inspect changes',
            prompt: '{{workspace}}: {{topic}} / {{ topic }} / {{focus}}',
          },
          {
            key: 'Explain',
            name: 'Explain',
            scope: 'global',
            description: '',
            prompt: 'Explain the code',
          },
        ],
        errors: ['An invalid file was skipped'],
        context: { workspace: '/repo' },
      }),
      { status: 200 },
    ),
  );
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

it('searches merged snippets, previews context, and inserts custom values once without sending', async () => {
  const fetch = collection();
  const choose = mount();
  const user = userEvent.setup();
  await userEvent.click(
    await screen.findByRole('button', { name: 'Review [workspace] — Inspect changes' }),
  );
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
    epoch: 'host',
    session: 'agent',
    conversation: 'generation',
  });
  expect(screen.getByLabelText('Prompt preview').textContent).toBe(
    '/repo: {{topic}} / {{ topic }} / {{focus}}',
  );
  expect(screen.getAllByRole('textbox', { name: 'topic' })).toHaveLength(1);
  // Values containing placeholders or replacement syntax must remain literal.
  await user.click(screen.getByRole('textbox', { name: 'topic' }));
  await user.paste('100% {{workspace}} $&');
  expect(choose).not.toHaveBeenCalled();
  await userEvent.click(screen.getByRole('button', { name: 'Insert prompt' }));
  expect(choose).toHaveBeenCalledWith('/repo: 100% {{workspace}} $& / 100% {{workspace}} $& / ');
  expect(screen.getByRole('alert').textContent).toContain('invalid file');
  await userEvent.type(screen.getByRole('textbox', { name: 'Search prompt snippets' }), 'explain');
  expect(screen.queryByRole('button', { name: /Review \[workspace\]/ })).toBeNull();
  expect(screen.getByRole('button', { name: 'Explain [global]' })).toBeTruthy();
});

it('preserves long multiline custom values in the preview and generated prompt', async () => {
  collection();
  const choose = mount();
  const user = userEvent.setup();
  await user.click(
    await screen.findByRole('button', { name: 'Review [workspace] — Inspect changes' }),
  );
  const value = `First sentence. Second sentence.\n\n${'Long paragraph with 100% {{workspace}} $&. '.repeat(200)}\nFinal line.\n`;
  await user.click(screen.getByRole('textbox', { name: 'topic' }));
  await user.paste(value);
  await user.click(screen.getByRole('textbox', { name: 'focus' }));
  await user.keyboard('First line{Enter}Second line');
  const expected = `/repo: ${value} / ${value} / First line\nSecond line`;
  expect(screen.getByLabelText('Prompt preview').textContent).toBe(expected);
  expect(choose).not.toHaveBeenCalled();
  await user.click(screen.getByRole('button', { name: 'Insert prompt' }));
  expect(choose).toHaveBeenCalledExactlyOnceWith(expected);
});

it('cancels selection without changing the draft', async () => {
  collection();
  const choose = mount();
  await userEvent.click(await screen.findByRole('button', { name: 'Explain [global]' }));
  await userEvent.click(screen.getByRole('button', { name: 'Cancel selection' }));
  expect(screen.queryByLabelText('Prompt preview')).toBeNull();
  expect(choose).not.toHaveBeenCalled();
});

it('does not fetch offline and reports request failures', async () => {
  const fetch = vi
    .fn()
    .mockResolvedValue(
      new Response(JSON.stringify({ error: 'stale conversation' }), { status: 400 }),
    );
  vi.stubGlobal('fetch', fetch);
  mount(false);
  expect(fetch).not.toHaveBeenCalled();
  cleanup();
  mount();
  expect((await screen.findByRole('alert')).textContent).toContain('stale conversation');
});
