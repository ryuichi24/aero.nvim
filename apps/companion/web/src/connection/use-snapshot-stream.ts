// SSE is authoritative. Identity/revision guards ignore callbacks from old streams.
import { useCallback, useEffect, useRef, type RefObject } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { parseSnapshot } from '../api';
import { useCompanionDispatch } from '../companion-context';

export function useSnapshotStream(resumed: RefObject<string | null>) {
  const client = useQueryClient();
  const dispatch = useCompanionDispatch();
  const streamRef = useRef<EventSource | null>(null);
  const disconnect = useCallback(() => {
    streamRef.current?.close();
    streamRef.current = null;
  }, []);
  const connect = useCallback(() => {
    disconnect();
    const stream = new EventSource('/api/events');
    streamRef.current = stream;
    let connectionRevision = 0;
    stream.onmessage = (event) => {
      if (streamRef.current !== stream) return;
      connectionRevision++;
      try {
        const snapshot = parseSnapshot(event.data);
        client.setQueryData(['snapshot'], snapshot);
        const session = snapshot.sessions.find((item) => item.id === resumed.current);
        if (session?.conversation && !['starting', 'exited', 'stopped'].includes(session.status)) {
          resumed.current = null;
          dispatch({
            type: 'select-session',
            selection: { id: session.id, conversation: session.conversation },
          });
        }
        dispatch({
          type: 'connection',
          online: snapshot.connected,
          pairing: false,
          message: snapshot.connected ? 'Connected · live' : 'Neovim unavailable',
        });
      } catch {
        dispatch({
          type: 'connection',
          online: false,
          message: 'Invalid stream data · actions disabled',
        });
      }
    };
    stream.onerror = async () => {
      if (streamRef.current !== stream) return;
      const revision = ++connectionRevision;
      dispatch({
        type: 'connection',
        online: false,
        message: 'Connection interrupted · reconnecting',
      });
      try {
        const response = await fetch('/api/snapshot');
        if (
          streamRef.current === stream &&
          connectionRevision === revision &&
          response.status === 401
        ) {
          stream.close();
          dispatch({
            type: 'connection',
            online: false,
            pairing: true,
            message: 'Pairing required',
          });
        }
      } catch {
        // EventSource resynchronizes when the network recovers.
      }
    };
  }, [client, dispatch, disconnect, resumed]);
  useEffect(() => {
    connect();
    return disconnect;
  }, [connect, disconnect]);
  return { connect, disconnect };
}
