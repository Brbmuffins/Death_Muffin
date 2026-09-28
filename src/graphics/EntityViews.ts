import * as THREE from 'three';
import { CENSER, ENEMIES, type EliteAffix, type EnemyId } from '../content/enemies';
import type { ThrallKind } from '../content/disciplines';
import type { Corpse, Enemy, SimEvent, Thrall } from '../gameplay/sim/types';
import { Creature } from './Creature';
import type { Effects, Handle } from './Effects';
import { fx } from './fxTextures';
import { SPELL_FX } from '../content/abilities';
import { audio } from '../audio/Audio';
import type { CreatureSlug } from './modelPaths';
import { STATUS_FX } from '../content/statuses';

const ENEMY_SLUG: Record<EnemyId, CreatureSlug> = {
  robber: 'grave_robber',
  hound: 'bone_hound',
  penitent: 'penitent',
  sac: 'carrion_sac',
  deacon: 'deacon',
  risen: 'skeleton_thrall',
  censer: 'censer_bearer',
  wraith: 'choir_wraith',
  rat: 'skull_rat',
  golem: 'bone_golem',
};

/** Shipped models to fall back on if a newer GLB is missing (older deploys, failed builds). */
const ENEMY_FALLBACK: Partial<Record<EnemyId, CreatureSlug>> = {
  censer: 'deacon',
  wraith: 'penitent',
  rat: 'bone_hound',
  golem: 'skeleton_thrall',
};
/** Enemies that cast (play 'cast' rather than 'attack' on the windup). */
const CASTERS = new Set<EnemyId>(['penitent', 'deacon', 'wraith', 'censer']);
/** Choir Wraiths float: a hover height and a slow bob. */
const HOVER = { wraith: 0.45 } as Partial<Record<EnemyId, number>>;

const THRALL_SLUG: Record<ThrallKind, CreatureSlug> = {
  warrior: 'skeleton_thrall',
  shieldbearer: 'skeleton_thrall',
  hound: 'bone_hound',
  wraith: 'skeleton_thrall',
  archer: 'skeleton_thrall',
  bonemage: 'skeleton_thrall',
  plaguebearer: 'carrion_sac',
};

/** Tint / glow per thrall kind (colour language: bone ivory-amber, rot olive, spirit cold blue). */
const THRALL_LOOK: Partial<Record<ThrallKind, { tint: number; emissive: number; glow: number; scale?: number; ring?: number }>> = {
  archer: { tint: 0xf2e6cc, emissive: 0x6b4a1f, glow: 0.25 },
  bonemage: { tint: 0xe6dccb, emissive: 0xb07a2a, glow: 0.35 },
  plaguebearer: { tint: 0xb9c48a, emissive: 0x5a6a18, glow: 0.35, scale: 0.8, ring: 1.05 },
};

/** Nominal ground speed of each walk clip (u/s) — scales playback to avoid foot sliding. */
const WALK_SPEED: Partial<Record<CreatureSlug, number>> = {
  grave_robber: 1.5,
  bone_hound: 2.6,
  penitent: 1.4,
  deacon: 1.4,
  carrion_sac: 1.1,
  skeleton_thrall: 1.6,
  censer_bearer: 1.4,
  skull_rat: 3.2,
  bone_golem: 1.1,
};

interface View {
  c: Creature;
  x: number;
  z: number;
  facing: number;
  lastState: string;
  def?: EnemyId;
  kind?: ThrallKind;
  ring?: Handle;
  eliteAura?: Handle;
  /** Censer Bearer's incense ring. */
  auraFx?: Handle;
  affix?: EliteAffix;
  /** Persistent affix tells (rings / cracks that follow the elite). */
  affixFx?: Handle[];
  /** Shrouded elites fade toward this opacity (1 inside Miasma). */
  shroud?: number;
  /** Set by a Corpse Explosion: the body shatters instead of sinking with rot. */
  shattered?: boolean;
  dieT?: number;
  sinkT?: number;
  animSkip: number;
  animDt: number;
  float?: boolean;
}

const A = SPELL_FX.affix;
const D = SPELL_FX.detonate;

/** Rough mouth/head height per rig, for drool and sparks. */
/** Common enemies nearest the camera focus that keep their moon shadow. */
const SHADOW_CASTERS = 12;
const HEAD_Y = { humanoid: 1.3, robed: 1.35, quadruped: 0.75, bloat: 1.05 } as const;

function killAffixFx(v: View) {
  v.affixFx?.forEach((h) => h.kill());
  v.affixFx = undefined;
}

