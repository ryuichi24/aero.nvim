import { expect, it } from 'vitest';
import fixture from '../../../../../tests/fixtures/companion-snapshot.json';
import { parseSnapshot } from './snapshot';

it('accepts the shared Lua/Go/browser wire fixture', () => {
  expect(parseSnapshot(JSON.stringify(fixture))).toEqual(fixture);
});

it('rejects malformed nested session and permission data before screens consume it', () => {
  for (const invalid of [
    null,
    { ...fixture, sessions: [null] },
    { ...fixture, sessions: [{ ...fixture.sessions[0], status: 'unknown' }] },
    {
      ...fixture,
      sessions: [{ ...fixture.sessions[0], permission: { id: 'p', title: 'Read', options: null } }],
    },
    { ...fixture, worktrees: [{ path: 42 }] },
    { ...fixture, submodules: [{ worktree: '/repo', path: '/repo/core', name: 'core' }] },
    { ...fixture, submodules: null },
  ]) {
    expect(() => parseSnapshot(JSON.stringify(invalid))).toThrow('Invalid stream snapshot');
  }
});
