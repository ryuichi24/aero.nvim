import type { Snapshot } from './types';

export function actionableAttention(snapshot: Snapshot | null) {
  return (
    snapshot?.inbox.filter((entry) => {
      if (entry.kind !== 'permission') return false;
      const owner = snapshot.sessions.find(
        (session) => session.id === entry.session && session.conversation === entry.conversation,
      );
      return (
        !!owner?.permission?.options.length &&
        owner.status !== 'stopped' &&
        owner.status !== 'exited'
      );
    }) || []
  );
}
