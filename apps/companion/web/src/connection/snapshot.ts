// Validate fields consumed by screens at the untrusted JSON boundary.
import type { Snapshot } from '../types';
const record = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value);
const strings = (value: unknown, fields: string[]) =>
  record(value) && fields.every((field) => typeof value[field] === 'string');
const optionalString = (value: Record<string, unknown>, key: string) =>
  value[key] === undefined || typeof value[key] === 'string';
const list = (value: unknown, check: (entry: unknown) => boolean) =>
  Array.isArray(value) && value.every(check);

export function parseSnapshot(text: string): Snapshot {
  const value: unknown = JSON.parse(text);
  const validSession = (session: unknown) => {
    if (
      !record(session) ||
      !strings(session, ['id', 'name', 'agent', 'worktree', 'status']) ||
      !['idle', 'busy', 'waiting', 'starting', 'stopped', 'exited'].includes(String(session.status))
    )
      return false;
    if (!['conversation', 'target', 'activity'].every((key) => optionalString(session, key)))
      return false;
    if (session.blocks !== undefined && !list(session.blocks, (block) => strings(block, ['kind'])))
      return false;
    if (session.queue !== undefined && !list(session.queue, (entry) => typeof entry === 'string'))
      return false;
    if (session.permission !== undefined) {
      const permission = session.permission;
      if (
        !record(permission) ||
        !strings(permission, ['id', 'title']) ||
        !list(permission.options, (option) => strings(option, ['optionId']))
      )
        return false;
    }
    return true;
  };
  if (
    !record(value) ||
    typeof value.connected !== 'boolean' ||
    typeof value.cursor !== 'string' ||
    !list(value.sessions, validSession) ||
    !list(value.inbox, (event) =>
      strings(event, ['id', 'session', 'conversation', 'kind', 'text']),
    ) ||
    !list(value.workspaces, (workspace) => strings(workspace, ['root', 'name'])) ||
    !list(value.worktrees, (tree) => strings(tree, ['path'])) ||
    (value.submodules !== undefined &&
      !list(value.submodules, (entry) => strings(entry, ['worktree', 'path', 'name', 'workspace'])))
  )
    throw new Error('Invalid stream snapshot');
  return value as unknown as Snapshot;
}
