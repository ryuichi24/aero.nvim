// JSDOM does not implement layout observation, which Radix checkbox inputs use.
globalThis.ResizeObserver ??= class ResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
};
