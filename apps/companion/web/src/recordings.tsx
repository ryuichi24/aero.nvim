import { useEffect, useMemo, useState } from 'react';
import { ImageLink } from './image-link';
import { sessionRecordings } from './screenshots';
import type { Session } from './types';

export function Recordings({ session }: { session: Session }) {
  const recordings = useMemo(() => sessionRecordings(session), [session]);
  const [status, setStatus] = useState<Record<string, string>>({});
  const paths = JSON.stringify(recordings.map((recording) => recording.href));
  useEffect(() => {
    const controller = new AbortController();
    for (const href of JSON.parse(paths) as string[]) {
      // A one-byte range request asks the bridge to preserve a complete copy,
      // while transferring almost no video data to the phone.
      void fetch(href, { headers: { Range: 'bytes=0-0' }, signal: controller.signal })
        .then(async (response) => {
          if (!response.ok) {
            const body = await response.json();
            throw new Error(body.error || 'Could not save recording');
          }
          await response.arrayBuffer();
          if (!controller.signal.aborted)
            setStatus((current) => ({ ...current, [href]: 'Saved for later' }));
        })
        .catch((error: unknown) => {
          if (!controller.signal.aborted)
            setStatus((current) => ({
              ...current,
              [href]: error instanceof Error ? error.message : 'Could not save recording',
            }));
        });
    }
    return () => controller.abort();
  }, [paths]);
  if (!recordings.length) return null;
  return (
    <details className="session-screenshots">
      <summary>Recordings ({recordings.length})</summary>
      <ul className="screenshot-list" aria-label="Session recordings">
        {recordings.map((recording) => (
          <li key={recording.href}>
            <ImageLink href={recording.href} title={recording.path} media="video">
              <strong>{recording.label}</strong>
              <span>{recording.path}</span>
            </ImageLink>
            <p className="recording-status">{status[recording.href] || 'Saving recording…'}</p>
          </li>
        ))}
      </ul>
    </details>
  );
}
