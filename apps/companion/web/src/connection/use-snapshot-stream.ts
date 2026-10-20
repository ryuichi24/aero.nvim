// SSE is authoritative. Identity/revision guards ignore callbacks from old streams.
import { useCallback, useEffect, useRef, type RefObject } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { parseSnapshot } from '../api';
import { useCompanionDispatch } from '../companion-context';

export function useSnapshotStream(resumed: RefObject<string | null>) {
  const client = useQueryClient();
  const dispatch = useCompanionDispatch();
  const streamRef = useRef<EventSource | null>(null);
  const lastActivity = useRef(Date.now());
  const attempt = useRef(0);
  const probe = useRef<AbortController | null>(null);
  const disconnect = useCallback(() => {
    probe.current?.abort();
    streamRef.current?.close();
    streamRef.current = null;
  }, []);
  const connect = useCallback(() => {
    disconnect();
    lastActivity.current = Date.now();
    attempt.current++;
    dispatch({
      type: 'connection',
      online: false,
      message: `Connecting to companion · attempt ${attempt.current}`,
    });
    const stream = new EventSource('/api/events');
    streamRef.current = stream;
    let connectionRevision = 0;
    stream.onopen = () => {
      if (streamRef.current !== stream) return;
      lastActivity.current = Date.now();
      dispatch({
        type: 'connection',
        online: false,
        pairing: false,
        message: 'Companion reached · waiting for Neovim snapshot',
      });
    };
    stream.addEventListener('heartbeat', () => {
      if (streamRef.current === stream) lastActivity.current = Date.now();
    });
    stream.onmessage = (event) => {
      if (streamRef.current !== stream) return;
      lastActivity.current = Date.now();
      connectionRevision++;
      try {
        const snapshot = parseSnapshot(event.data);
        attempt.current = 0;
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
          message: snapshot.connected
            ? 'Connected · live'
            : 'Companion reached · Neovim unavailable · retrying',
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
        probe.current?.abort();
        const controller = new AbortController();
        probe.current = controller;
        const timeout = window.setTimeout(() => controller.abort(), 8000);
        let response: Response;
        try {
          response = await fetch('/api/snapshot', { signal: controller.signal });
        } finally {
          window.clearTimeout(timeout);
        }
        if (
          streamRef.current === stream &&
          connectionRevision === revision &&
          response.status === 401
        ) {
          disconnect();
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
    const recover = () => {
      if (document.visibilityState !== 'hidden' && navigator.onLine !== false) connect();
    };
    const offline = () => {
      disconnect();
      dispatch({
        type: 'connection',
        online: false,
        message: 'Phone is offline · waiting for network',
      });
    };
    const watchdog = window.setInterval(() => {
      if (streamRef.current && Date.now() - lastActivity.current > 20000) recover();
    }, 1000);
    document.addEventListener('visibilitychange', recover);
    window.addEventListener('pageshow', recover);
    window.addEventListener('online', recover);
    window.addEventListener('offline', offline);
    return () => {
      disconnect();
      window.clearInterval(watchdog);
      document.removeEventListener('visibilitychange', recover);
      window.removeEventListener('pageshow', recover);
      window.removeEventListener('online', recover);
      window.removeEventListener('offline', offline);
    };
  }, [connect, disconnect, dispatch]);
  return { connect, disconnect };
}
