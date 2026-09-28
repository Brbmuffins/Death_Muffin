import { AREAS } from '../../content/areas';
import { enemyDamageScale, enemyHpScale } from '../../content/enemies';
import { FRACTURE } from '../../content/abilities';
import { DIFFICULTIES } from '../../content/difficulty';
import { ascensionLevels } from '../../content/ascension';
import type { WorldSim } from './WorldSim';
import type { BossPhase, BossState } from './types';

export const BOSS_ARENA = { x: 0, z: -116, r: 13 };
export const BOSS_RADIUS = 1.6;
const BASE_HP = 26000;

interface Pending {
  kind: 'toll' | 'slam' | 'rain';
  at: number;
  x: number;
  z: number;
  r: number;
  targets?: [number, number][];
}

/**
 * The Bell-Sworn Prelate — the audit's replacement for the Void Warden. Keeps
 * the proven three-phase shape, but every attack has a readable physical
 * cause and a telegraph:
 *   Toll (all phases)  — ring around the bell; step out before it sounds.
 *   Slam               — the bell drops in front of it.
 *   Bell Rain (P2+)    — cracked bell shards fall on marked circles.
 *   Procession (P2/P3) — penitents file out of the walls on phase change.
 */
export class BossBrain {
  state: BossState = {
    active: false,
    x: BOSS_ARENA.x,
    z: BOSS_ARENA.z,
    facing: 0,
    hp: 1,
    maxHp: 1,
    phase: 1,
    state: 'idle',
    stateT: 0,
    flash: 0,
    fracture: 0,
    fractureT: 0,
    withered: 0,
    witheredT: 0,
    witheredDps: 0,
    level: AREAS.sanctum.level,
  };
  private pending: Pending[] = [];
  private tollCd = 4;
  private slamCd = 2;
  private rainCd = 6;
  private lastHitBy = '';
  private staggerT = 0;

  constructor(private sim: WorldSim) {}

  awaken(by: string) {
    if (this.state.active) return;
    const s = this.state;
    const party = Math.max(1, this.sim.players.size);
    s.active = true;
    s.level = AREAS.sanctum.level + ascensionLevels(this.sim.ascension);
    s.maxHp = BASE_HP * enemyHpScale(s.level) * (1 + 0.8 * (party - 1)) * DIFFICULTIES[this.sim.difficulty].enemyHpMult;
    s.hp = s.maxHp;
    s.phase = 1;
    s.state = 'idle';
    s.stateT = 0;
    s.x = BOSS_ARENA.x;
    s.z = BOSS_ARENA.z - 4;
    this.tollCd = 3.5;
    this.slamCd = 2;
    this.rainCd = 7;
    this.pending = [];
    this.staggerT = 0;
    this.lastHitBy = by;
    this.sim.emit({ t: 'boss', kind: 'awaken', x: s.x, z: s.z, phase: 1 });
  }

  damage(amount: number, by: string, fracture: number) {
    const s = this.state;
    if (!s.active || s.hp <= 0) return;
    s.hp -= amount * (1 + FRACTURE.perStack * s.fracture);
    s.flash = 1;
    this.lastHitBy = by;
    if (fracture) {
      s.fracture = Math.min(FRACTURE.maxStacks, s.fracture + fracture);
      s.fractureT = FRACTURE.durationMs / 1000;
    }
  }

  /** Pause movement, attacks and active telegraphs for a short host-owned stagger. */
  stagger(seconds: number) {
    if (!this.state.active || this.state.hp <= 0) return;
    this.staggerT = Math.max(this.staggerT, seconds);
    this.state.flash = 1;
  }

  private dmg(base: number) {
    return base * enemyDamageScale(this.state.level) * DIFFICULTIES[this.sim.difficulty].enemyDamageMult;
  }

  private setPhase(p: BossPhase) {
    const s = this.state;
    s.phase = p;
    this.sim.emit({ t: 'boss', kind: 'phase', x: s.x, z: s.z, phase: p });
    // Procession: penitents file in from the side aisles.
    const spawns: [number, number][] = [
      [-11, -110],
      [11, -110],
      [-11, -123],
      [11, -123],
    ];
    const count = p === 2 ? 4 : 6;
    for (let i = 0; i < count; i++) {
      const [x, z] = spawns[i % spawns.length];
      this.sim.spawnEnemy(i % 2 ? 'penitent' : 'risen', 'sanctum', x + (i > 3 ? 1.5 : 0), z, false);
    }
    this.sim.emit({ t: 'boss', kind: 'summon', x: s.x, z: s.z, phase: p, targets: spawns });
  }

