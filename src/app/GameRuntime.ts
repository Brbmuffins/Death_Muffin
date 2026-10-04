import * as THREE from 'three';
import { EffectComposer } from 'three/examples/jsm/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/examples/jsm/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/examples/jsm/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/examples/jsm/postprocessing/OutputPass.js';
import { ShadowCadence } from '../graphics/shadowCadence';
import { ResolutionGovernor, budgetFps, shouldProcessFrame, shouldRender } from './framePacing';
import { perfFrame } from '../net/perfBeacon';
import { onSettingsChange, settings } from './settings';
import { AFK_AWAY_CAP_S, AwayClock, catchUpSeconds } from './awayClock';
import { FpsOverlay } from '../ui/FpsOverlay';

/** What a scene hands the runtime: something to draw and a per-frame tick. */
export interface RuntimeView {
  scene: THREE.Scene;
  camera: THREE.PerspectiveCamera;
  update(dt: number, now: number): void;
  /** AFK-only simulation while hidden, without rendering or adding combat ticks. */
  backgroundUpdate?(seconds: number): Promise<void>;
  /**
   * The page is back after being away (phone app switch, frozen tab). `awaySeconds` is the capped time to catch up
   * (0 for a plain resume). Catch up AFK progress only; never stop AFK because of the absence.
   */
  resumed?(awaySeconds: number): Promise<void>;
  bloom?: { strength: number; radius: number; threshold: number };
}

/** Gravecrawl-style render budget: 1.25x is crisp enough for the 3D layer (the HUD is DOM) and saves ~30% of the pixels vs 1.5x. */
export const HIGH_DPR_CAP = 1.25;
const DEFAULT_BLOOM = { strength: 0.85, radius: 0.55, threshold: 0.82 };

/**
 * One WebGL renderer for the whole app lifetime. Scenes no longer create or
 * dispose renderers — they swap the active view. This removes per-transition
 * shader churn and the leaked resize listeners the old fitToWindow() caused.
 */
export class GameRuntime {
  readonly renderer: THREE.WebGLRenderer;
  private composer: EffectComposer;
  private renderPass: RenderPass;
  private bloomPass: UnrealBloomPass;
  private view: RuntimeView | null = null;
  private clock = new THREE.Clock();
  private raf = 0;
  private backgroundTimer = 0;
  private backgroundBusy = false;
  private away = new AwayClock(Date.now());
  private resumeQueued = false;
  /** The page was really hidden/frozen since the last resume. A long main-thread stall while visible is not an absence. */
  private wentAway = false;
  private bloomEnabled = true;
  private lastFrameAt = 0;
  private lastRenderAt = 0;
  private compactMq: MediaQueryList | null = (() => {
    try {
      return window.matchMedia('(pointer: coarse) and (max-width: 760px), (pointer: coarse) and (max-height: 520px)');
    } catch {
      return null;
    }
  })();
  private shadows = new ShadowCadence();

  /** Smoothed frame time, exposed for the debug overlay / perf checks. */
  frameMs = 16.7;
  /** F3 / ?fps performance overlay. */
  private overlay: FpsOverlay | null = null;

  constructor(canvas: HTMLCanvasElement) {
    const renderer = new THREE.WebGLRenderer({
      canvas,
      antialias: true,
      powerPreference: 'high-performance',
    });
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.2;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    // Shadows refresh at ~30 Hz (ShadowCadence) instead of every frame: the loop sets needsUpdate on the frames that are due.
    renderer.shadowMap.autoUpdate = false;
    // Error checks read the shader logs synchronously, stalling on every compile; dev builds keep them.
    renderer.debug.checkShaderErrors = import.meta.env.DEV;
    this.renderer = renderer;
    renderer.info.autoReset = false;

    this.composer = new EffectComposer(renderer);
    this.renderPass = new RenderPass(new THREE.Scene(), new THREE.PerspectiveCamera());
    this.bloomPass = new UnrealBloomPass(
      new THREE.Vector2(window.innerWidth, window.innerHeight),
      DEFAULT_BLOOM.strength,
      DEFAULT_BLOOM.radius,
      DEFAULT_BLOOM.threshold,
    );
    this.composer.addPass(this.renderPass);
    this.composer.addPass(this.bloomPass);
    this.composer.addPass(new OutputPass());

    window.addEventListener('resize', this.resize);
    onSettingsChange(() => this.applyQuality());
    this.applyQuality();
    this.overlay = new FpsOverlay({ renderer, resolutionScale: () => this.resolution.scale });
  }

  /** Lowers the render resolution while the GPU can't hold the frame cap (see ResolutionGovernor). */
  readonly resolution = new ResolutionGovernor();
  private qualityKey = '';

  private applyQuality() {
    const high = settings.quality === 'high';
    // Any settings change lands here; only a graphics change restarts the governor at full resolution.
    const key = `${settings.quality}|${settings.fps}|${settings.autoResolution}`;
    if (key !== this.qualityKey) {
      this.qualityKey = key;
      this.resolution.reset();
      this.resolution.hold();
    }
    const ratio = (high ? Math.min(window.devicePixelRatio, HIGH_DPR_CAP) : 1) * this.resolution.scale;
    this.renderer.setPixelRatio(ratio);
    this.composer.setPixelRatio(ratio);
    this.renderer.shadowMap.enabled = high;
    this.shadows.force();
    this.bloomEnabled = high;
    this.resize();
  }

