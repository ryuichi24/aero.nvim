import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, expect, it, vi } from 'vitest';
import { ReportCommand } from './report-command';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it('lists worktree reports and drafts existing and new report commands without submitting', async () => {
  const fetch = vi.fn().mockResolvedValue(
    new Response(JSON.stringify({ entries: [{ name: 'Startup notes.md', directory: false }] }), {
      status: 200,
    }),
  );
  vi.stubGlobal('fetch', fetch);
  const choose = vi.fn();
  render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <ReportCommand worktree="/workspace" online onChoose={choose} />
    </QueryClientProvider>,
  );
  await userEvent.click(await screen.findByRole('button', { name: 'Startup notes.md' }));
  expect(choose).toHaveBeenLastCalledWith('/report select Startup notes.md');
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ worktree: '/workspace', path: '' });
  await userEvent.type(
    screen.getByRole('textbox', { name: 'New report name' }),
    'New investigation',
  );
  await userEvent.click(screen.getByRole('button', { name: 'Use new report' }));
  expect(choose).toHaveBeenLastCalledWith('/report new New investigation');
  expect(fetch).toHaveBeenCalledTimes(1);
});
