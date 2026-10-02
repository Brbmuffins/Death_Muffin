import * as THREE from 'three';
import { EffectComposer } from 'three/examples/jsm/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/examples/jsm/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/examples/jsm/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/examples/jsm/postprocessing/OutputPass.js';
import { ResolutionGovernor, budgetFps, shouldProcessFrame, shouldRender } from './framePacing';
import { onSettingsChange, settings } from './settings';

/** What a scene hands the runtime: something to draw and a per-frame tick. */
export interface RuntimeView {
  scene: THREE.Scene;
  camera: THREE.PerspectiveCamera;
  update(dt: number, now: number): void;
  /** AFK-only simulation while hidden, without rendering or adding combat ticks. */
  backgroundUpdate?(seconds: number): Promise<void>;
  bloom?: { strength: number; radius: number; threshold: number };
}

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

  /** Smoothed frame time, exposed for the debug overlay / perf checks. */
  frameMs = 16.7;

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
    // Error checks read the shader logs synchronously, stalling on every compile; dev builds keep them.
    renderer.debug.checkShaderErrors = import.meta.env.DEV;
    this.renderer = renderer;

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
    const ratio = (high ? Math.min(window.devicePixelRatio, 1.5) : 1) * this.resolution.scale;
    this.renderer.setPixelRatio(ratio);
    this.composer.setPixelRatio(ratio);
    this.renderer.shadowMap.enabled = high;
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

  get shadowsEnabled() {
    return this.renderer.shadowMap.enabled;
  }

  setView(view: RuntimeView | null) {
    this.view = view;
    // A scene swap is a load: slow frames around it are not a GPU problem.
    this.resolution.hold();
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
      const t = performance.now();
      // Frame cap: skip before touching the clock so the next dt covers the whole gap.
      if (!shouldProcessFrame(t, this.lastFrameAt, settings.fps)) return;
      this.lastFrameAt = t;
      const dt = Math.min(this.clock.getDelta(), 0.1);
      this.frameMs += (dt * 1000 - this.frameMs) * 0.05;
      const view = this.view;
      if (!view) {
        this.renderer.clear();
        return;
      }
      view.update(dt, this.now());
      // update() may have swapped the view (scene transition) — render the current one.
      const current = this.view;
      if (!current) return;
      // A full-screen panel on a phone hides the 3D view: keep simulating, but redraw rarely.
      const covered = document.body.classList.contains('dm-panel-open') && !!this.compactMq?.matches;
      if (!shouldRender(t, this.lastRenderAt, covered)) return;
      this.lastRenderAt = t;
      if (this.bloomEnabled) this.composer.render(dt);
      else this.renderer.render(current.scene, current.camera);
      if (!covered && settings.autoResolution && this.resolution.frame(dt, this.frameMs, budgetFps(settings.fps))) this.applyQuality();
    };
    loop();
    this.backgroundTimer = window.setInterval(() => {
      if (!document.hidden || this.backgroundBusy) return;
      const elapsed = this.clock.getDelta();
      if (!this.view?.backgroundUpdate) return;
      this.backgroundBusy = true;
      void this.view.backgroundUpdate(Math.min(elapsed, 90)).catch(console.error).finally(() => { this.backgroundBusy = false; });
    }, 1000);
  }

  stop() {
    cancelAnimationFrame(this.raf);
    window.clearInterval(this.backgroundTimer);
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
      if (this.bloomEnabled) this.composer.render(step);
      else this.renderer.render(v.scene, v.camera);
    }
  }

  private qaClock = 0;

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