  update(dt: number) {
    const s = this.state;
    if (!s.active) return;
    s.flash = Math.max(0, s.flash - dt * 4);
    if (s.fractureT > 0 && (s.fractureT -= dt) <= 0) s.fracture = 0;
    if (s.witheredT > 0 && s.withered > 0) {
      s.witheredT -= dt;
      s.hp -= s.withered * s.witheredDps * dt;
      if (s.witheredT <= 0) s.withered = 0;
    }

    if (s.hp <= 0) {
      s.active = false;
      s.state = 'dead';
      this.pending = [];
      this.sim.emit({ t: 'boss', kind: 'defeated', x: s.x, z: s.z, phase: s.phase, killer: this.lastHitBy });
      return;
    }
    const ratio = s.hp / s.maxHp;
    if (s.phase === 1 && ratio <= 0.6) this.setPhase(2);
    else if (s.phase === 2 && ratio <= 0.3) this.setPhase(3);

    const players = [...this.sim.players.values()].filter((p) => p.alive && p.area === 'sanctum');
    if (!players.length) {
      // Everyone left or fell: the Prelate resets and waits to be summoned again.
      s.active = false;
      s.state = 'idle';
      this.pending = [];
      this.sim.emit({ t: 'boss', kind: 'defeated', x: s.x, z: s.z, phase: s.phase, killer: '' });
      return;
    }

    // A stagger pauses the boss clock, including attacks already telegraphed.
    // The room clock keeps advancing, so move their due times forward too.
    if (this.staggerT > 0) {
      const paused = Math.min(dt, this.staggerT);
      this.staggerT -= paused;
      for (const attack of this.pending) attack.at += paused;
      dt -= paused;
      if (dt <= 0) return;
    }
    s.stateT += dt;

    // Resolve telegraphed attacks.
    const now = this.sim.time;
    for (const p of [...this.pending]) {
      if (now < p.at) continue;
      this.pending.splice(this.pending.indexOf(p), 1);
      const circles = p.targets ?? [[p.x, p.z]];
      const hurt = new Set<string>();
      for (const [cx, cz] of circles) {
        for (const pl of players) {
          if (hurt.has(pl.id) || Math.hypot(pl.x - cx, pl.z - cz) > p.r + 0.4) continue;
          hurt.add(pl.id);
          const base = p.kind === 'toll' ? 24 : p.kind === 'slam' ? 20 : 18;
          this.sim.emit({ t: 'hurt', player: pl.id, dmg: this.dmg(base), from: 'boss', x: cx, z: cz });
        }
        for (const t of [...this.sim.thralls.values()]) {
          if (Math.hypot(t.x - cx, t.z - cz) <= p.r) {
            t.hp -= this.dmg(20);
            t.flash = 1;
            if (t.hp <= 0) this.sim.killThrall(t, 'killed');
          }
        }
      }
      this.sim.emit({ t: 'boss', kind: p.kind, x: p.x, z: p.z, phase: s.phase, targets: p.targets, r: p.r, ms: 0 });
    }

    const fast = s.phase === 3 ? 0.62 : s.phase === 2 ? 0.82 : 1;
    this.tollCd -= dt;
    this.slamCd -= dt;
    this.rainCd -= dt;

    let nearest = players[0];
    let nd = Infinity;
    for (const p of players) {
      const d = Math.hypot(p.x - s.x, p.z - s.z);
      if (d < nd) {
        nd = d;
        nearest = p;
      }
    }

    const busy = this.pending.length > 0;
    if (!busy) {
      if (this.tollCd <= 0) {
        this.tollCd = 9 * fast;
        const ms = 1500 * (s.phase === 3 ? 0.8 : 1);
        this.telegraph('toll', s.x, s.z, 6.5, ms);
      } else if (this.rainCd <= 0 && s.phase >= 2) {
        this.rainCd = 8 * fast;
        const targets: [number, number][] = players.map((p) => [p.x, p.z]);
        const extra = s.phase === 3 ? 4 : 2;
        for (let i = 0; i < extra; i++) {
          const a = this.sim.rand() * Math.PI * 2;
          const r = 3 + this.sim.rand() * (BOSS_ARENA.r - 4);
          targets.push([BOSS_ARENA.x + Math.cos(a) * r, BOSS_ARENA.z + Math.sin(a) * r]);
        }
        this.telegraph('rain', s.x, s.z, 2.3, 1400, targets);
      } else if (this.slamCd <= 0 && nd < 4.5) {
        this.slamCd = 3.2 * fast;
        const dirX = (nearest.x - s.x) / (nd || 1);
        const dirZ = (nearest.z - s.z) / (nd || 1);
        this.telegraph('slam', s.x + dirX * 2.6, s.z + dirZ * 2.6, 2.6, 900 * (s.phase === 3 ? 0.8 : 1));
      }
    }

    // Lumber toward the nearest player, staying inside the sanctum.
    const speed = (s.phase === 3 ? 2.6 : s.phase === 2 ? 2 : 1.6) * (busy ? 0.25 : 1);
    if (nd > 3) {
      const dx = nearest.x - s.x;
      const dz = nearest.z - s.z;
      s.x += (dx / nd) * speed * dt;
      s.z += (dz / nd) * speed * dt;
      const ox = s.x - BOSS_ARENA.x;
      const oz = s.z - BOSS_ARENA.z;
      const or = Math.hypot(ox, oz);
      if (or > BOSS_ARENA.r - 2) {
        s.x = BOSS_ARENA.x + (ox / or) * (BOSS_ARENA.r - 2);
        s.z = BOSS_ARENA.z + (oz / or) * (BOSS_ARENA.r - 2);
      }
      s.state = busy ? s.state : 'move';
    }
    s.facing = Math.atan2(nearest.x - s.x, nearest.z - s.z);
  }

  private telegraph(kind: Pending['kind'], x: number, z: number, r: number, ms: number, targets?: [number, number][]) {
    this.pending.push({ kind, at: this.sim.time + ms / 1000, x, z, r, targets });
    this.state.state = kind === 'rain' ? 'rain' : kind;
    this.state.stateT = 0;
    this.sim.emit({ t: 'boss', kind, x, z, phase: this.state.phase, targets, r, ms });
  }
}