  private resize = () => {
    const w = window.innerWidth;
    const h = window.innerHeight;
    this.renderer.setSize(w, h);
    this.composer.setSize(w, h);
    if (this.view) {
      this.view.camera.aspect = w / h;
      this.view.camera.updateProjectionMatrix();
    }
  };

  /** The next frame re-renders the shadow map (teleport, area change: the old one is for somewhere else). */
  refreshShadows() {
    this.shadows.force();
  }

  get shadowsEnabled() {
    return this.renderer.shadowMap.enabled;
  }

  setView(view: RuntimeView | null) {
    this.view = view;
    // A scene swap is a load: slow frames around it are not a GPU problem.
    this.resolution.hold();
    this.shadows.force();
    if (view) {
      this.renderPass.scene = view.scene;
      this.renderPass.camera = view.camera;
      const b = view.bloom ?? DEFAULT_BLOOM;
      this.bloomPass.strength = b.strength;
      this.bloomPass.radius = b.radius;
      this.bloomPass.threshold = b.threshold;
      this.resize();
    }
  }

  start() {
    const loop = () => {
      this.raf = requestAnimationFrame(loop);
      if (document.hidden) return;
      // A frame after a long stall (a frozen phone tab thawing before any event reached us) is an absence too.
      this.resumeNow(false);
      const t = performance.now();
      // Frame cap: skip before touching the clock so the next dt covers the whole gap.
      if (!shouldProcessFrame(t, this.lastFrameAt, settings.fps)) return;
      const gapMs = this.lastFrameAt > 0 ? t - this.lastFrameAt : 0; // unclamped, unlike dt: the overlay's worst frame must show a 300 ms hitch as 300
      this.lastFrameAt = t;
      perfFrame(t);
      const dt = Math.min(this.clock.getDelta(), 0.1);
      this.frameMs += (dt * 1000 - this.frameMs) * 0.05;
      const view = this.view;
      if (!view) {
        this.renderer.clear();
        return;
      }
      view.update(dt, this.now());
      const tUpdated = performance.now();
      // update() may have swapped the view (scene transition) — render the current one.
      const current = this.view;
      if (!current) return;
      // A full-screen panel on a phone hides the 3D view: keep simulating, but redraw rarely.
      const covered = document.body.classList.contains('dm-panel-open') && !!this.compactMq?.matches;
      if (!shouldRender(t, this.lastRenderAt, covered)) return;
      this.lastRenderAt = t;
      this.renderer.shadowMap.needsUpdate = this.shadows.due(t);
      this.renderer.info.reset(); // autoReset is off: calls/triangles below cover every pass of this frame (perf beacon)
      this.overlay?.beginGpu();
      if (this.bloomEnabled) this.composer.render(dt);
      else this.renderer.render(current.scene, current.camera);
      this.overlay?.endGpu();
      if (this.overlay?.visible) {
        const tDrawn = performance.now();
        this.overlay.frame({ frameMs: gapMs, updateMs: tUpdated - t, renderMs: tDrawn - tUpdated }, tDrawn);
      }
      if (!covered && settings.autoResolution && this.resolution.frame(dt, this.frameMs, budgetFps(settings.fps))) this.applyQuality();
    };
    loop();
    this.backgroundTimer = window.setInterval(() => {
      if (!document.hidden || this.backgroundBusy) return;
      this.wentAway = true;
      // Wall clock, not the frame clock: a throttled or briefly thawed tab must count every second it was away.
      const elapsed = this.away.lap(Date.now());
      this.clock.getDelta();
      if (!this.view?.backgroundUpdate || elapsed <= 0) return;
      this.backgroundBusy = true;
      void this.view.backgroundUpdate(Math.min(elapsed, AFK_AWAY_CAP_S)).catch(console.error).finally(() => {
        this.backgroundBusy = false;
        if (this.resumeQueued) this.resumeNow(true);
      });
    }, 1000);
    document.addEventListener('visibilitychange', this.onVisibility);
    window.addEventListener('pageshow', this.onResumeEvent);
    document.addEventListener('resume', this.onResumeEvent);
    window.addEventListener('pagehide', this.onHideEvent);
    document.addEventListener('freeze', this.onHideEvent);
  }

  private onVisibility = () => {
    if (document.hidden) this.onHideEvent();
    else this.resumeNow(true);
  };
  private onResumeEvent = () => this.resumeNow(true);
  /** Hidden / frozen / leaving: bank the visible time so the wall-clock mark is exactly when we went away. */
  private onHideEvent = () => {
    this.wentAway = true;
    if (!this.backgroundBusy) this.away.lap(Date.now());
  };

