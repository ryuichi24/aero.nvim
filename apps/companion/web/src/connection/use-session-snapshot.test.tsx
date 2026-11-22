import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import type { ReactNode } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { useSessionSnapshot } from './use-session-snapshot';
import type { Session } from '../types';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const summary: Session = {
  id: 'saved',
  name: 'Saved chat',
  agent: 'fixture',
  worktree: '/repo',
  status: 'stopped',
  target: 'target',
  transcript_lazy: true,
};

function setup(active = false) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  );
  const hook = renderHook(({ session, open }) => useSessionSnapshot(session, 'epoch', open), {
    wrapper,
    initialProps: { session: summary, open: active },
  });
  return { ...hook, client };
}

it('loads only an opened session, reuses cached history, and sends its cursor on refresh', async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          cursor: 'revision-1',
          session: { ...summary, blocks: [{ kind: 'agent', text: 'Saved answer' }] },
        }),
      ),
    )
    .mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ cursor: 'revision-1', unchanged: true }))),
    );
  vi.stubGlobal('fetch', fetch);
  const hook = setup();
  expect(fetch).not.toHaveBeenCalled();
  hook.rerender({ session: summary, open: true });
  await waitFor(() => expect(hook.result.current.session?.blocks?.[0].text).toBe('Saved answer'));
  expect(fetch).toHaveBeenCalledTimes(1);

  await act(async () => {
    await hook.result.current.refetch();
  });
  expect(JSON.parse(fetch.mock.calls[1][1].body).cursor).toBe('revision-1');
  expect(hook.result.current.session?.blocks?.[0].text).toBe('Saved answer');

  hook.rerender({ session: summary, open: false });
  expect(hook.result.current.session?.blocks?.[0].text).toBe('Saved answer');
  expect(
    hook.client
      .getQueryCache()
      .find({
        queryKey: ['session-snapshot', 'epoch', summary.id, summary.target, summary.conversation],
      })
      ?.getObserversCount(),
  ).toBe(0);
});

it('isolates cached histories by session identity and cancels a pending read when switching', async () => {
  const signals: AbortSignal[] = [];
  const fetch = vi.fn().mockImplementation((_url, options) => {
    signals.push(options.signal);
    return new Promise((_resolve, reject) => {
      options.signal.addEventListener(
        'abort',
        () => reject(new DOMException('Aborted', 'AbortError')),
        { once: true },
      );
    });
  });
  vi.stubGlobal('fetch', fetch);
  const hook = setup(true);
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  hook.rerender({ session: { ...summary, id: 'other', target: 'other-target' }, open: true });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
  expect(signals[0].aborted).toBe(true);
  expect(hook.result.current.session?.id).toBe('other');
  expect(hook.result.current.session?.blocks).toBeUndefined();
  hook.rerender({ session: { ...summary, id: 'other', target: 'other-target' }, open: false });
  expect(signals[1].aborted).toBe(true);
});
