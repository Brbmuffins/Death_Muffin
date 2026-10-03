import * as THREE from 'three';
import { runIdleSequence } from './warmModel';

/**
 * Warm-up RENDER. `warmModel` compiles a body's own material and uploads its textures, but a real draw also needs the variants only the
 * live scene asks for: the shadow depth / skinned depth programs (WebGLShadowMap), the render-target flavour of each program when the bloom
 * composer is on, fog / light state, geometry buffers and the bone textures. Compiling those on first spawn froze fights on D3D11.
 *
 * So bodies are staged: built, placed in front of the real camera in the REAL scene, drawn once through the same path as a frame
 * (`StageHost.render`), then removed. Their materials stay pinned by Creature (first body per template + variant), so the programs live on.
 */

/** Something the stage can draw: a Creature fits. */
export interface StageBody {
  root: THREE.Object3D;
  ready: Promise<unknown>;
  dispose(): void;
}

export interface StageHost {
  scene: THREE.Scene;
  camera: THREE.Camera;
  /** Where the camera is looking (ground point). */
  focus: () => { x: number; z: number };
  /** Compile `obj`'s programs ahead (in parallel where the driver supports it), for the same target flavour as `render(small)`. */
  compile: (obj: THREE.Object3D, small: boolean) => Promise<void>;
  /** Draws the scene as a real frame. `small`: a tiny target instead of the screen / composer, same programs. Returns false if it could not. */
  render: (small: boolean) => boolean;
  /** QA: how many shader programs exist now (renderer.info.programs). */
  programs?: () => number;
}

/** QA log of every stage draw: which bodies, small or full, programs it created. */
export const stageLog: { slugs: string[]; small: boolean; newPrograms: number; ms: number }[] = [];
(globalThis as unknown as { __dmStageLog?: unknown }).__dmStageLog = stageLog;

/** One body's worth of ground in the grid, metres. */
export const STAGE_SPACING = 2.1;

/** Pure: positions for `n` bodies, `cols` per row, centred on the origin (so they sit in the middle of the view). */
export function gridLayout(n: number, cols: number, spacing = STAGE_SPACING): { x: number; z: number }[] {
  const out: { x: number; z: number }[] = [];
  const rows = Math.ceil(n / cols);
  for (let i = 0; i < n; i++) {
    const r = Math.floor(i / cols);
    const c = i % cols;
    const inRow = Math.min(cols, n - r * cols);
    out.push({ x: (c - (inRow - 1) / 2) * spacing, z: (r - (rows - 1) / 2) * spacing });
  }
  return out;
}

/** Pure: split into slices of at most `size` (at least 1). */
export function slices<T>(items: readonly T[], size: number): T[][] {
  const s = Math.max(1, Math.floor(size));
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += s) out.push(items.slice(i, i + s));
  return out;
}

/** Pure: keys not yet claimed; claims them. A key is staged once per session however many callers ask. */
export function claimKeys(claimed: Set<string>, keys: readonly string[]): string[] {
  const fresh: string[] = [];
  for (const k of keys) if (!claimed.has(k)) {
    claimed.add(k);
    fresh.push(k);
  }
  return fresh;
}

/** Pure: label-free progress of a staging run, 0..1. */
export const stageProgress = (doneBodies: number, total: number) => (total <= 0 ? 1 : Math.max(0, Math.min(1, doneBodies / total)));

export interface StageResult {
  staged: number;
  /** Bodies that were not drawn in time (still built and loading: hand `rest` to `stageLate`). */
  skipped: number;
  rest: StageBody[];
  /** Bodies whose root was outside the camera frustum when drawn (they would not have warmed). */
  outOfView: number;
  ms: number;
}

/** Hides every top-level branch of the scene that has no light in it (lights inside stay: their count is part of every program's key). Returns the undo. */
function isolate(scene: THREE.Scene, keep: THREE.Object3D): () => void {
  const hidden: THREE.Object3D[] = [];
  for (const child of scene.children) {
    if (child === keep || !child.visible || (child as THREE.Light).isLight) continue;
    let hasLight = false;
    child.traverse((o) => {
      if ((o as THREE.Light).isLight) hasLight = true;
    });
    if (hasLight) continue;
    child.visible = false;
    hidden.push(child);
  }
  return () => {
    for (const o of hidden) o.visible = true;
  };
}

/** The transparent twins drawn by the stage: referenced for the session so nothing ever disposes them (their programs stay compiled). */
const pinnedTwins: THREE.Material[] = [];

const frustum = new THREE.Frustum();
const projScreen = new THREE.Matrix4();

/** Free a staged body's per-instance GPU leftovers (bone texture); pinned materials / shared geometry stay. */
function release(b: StageBody) {
  b.root.traverse((o) => (o as THREE.SkinnedMesh).skeleton?.dispose());
  b.dispose();
}