function boneSword() {
  const g = new THREE.Group();
  const metal = new THREE.MeshStandardMaterial({ color: 0x6f6a74, metalness: 0.7, roughness: 0.45 });
  const blade = new THREE.Mesh(new THREE.BoxGeometry(0.06, 0.95, 0.02), metal);
  blade.position.y = 0.55;
  const guard = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.05, 0.05), metal);
  guard.position.y = 0.08;
  g.add(blade, guard);
  return g;
}

/** A recurve of fused rib bone with a sinew string (code-built; no asset). */
function boneBow() {
  const g = new THREE.Group();
  const bone = new THREE.MeshStandardMaterial({ color: 0xd8cfbd, roughness: 0.7 });
  const limb = new THREE.Mesh(new THREE.TorusGeometry(0.42, 0.025, 5, 14, Math.PI * 0.85), bone);
  limb.rotation.z = Math.PI / 2 + Math.PI * 0.075;
  const string = new THREE.Mesh(new THREE.CylinderGeometry(0.006, 0.006, 0.76, 3), new THREE.MeshBasicMaterial({ color: 0x9a8a70 }));
  string.position.x = -0.1;
  g.add(limb, string);
  return g;
}

/** A femur staff crowned with an amber ember. */
function boneStaff() {
  const g = new THREE.Group();
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.035, 1.3, 6), new THREE.MeshStandardMaterial({ color: 0xcfc3ad, roughness: 0.75 }));
  shaft.position.y = 0.45;
  const orb = new THREE.Mesh(new THREE.SphereGeometry(0.08, 10, 8), new THREE.MeshStandardMaterial({ color: 0x5a3a14, emissive: 0xd9a66b, emissiveIntensity: 1.2 }));
  orb.position.y = 1.15;
  g.add(shaft, orb);
  return g;
}

function roundShield(r: number) {
  const g = new THREE.Group();
  const disc = new THREE.Mesh(
    new THREE.CylinderGeometry(r, r, 0.06, 18),
    new THREE.MeshStandardMaterial({ color: 0x4d4033, metalness: 0.5, roughness: 0.55 }),
  );
  disc.rotation.z = Math.PI / 2;
  const boss = new THREE.Mesh(
    new THREE.SphereGeometry(r * 0.22, 10, 8),
    new THREE.MeshStandardMaterial({ color: 0x3a2f55, emissive: 0x7c3aed, emissiveIntensity: 0.9 }),
  );
  boss.position.x = 0.05;
  g.add(disc, boss);
  return g;
}

/**
 * Maps simulation entities onto animated Creatures: enemies climb out of the
 * ground, die into corpses that stay where they fell, and are consumed or
 * sink away; thralls get weapons, a violet summon ring and a lilac glow.
 */
export class EntityViews {
  readonly group = new THREE.Group();
  private enemies = new Map<number, View>();
  private thralls = new Map<number, View>();
  private corpses = new Map<number, View>();
  private dying: View[] = [];
  private fading: View[] = [];
  private frame = 0;
  /** Enemy under the cursor — gets a faint lilac highlight. */
  hoverId: number | null = null;

  constructor(
    scene: THREE.Scene,
    private effects: Effects,
  ) {
    scene.add(this.group);
  }

  private makeEnemy(e: Enemy): View {
    const slug = ENEMY_SLUG[e.def];
    const risen = e.def === 'risen';
    const wraith = e.def === 'wraith';
    const c = new Creature(slug, {
      // Hostile skeletons read darker and sickly so they never look like your thralls.
      tint: risen ? 0x8a8078 : 0xffffff,
      emissive: e.elite ? 0x4a1f8a : risen ? 0x2a3a18 : wraith ? 0x9fb6d8 : 0x000000,
      emissiveIntensity: e.elite ? 0.14 : risen ? 0.3 : wraith ? 0.35 : 0,
      // The choir is half-there: translucent, pale, no shadow.
      spectral: wraith,
      fallback: ENEMY_FALLBACK[e.def],
    });
    c.root.scale.setScalar(e.scale / (e.def === 'risen' ? 1 : 1));
    this.group.add(c.root);
    const v: View = { c, x: e.x, z: e.z, facing: e.facing, lastState: '', def: e.def, animSkip: 0, animDt: 0 };
    if (e.elite) {
      v.eliteAura = this.effects.decal({
        tex: fx.ring(),
        color: 0x9b5cff,
        x: e.x,
        z: e.z,
        r: 1.1 * e.scale,
        duration: 1e9,
        opacity: 0.8,
        pulse: 4,
        follow: () => ({ x: v.x, z: v.z }),
      });
    }
    if (e.affix) this.dressAffix(v, e);
    return v;
  }

