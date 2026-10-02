/**
 * Auto-refresh support: deploy-release.sh writes `<sha> <iso-time>` to release.txt next to the play page on every
 * deploy. We remember the value seen at startup and report when it changes. Any failure to read it means "unknown",
 * never "changed".
 */

export function parseRelease(text: string): string | null {
  const sha = text.trim().split(/\s+/)[0] ?? '';
  return /^[0-9a-f]{7,64}$/i.test(sha) ? sha.toLowerCase() : null;
}

export interface ReleaseWatchOptions {
  url: string;
  fetchImpl?: typeof fetch;
}

export class ReleaseWatch {
  private baseline: string | null = null;

  constructor(private readonly o: ReleaseWatchOptions) {}

  get known() {
    return this.baseline;
  }

  private async read(): Promise<string | null> {
    try {
      const f = this.o.fetchImpl ?? fetch;
      const sep = this.o.url.includes('?') ? '&' : '?';
      const res = await f(`${this.o.url}${sep}t=${Date.now()}`, { cache: 'no-store' });
      if (!res.ok) return null;
      return parseRelease(await res.text());
    } catch {
      return null;
    }
  }

  /** Take (or retake) the baseline: the release this page was loaded from. */
  async init(): Promise<void> {
    if (this.baseline === null) this.baseline = await this.read();
  }

  /** True when the live release differs from the baseline. No baseline or an unreadable file = false. */
  async changed(): Promise<boolean> {
    if (this.baseline === null) {
      await this.init(); // the first read was missing: use this one as the baseline, nothing to compare yet
      return false;
    }
    const now = await this.read();
    return now !== null && now !== this.baseline;
  }
}

const enabled = () => import.meta.env.PROD && import.meta.env.VITE_OFFLINE_BUILD !== '1';

let shared: ReleaseWatch | null = null;

/** Called once at app start (play build only): records the release this page came from. */
export function startReleaseBaseline(): ReleaseWatch | null {
  if (!enabled()) return null;
  shared ??= new ReleaseWatch({ url: `${import.meta.env.BASE_URL}release.txt` });
  void shared.init();
  return shared;
}

export function releaseWatch(): ReleaseWatch | null {
  return shared;
}
