import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';
import { post } from '../api';
import type { Session } from '../types';

interface SessionSnapshot {
  cursor: string;
  session: Session;
}

// Histories live in their own bounded cache, never in the global SSE snapshot.
export function useSessionSnapshot(
  session: Session | undefined,
  epoch: string | undefined,
  active: boolean,
) {
  const client = useQueryClient();
  const queryKey = ['session-snapshot', epoch, session?.id, session?.target, session?.conversation];
  const query = useQuery({
    queryKey,
    subscribed: active,
    enabled: !!(active && session?.transcript_lazy && epoch && session.target),
    staleTime: 30_000,
    gcTime: 120_000,
    refetchInterval:
      active && session?.conversation && !['stopped', 'exited'].includes(session.status)
        ? 1500
        : false,
    refetchIntervalInBackground: false,
    queryFn: async ({ signal }): Promise<SessionSnapshot> => {
      const cached = client.getQueryData<SessionSnapshot>(queryKey);
      const result = await post<Partial<SessionSnapshot> & { unchanged?: boolean }>(
        'session_snapshot',
        {
          epoch,
          session: session?.id,
          target: session?.target,
          conversation: session?.conversation,
          cursor: cached?.cursor,
        },
        signal,
      );
      if (result.unchanged && cached && result.cursor === cached.cursor) return cached;
      if (
        !result.session ||
        result.session.id !== session?.id ||
        result.session.conversation !== session?.conversation ||
        typeof result.cursor !== 'string' ||
        !Array.isArray(result.session.blocks ?? []) ||
        !(result.session.blocks ?? []).every((block) => block && typeof block.kind === 'string')
      ) {
        throw new Error('Invalid session snapshot');
      }
      return result as SessionSnapshot;
    },
  });
  const { refetch } = query;
  useEffect(() => {
    if (active && session?.transcript_lazy && epoch && session.target)
      void refetch({ cancelRefetch: false });
  }, [
    active,
    epoch,
    session?.id,
    session?.target,
    session?.conversation,
    session?.status,
    session?.permission?.id,
    session?.transcript_lazy,
    refetch,
  ]);
  return {
    ...query,
    session:
      session && query.data && session.transcript_lazy
        ? {
            ...session,
            blocks: query.data.session.blocks,
            usage: session.usage ?? query.data.session.usage,
            acp_session_id: session.acp_session_id ?? query.data.session.acp_session_id,
          }
        : session,
  };
}