  /** A readable, persistent tell for each elite affix. */
  private dressAffix(v: View, e: Enemy) {
    v.affix = e.affix;
    const follow = () => ({ x: v.x, z: v.z });
    const fxs: Handle[] = [];
    switch (e.affix) {
      case 'bellTolled':
        // Bronze bell-ring pulse around the feet.
        fxs.push(this.effects.decal({ tex: fx.ring(), color: A.bell, x: e.x, z: e.z, r: 1.55 * e.scale, duration: 1e9, opacity: 0.6, pulse: 2.5, follow }));
        break;
      case 'hungering':
        // Olive slick where it slavers.
        fxs.push(this.effects.decal({ tex: fx.glow(), color: A.drool, x: e.x, z: e.z, r: 1.2 * e.scale, duration: 1e9, opacity: 0.45, follow }));
        break;
      case 'shrouded':
        // Grave-dusk pall; the body itself is dimmed in sync().
        fxs.push(this.effects.decal({ tex: fx.glow(), color: A.shroud, x: e.x, z: e.z, r: 1.5 * e.scale, duration: 1e9, opacity: 0.7, blending: THREE.NormalBlending, follow }));
        v.shroud = 1;
        break;
      case 'vengeful':
        // Ember cracks spreading under it.
        fxs.push(this.effects.decal({ tex: fx.cracks(), color: A.vengeful, x: e.x, z: e.z, r: 1.3 * e.scale, duration: 1e9, opacity: 0.75, pulse: 3, spin: 0.2, follow }));
        break;
    }
    v.affixFx = fxs;
  }

  /** Per-frame affix particles / shroud fade. */
  private tickAffix(v: View, e: Enemy, dt: number, nearFx: boolean) {
    const headY = HEAD_Y[ENEMIES[e.def].rig] * e.scale;
    switch (e.affix) {
      case 'hungering':
        if (nearFx && Math.random() < dt * 4) {
          const f = v.facing;
          this.effects.emit({ x: e.x + Math.sin(f) * 0.3 * e.scale, y: headY, z: e.z + Math.cos(f) * 0.3 * e.scale, count: 1, color: A.drool, spread: 0.06, speed: 0.1, up: -0.3, life: 0.7, size: 0.13, gravity: 7 });
        }
        break;
      case 'vengeful':
        if (nearFx && Math.random() < dt * 3) {
          this.effects.emit({ x: e.x, y: 0.3 + Math.random() * headY, z: e.z, count: 1, color: A.vengeful, spread: 0.35 * e.scale, speed: 0.2, up: 1.1, life: 0.7, size: 0.12 });
        }
        break;
      case 'shrouded': {
        // Revealed (opaque) only while it stands in a player's Miasma — the slow flag rides the snapshot.
        const target = e.slowT > 0 ? 1 : 0.38;
        v.shroud = (v.shroud ?? 1) + (target - (v.shroud ?? 1)) * Math.min(1, dt * 6);
        v.c.setOpacity(v.shroud);
        if (nearFx && target < 1 && Math.random() < dt * 2) {
          this.effects.emitSmoke({ x: e.x, y: 0.4 + Math.random() * headY, z: e.z, count: 1, color: A.shroud, spread: 0.4 * e.scale, speed: 0.15, up: 0.4, life: 1.2, size: 0.9, shrink: -0.6 });
        }
        break;
      }
    }
  }

  private makeThrall(t: Thrall): View {
    const wraith = t.kind === 'wraith';
    const look = THRALL_LOOK[t.kind];
    const c = new Creature(THRALL_SLUG[t.kind], {
      tint: look?.tint ?? (wraith ? 0xb9c4ff : 0xf4ecff),
      emissive: look?.emissive ?? (wraith ? 0x8f9ed1 : 0x1f8f86),
      emissiveIntensity: wraith ? 1.1 : (look?.glow ?? 0.18) + (t.empowered ? 0.22 : 0),
      spectral: wraith,
      scale: look?.scale ?? (t.kind === 'shieldbearer' ? 1.1 : 1),
    });
    if (t.kind === 'warrior' || t.kind === 'shieldbearer') {
      c.attach('R_Hand', boneSword(), new THREE.Vector3(0, 0.25, 1));
      c.attach('L_Hand', roundShield(t.kind === 'shieldbearer' ? 0.5 : 0.32), new THREE.Vector3(0, 1, 0));
    } else if (t.kind === 'archer') c.attach('L_Hand', boneBow(), new THREE.Vector3(0, 1, 0));
    else if (t.kind === 'bonemage') c.attach('R_Hand', boneStaff(), new THREE.Vector3(0, 0.25, 1));
    this.group.add(c.root);
    const v: View = { c, x: t.x, z: t.z, facing: t.facing, lastState: '', kind: t.kind, animSkip: 0, animDt: 0, float: wraith };
    v.ring = this.effects.decal({
      tex: fx.ring(),
      color: wraith ? 0x8fb4ff : SPELL_FX.exhume.spirit,
      x: t.x,
      z: t.z,
      r: look?.ring ?? (t.kind === 'hound' ? 0.9 : 0.75),
      duration: 1e9,
      opacity: t.empowered ? 1 : 0.7,
      follow: () => ({ x: v.x, z: v.z }),
    });
    return v;
  }

