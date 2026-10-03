/**
 * Performance beacon: every 15 s the client sends a tiny summary of its own frame timing (plus a little context) over the realtime
 * socket, so a stutter report can be split into "client frame stalls" vs "network". The per-frame hook (`perfFrame`) writes one float
 * into a preallocated ring and allocates nothing. Nothing is shown to the player. Off in DEV / offline builds unless `?perfbeacon`.
 */

export const PERF_WINDOW_MS = 15000;
const RING = 4096; // 15 s at ~270 fps; older samples are overwritten

/** Fixed-size frame-interval ring with percentile summary. record() is allocation-free. */
export class FrameStats {
  private ring = new Float32Array(RING);
  private scratch = new Float32Array(RING);
  private len = 0;
  private head = 0;
  maxMs = 0;
  maxAt = 0;
  count = 0;

  record(ms: number, at = 0) {
    this.ring[this.head] = ms;
    this.head = (this.head + 1) % RING;
    if (this.len < RING) this.len++;
    this.count++;
    if (ms > this.maxMs) {
      this.maxMs = ms;
      this.maxAt = at;
    }
  }

  /** Percentiles over the retained samples (sorts a scratch copy: call once per report, not per frame). */
  summary() {
    const n = this.len;
    if (!n) return { n: 0, p50: 0, p95: 0, max: 0 };
    const s = this.scratch.subarray(0, n);
    s.set(n === RING ? this.ring : this.ring.subarray(0, n));
    s.sort();
    const at = (q: number) => s[Math.min(n - 1, Math.floor(q * n))];
    return { n: this.count, p50: at(0.5), p95: at(0.95), max: this.maxMs };
  }

  reset() {
    this.len = 0;
    this.head = 0;
    this.count = 0;
    this.maxMs = 0;
    this.maxAt = 0;
  }
}

const r1 = (n: number) => Math.round(n * 10) / 10;

/** Context read once per report; the scene fills it in (see WorldScene.startPerfBeacon). */
export type PerfContext = Record<string, number | string | undefined>;

export interface PerfBeaconDeps {
  send(payload: unknown): void;
  connected(): boolean;
  context(): PerfContext;
  /** Once per session (GPU string etc.). */
  session(): PerfContext;
}

export class PerfBeacon {
  private frames = new FrameStats();
  private last = 0;
  private winStart = 0;
  private hiddenAt = 0;
  private hiddenMs = 0;
  private skipNext = true;
  private ltN = 0;
  private ltMs = 0;
  private ltMax = 0;
  private events: string[] = [];
  private timer = 0;
  private obs: PerformanceObserver | null = null;
  private sentSession = false;
  private onVis = () => {
    if (document.hidden) this.hiddenAt = performance.now();
    else if (this.hiddenAt) {
      this.hiddenMs += performance.now() - this.hiddenAt;
      this.hiddenAt = 0;
      this.skipNext = true; // the first interval after a tab switch is the hidden time, not a stall
    }
  };

  constructor(private deps: PerfBeaconDeps) {}

  start() {
    this.winStart = performance.now();
    document.addEventListener('visibilitychange', this.onVis);
    try {
      this.obs = new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          this.ltN++;
          this.ltMs += e.duration;
          if (e.duration > this.ltMax) this.ltMax = e.duration;
        }
      });
      this.obs.observe({ type: 'longtask', buffered: false });
    } catch {
      this.obs = null; // longtask unsupported: report zeros
    }
    this.timer = window.setInterval(() => this.flush(), PERF_WINDOW_MS);
  }

  stop() {
    window.clearInterval(this.timer);
    document.removeEventListener('visibilitychange', this.onVis);
    this.obs?.disconnect();
  }

  /** Per rendered-frame hook: no allocation. `t` is performance.now(). */
  frame(t: number) {
    if (this.skipNext) this.skipNext = false;
    else this.frames.record(t - this.last, (t - this.winStart) / 1000);
    this.last = t;
  }

  note(e: string) {
    if (this.events.length < 8) this.events.push(e.length > 40 ? e.slice(0, 40) : e);
  }

  private flush() {
    const now = performance.now();
    if (this.hiddenAt) {
      this.hiddenMs += now - this.hiddenAt;
      this.hiddenAt = now;
    }
    const connected = this.deps.connected();
    const s = this.frames.summary();
    const win = now - this.winStart;
    const live = Math.max(1, win - this.hiddenMs);
    if (connected && s.n > 0) {
      const p: Record<string, unknown> = {
        v: 1,
        win: Math.round(win),
        fps: r1((s.n * 1000) / live),
        p50: r1(s.p50),
        p95: r1(s.p95),
        max: r1(s.max),
        maxAt: Math.round(this.frames.maxAt),
        lt: [this.ltN, Math.round(this.ltMs), Math.round(this.ltMax)],
        hid: Math.round(this.hiddenMs),
        ...this.deps.context(),
        ev: this.events,
      };
      if (!this.sentSession) {
        Object.assign(p, this.deps.session());
        this.sentSession = true;
      }
      this.deps.send(p);
    }
    this.frames.reset();
    this.winStart = now;
    this.hiddenMs = 0;
    this.ltN = this.ltMs = this.ltMax = 0;
    this.events = [];
  }
}

let active: PerfBeacon | null = null;

/** Beacon on: real online builds, or any build with ?perfbeacon (QA). */
export function perfBeaconWanted(): boolean {
  try {
    if (new URLSearchParams(location.search).has('perfbeacon')) return true;
  } catch { /* no location */ }
  return !import.meta.env.DEV && import.meta.env.VITE_OFFLINE_BUILD !== '1';
}

export function setPerfBeacon(b: PerfBeacon | null) {
  active = b;
}
/** Hot-path hook; a single null check when the beacon is off. */
export function perfFrame(t: number) {
  if (active) active.frame(t);
}
/** Short "what happened" note (≤40 chars, max 8 per window). */
export function perfNote(e: string) {
  if (active) active.note(e);
}

/** GPU / device facts, read once per session. */
export function perfSessionInfo(gl: WebGLRenderingContext | WebGL2RenderingContext | null): PerfContext {
  let gpu = '';
  try {
    const ext = gl?.getExtension('WEBGL_debug_renderer_info');
    gpu = String((ext ? gl!.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl?.getParameter(gl.RENDERER)) ?? '').slice(0, 80);
  } catch { /* blocked */ }
  const nav = navigator as Navigator & { deviceMemory?: number };
  return { gpu, hc: nav.hardwareConcurrency, dmem: nav.deviceMemory, plat: String(nav.platform ?? '').slice(0, 20) };
}
