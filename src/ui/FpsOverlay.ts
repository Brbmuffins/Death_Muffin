import type * as THREE from 'three';
import { FrameStats, HITCH_MS, type FrameSample, type Verdict } from '../app/frameStats';
import { budgetFps } from '../app/framePacing';
import { settings } from '../app/settings';

/**
 * Performance overlay: F3 toggles it (remembered per browser), `?fps` forces it on. Shows frame rate, worst frame,
 * hitches, where the frame time goes (game logic / draw submission / GPU), and what is being drawn, so "it lags"
 * can be told apart: GPU-bound, CPU-bound, or stutters. Costs nothing while hidden.
 */

const STORE_KEY = 'dm.fpsOverlay';
const REFRESH_MS = 250;

const VERDICT_TEXT: Record<Verdict, string> = {
  ok: 'holding the frame cap',
  gpu: 'GPU-bound: try Graphics → Low',
  cpu: 'CPU-bound: game logic / draw count',
  unclear: 'slow, mixed cause',
};

export interface OverlaySource {
  renderer: THREE.WebGLRenderer;
  /** Render-resolution multiplier from the resolution governor. */
  resolutionScale(): number;
}

interface TimerExt {
  TIME_ELAPSED_EXT: number;
  GPU_DISJOINT_EXT: number;
}

/** GPU frame time via EXT_disjoint_timer_query_webgl2; results arrive a few frames late, so queries are pooled. */
class GpuTimer {
  private pending: WebGLQuery[] = [];
  private free: WebGLQuery[] = [];
  private active: WebGLQuery | null = null;

  private constructor(private gl: WebGL2RenderingContext, private ext: TimerExt) {}

  static create(gl: WebGLRenderingContext | WebGL2RenderingContext): GpuTimer | null {
    if (typeof WebGL2RenderingContext === 'undefined' || !(gl instanceof WebGL2RenderingContext)) return null;
    const ext = gl.getExtension('EXT_disjoint_timer_query_webgl2') as TimerExt | null;
    return ext ? new GpuTimer(gl, ext) : null;
  }

  begin() {
    if (this.active || this.pending.length > 8) return;
    const q = this.free.pop() ?? this.gl.createQuery();
    if (!q) return;
    this.gl.beginQuery(this.ext.TIME_ELAPSED_EXT, q);
    this.active = q;
  }

  end() {
    if (!this.active) return;
    this.gl.endQuery(this.ext.TIME_ELAPSED_EXT);
    this.pending.push(this.active);
    this.active = null;
  }

  /** Finished results in ms, oldest first. A disjoint event (clock change) voids everything in flight. */
  poll(): number[] {
    const gl = this.gl;
    const out: number[] = [];
    if (gl.getParameter(this.ext.GPU_DISJOINT_EXT)) {
      this.free.push(...this.pending);
      this.pending = [];
      return out;
    }
    while (this.pending.length && gl.getQueryParameter(this.pending[0], gl.QUERY_RESULT_AVAILABLE)) {
      const q = this.pending.shift()!;
      out.push(gl.getQueryParameter(q, gl.QUERY_RESULT) / 1e6);
      this.free.push(q);
    }
    return out;
  }
}

function readStored(): boolean {
  try {
    return localStorage.getItem(STORE_KEY) === '1';
  } catch {
    return false;
  }
}

function writeStored(on: boolean) {
  try {
    if (on) localStorage.setItem(STORE_KEY, '1');
    else localStorage.removeItem(STORE_KEY);
  } catch {
    /* private window: the toggle just isn't remembered */
  }
}

const f1 = (n: number) => n.toFixed(1);
const kilo = (n: number) => (n >= 1e6 ? `${f1(n / 1e6)}M` : n >= 1e3 ? `${f1(n / 1e3)}k` : String(n));

export class FpsOverlay {
  private el: HTMLDivElement | null = null;
  private stats = new FrameStats();
  private gpu: GpuTimer | null | undefined;
  private lastPaint = 0;
  /** Resource counts after the previous frame, to attribute a stutter to new shaders / textures / meshes. */
  private prev = { shaders: -1, tex: 0, geo: 0 };
  private hitchLog: string[] = [];
  visible = false;

  constructor(private src: OverlaySource) {
    const forced = typeof location !== 'undefined' && /[?&]fps\b/.test(location.search);
    if (forced || readStored()) this.show();
    window.addEventListener('keydown', (e) => {
      if (e.key !== 'F3' || e.repeat) return;
      e.preventDefault();
      if (this.visible) this.hide();
      else this.show();
      writeStored(this.visible);
    });
  }