/**
 * Draws `bodies` once (in batches of `batch`) in the real scene, then removes them. Waits for each body's `ready` (up to `deadline`, a
 * performance.now() timestamp). Never throws; whatever it could not do is simply left to the normal first-draw path.
 * `small`: draw into a tiny target (idle-time slices in play); otherwise the real frame path, twice (the veil hides it).
 */
export async function stageBodies(host: StageHost, bodies: readonly StageBody[], o: { small: boolean; batch?: number; deadline: number; onProgress?: (f: number) => void; now?: () => number }): Promise<StageResult> {
  const now = o.now ?? (() => performance.now());
  const t0 = now();
  const res: StageResult = { staged: 0, skipped: 0, rest: [], outOfView: 0, ms: 0 };
  const batch = Math.max(1, o.batch ?? 16);
  // Bodies are staged as they become ready (a slow GLB never holds the others back): a batch goes out when it is full, or when nothing
  // more is arriving soon, or the stage is out of time.
  const state = bodies.map(() => 'wait' as 'wait' | 'ok' | 'bad' | 'done');
  bodies.forEach((b, i) =>
    b.ready.then(
      () => { state[i] = b.root.children.length ? 'ok' : 'bad'; },
      () => { state[i] = 'bad'; },
    ),
  );
  let finished = 0;
  let lastGo = t0;
  while (finished < bodies.length) {
    const t = now();
    const idx: number[] = [];
    state.forEach((st, i) => { if (st === 'ok') idx.push(i); });
    for (let i = 0; i < bodies.length; i++) if (state[i] === 'bad') {
      state[i] = 'done';
      finished++;
      try { release(bodies[i]); } catch { /* already gone */ }
    }
    const waiting = state.filter((st) => st === 'wait').length;
    if (t >= o.deadline) break;
    if (idx.length && (idx.length >= batch || !waiting || t - lastGo > 350)) {
      const ready = idx.slice(0, batch).map((i) => bodies[i]);
      for (const i of idx.slice(0, batch)) state[i] = 'done';
      finished += ready.length;
      lastGo = t;
      await stageOne(host, ready, o.small, o.deadline, now, res);
      o.onProgress?.(stageProgress(finished, bodies.length));
      await new Promise((r) => setTimeout(r, 0));
      continue;
    }
    await new Promise((r) => setTimeout(r, 40));
  }
  // Whatever is still loading when time ran out is staged later in small idle slices (stageLate).
  for (let i = 0; i < bodies.length; i++) if (state[i] !== 'done') res.rest.push(bodies[i]);
  res.skipped = res.rest.length;
  res.ms = Math.round(now() - t0);
  return res;
}

