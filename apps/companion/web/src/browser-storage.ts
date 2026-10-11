export function readStored<T>(
  key: string,
  fallback: T,
  storage: 'session' | 'local' = 'session',
): T {
  try {
    const value = JSON.parse(
      (storage === 'local' ? localStorage : sessionStorage).getItem(key) || 'null',
    );
    return value !== null &&
      typeof value === typeof fallback &&
      Array.isArray(value) === Array.isArray(fallback)
      ? value
      : fallback;
  } catch {
    return fallback;
  }
}

export function store(key: string, value: unknown, storage: 'session' | 'local' = 'session') {
  try {
    (storage === 'local' ? localStorage : sessionStorage).setItem(key, JSON.stringify(value));
  } catch {
    /* Navigation and drafts remain usable without storage. */
  }
}
