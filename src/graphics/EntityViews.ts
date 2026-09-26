import * as THREE from 'three';
import type { EnemyId } from '../content/enemies';
import type { ThrallKind } from '../content/disciplines';
import type { Corpse, Enemy, SimEvent, Thrall } from '../gameplay/sim/types';
import { Creature } from './Creature';
import type { Effects, Handle } from './Effects';
import { fx } from './fxTextures';
import { SPELL_FX } from '../content/abilities';
import { audio } from '../audio/Audio';
import type { CreatureSlug } from './modelPaths';

const ENEMY_SLUG: Record<EnemyId, CreatureSlug> = {
  robber: 'grave_robber',
  hound: 'bone_hound',
  penitent: 'penitent',
  sac: 'carrion_sac',
  deacon: 'deacon',
  risen: 'skeleton_thrall',
};

const THRALL_SLUG: Record<ThrallKind, CreatureSlug> = {
  warrior: 'skeleton_thrall',
  shieldbearer: 'skeleton_thrall',
  hound: 'bone_hound',
  wraith: 'skeleton_thrall',
};

/** Nominal ground speed of each walk clip (u/s) — scales playback to avoid foot sliding. */
const WALK_SPEED: Partial<Record<CreatureSlug, number>> = {
  grave_robber: 1.5,
  bone_hound: 2.6,
  penitent: 1.4,
  deacon: 1.4,
  carrion_sac: 1.1,
  skeleton_thrall: 1.6,
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
  dieT?: number;
  sinkT?: number;
  animSkip: number;
  animDt: number;
  float?: boolean;
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
    const c = new Creature(slug, {
      // Hostile skeletons read darker and sickly so they never look like your thralls.
      tint: risen ? 0x8a8078 : 0xffffff,
      emissive: e.elite ? 0x4a1f8a : risen ? 0x2a3a18 : 0x000000,
      emissiveIntensity: e.elite ? 0.14 : risen ? 0.3 : 0,
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
    return v;
  }

  private makeThrall(t: Thrall): View {
    const wraith = t.kind === 'wraith';
    const c = new Creature(THRALL_SLUG[t.kind], {
      tint: wraith ? 0xb9c4ff : 0xf4ecff,
      emissive: wraith ? 0x8f9ed1 : 0x1f8f86,
      emissiveIntensity: wraith ? 1.1 : t.empowered ? 0.4 : 0.18,
      spectral: wraith,
      scale: t.kind === 'shieldbearer' ? 1.1 : 1,
    });
    if (t.kind === 'warrior' || t.kind === 'shieldbearer') {
      c.attach('R_Hand', boneSword(), new THREE.Vector3(0, 0.25, 1));
      c.attach('L_Hand', roundShield(t.kind === 'shieldbearer' ? 0.5 : 0.32), new THREE.Vector3(0, 1, 0));
    }
    this.group.add(c.root);
    const v: View = { c, x: t.x, z: t.z, facing: t.facing, lastState: '', kind: t.kind, animSkip: 0, animDt: 0, float: wraith };
    v.ring = this.effects.decal({
      tex: fx.ring(),
      color: wraith ? 0x8fb4ff : SPELL_FX.exhume.spirit,
      x: t.x,
      z: t.z,
      r: t.kind === 'hound' ? 0.9 : 0.75,
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
          this.corpses.set(c.id, v);
        } else {
          // Corpse without a dying body (a sacrificed thrall, or a late join): lay one down.
          const slug = ENEMY_SLUG[c.enemy];
          const cr = new Creature(slug, { tint: c.enemy === 'risen' ? 0x8a8078 : 0xffffff });
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
        } else if (ev.reason === 'burst') {
          this.effects.emit({ x: v.x, y: 0.5, z: v.z, count: 20, color: SPELL_FX.miasma.rot, spread: 0.6, speed: 2.5, up: 1.5, life: 0.7, size: 0.3 });
        }
        break;
      }
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

  private syncFacing(v: View, target: number, dt: number) {
    let d = target - v.facing;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    v.facing += d * Math.min(1, dt * 10);
  }

  /** LOD: far creatures animate at a lower rate. */
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
      v.c.root.position.set(e.x, -1.7 * (1 - rise) * (1 - rise), e.z);
      v.c.root.rotation.y = v.facing;
      v.c.flash = e.flash;
      const key = e.state === 'windup' || e.state === 'channel' ? e.state : e.moving ? 'walk' : 'idle';
      if (key !== v.lastState) {
        if (key === 'windup' || key === 'channel') {
          const cast = e.def === 'penitent' || e.def === 'deacon';
          v.c.playOnce(cast ? 'cast' : 'attack', cast ? 1.3 : 1.6);
        } else if (key === 'walk') v.c.setLoop('walk', Math.max(0.6, e.speed / (WALK_SPEED[v.c.slug] ?? 1.5)));
        else v.c.setLoop('idle');
        v.lastState = key;
      }
      this.tickAnim(v, dt, focusX, focusZ);
      if (e.withered > 0 && Math.random() < dt * (1.5 + e.withered)) {
        this.effects.emit({ x: e.x, y: 0.8 + Math.random() * 0.8, z: e.z, count: 1, color: SPELL_FX.miasma.rot, spread: 0.4, speed: 0.2, up: 0.7, life: 0.9, size: 0.2 });
      }
      if (e.fracture > 0 && Math.random() < dt * 2 * e.fracture) {
        this.effects.emit({ x: e.x, y: 1.2, z: e.z, count: 1, color: SPELL_FX.needle.dust, spread: 0.3, speed: 0.6, up: 0.4, life: 0.5, size: 0.1, gravity: 5 });
      }
      if (e.state === 'rising' && Math.random() < dt * 12) {
        this.effects.emitSmoke({ x: e.x, y: 0.1, z: e.z, count: 1, color: 0x2a2230, spread: 0.5, speed: 0.5, up: 0.6, life: 1, size: 0.9 });
      }
    }
    // Enemies that vanished without a death event (mirror resync, area clear).
    for (const [id, v] of this.enemies) {
      if (!enemies.has(id)) {
        this.enemies.delete(id);
        v.eliteAura?.kill();
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
