import { useEffect, useState } from 'react';

const storageKey = 'aero-companion-ui-zoom';
const minimum = 10;
const maximum = 200;
const step = 10;

function savedZoom() {
  try {
    const value = Number(localStorage.getItem(storageKey));
    if (Number.isFinite(value) && value >= minimum && value <= maximum) return value;
  } catch {
    // Zoom remains available when browser storage is unavailable.
  }
  return 100;
}

export function UIZoom() {
  const [zoom, setZoom] = useState(savedZoom);

  useEffect(() => {
    const root = document.documentElement;
    const previous = root.style.fontSize;
    root.style.fontSize = `${zoom}%`;
    try {
      localStorage.setItem(storageKey, String(zoom));
    } catch {
      // Keep the current zoom even if it cannot be saved.
    }
    return () => {
      root.style.fontSize = previous;
    };
  }, [zoom]);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (!(event.metaKey || event.ctrlKey) || event.altKey) return;
      if (!['+', '=', '-', '0'].includes(event.key)) return;
      event.preventDefault();
      if (event.key === '0') setZoom(100);
      else {
        const direction = event.key === '-' ? -1 : 1;
        setZoom((value) => Math.min(maximum, Math.max(minimum, value + direction * step)));
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  return (
    <div className="ui-zoom" role="group" aria-label="UI zoom">
      <button
        type="button"
        aria-label="Zoom out"
        title="Zoom out (Ctrl/Cmd −)"
        disabled={zoom <= minimum}
        onClick={() => setZoom((value) => Math.max(minimum, value - step))}
      >
        −
      </button>
      <button
        type="button"
        aria-label={`Reset UI zoom (${zoom}%)`}
        title="Reset zoom (Ctrl/Cmd 0)"
        onClick={() => setZoom(100)}
      >
        {zoom}%
      </button>
      <button
        type="button"
        aria-label="Zoom in"
        title="Zoom in (Ctrl/Cmd +)"
        disabled={zoom >= maximum}
        onClick={() => setZoom((value) => Math.min(maximum, value + step))}
      >
        +
      </button>
    </div>
  );
}
