import { afterEach, expect, it, vi } from 'vitest';
import { post, RequestError } from './api';

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

it('bounds stalled requests and preserves unknown action outcomes', async () => {
  vi.useFakeTimers();
  vi.stubGlobal(
    'fetch',
    vi.fn(
      (_url, options: RequestInit) =>
        new Promise((_resolve, reject) => {
          options.signal!.addEventListener('abort', () =>
            reject(new DOMException('Aborted', 'AbortError')),
          );
        }),
    ),
  );
  const result = post('prompt', { operation_id: 'timeout-action-0001' }).catch((error) => error);
  await vi.advanceTimersByTimeAsync(30_000);
  const error = await result;
  expect(error).toBeInstanceOf(RequestError);
  if (!(error instanceof RequestError)) throw error;
  expect(error.unknownOutcome).toBe(true);
  expect(error.message).toContain('Request timed out');
  expect(vi.getTimerCount()).toBe(0);
});

it('clears the request deadline after receiving a receipt', async () => {
  vi.useFakeTimers();
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue(new Response(JSON.stringify({ result: { status: 'accepted' } }))),
  );
  expect(await post('prompt', {})).toEqual({ result: { status: 'accepted' } });
  expect(vi.getTimerCount()).toBe(0);
});
