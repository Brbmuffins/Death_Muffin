/**
 * Gear-versus-animation clearance matrix (docs/GEAR-VISUALS-PLAN.md, Phase 0). Drives a real NecromancerAvatar (the
 * Avatars -> Creature attach / calibrate / follow path) through every clip a hero ships, sampled every 1/15 s, with a
 * main-hand weapon, an off-hand piece, a helm and a cape worn, and records per item and clip:
 *
 *   pen    deepest prop vertex inside the body capsules (torso, chest, head, upper arms, thighs), metres
 *   drift  how far a held prop's tip sits from where a fully hand-driven grip (follow = 1) would put it, metres
 *   gap    how much farther the nearest prop vertex is from the hand bone than at the settled idle pose, metres
 *   float / sink   helm apex above the skull crown past a 9 cm allowance (the fitted dome sits on the hood top; its crest or crown ornaments add up to ~9 cm), or skull pushing through the helm, metres
 *   hem    cape hem vertices inside the thigh / calf capsules, metres
 *
 * Capsule radii come from the skinned mesh itself (a low percentile of the vertices each bone owns, in bind pose), so a
 * hit means the vertex is inside the solid core of the body. Measurement only: nothing here changes how the game renders.
 */
import * as THREE from 'three';
import { expect, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { CREATURE_MODELS } from '../modelPaths';
import { capsuleDepth, creatureTemplate, propPoints, type Capsule } from './propHarness';
import type { ModelTemplate } from '../AssetCache';
import type { NecromancerAvatar as AvatarType } from '../Avatars';

export const HEROES = ['hero_ossuary', 'hero_gravecaller', 'hero_mourner', 'hero_rotweaver'] as const;
export type Hero = (typeof HEROES)[number];
export const MAINS = ['staff', 'scythe', 'wand', 'sickle'] as const;
export const OFFS = ['skull_focus', 'grimoire', 'mourning_bell'] as const;
export const TWO_HANDED = new Set<string>(['staff', 'scythe']);
export const HELM_ID = 'helm_gold';
export const CAPE_ID = 'cape_apprentice';
export const SAMPLE_DT = 1 / 15;
const SIM_DT = 1 / 60;
const SETTLE_FRAMES = 70;
export const LOOPS = new Set(['idle', 'walk', 'run']);
/** Clips sampled by the vitest guard (the full matrix runs in `npm run qa:gear-clip`). */
export const GUARD_CLIPS = ['idle', 'run', 'attack', 'cast', 'dig', 'slam', 'sweep', 'flick', 'channel', 'summon'];
/** Guard configurations: four mains and three off-hands, each covered at least once. */
export const GUARD_CONFIGS: [string, string][] = [['staff', 'skull_focus'], ['scythe', 'mourning_bell'], ['wand', 'grimoire'], ['sickle', 'skull_focus']];

export type MetricKey = 'pen' | 'drift' | 'gap' | 'float' | 'sink' | 'hem' | 'support';
export interface Cell { worst: number; p95: number; t: number }
/** `hero|item|clip|metric` -> stats; item is a weapon kind, an off-hand kind, `helm` or `cape`. */
export type Matrix = Record<string, Cell>;

export function clipNames(hero: string): string[] {
  return (JSON.parse(readFileSync(`public/models/${hero}/clips.json`, 'utf8')) as { clips: string[] }).clips;
}

// --- body capsules from bones + skinned mesh ----------------------------------------------------------------------------

interface Seg { name: string; a: THREE.Object3D; b: THREE.Object3D; bones: RegExp; r: number }
interface HeadRig { bone: THREE.Object3D; upLocal: THREE.Vector3; verts: number[]; mesh: THREE.SkinnedMesh; crownBind: number }
export interface Rig {
  segs: Seg[];
  head: HeadRig;
  hands: { R: THREE.Object3D; L: THREE.Object3D };
  /** Frame cache of capsules by name. */
  capsules: Map<string, Capsule>;
}

const SPECS: [string, string, string, RegExp][] = [
  ['torso', 'Hip', 'Spine02', /^(Hip|Pelvis|Waist|Spine01|Spine02)$/],
  ['chest', 'Spine02', 'Head', /^(Spine02|NeckTwist0\d)$/],
  ['armL', 'L_Upperarm', 'L_Forearm', /^L_Upperarm/],
  ['armR', 'R_Upperarm', 'R_Forearm', /^R_Upperarm/],
  ['thighL', 'L_Thigh', 'L_Calf', /^L_(Thigh|ThighTwist)/],
  ['thighR', 'R_Thigh', 'R_Calf', /^R_(Thigh|ThighTwist)/],
  ['calfL', 'L_Calf', 'L_Foot', /^L_(Calf|CalfTwist)/],
  ['calfR', 'R_Calf', 'R_Foot', /^R_(Calf|CalfTwist)/],
];
export const BODY_CAPS = ['torso', 'chest', 'head', 'armL', 'armR', 'thighL', 'thighR'];
export const LEG_CAPS = ['thighL', 'thighR', 'calfL', 'calfR'];

function distToSeg(p: THREE.Vector3, a: THREE.Vector3, b: THREE.Vector3): number {
  const ab = b.clone().sub(a);
  const t = Math.max(0, Math.min(1, p.clone().sub(a).dot(ab) / Math.max(1e-9, ab.lengthSq())));
  return p.distanceTo(a.clone().addScaledVector(ab, t));
}

function percentile(values: number[], q: number): number {
  if (!values.length) return 0;
  const s = [...values].sort((x, y) => x - y);
  const at = (s.length - 1) * q;
  const lo = Math.floor(at);
  return s[lo] + (s[Math.min(s.length - 1, lo + 1)] - s[lo]) * (at - lo);
}

/** Measure the skinned body in bind pose (call before the avatar's first update). */
export function buildRig(avatar: AvatarType): Rig {
  const root = avatar.c.root;
  root.updateMatrixWorld(true);
  const bone = (n: string) => root.getObjectByName(n)!;
  let mesh: THREE.SkinnedMesh | null = null;
  root.traverse((o) => { if ((o as THREE.SkinnedMesh).isSkinnedMesh && !mesh) mesh = o as THREE.SkinnedMesh; });
  const m = mesh as unknown as THREE.SkinnedMesh;
  m.skeleton.update();
  const names = m.skeleton.bones.map((b) => b.name);
  const si = m.geometry.getAttribute('skinIndex');
  const sw = m.geometry.getAttribute('skinWeight');
  const n = si.count;
  const dominant: string[] = [];
  const bindPos: THREE.Vector3[] = [];
  for (let i = 0; i < n; i++) {
    let best = 0;
    let bw = -1;
    for (let k = 0; k < 4; k++) {
      const w = sw.getComponent(i, k);
      if (w > bw) { bw = w; best = si.getComponent(i, k); }
    }
    dominant.push(names[best]);
    bindPos.push(m.getVertexPosition(i, new THREE.Vector3()).applyMatrix4(m.matrixWorld));
  }
  const wp = (o: THREE.Object3D) => o.getWorldPosition(new THREE.Vector3());
  const segs: Seg[] = SPECS.map(([name, a, b, re]) => {
    const A = wp(bone(a));
    const B = wp(bone(b));
    const d: number[] = [];
    for (let i = 0; i < n; i += 2) if (re.test(dominant[i])) d.push(distToSeg(bindPos[i], A, B));
    return { name, a: bone(a), b: bone(b), bones: re, r: Math.max(0.02, Math.min(0.2, percentile(d, 0.2))) };
  });
  // Head: vertices owned by the Head bone; up = from the bone toward their centroid, in the bone's own frame.
  const headBone = bone('Head');
  const verts: number[] = [];
  for (let i = 0; i < n; i += 2) if (dominant[i] === 'Head') verts.push(i);
  const hp = wp(headBone);
  const centroid = new THREE.Vector3();
  verts.forEach((i) => centroid.add(bindPos[i]));
  centroid.divideScalar(Math.max(1, verts.length));
  const upLocal = headBone.worldToLocal(centroid.clone()).normalize();
  const upW = centroid.clone().sub(hp).normalize();
  const crownBind = Math.max(...verts.map((i) => bindPos[i].clone().sub(hp).dot(upW)));
  const hr = verts.map((i) => { const v = bindPos[i].clone().sub(hp); return v.addScaledVector(upW, -v.dot(upW)).length(); });
  const head: HeadRig = { bone: headBone, upLocal, verts, mesh: m, crownBind };
  segs.push({ name: 'head', a: headBone, b: headBone, bones: /^Head$/, r: Math.max(0.03, Math.min(0.2, percentile(hr, 0.3))) });
  return { segs, head, hands: { R: bone('R_Hand'), L: bone('L_Hand') }, capsules: new Map() };
}

const _up = new THREE.Vector3();
function headUp(rig: Rig): THREE.Vector3 {
  return _up.copy(rig.head.upLocal).transformDirection(rig.head.bone.matrixWorld).normalize();
}

/** Capsules for the current pose (the head is a short capsule from 40% to 75% of the way up to the crown). */
function poseCapsules(rig: Rig) {
  const wp = (o: THREE.Object3D) => o.getWorldPosition(new THREE.Vector3());
  for (const s of rig.segs) {
    if (s.name === 'head') {
      const base = wp(s.a);
      const up = headUp(rig);
      rig.capsules.set('head', { a: base.clone().addScaledVector(up, rig.head.crownBind * 0.4), b: base.clone().addScaledVector(up, rig.head.crownBind * 0.75), r: s.r });
    } else {
      rig.capsules.set(s.name, { a: wp(s.a), b: wp(s.b), r: s.r });
    }
  }
}

function maxDepth(pts: THREE.Vector3[], caps: Capsule[]): number {
  let d = 0;
  for (const p of pts) for (const c of caps) d = Math.max(d, capsuleDepth(p, c));
  return d;
}

// --- measurement ----------------------------------------------------------------------------------------------------

type Access = {
  worn: Map<string, { obj: THREE.Object3D }>;
  cape: { obj: THREE.Object3D } | null;
};
interface PropFrame { obj: THREE.Object3D; hand: THREE.Object3D; tipLocal: THREE.Vector3; rec: { baseQ?: THREE.Quaternion } | undefined }

/** Farthest vertex from the grip (the prop's origin), in the prop's own frame. */
function farthest(obj: THREE.Object3D): THREE.Vector3 {
  obj.updateWorldMatrix(true, true);
  const inv = new THREE.Matrix4().copy(obj.matrixWorld).invert();
  let best = new THREE.Vector3(0, 1, 0);
  let bd = 0;
  for (const p of propPoints(obj, 400)) {
    const l = p.clone().applyMatrix4(inv);
    if (l.length() > bd) { bd = l.length(); best = l; }
  }
  return best;
}

/** Where the tip would be if the prop rode the wrist rigidly: the calibrated hand-relative pose (`baseQ`) with no steadying. */
function rigidTip(f: PropFrame): THREE.Vector3 | null {
  const q = f.rec?.baseQ;
  const parent = f.obj.parent;
  if (!q || !parent) return null;
  const pm = parent.matrixWorld;
  const m = new THREE.Matrix4().compose(f.obj.position, q, f.obj.scale);
  return f.tipLocal.clone().applyMatrix4(m).applyMatrix4(pm);
}

function nearest(pts: THREE.Vector3[], p: THREE.Vector3): number {
  let d = Infinity;
  for (const q of pts) d = Math.min(d, q.distanceTo(p));
  return d;
}

class Series {
  vals: number[] = [];
  ts: number[] = [];
  push(v: number, t: number) { this.vals.push(v); this.ts.push(t); }
  cell(): Cell {
    let wi = 0;
    this.vals.forEach((v, i) => { if (v > this.vals[wi]) wi = i; });
    return { worst: this.vals[wi] ?? 0, p95: percentile(this.vals, 0.95), t: this.ts[wi] ?? 0 };
  }
}

export interface Support { min: number; med: number }

/** Run one equipment configuration through `clips`; returns cells per `item|clip|metric` and support-hand distances. */
export async function measureConfig(
  Avatar: typeof AvatarType,
  hero: Hero,
  main: string,
  off: string,
  clips: string[],
  store: { models: Map<string, ModelTemplate> },
): Promise<{ cells: Record<string, Cell>; support: Record<string, Support> }> {
  const tpl = await creatureTemplate(hero, CREATURE_MODELS[hero].height);
  tpl.skinned = true;
  store.models.set(CREATURE_MODELS[hero].url, tpl);
  store.models.set(CREATURE_MODELS.necromancer.url, await creatureTemplate('necromancer', CREATURE_MODELS.necromancer.height));
  const avatar = new Avatar(new THREE.Scene(), '#a26bff', false, hero);
  await vi.waitFor(() => expect(avatar.c.loaded).toBe(true));
  (avatar as unknown as { swayT: number }).swayT = 0; // the cape's sway phase is random per avatar
  const rig = buildRig(avatar);
  avatar.setEquipment({ main_hand: { item_id: `${main}_gold` }, off_hand: { item_id: `${off}_gold` }, head: { item_id: HELM_ID } });
  // The four necromancer rigs are hooded, so a worn helm is tint only; the dome is mounted anyway to keep its fit measured.
  avatar.mountDome({ item_id: HELM_ID });
  avatar.setCape(CAPE_ID);
  const acc = avatar as unknown as Access;
  await vi.waitFor(() => { for (const [slot, w] of acc.worn) if (slot !== 'head') expect(w.obj.userData.model === true).toBe(true); });
  const c = avatar.c as unknown as {
    actions: Map<string, THREE.AnimationAction>;
    attached: { obj: THREE.Object3D; baseQ?: THREE.Quaternion }[];
    oneShot: THREE.AnimationAction | null;
    oneShotEnd: number | null;
    current: THREE.AnimationAction | null;
  };
  const root = avatar.c.root;
  const mainObj = acc.worn.get('main_hand')!.obj;
  const offObj = acc.worn.get('off_hand')!.obj;
  const helmObj = acc.worn.get('head')!.obj;
  const capeObj = acc.cape!.obj;
  const hemMesh = capeObj.children[0].children[1] as THREE.Object3D;
  const props: Record<'main' | 'off', PropFrame> = {
    main: { obj: mainObj, hand: rig.hands.R, tipLocal: new THREE.Vector3(), rec: undefined },
    off: { obj: offObj, hand: rig.hands.L, tipLocal: new THREE.Vector3(), rec: undefined },
  };

  let x = 0;
  const step = (moving: boolean) => {
    x += moving ? 5.2 * SIM_DT : 0;
    avatar.update(SIM_DT, x, 0, 0.8, moving, 5.2);
  };
  const reset = () => {
    for (const a of c.actions.values()) a.stop();
    c.oneShot = null;
    c.oneShotEnd = null;
    c.current = null;
    avatar.c.setLoop('idle');
    for (let i = 0; i < SETTLE_FRAMES; i++) step(false);
    // The game re-calibrates a prop that has drifted >25 deg every 2 s of idle (a visible snap); keep that out of the
    // measurement so the numbers do not depend on clip order. Reported separately as 'recal' by drift being large.
    (avatar.c as unknown as { recheckT: number }).recheckT = 1e9;
    (avatar as unknown as { swayT: number }).swayT = 0; // every clip starts the cape at the same sway phase
    root.updateMatrixWorld(true);
  };
  // Calibrate props once, from the settled idle (the game does the same): then freeze their tips and parents.
  reset();
  for (const k of ['main', 'off'] as const) {
    const f = props[k];
    f.tipLocal = farthest(f.obj);
    f.rec = c.attached.find((a) => a.obj === f.obj);
  }
  const idleGap = {} as Record<'main' | 'off', number>;
  const gapRef = () => {
    for (const k of ['main', 'off'] as const) idleGap[k] = nearest(propPoints(props[k].obj, 300), props[k].hand.getWorldPosition(new THREE.Vector3()));
  };
  gapRef();

  const series = new Map<string, Series>();
  const record = (key: string, v: number, t: number) => {
    let s = series.get(key);
    if (!s) series.set(key, (s = new Series()));
    s.push(v, t);
  };
  const supportVals = new Map<string, number[]>();

  const sample = (clip: string, t: number) => {
    root.updateMatrixWorld(true);
    for (const m of [rig.head.mesh]) m.skeleton.update();
    poseCapsules(rig);
    const body = BODY_CAPS.map((n) => rig.capsules.get(n)!);
    const legs = LEG_CAPS.map((n) => rig.capsules.get(n)!);
    for (const [k, kind] of [['main', main], ['off', off]] as const) {
      const f = props[k];
      const pts = propPoints(f.obj, 300);
      record(`${kind}|${clip}|pen`, maxDepth(pts, body), t);
      const rt = rigidTip(f);
      const tip = f.tipLocal.clone().applyMatrix4(f.obj.matrixWorld);
      record(`${kind}|${clip}|drift`, rt ? rt.distanceTo(tip) : 0, t);
      record(`${kind}|${clip}|gap`, Math.max(0, nearest(pts, f.hand.getWorldPosition(new THREE.Vector3())) - idleGap[k]), t);
    }
    // Support hand on a two-hander's shaft: the left hand to the shaft's axis (origin..tip), metres.
    if (TWO_HANDED.has(main)) {
      const o = mainObj.getWorldPosition(new THREE.Vector3());
      const tip = props.main.tipLocal.clone().applyMatrix4(mainObj.matrixWorld);
      const ext = tip.clone().sub(o).multiplyScalar(-0.6).add(o); // a little past the butt end
      const arr = supportVals.get(clip) ?? [];
      arr.push(distToSeg(rig.hands.L.getWorldPosition(new THREE.Vector3()), ext, tip));
      supportVals.set(clip, arr);
    }
    // Helm against the skull.
    const up = headUp(rig).clone();
    const hp = rig.head.bone.getWorldPosition(new THREE.Vector3());
    const mesh = rig.head.mesh;
    let crown = -Infinity;
    const hv: THREE.Vector3[] = [];
    for (let i = 0; i < rig.head.verts.length; i += 3) {
      const v = mesh.getVertexPosition(rig.head.verts[i], new THREE.Vector3()).applyMatrix4(mesh.matrixWorld);
      hv.push(v);
      crown = Math.max(crown, v.clone().sub(hp).dot(up));
    }
    const hpts = propPoints(helmObj, 260);
    let top = -Infinity;
    let low = Infinity;
    const horiz = (p: THREE.Vector3) => { const v = p.clone().sub(hp); return v.addScaledVector(up, -v.dot(up)).length(); };
    for (const p of hpts) { const h = p.clone().sub(hp).dot(up); top = Math.max(top, h); low = Math.min(low, h); }
    const helmR = percentile(hpts.map(horiz), 0.95);
    const headR = Math.max(0, ...hv.filter((v) => v.clone().sub(hp).dot(up) >= low).map(horiz));
    const clear = top - crown;
    record(`helm|${clip}|float`, Math.max(0, clear - 0.09), t);
    record(`helm|${clip}|sink`, Math.max(0, -clear, headR - helmR), t);
    // Cape: cloth against the body core, hem against the legs.
    const cpts = propPoints(capeObj, 260);
    record(`cape|${clip}|pen`, maxDepth(cpts, body), t);
    record(`cape|${clip}|hem`, maxDepth(propPoints(hemMesh, 260), legs), t);
  };

  for (const clip of clips) {
    const action = c.actions.get(clip);
    if (!action) continue;
    reset();
    gapRef();
    const dur = action.getClip().duration;
    // The run clip is played the way the game does (moving at 5.2 u/s picks it); walk is forced, as 5.2 u/s always runs.
    const moving = clip === 'run';
    if (clip === 'idle' || moving) avatar.c.setLoop('idle');
    else if (clip === 'walk') avatar.c.setLoop('walk');
    else {
      action.setLoop(THREE.LoopOnce, 1);
      action.clampWhenFinished = true;
      action.timeScale = 1;
      action.enabled = true;
      action.reset().setEffectiveWeight(1).fadeIn(0.08).play();
      c.current?.fadeOut(0.12);
      c.oneShot = action;
      c.current = action;
      c.oneShotEnd = null;
    }
    const frames = Math.round(dur / SIM_DT);
    const every = Math.round(SAMPLE_DT / SIM_DT);
    for (let i = 0; i <= frames; i++) {
      step(moving);
      if (i % every === 0) sample(clip, i * SIM_DT);
    }
  }
  avatar.dispose();
  const cells: Record<string, Cell> = {};
  for (const [k, s] of series) cells[k] = s.cell();
  const support: Record<string, Support> = {};
  for (const [clip, v] of supportVals) support[`${main}|${clip}`] = { min: Math.min(...v), med: percentile(v, 0.5) };
  return { cells, support };
}

/** Merge a config's cells into the matrix (worst of worsts, so two configs never hide each other). */
export function merge(into: Matrix, hero: string, cells: Record<string, Cell>) {
  for (const [k, c] of Object.entries(cells)) {
    const key = `${hero}|${k}`;
    const cur = into[key];
    if (!cur) into[key] = { ...c };
    else {
      if (c.worst > cur.worst) { cur.worst = c.worst; cur.t = c.t; }
      cur.p95 = Math.max(cur.p95, c.p95);
    }
  }
}