async function stageOne(host: StageHost, ready: StageBody[], small: boolean, deadline: number, now: () => number, res: StageResult) {
  const group = new THREE.Group();
  group.name = 'warm-stage';
  try {
    const f = host.focus();
    const pos = gridLayout(ready.length, Math.min(8, ready.length));
    ready.forEach((b, i) => {
      b.root.position.set(f.x + pos[i].x, 0, f.z + pos[i].z);
      group.add(b.root);
    });
    // Shadow-LOD turns casting on for near bodies, props included (held props never cast on their own): stage them casting so every depth
    // variant (double-sided props, skinned depth) is compiled. Spectral bodies (transparent, no depth write) never cast, as in play.
    group.traverse((o) => {
      const m = o as THREE.Mesh;
      if (!m.isMesh) return;
      const mat = m.material as THREE.Material | THREE.Material[];
      const ghost = (Array.isArray(mat) ? mat : [mat]).some((x) => x.transparent && !x.depthWrite);
      m.castShadow = !ghost;
    });
    host.scene.add(group);
    host.scene.updateMatrixWorld(true);
    host.camera.updateMatrixWorld();
    projScreen.multiplyMatrices((host.camera as THREE.PerspectiveCamera).projectionMatrix, host.camera.matrixWorldInverse);
    frustum.setFromProjectionMatrix(projScreen);
    for (const b of ready) if (!frustum.containsPoint(new THREE.Vector3(b.root.position.x, 1, b.root.position.z))) res.outOfView++;
    // Parallel compile first (does not stall the page), then the real draw does the rest synchronously.
    await Promise.race([host.compile(group, small).catch(() => undefined), new Promise<void>((r) => setTimeout(r, Math.max(500, deadline - now())))]);
    // The group may have been pulled out by a scene teardown while waiting.
    if (group.parent === host.scene) {
      const p0 = host.programs?.() ?? 0;
      const t0 = now();
      const undo = small ? isolate(host.scene, group) : () => {};
      try {
        host.render(small);
        // Second draw with every caster's depth pass double-sided: a DoubleSide GLB material (cloaks, wings) needs its own depth program
        // and nothing else on screen tells us which bodies have one. `shadowSide` touches only the depth variant, never the colour program.
        const mats = new Set<THREE.Material>();
        group.traverse((o) => {
          const m = (o as THREE.Mesh).material as THREE.Material | THREE.Material[] | undefined;
          if (m) for (const x of Array.isArray(m) ? m : [m]) mats.add(x);
        });
        for (const m of mats) m.shadowSide = THREE.DoubleSide;
        try {
          host.render(small);
        } finally {
          for (const m of mats) m.shadowSide = null;
        }
        // Corpses fade out and the shrouded fade: a transparent DoubleSide material is drawn in two passes (back faces, then front), each its own
        // program, and the first fade of every cloaked body compiled them mid-fight. Draw a transparent twin of each such material once.
        const swaps: [THREE.Mesh, THREE.Material][] = [];
        const twins = new Map<THREE.Material, THREE.Material>();
        group.traverse((o) => {
          const mesh = o as THREE.Mesh;
          const m = mesh.material as THREE.Material | THREE.Material[] | undefined;
          if (!mesh.isMesh || !m || Array.isArray(m) || m.side !== THREE.DoubleSide || m.transparent) return;
          let t = twins.get(m);
          if (!t) {
            t = m.clone();
            t.transparent = true;
            t.depthWrite = false;
            // clone() drops the shader hooks (wing flap, friend rim): without them the twin would be a different program.
            t.onBeforeCompile = m.onBeforeCompile;
            t.customProgramCacheKey = m.customProgramCacheKey;
            twins.set(m, t);
            pinnedTwins.push(t);
          }
          swaps.push([mesh, m]);
          mesh.material = t;
        });
        if (swaps.length) {
          try {
            host.render(small);
          } finally {
            for (const [mesh, m] of swaps) mesh.material = m;
          }
        }
      } finally {
        undo();
      }
      stageLog.push({ slugs: ready.map((b) => (b as unknown as { slug?: string }).slug ?? '?'), small, newPrograms: (host.programs?.() ?? 0) - p0, ms: Math.round(now() - t0) });
    }
    res.staged += ready.length;
  } catch (err) {
    console.warn('[graphics] warm stage failed', err);
  } finally {
    group.removeFromParent();
    for (const b of ready) {
      try { release(b); } catch { /* ignore */ }
    }
  }
}

/** Session-wide record of what has been staged (or is queued to be), so login, area entry and neighbours never repeat a body. */
export const stagedKeys = new Set<string>();

/**
 * Idle-time slices: each maker is called only when its slice runs (so no body is built before its turn), `perSlice` bodies at a time, one
 * slice per idle turn, never in a hidden tab. Returns a cancel function; keys that never got their turn are un-claimed so a later area
 * entry can stage them.
 */
export function stageInSlices(host: StageHost, makers: readonly { key: string; make: () => StageBody }[], perSlice = 2): () => void {
  const pending = new Set(makers.map((m) => m.key));
  const tasks = slices(makers, perSlice).map((group) => async () => {
    if (typeof document !== 'undefined' && document.hidden) return;
    for (const m of group) pending.delete(m.key);
    await stageBodies(host, group.map((m) => m.make()), { small: true, batch: perSlice, deadline: performance.now() + 4000 });
  });
  const cancel = runIdleSequence(tasks);
  return () => {
    cancel();
    for (const k of pending) stagedKeys.delete(k);
    pending.clear();
  };
}

/**
 * Bodies the veil had no time for: still staged, a couple per idle turn in the tiny target, each given up to `waitMs` to finish loading.
 * A body that never loads is released. Returns a cancel function.
 */
let latePending = 0;
/** Bodies still waiting for a late stage slice (QA waits on this before measuring). */
export const warmPending = () => latePending;
(globalThis as unknown as { __dmWarmPending?: () => number }).__dmWarmPending = warmPending;

export function stageLate(host: StageHost, bodies: readonly StageBody[], perSlice = 2, waitMs = 20000): () => void {
  let cancelled = false;
  latePending += bodies.length;
  const tasks = slices(bodies, perSlice).map((group) => async () => {
    try {
      if (cancelled || (typeof document !== 'undefined' && document.hidden)) return void group.forEach(release);
      const res = await stageBodies(host, group, { small: true, batch: perSlice, deadline: performance.now() + waitMs });
      for (const b of res.rest) try { release(b); } catch { /* ignore */ }
    } finally {
      latePending -= group.length;
    }
  });
  const cancel = runIdleSequence(tasks);
  return () => {
    cancelled = true;
    cancel();
  };
}