  onEvent(ev: SimEvent, lookupCorpseFacing?: (c: Corpse) => number) {
    switch (ev.t) {
      case 'spawn':
        this.effects.emitSmoke({ x: ev.x, y: 0.2, z: ev.z, count: 10, color: 0x2a2230, spread: 0.7, speed: 1, up: 0.9, life: 1.3, size: 1.2, shrink: -1 });
        this.effects.emit({ x: ev.x, y: 0.1, z: ev.z, count: 4, color: 0x5b2bb0, spread: 0.5, speed: 0.6, up: 1.4, life: 0.8, size: 0.24 });
        this.effects.decal({ tex: fx.cracks(), color: 0x7c3aed, x: ev.x, z: ev.z, r: ev.elite ? 1.6 : 1.1, rot: Math.random() * 6, duration: 2.2, opacity: 0.8, growFrom: 0.3 });
        break;
      case 'death': {
        const v = this.enemies.get(ev.id);
        if (!v) break;
        this.enemies.delete(ev.id);
        v.eliteAura?.kill();
        v.auraFx?.kill();
        killAffixFx(v);
        if (v.shroud !== undefined && v.shroud < 1) v.c.setOpacity(1);
        if (ev.def === 'wraith') {
          // A wraith leaves no body: it thins to mist and sinks away.
          this.effects.emit({ x: ev.x, y: 1.4, z: ev.z, count: 22, color: 0xb9cbe6, spread: 0.6, speed: 0.9, up: 1.2, life: 1.1, size: 0.3, drag: 1 });
          v.sinkT = 0;
          this.fading.push(v);
          break;
        }
        v.dieT = 0;
        if (!v.c.playOnce('death')) v.c.toppled = 0.0001;
        this.dying.push(v);
        this.effects.emitSmoke({ x: ev.x, y: 0.3, z: ev.z, count: 6, color: 0x3b3440, spread: 0.6, speed: 0.8, up: 0.4, life: 1, size: 1 });
        if (ev.elite) {
          this.effects.emit({ x: ev.x, y: 1, z: ev.z, count: 40, color: 0xb58cff, spread: 0.8, speed: 3, up: 2, life: 1.1, size: 0.35 });
          this.effects.lightFlash(ev.x, 1.5, ev.z, 0xa26bff, 25, 0.5);
        }
        break;
      }
      case 'corpse': {
        const c = ev.corpse;
        if (c.echoOwner) break;
        let best = -1;
        let bestD = 1.2;
        this.dying.forEach((v, i) => {
          const d = Math.hypot(v.x - c.x, v.z - c.z);
          if (v.def === c.enemy && d < bestD) {
            bestD = d;
            best = i;
          }
        });
        if (best >= 0) {
          const v = this.dying.splice(best, 1)[0];
          v.c.setCastShadow(false);
          this.corpses.set(c.id, v);
        } else {
          // Corpse without a dying body (a sacrificed thrall, or a late join): lay one down.
          const slug = ENEMY_SLUG[c.enemy];
          const cr = new Creature(slug, { tint: c.enemy === 'risen' ? 0x8a8078 : 0xffffff, castShadow: false });
          cr.root.position.set(c.x, 0, c.z);
          cr.root.rotation.y = lookupCorpseFacing?.(c) ?? c.facing;
          cr.root.scale.setScalar(c.scale);
          this.group.add(cr.root);
          const v: View = { c: cr, x: c.x, z: c.z, facing: c.facing, lastState: 'corpse', animSkip: 0, animDt: 0, dieT: 5 };
          const tryHold = () => {
            if (!cr.loaded) return void setTimeout(tryHold, 150);
            if (!cr.holdLastFrame('death')) cr.toppled = 1;
          };
          tryHold();
          v.c.setCastShadow(false);
          this.corpses.set(c.id, v);
        }
        if (c.kind === 'toxic') {
          this.effects.decal({ tex: fx.disc(), color: 0x6f8f3a, x: c.x, z: c.z, r: 2.4 * c.scale, duration: 5, opacity: 0.35, pulse: 6, growFrom: 0.6 });
        }
        if (c.kind === 'resonant') {
          this.effects.decal({ tex: fx.ring(), color: 0xc6a4ff, x: c.x, z: c.z, r: 1.2, duration: 26, opacity: 0.6, pulse: 3 });
        }
        break;
      }
      case 'corpseGone': {
        const v = this.corpses.get(ev.id);
        if (!v) break;
        this.corpses.delete(ev.id);
        v.sinkT = 0;
        this.fading.push(v);
        if (ev.reason === 'consumed') {
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 22, color: SPELL_FX.exhume.spirit, spread: 0.6, speed: 0.8, up: 2.6, life: 0.9, size: 0.35 });
        } else if (ev.reason === 'litany') {
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 18, color: SPELL_FX.litany.core, spread: 0.6, speed: 0.8, up: 2.2, life: 0.8, size: 0.35 });
        } else if (ev.reason === 'raised') {
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 18, color: SPELL_FX.enemy.rot, spread: 0.6, speed: 0.8, up: 2, life: 1, size: 0.35 });
        } else if (ev.reason === 'devoured') {
          // Torn apart and swallowed: olive gore, no spirit left to rise.
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 22, color: A.drool, spread: 0.5, speed: 1.6, up: 1.4, life: 0.7, size: 0.26, gravity: 5 });
          this.effects.emitSmoke({ x: v.x, y: 0.3, z: v.z, count: 3, color: 0x2b3317, spread: 0.4, speed: 0.6, up: 0.4, life: 1, size: 1 });
        } else if (ev.reason === 'burst' && v.shattered) {
          // Corpse Explosion: the body is blown apart (the blast VFX plays from the 'detonated' event).
          v.c.setOpacity(0);
          v.sinkT = 0.8;
        } else if (ev.reason === 'burst') {
          this.effects.emit({ x: v.x, y: 0.5, z: v.z, count: 20, color: SPELL_FX.miasma.rot, spread: 0.6, speed: 2.5, up: 1.5, life: 0.7, size: 0.3 });
        }
        break;
      }
      case 'detonated': {
        if (!ev.ok) break;
        const v = this.corpses.get(ev.corpseId);
        if (v) v.shattered = true;
        break;
      }
      case 'affix':
        this.affixMoment(ev);
        break;
      case 'thrallGone': {
        const v = this.thralls.get(ev.id);
        if (!v) break;
        this.thralls.delete(ev.id);
        v.ring?.kill();
        v.sinkT = 0;
        this.fading.push(v);
        this.effects.emit({ x: ev.x, y: 0.8, z: ev.z, count: ev.reason === 'sacrificed' ? 30 : 14, color: 0xd8cfbd, spread: 0.5, speed: 2, up: 1.2, life: 0.8, size: 0.25, gravity: 3 });
        break;
      }
      case 'thrall': {
        audio.play('thrallRise', ev.x, ev.z);
        const X = SPELL_FX.exhume;
        this.effects.decal({ tex: fx.sigil(), color: X.spirit, x: ev.x, z: ev.z, r: 1.4, duration: 1.3, opacity: 0.9, growFrom: 0.2, spin: 2 });
        this.effects.emit({ x: ev.x, y: 0.2, z: ev.z, count: 40, color: X.spirit, spread: 0.5, speed: 0.6, up: 3.6, life: 1, size: 0.36, gravity: -0.6 });
        this.effects.emit({ x: ev.x, y: 0.2, z: ev.z, count: 16, color: X.beam, spread: 0.3, speed: 0.3, up: 5, life: 0.7, size: 0.22 });
        this.effects.emitSmoke({ x: ev.x, y: 0.2, z: ev.z, count: 6, color: 0x1c2a2a, spread: 0.6, speed: 0.8, up: 0.8, life: 1.2, size: 1.2 });
        this.effects.lightFlash(ev.x, 1.2, ev.z, X.spirit, 22, 0.6);
        break;
      }
        break;
    }
  }

  /** One-off affix beats reported by the host. */
  private affixMoment(ev: Extract<SimEvent, { t: 'affix' }>) {
    const { x, z } = ev;
    switch (ev.affix) {
      case 'bellTolled': {
        const r = ev.r ?? 3;
        audio.play('toll', x, z);
        for (let k = 0; k < 3; k++) {
          this.effects.decal({ tex: fx.ring(), color: A.bell, x, z, r: r * (0.75 + k * 0.2), duration: 0.5, opacity: 1 - k * 0.25, growFrom: 0.15, delay: k * 0.07 });
        }
        this.effects.emit({ x, y: 0.8, z, count: 36, color: A.bell, spread: r * 0.3, speed: 5, up: 0.8, life: 0.5, size: 0.28 });
        this.effects.lightFlash(x, 1.5, z, A.bell, 30, 0.4);
        break;
      }
      case 'hungering': {
        const tx = ev.tx ?? x;
        const tz = ev.tz ?? z;
        audio.play('raise', tx, tz);
        this.effects.beam({ x: tx, y: 0.3, z: tz }, () => ({ x, y: 1.1, z }), A.drool, 0.07, 0.45);
        this.effects.emit({ x, y: 1.1, z, count: 14, color: A.drool, spread: 0.3, speed: 0.8, up: 0.4, life: 0.8, size: 0.2, gravity: 4 });
        break;
      }
      case 'vengeful': {
        const r = ev.r ?? 1.8;
        audio.play('burst', x, z);
        this.effects.decal({ tex: fx.cracks(), color: A.vengeful, x, z, r: r * 1.4, rot: Math.random() * 6, duration: 2, opacity: 0.9, growFrom: 0.3 });
        this.effects.decal({ tex: fx.ring(), color: D.ember, x, z, r, duration: 0.5, opacity: 1, growFrom: 0.2 });
        this.effects.emit({ x, y: 0.6, z, count: 40, color: A.vengeful, spread: 0.5, speed: 3.5, up: 2.2, life: 0.8, size: 0.3 });
        this.effects.emitSmoke({ x, y: 0.4, z, count: 6, color: D.smoke, spread: 0.8, speed: 1, up: 0.8, life: 1.2, size: 1.3 });
        this.effects.lightFlash(x, 1.2, z, A.vengeful, 32, 0.5);
        break;
      }
    }
  }

  private syncFacing(v: View, target: number, dt: number) {
    let d = target - v.facing;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    v.facing += d * Math.min(1, dt * 10);
  }

  /** LOD: far creatures animate at a lower rate. */
  /**
   * Shadow LOD: only the nearest enemies (and every elite) cast moon shadows.
   * A horde at the cap otherwise re-renders ~100 skinned bodies in the shadow pass.
   */
  private shadowLod(enemies: Map<number, Enemy>, fx0: number, fz0: number) {
    const ranked: { v: View; d: number }[] = [];
    for (const [id, e] of enemies) {
      const v = this.enemies.get(id);
      if (!v) continue;
      if (e.elite) v.c.setCastShadow(true);
      else ranked.push({ v, d: (e.x - fx0) ** 2 + (e.z - fz0) ** 2 });
    }
    ranked.sort((a, b) => a.d - b.d);
    ranked.forEach((r, i) => r.v.c.setCastShadow(i < SHADOW_CASTERS));
  }

  private tickAnim(v: View, dt: number, fx0: number, fz0: number) {
    const far = Math.abs(v.x - fx0) > 26 || Math.abs(v.z - fz0) > 22;
    v.animDt += dt;
    if (far) {
      v.animSkip = (v.animSkip + 1) % 3;
      if (v.animSkip !== 0) return;
    }
    v.c.update(v.animDt);
    v.animDt = 0;
  }

  sync(
    enemies: Map<number, Enemy>,
    thralls: Map<number, Thrall>,
    dt: number,
    focusX: number,
    focusZ: number,
  ) {
    this.frame++;
    if (this.frame % 10 === 0) this.shadowLod(enemies, focusX, focusZ);
    for (const [id, e] of enemies) {
      let v = this.enemies.get(id);
      if (!v) {
        v = this.makeEnemy(e);
        this.enemies.set(id, v);
      }
      v.x = e.x;
      v.z = e.z;
      this.syncFacing(v, e.facing, dt);
      const rise = e.state === 'rising' ? Math.min(1, e.stateT / 1.1) : 1;
      const hover = HOVER[e.def];
      const lift = hover ? hover + Math.sin(performance.now() / 520 + id) * 0.12 : 0;
      v.c.root.position.set(e.x, -1.7 * (1 - rise) * (1 - rise) + lift, e.z);
      v.c.root.rotation.y = v.facing;
      v.c.flash = e.flash;
      const key = e.state === 'windup' || e.state === 'channel' ? e.state : e.moving ? 'walk' : 'idle';
      if (key !== v.lastState) {
        if (key === 'windup' || key === 'channel') {
          const cast = CASTERS.has(e.def);
          v.c.playOnce(cast ? 'cast' : 'attack', cast ? 1.3 : 1.6);
        } else if (key === 'walk') v.c.setLoop('walk', Math.max(0.6, e.speed / (WALK_SPEED[v.c.slug] ?? 1.5)));
        else v.c.setLoop('idle');
        v.lastState = key;
      }
      this.tickAnim(v, dt, focusX, focusZ);
      const nearFx = Math.abs(e.x - focusX) < 24 && Math.abs(e.z - focusZ) < 20;
      if (nearFx && e.withered > 0 && Math.random() < dt * (1 + e.withered * 0.75)) {
        this.effects.emit({ x: e.x, y: 0.8 + Math.random() * 0.8, z: e.z, count: 1, color: SPELL_FX.miasma.rot, spread: 0.4, speed: 0.2, up: 0.7, life: 0.9, size: 0.2 });
      }
      if (nearFx && e.fracture > 0 && Math.random() < dt * 1.5 * e.fracture) {
        this.effects.emit({ x: e.x, y: 1.2, z: e.z, count: 1, color: SPELL_FX.needle.dust, spread: 0.3, speed: 0.6, up: 0.4, life: 0.5, size: 0.1, gravity: 5 });
      }
      // Status tells: marrow drips, frost motes, a priest-gold glint.
      if (nearFx && (e.bleedT ?? 0) > 0 && Math.random() < dt * 4) {
        this.effects.emit({ x: e.x, y: 0.7 + Math.random() * 0.6, z: e.z, count: 1, color: Math.random() < 0.7 ? STATUS_FX.hemorrhage.crimson : STATUS_FX.hemorrhage.ember, spread: 0.3, speed: 0.1, up: -0.2, life: 0.6, size: 0.12, gravity: 8 });
      }
      if (nearFx && (e.chillT ?? 0) > 0 && Math.random() < dt * 3) {
        this.effects.emit({ x: e.x, y: 0.3 + Math.random() * 1.2, z: e.z, count: 1, color: STATUS_FX.chill.frost, spread: 0.45, speed: 0.15, up: 0.2, life: 0.8, size: 0.14, drag: 0.5 });
      }
      if (nearFx && (e.sanctT ?? 0) > 0 && Math.random() < dt * 2) {
        this.effects.emit({ x: e.x, y: 1.9 * e.scale, z: e.z, count: 1, color: STATUS_FX.sanctified.gold, spread: 0.35, speed: 0.1, up: 0.5, life: 0.7, size: 0.16 });
      }
      // Incensed (a Censer Bearer's aura): bronze motes drifting off the shoulders.
      if (nearFx && (e.incenseT ?? 0) > 0 && Math.random() < dt * 3) {
        this.effects.emit({ x: e.x, y: 1.2 * e.scale, z: e.z, count: 1, color: STATUS_FX.incensed.bronze, spread: 0.4, speed: 0.2, up: 0.6, life: 0.8, size: 0.14 });
      }
      // The Censer Bearer itself trails incense smoke and wears its aura on the ground.
      if (ENEMIES[e.def].aura) {
        if (!v.auraFx) v.auraFx = this.effects.decal({ tex: fx.ring(), color: STATUS_FX.incensed.bronze, x: e.x, z: e.z, r: CENSER.radius, duration: 1e9, opacity: 0.22, pulse: 2.5, follow: () => ({ x: v!.x, z: v!.z }) });
        if (nearFx && Math.random() < dt * 2) this.effects.emitSmoke({ x: e.x, y: 1.1, z: e.z, count: 1, color: STATUS_FX.incensed.smoke, spread: 0.3, speed: 0.3, up: 0.5, life: 1.4, size: 0.9, shrink: -0.5 });
      }
      if (nearFx && hover && Math.random() < dt * 4) {
        this.effects.emit({ x: e.x, y: lift + 0.2, z: e.z, count: 1, color: 0xb9cbe6, spread: 0.35, speed: 0.1, up: -0.3, life: 0.7, size: 0.18 });
      }
      if (nearFx && e.state === 'rising' && Math.random() < dt * 8) {
        this.effects.emitSmoke({ x: e.x, y: 0.1, z: e.z, count: 1, color: 0x2a2230, spread: 0.5, speed: 0.5, up: 0.6, life: 1, size: 0.9 });
      }
      // A mirror may learn the affix after the view exists (late snapshot field).
      if (e.affix && !v.affix) this.dressAffix(v, e);
      if (v.affix) this.tickAffix(v, e, dt, nearFx);
    }
    // Enemies that vanished without a death event (mirror resync, area clear).
    for (const [id, v] of this.enemies) {
      if (!enemies.has(id)) {
        this.enemies.delete(id);
        v.eliteAura?.kill();
        v.auraFx?.kill();
        killAffixFx(v);
        v.sinkT = 0;
        this.fading.push(v);
      }
    }

    for (const [id, t] of thralls) {
      let v = this.thralls.get(id);
      if (!v) {
        v = this.makeThrall(t);
        this.thralls.set(id, v);
      }
      v.x = t.x;
      v.z = t.z;
      this.syncFacing(v, t.facing, dt);
      const rise = t.state === 'rising' ? Math.min(1, t.stateT / 0.9) : 1;
      const hover = v.float ? 0.25 + Math.sin(performance.now() / 400 + id) * 0.1 : 0;
      v.c.root.position.set(t.x, -1.8 * (1 - rise) * (1 - rise) + hover, t.z);
      v.c.root.rotation.y = v.facing;
      v.c.flash = t.flash;
      const key = t.state === 'attack' && t.stateT < 0.1 ? 'attack' : t.moving ? 'move' : 'idle';
      if (key === 'attack' && v.lastState !== 'attack') v.c.playOnce('attack', 1.7);
      else if (key === 'move' && v.lastState !== 'move') v.c.setLoop(t.speed > 6.5 ? 'run' : 'walk', 1.3);
      else if (key === 'idle' && v.lastState !== 'idle') v.c.setLoop('idle');
      v.lastState = key;
      this.tickAnim(v, dt, focusX, focusZ);
    }
    for (const [id, v] of this.thralls) {
      if (!thralls.has(id)) {
        this.thralls.delete(id);
        v.ring?.kill();
        v.sinkT = 0;
        this.fading.push(v);
      }
    }

    for (let i = this.dying.length - 1; i >= 0; i--) {
      const v = this.dying[i];
      v.dieT! += dt;
      v.c.update(dt);
      this.topple(v, dt);
      // No corpse arrived (corpse kind "none"): crumble away.
      if (v.dieT! > 1.4) {
        this.dying.splice(i, 1);
        v.sinkT = 0;
        this.fading.push(v);
      }
    }
    for (const v of this.corpses.values()) {
      if ((v.dieT = (v.dieT ?? 0) + dt) < 3) v.c.update(dt);
      this.topple(v, dt);
    }
    for (let i = this.fading.length - 1; i >= 0; i--) {
      const v = this.fading[i];
      v.sinkT! += dt;
      v.c.root.position.y -= dt * 1.3;
      v.c.setOpacity(Math.max(0, 1 - v.sinkT! / 0.9));
      if (v.sinkT! > 0.9) {
        v.c.dispose();
        this.fading.splice(i, 1);
      }
    }
  }

  /** Drop corpse bodies the authority no longer has (resync after migration / drift). */
  pruneCorpses(valid: Map<number, unknown>) {
    for (const [id, v] of this.corpses) {
      if (valid.has(id)) continue;
      this.corpses.delete(id);
      v.sinkT = 0;
      this.fading.push(v);
    }
  }

  /** Models without a death clip tip over onto their side. */
  private topple(v: View, dt: number) {
    if (!v.c.toppled) return;
    v.c.toppled = Math.min(1, v.c.toppled + dt * 3);
    v.c.root.rotation.z = (Math.PI / 2) * v.c.toppled;
    v.c.root.position.y = 0.2 * v.c.toppled;
  }

  /** Screen-space enemy picking helper: world positions of live enemies. */
  enemyAnchor(id: number): THREE.Vector3 | null {
    const v = this.enemies.get(id);
    return v ? new THREE.Vector3(v.x, 1, v.z) : null;
  }

  counts() {
    return { enemies: this.enemies.size, thralls: this.thralls.size, corpses: this.corpses.size, dying: this.dying.length, fading: this.fading.length };
  }

  dispose() {
    for (const map of [this.enemies, this.thralls, this.corpses]) for (const v of map.values()) v.c.dispose();
    for (const v of [...this.dying, ...this.fading]) v.c.dispose();
    this.group.removeFromParent();
  }
}
