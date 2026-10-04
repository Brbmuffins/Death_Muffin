/** Pure rolling frame statistics for the FPS overlay (no DOM, no three). */

export interface FrameSample {
  /** Wall time since the previous processed frame. */
  frameMs: number;
  /** CPU time in view.update (game logic, AI, animation mixers). */
  updateMs: number;
  /** CPU time spent issuing draw calls (renderer.render / composer.render). */
  renderMs: number;
}

export interface FrameSummary {
  fps: number;
  avgMs: number;
  /** Slowest frame in the window. */
  worstMs: number;
  /** Frames over HITCH_MS in the window. */
  hitches: number;
  updateMs: number;
  renderMs: number;
  /** Measured GPU time per frame (null: timer queries unsupported or not ready). */
  gpuMs: number | null;
  verdict: Verdict;
}

export type Verdict = 'ok' | 'gpu' | 'cpu' | 'unclear';

/** A frame this slow is a visible stutter. */
export const HITCH_MS = 50;

/**
 * Where the frame time goes. The budget is the frame cap (Max judged at 60). Holding the budget is 'ok'. Otherwise:
 * CPU work (update + draw submission) filling most of the frame is 'cpu'; a measured GPU time filling it, or CPU work
 * well under it (the loop is waiting on the GPU), is 'gpu'.
 */
export function verdict(avgMs: number, cpuMs: number, gpuMs: number | null, budgetMs: number): Verdict {
  if (avgMs <= budgetMs * 1.1) return 'ok';
  if (cpuMs >= avgMs * 0.7) return 'cpu';
  if (gpuMs !== null ? gpuMs >= avgMs * 0.6 : cpuMs <= avgMs * 0.5) return 'gpu';
  return 'unclear';
}

export class FrameStats {
  private samples: FrameSample[] = [];
  private gpu: number[] = [];

  constructor(private windowMs = 1000) {}

  push(s: FrameSample) {
    this.samples.push(s);
    let total = 0;
    for (const x of this.samples) total += x.frameMs;
    while (this.samples.length > 1 && total - this.samples[0].frameMs >= this.windowMs) total -= this.samples.shift()!.frameMs;
  }

  pushGpu(ms: number) {
    this.gpu.push(ms);
    if (this.gpu.length > 60) this.gpu.shift();
  }

  summary(budgetMs: number): FrameSummary | null {
    const n = this.samples.length;
    if (!n) return null;
    let frame = 0, update = 0, render = 0, worst = 0, hitches = 0;
    for (const s of this.samples) {
      frame += s.frameMs;
      update += s.updateMs;
      render += s.renderMs;
      worst = Math.max(worst, s.frameMs);
      if (s.frameMs > HITCH_MS) hitches++;
    }
    const avgMs = frame / n;
    const gpuMs = this.gpu.length ? this.gpu.reduce((a, b) => a + b, 0) / this.gpu.length : null;
    const updateMs = update / n;
    const renderMs = render / n;
    return {
      fps: frame > 0 ? (n * 1000) / frame : 0,
      avgMs,
      worstMs: worst,
      hitches,
      updateMs,
      renderMs,
      gpuMs,
      verdict: verdict(avgMs, updateMs + renderMs, gpuMs, budgetMs),
    };
  }
}
