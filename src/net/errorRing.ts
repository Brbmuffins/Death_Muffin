/**
 * The last few uncaught client errors, attached to a bug report so the report says what the console said. Recording costs one
 * string per error (never per frame); nothing leaves the page unless the player sends a report.
 */
const MAX = 5;
const ring: string[] = [];

export function noteClientError(text: string) {
  ring.push(`${new Date().toISOString().slice(11, 19)} ${text}`.slice(0, 400));
  if (ring.length > MAX) ring.shift();
}

export function recentClientErrors(): string[] {
  return [...ring];
}

export function installErrorRing(target: Window = window) {
  target.addEventListener('error', (e) => noteClientError(`${e.message || 'error'}${e.filename ? ` @ ${e.filename.split('/').pop()}:${e.lineno}` : ''}`));
  target.addEventListener('unhandledrejection', (e) => {
    const r = e.reason as { message?: unknown } | undefined;
    noteClientError(`unhandled: ${typeof r?.message === 'string' ? r.message : String(e.reason)}`);
  });
}
