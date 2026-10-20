import { act, render, screen } from '@testing-library/react';
import { expect, it, vi } from 'vitest';
import { App } from '../app';
import { FakeEvents, connect } from '../test/companion-harness';

it('reports connection stages and replaces a silently stalled stream', () => {
  vi.useFakeTimers();
  try {
    render(<App />);
    expect(screen.getAllByText(/Connecting to companion/).length).toBeGreaterThan(0);
    const first = FakeEvents.instances.at(-1)!;
    act(() => first.onopen?.());
    expect(screen.getAllByText(/waiting for Neovim snapshot/).length).toBeGreaterThan(0);
    connect();
    act(() => vi.advanceTimersByTime(21000));
    expect(first.close).toHaveBeenCalled();
    expect(FakeEvents.instances.length).toBe(2);
    // Late data from the abandoned connection must not restore live status.
    act(() => first.onmessage?.(new MessageEvent('message', { data: '{}' })));
    expect(screen.getAllByText(/Connecting to companion/).length).toBeGreaterThan(0);
  } finally {
    vi.useRealTimers();
  }
});

it('keeps an idle healthy stream and reconnects when the network returns', () => {
  vi.useFakeTimers();
  try {
    render(<App />);
    connect();
    const first = FakeEvents.instances.at(-1)!;
    const heartbeat = first.addEventListener.mock.calls.find(([name]) => name === 'heartbeat')![1];
    act(() => {
      vi.advanceTimersByTime(15000);
      heartbeat();
      vi.advanceTimersByTime(15000);
    });
    expect(FakeEvents.instances.length).toBe(1);
    act(() => window.dispatchEvent(new Event('offline')));
    expect(screen.getAllByText(/Phone is offline/).length).toBeGreaterThan(0);
    act(() => window.dispatchEvent(new Event('online')));
    expect(FakeEvents.instances.length).toBe(2);
  } finally {
    vi.useRealTimers();
  }
});