  private show() {
    this.visible = true;
    this.stats = new FrameStats();
    if (!this.el) {
      const el = document.createElement('div');
      el.className = 'fps-overlay';
      el.setAttribute('aria-hidden', 'true');
      Object.assign(el.style, {
        position: 'fixed',
        top: '8px',
        left: '50%',
        transform: 'translateX(-50%)',
        zIndex: '9999',
        pointerEvents: 'none',
        padding: '6px 10px',
        borderRadius: '6px',
        background: 'rgba(8, 6, 12, 0.78)',
        border: '1px solid rgba(255, 255, 255, 0.12)',
        color: '#e8e2d4',
        font: '11px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        whiteSpace: 'pre',
      } satisfies Partial<CSSStyleDeclaration>);
      el.textContent = 'measuring…';
      this.el = el;
    }
    document.body.appendChild(this.el);
  }

  private hide() {
    this.visible = false;
    this.el?.remove();
  }

  /** Called right around the draw; no-ops while hidden. */
  beginGpu() {
    if (!this.visible) return;
    if (this.gpu === undefined) this.gpu = GpuTimer.create(this.src.renderer.getContext());
    this.gpu?.begin();
  }

  endGpu() {
    if (this.visible) this.gpu?.end();
  }

  /**
   * A frame whose own work (logic + draw) took over HITCH_MS is logged with what appeared in it. three compiles shaders and
   * uploads textures synchronously inside render(), so "+3 shaders" on a slow draw is a first-draw hitch; a slow logic time
   * with no new resources is game code (spawning, AI, pathing).
   */
  private trackHitch(s: FrameSample) {
    const info = this.src.renderer.info;
    const now = { shaders: info.programs?.length ?? 0, tex: info.memory.textures, geo: info.memory.geometries };
    const was = this.prev;
    this.prev = now;
    const work = s.updateMs + s.renderMs;
    if (was.shaders < 0 || work <= HITCH_MS) return;
    const parts = [`${Math.round(work)} ms (logic ${Math.round(s.updateMs)} / draw ${Math.round(s.renderMs)})`];
    const dS = now.shaders - was.shaders, dT = now.tex - was.tex, dG = now.geo - was.geo;
    if (dS > 0) parts.push(`+${dS} shaders`);
    if (dT > 0) parts.push(`+${dT} textures`);
    if (dG > 0) parts.push(`+${dG} meshes`);
    if (dS <= 0 && dT <= 0 && dG <= 0) parts.push(s.updateMs > s.renderMs ? 'game logic' : 'no new resources');
    const t = new Date();
    const stamp = `${String(t.getMinutes()).padStart(2, '0')}:${String(t.getSeconds()).padStart(2, '0')}`;
    this.hitchLog.unshift(`  ${stamp}  ${parts.join('  ')}`);
    if (this.hitchLog.length > 6) this.hitchLog.pop();
    console.info('[fps] stutter', stamp, parts.join(' '));
  }

  /** One processed frame. `renderer.info` must still hold this frame's counts. */
  frame(sample: FrameSample, now: number) {
    if (!this.visible || !this.el) return;
    this.stats.push(sample);
    this.trackHitch(sample);
    if (this.gpu) for (const ms of this.gpu.poll()) this.stats.pushGpu(ms);
    if (now - this.lastPaint < REFRESH_MS) return;
    this.lastPaint = now;
    const cap = budgetFps(settings.fps);
    const s = this.stats.summary(1000 / cap);
    if (!s) return;
    const r = this.src.renderer;
    const info = r.info;
    const canvas = r.domElement;
    const heap = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
    const gpuText = s.gpuMs === null ? (this.gpu === null ? 'n/a' : '…') : `${f1(s.gpuMs)} ms`;
    const lines = [
      `${Math.round(s.fps)} fps   avg ${f1(s.avgMs)} ms   worst ${f1(s.worstMs)} ms   hitches ${s.hitches}/s`,
      `logic ${f1(s.updateMs)} ms   draw ${f1(s.renderMs)} ms   gpu ${gpuText}`,
      `calls ${info.render.calls}   tris ${kilo(info.render.triangles)}   tex ${info.memory.textures}   geo ${info.memory.geometries}   shaders ${info.programs?.length ?? 0}`,
      `${settings.quality} · cap ${settings.fps || 'max'} · ${canvas.width}×${canvas.height} (res ${Math.round(this.src.resolutionScale() * 100)}%)` +
        (heap ? ` · heap ${Math.round(heap.usedJSHeapSize / 1048576)} MB` : ''),
      `→ ${VERDICT_TEXT[s.verdict]}`,
      ...(this.hitchLog.length ? ['', 'recent stutters (this frame\'s work):', ...this.hitchLog] : []),
    ];
    this.el.textContent = lines.join('\n');
    this.el.style.borderColor = s.verdict === 'ok' ? 'rgba(120, 200, 120, 0.45)' : 'rgba(230, 120, 90, 0.6)';
  }
}