  /**
   * Back in front of the player. Takes the unsimulated wall-clock gap (shared with the hidden-tab interval, so nothing
   * is counted twice), caps it, and hands it to the view's AFK catch-up. `force` also notifies the view of a resume
   * that had no gap, so it can guard against the return tap.
   */
  private resumeNow(force: boolean) {
    if (document.hidden) return;
    // A tick or catch-up is mid-flight: come back to this the moment it lands, so the return is never skipped.
    if (this.backgroundBusy) { if (force) this.resumeQueued = true; return; }
    this.resumeQueued = false;
    const gap = this.away.lap(Date.now());
    // Only a real hide/freeze counts: a visible stall (slow device, long task) must not pop a ledger or close the player's panels.
    const seconds = this.wentAway ? catchUpSeconds(gap) : 0;
    this.wentAway = false;
    if (!seconds && !force) return;
    const view = this.view;
    if (!view?.resumed) return;
    this.backgroundBusy = true;
    void view.resumed(seconds).catch(console.error).finally(() => {
      this.backgroundBusy = false;
      if (this.resumeQueued) this.resumeNow(true);
    });
  }

  stop() {
    cancelAnimationFrame(this.raf);
    window.clearInterval(this.backgroundTimer);
    document.removeEventListener('visibilitychange', this.onVisibility);
    window.removeEventListener('pageshow', this.onResumeEvent);
    document.removeEventListener('resume', this.onResumeEvent);
    window.removeEventListener('pagehide', this.onHideEvent);
    document.removeEventListener('freeze', this.onHideEvent);
  }

  /**
   * QA helper: advance the active view deterministically in fixed steps, then
   * render once. Hidden browser panes throttle requestAnimationFrame, so
   * automated checks drive time explicitly instead of waiting on the loop.
   */
  advance(seconds: number, step = 1 / 60, render = true) {
    this.qaClock = Math.max(this.qaClock, performance.now());
    for (let i = 0, n = Math.round(seconds / step); i < n && this.view; i++) {
      this.qaClock += step * 1000;
      this.view.update(step, this.qaClock);
    }
    const v = this.view;
    if (v && render) {
      this.renderer.shadowMap.needsUpdate = true; // QA stepping: every rendered frame is a shadow frame
      if (this.bloomEnabled) this.composer.render(step);
      else this.renderer.render(v.scene, v.camera);
    }
  }

  private qaClock = 0;

  private warmTarget: THREE.WebGLRenderTarget | null = null;
  private tinyTarget() {
    // Same flavour of target the composer's RenderPass draws into (half-float, linear), so program keys match; 4x4 so it costs nothing.
    return (this.warmTarget ??= new THREE.WebGLRenderTarget(4, 4, { type: THREE.HalfFloatType }));
  }

  /**
   * Warm-up draw of the active view (see graphics/warmRender.ts). Full: exactly the frame path (composer on High). Small: the same scene state
   * into a 4x4 target (or a 1 px scissor with bloom off), so programs, depth variants, geometry and texture uploads happen without a full-size pass.
   */
  warmRender(small: boolean): boolean {
    const v = this.view;
    if (!v) return false;
    this.renderer.shadowMap.needsUpdate = true;
    if (!small) {
      if (this.bloomEnabled) this.composer.render(0);
      else this.renderer.render(v.scene, v.camera);
      return true;
    }
    const r = this.renderer;
    if (this.bloomEnabled) {
      r.setRenderTarget(this.tinyTarget());
      try { r.render(v.scene, v.camera); } finally { r.setRenderTarget(null); }
    } else {
      r.setScissorTest(true);
      r.setScissor(0, 0, 1, 1);
      try { r.render(v.scene, v.camera); } finally { r.setScissorTest(false); }
    }
    return true;
  }

  /** The target real frames draw into (null: the screen, bloom off), for compiling the right program flavour. */
  frameTarget(): THREE.WebGLRenderTarget | null {
    return this.bloomEnabled ? this.tinyTarget() : null;
  }

  /** Parallel shader compile of `obj` for the same target flavour as `warmRender(small)`. */
  async warmCompile(obj: THREE.Object3D, small: boolean): Promise<void> {
    const v = this.view;
    if (!v) return;
    const r = this.renderer;
    const rt = this.bloomEnabled ? this.tinyTarget() : null;
    let p: Promise<unknown>;
    r.setRenderTarget(rt);
    try { p = r.compileAsync(obj, v.camera, v.scene); } finally { r.setRenderTarget(null); }
    await p;
  }

  /** QA: render the current view and read the canvas back as a data URL. */
  capture(type = 'image/webp', quality = 0.9): string | null {
    const v = this.view;
    if (!v) return null;
    if (this.bloomEnabled) this.composer.render(1 / 60);
    else this.renderer.render(v.scene, v.camera);
    return this.renderer.domElement.toDataURL(type, quality);
  }

  /** Monotonic clock shared by the RAF loop and advance(). */
  now() {
    return Math.max(performance.now(), this.qaClock);
  }
}

let runtime: GameRuntime | null = null;

export function initRuntime(canvas: HTMLCanvasElement): GameRuntime {
  runtime = new GameRuntime(canvas);
  runtime.start();
  return runtime;
}

export function getRuntime(): GameRuntime {
  if (!runtime) throw new Error('GameRuntime not initialised');
  return runtime;
}
