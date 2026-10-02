import * as THREE from 'three';

/**
 * First-draw hitch fix: three compiles shader programs and uploads textures synchronously the first time a mesh is
 * rendered, which froze the frame whenever a new creature type spawned. Creature calls `warmModel` before it attaches
 * a freshly cloned body, so the compile runs in parallel (KHR_parallel_shader_compile) and the uploads are spread over
 * a few frames; the body only becomes visible once its first draw is cheap.
 */
export interface WarmContext {
  renderer: THREE.WebGLRenderer;
  camera: THREE.Camera;
  /** The live scene: its lights and fog decide which program variants the real draw needs. */
  scene: THREE.Scene;
}

let ctx: WarmContext | null = null;
/** Set once the world scene is lit; creatures built before that (and in tests) attach immediately. */
export function setWarmContext(next: WarmContext | null) {
  ctx = next;
}
export const hasWarmContext = () => ctx !== null;

/** Give up waiting after this long and attach anyway (hidden tab, stalled driver); the warm keeps going meanwhile. */
const WARM_TIMEOUT_MS = 5000;
/** Texture uploads per animation frame. */
const UPLOADS_PER_FRAME = 2;

/**
 * Uploads textures a couple per frame. A texture is uploaded once (WeakSet); asking again for one that is queued or
 * done returns the same promise. `upload` and `schedule` are injectable for tests.
 */
export class UploadQueue {
  private done = new WeakSet<THREE.Texture>();
  private waiting = new Map<THREE.Texture, Promise<void>>();
  private queue: { tex: THREE.Texture; resolve: () => void }[] = [];
  private scheduled = false;

  constructor(
    private upload: (tex: THREE.Texture) => void,
    private perFrame = UPLOADS_PER_FRAME,
    private schedule: (fn: () => void) => void = (fn) => requestAnimationFrame(fn),
  ) {}

  enqueue(tex: THREE.Texture): Promise<void> {
    if (this.done.has(tex)) return Promise.resolve();
    let p = this.waiting.get(tex);
    if (p) return p;
    p = new Promise<void>((resolve) => this.queue.push({ tex, resolve }));
    this.waiting.set(tex, p);
    this.pump();
    return p;
  }

  get pending() {
    return this.queue.length;
  }

  private pump() {
    if (this.scheduled || !this.queue.length) return;
    this.scheduled = true;
    this.schedule(() => {
      this.scheduled = false;
      for (const job of this.queue.splice(0, this.perFrame)) {
        try {
          this.upload(job.tex);
        } catch (err) {
          console.warn('[graphics] texture warm failed', err);
        }
        this.done.add(job.tex);
        this.waiting.delete(job.tex);
        job.resolve();
      }
      this.pump();
    });
  }
}

/** Every texture a material references (maps, normal/roughness/emissive maps, …). */
export function materialTextures(mats: Iterable<THREE.Material>): Set<THREE.Texture> {
  const out = new Set<THREE.Texture>();
  for (const m of mats) for (const v of Object.values(m)) if ((v as THREE.Texture)?.isTexture) out.add(v as THREE.Texture);
  return out;
}

/** One promise per (template, program-variant signature): the second creature of a type skips straight through. */
export class WarmOnce {
  private byKey = new WeakMap<object, Map<string, Promise<void>>>();
  run(key: object, sig: string, make: () => Promise<void>): Promise<void> {
    let m = this.byKey.get(key);
    if (!m) this.byKey.set(key, (m = new Map()));
    let p = m.get(sig);
    if (!p) m.set(sig, (p = make()));
    return p;
  }
}

let uploads: UploadQueue | null = null;
let uploadsFor: THREE.WebGLRenderer | null = null;
const once = new WarmOnce();

/**
 * Resolves when `model` (whose materials are already cloned and varianted) can be drawn without a first-use stall.
 * `template` + `sig` identify the program variant so a type that is already warm costs nothing. Never rejects.
 */
export function warmModel(model: THREE.Object3D, mats: Iterable<THREE.Material>, template: object, sig: string): Promise<void> {
  const c = ctx;
  if (!c || (typeof document !== 'undefined' && document.hidden)) return Promise.resolve();
  const warm = once.run(template, sig, async () => {
    if (!uploads || uploadsFor !== c.renderer) {
      uploadsFor = c.renderer;
      uploads = new UploadQueue((t) => c.renderer.initTexture(t));
    }
    const q = uploads;
    try {
      await Promise.all([c.renderer.compileAsync(model, c.camera, c.scene), ...[...materialTextures(mats)].map((t) => q.enqueue(t))]);
    } catch (err) {
      console.warn('[graphics] model warm failed', err);
    }
  });
  return Promise.race([warm, new Promise<void>((r) => setTimeout(r, WARM_TIMEOUT_MS))]);
}

/**
 * Runs `tasks` one after another, each when the browser is idle, so background preloading never competes with a fight.
 * Returns a cancel function.
 */
export function runIdleSequence(tasks: (() => Promise<unknown>)[]): () => void {
  let cancelled = false;
  let i = 0;
  const idle = (fn: () => void) => (typeof requestIdleCallback === 'function' ? requestIdleCallback(fn, { timeout: 2000 }) : setTimeout(fn, 200));
  const step = () => {
    if (cancelled || i >= tasks.length) return;
    const task = tasks[i++];
    Promise.resolve()
      .then(task)
      .catch((err) => console.warn('[graphics] preload failed', err))
      .then(() => idle(step));
  };
  idle(step);
  return () => {
    cancelled = true;
  };
}
