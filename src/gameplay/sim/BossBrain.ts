import { AREAS } from '../../../server/rules/content/areas';
import { enemyDamageScale, enemyHpScale } from '../../../server/rules/content/enemies';
import { FRACTURE } from '../../content/abilities';
import { DIFFICULTIES } from '../../../server/rules/content/difficulty';
import { ABBESS, ABBESS_NICHE_SPOTS, BOSSES, CONGREGATION, GRAVEDIGGER, GRAVEDIGGER_PITS, MIRE, REGENT, SAINT, type BossId } from '../../../server/rules/content/bosses';
import { FEN_FLOOD_SCALE, FEN_HUMMOCKS, FEN_SURFACE_SPOTS, inBog, hummockAt } from '../../../server/rules/content/fen';
import type { EnemyId } from '../../../server/rules/content/enemies';
import { EMPOWER, empoweredLevel } from '../../../server/rules/gameplay/goldSinkRules';
import type { WorldSim } from './WorldSim';
import type { BossPhase, BossState, PlayerBody } from './types';

/** The Prelate's arena (kept for older call sites; every boss's arena lives in content/bosses.ts). */
export const BOSS_ARENA = BOSSES.prelate.arena;
export const BOSS_RADIUS = 1.6;
/** A boss ring strikes this far past its nominal radius (a body width); telegraphs draw it so the red is where the blow lands. */
export const BOSS_RING_PAD = 0.4;

export interface Pending {
  kind: string;
  at: number;
  x: number;
  z: number;
  r: number;
  targets?: [number, number][];
  /** Facing (radians) for cones, lines and spokes. */
  dir?: number;
  /** A niche's attacks don't count as the boss being busy. */
  side?: boolean;
}

/** Axis-aligned cover box (Drowned Congregation pews), same shape as the nav's prop boxes. */
export interface CoverBox {
  x0: number;
  z0: number;
  x1: number;
  z1: number;
}

const angleTo = (fx: number, fz: number, tx: number, tz: number) => Math.atan2(tx - fx, tz - fz);
const angleDiff = (a: number, b: number) => {
  let d = Math.abs(a - b) % (Math.PI * 2);
  return d > Math.PI ? Math.PI * 2 - d : d;
};
/** Distance from P to the segment AB. */
function segDist(px: number, pz: number, ax: number, az: number, bx: number, bz: number) {
  const vx = bx - ax;
  const vz = bz - az;
  const l2 = vx * vx + vz * vz || 1;
  const t = Math.max(0, Math.min(1, ((px - ax) * vx + (pz - az) * vz) / l2));
  return Math.hypot(px - (ax + vx * t), pz - (az + vz * t));
}
/** Does segment AB cross the box (slab test)? */
export function segmentHitsBox(ax: number, az: number, bx: number, bz: number, b: CoverBox) {
  let t0 = 0;
  let t1 = 1;
  const d = [bx - ax, bz - az];
  const o = [ax, az];
  const lo = [b.x0, b.z0];
  const hi = [b.x1, b.z1];
  for (let i = 0; i < 2; i++) {
    if (Math.abs(d[i]) < 1e-9) {
      if (o[i] < lo[i] || o[i] > hi[i]) return false;
      continue;
    }
    let ta = (lo[i] - o[i]) / d[i];
    let tb = (hi[i] - o[i]) / d[i];
    if (ta > tb) [ta, tb] = [tb, ta];
    t0 = Math.max(t0, ta);
    t1 = Math.min(t1, tb);
    if (t0 > t1) return false;
  }
  return true;
}

/**
 * Shared boss machinery (area-bosses brief §2): awaken, damage + Fracture + Withered, a host-owned stagger,
 * phase thresholds at 60% / 30%, telegraphed attacks resolved on time, the wipe reset, defeat, and the arena leash.
 * Each boss adds its attacks in `think` and how they land in `resolve`.
 */
export abstract class BossBrain {
  readonly def;
  state: BossState;
  protected pending: Pending[] = [];
  protected lastHitBy = '';
  protected staggerT = 0;
  private adds = new Set<number>();

  constructor(protected sim: WorldSim, readonly id: BossId) {
    this.def = BOSSES[id];
    this.state = {
      id,
      active: false,
      x: this.def.arena.x,
      z: this.def.arena.z,
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
      level: AREAS[this.def.area].level,
    };
  }

  protected get arena() {
    return this.def.arena;
  }

  /** `empowered`: a Covenant Seal summon (goldSinkRules): the level knob goes up and so does the health. */
  awaken(by: string, empowered = false) {
    if (this.state.active) return;
    const s = this.state;
    const party = Math.max(1, this.sim.players.size);
    s.active = true;
    s.empowered = empowered;
    s.level = this.sim.areaLevel(this.def.area);
    if (empowered) s.level = empoweredLevel(s.level);
    s.maxHp = this.def.baseHp * enemyHpScale(s.level) * (empowered ? EMPOWER.hpMult : 1) * (1 + 0.8 * (party - 1)) * DIFFICULTIES[this.sim.difficulty].enemyHpMult;
    s.hp = s.maxHp;
    s.phase = 1;
    s.state = 'idle';
    s.stateT = 0;
    s.x = this.arena.x;
    s.z = this.arena.z;
    s.facing = 0;
    s.flash = 0;
    s.fracture = 0;
    s.fractureT = 0;
    s.withered = 0;
    s.witheredT = 0;
    s.witheredDps = 0;
    this.pending = [];
    this.staggerT = 0;
    this.adds.clear();
    this.lastHitBy = by;
    this.onAwaken();
    this.sim.emit({ t: 'boss', kind: 'awaken', x: s.x, z: s.z, phase: 1, boss: this.id, ...(empowered ? { empowered: true } : {}) });
  }

  protected abstract onAwaken(): void;
  protected abstract onPhase(p: BossPhase): void;
  protected abstract think(dt: number, players: PlayerBody[]): void;
  protected onDefeat() {}
  /** Host migration: rebuild what only the old host's brain knew (niches, pits). Cooldowns restart. */
  resume() {}

  /** Adds belong to this attempt; they leave with the boss without granting a kill or a corpse. */
  protected spawnAdd(def: EnemyId, x: number, z: number, elite = false) {
    const enemy = this.sim.spawnEnemy(def, this.def.area, x, z, elite);
    this.adds.add(enemy.id);
    return enemy;
  }

  private clearAdds() {
    for (const id of this.adds) this.sim.enemies.delete(id);
    this.adds.clear();
  }
  /** Extra per-tick work before attacks (regen, hazards); runs after the stagger. */
  protected tick(_dt: number, _players: PlayerBody[]) {}

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

  protected dmg(base: number) {
    return base * enemyDamageScale(this.state.level) * DIFFICULTIES[this.sim.difficulty].enemyDamageMult;
  }

  private setPhase(p: BossPhase) {
    const s = this.state;
    s.phase = p;
    this.sim.emit({ t: 'boss', kind: 'phase', x: s.x, z: s.z, phase: p, boss: this.id });
    this.onPhase(p);
  }

  update(dt: number) {
    const s = this.state;
    if (!s.active) return;
    s.flash = Math.max(0, s.flash - dt * 4);
    if (s.fractureT > 0 && (s.fractureT -= dt) <= 0) s.fracture = 0;
    if (s.witheredT > 0 && s.withered > 0) {
      s.witheredT -= dt;
      // The Mire Mother is untouchable while sunk (damage() refuses her): rot ticks run out but do not bite.
      if (s.state !== 'sunk') s.hp -= s.withered * s.witheredDps * dt;
      if (s.witheredT <= 0) s.withered = 0;
    }

    if (s.hp <= 0) {
      s.active = false;
      s.state = 'dead';
      this.pending = [];
      this.onDefeat();
      this.clearAdds();
      this.sim.emit({ t: 'boss', kind: 'defeated', x: s.x, z: s.z, phase: s.phase, killer: this.lastHitBy, boss: this.id, ...(s.empowered ? { empowered: true } : {}) });
      return;
    }
    const ratio = s.hp / s.maxHp;
    if (s.phase === 1 && ratio <= 0.6) this.setPhase(2);
    else if (s.phase === 2 && ratio <= 0.3) this.setPhase(3);

    const players = [...this.sim.players.values()].filter((p) => p.alive && p.area === this.def.area);
    if (!players.length) {
      // Everyone left or fell: the boss resets and waits to be summoned again.
      s.active = false;
      s.state = 'idle';
      this.pending = [];
      this.onDefeat();
      this.clearAdds();
      this.sim.emit({ t: 'boss', kind: 'defeated', x: s.x, z: s.z, phase: s.phase, killer: '', boss: this.id });
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
    this.tick(dt, players);

    // Resolve telegraphed attacks.
    const now = this.sim.time;
    for (const p of [...this.pending]) {
      if (now < p.at) continue;
      this.pending.splice(this.pending.indexOf(p), 1);
      this.resolve(p, players);
    }
    this.think(dt, players);
  }

  /** Default resolution: circles (Prelate toll/slam/rain, and any boss's ring attack). */
  protected resolve(p: Pending, players: PlayerBody[]) {
    const s = this.state;
    const circles = p.targets ?? [[p.x, p.z]];
    const hurt = new Set<string>();
    for (const [cx, cz] of circles) {
      for (const pl of players) {
        if (hurt.has(pl.id) || Math.hypot(pl.x - cx, pl.z - cz) > p.r + BOSS_RING_PAD) continue;
        hurt.add(pl.id);
        this.sim.emit({ t: 'hurt', player: pl.id, dmg: this.dmg(this.circleDamage(p.kind)), from: 'boss', x: cx, z: cz });
      }
      this.hurtThralls((t) => Math.hypot(t.x - cx, t.z - cz) <= p.r);
    }
    this.sim.emit({ t: 'boss', kind: p.kind as never, x: p.x, z: p.z, phase: s.phase, targets: p.targets, r: p.r, ms: 0, boss: this.id });
  }

  protected circleDamage(_kind: string) {
    return 20;
  }

  protected hurtThralls(inside: (t: { x: number; z: number }) => boolean, base = 20) {
    for (const t of [...this.sim.thralls.values()]) {
      if (!inside(t)) continue;
      t.hp -= this.dmg(base);
      t.flash = 1;
      if (t.hp <= 0) this.sim.killThrall(t, 'killed');
    }
  }

  /** A cone / line / spoke hit on players: emits hurt for each caught body and returns their ids. */
  protected strikePlayers(players: PlayerBody[], caught: (p: PlayerBody) => boolean, base: number, x: number, z: number) {
    const ids: string[] = [];
    for (const pl of players) {
      if (!caught(pl)) continue;
      ids.push(pl.id);
      this.sim.emit({ t: 'hurt', player: pl.id, dmg: this.dmg(base), from: 'boss', x, z });
    }
    return ids;
  }

  protected telegraph(kind: string, x: number, z: number, r: number, ms: number, extra: Partial<Pending> = {}, delayMs = 0) {
    const p: Pending = { kind, at: this.sim.time + (ms + delayMs) / 1000, x, z, r, ...extra };
    this.pending.push(p);
    if (!p.side) {
      this.state.state = (['toll', 'slam', 'rain', 'summon'].includes(kind) ? kind : kind === 'rotRain' || kind === 'coals' || kind === 'conflagration' || kind === 'hands' || kind === 'rite' || kind === 'bury' || kind === 'hymn' || kind === 'grasp' || kind === 'chorus' || kind === 'communion' ? 'rain' : 'slam') as BossState['state'];
      this.state.stateT = 0;
    }
    this.sim.emit({ t: 'boss', kind: kind as never, x, z, phase: this.state.phase, targets: p.targets, r, ms: ms + delayMs, dir: p.dir, boss: this.id });
  }

  protected get busy() {
    return this.pending.some((p) => !p.side);
  }

  protected nearest(players: PlayerBody[]) {
    const s = this.state;
    let nearest = players[0];
    let nd = Infinity;
    for (const p of players) {
      const d = Math.hypot(p.x - s.x, p.z - s.z);
      if (d < nd) {
        nd = d;
        nearest = p;
      }
    }
    return { nearest, nd };
  }

  /** Lumber toward the nearest player, leashed inside the arena (radius − margin). */
  protected chase(nearest: PlayerBody, nd: number, speed: number, dt: number, margin = 2, stopAt = 3, busy = this.busy) {
    const s = this.state;
    if (nd > stopAt) {
      const dx = nearest.x - s.x;
      const dz = nearest.z - s.z;
      s.x += (dx / nd) * speed * dt;
      s.z += (dz / nd) * speed * dt;
      const ox = s.x - this.arena.x;
      const oz = s.z - this.arena.z;
      const or = Math.hypot(ox, oz);
      if (or > this.arena.r - margin) {
        s.x = this.arena.x + (ox / or) * (this.arena.r - margin);
        s.z = this.arena.z + (oz / or) * (this.arena.r - margin);
      }
      s.state = busy ? s.state : 'move';
    }
    s.facing = Math.atan2(nearest.x - s.x, nearest.z - s.z);
  }

  /** A point on the arena rim (for adds and pits). */
  protected rim(angle: number, frac = 0.85): [number, number] {
    return [this.arena.x + Math.sin(angle) * this.arena.r * frac, this.arena.z + Math.cos(angle) * this.arena.r * frac];
  }
}

/**
 * The Bell-Sworn Prelate — unchanged from the single-boss build. Every attack has a readable physical cause and a
 * telegraph:
 *   Toll (all phases)  — ring around the bell; step out before it sounds.
 *   Slam               — the bell drops in front of it.
 *   Bell Rain (P2+)    — cracked bell shards fall on marked circles.
 *   Procession (P2/P3) — penitents file out of the walls on phase change.
 */
export class PrelateBrain extends BossBrain {
  private tollCd = 4;
  private slamCd = 2;
  private rainCd = 6;
  /** Prelate Echoes III: when the chasing volley is aimed (0 = none pending). */
  private chaseAt = 0;

  constructor(sim: WorldSim) {
    super(sim, 'prelate');
  }

  protected tick(_dt: number, players: PlayerBody[]) {
    if (this.chaseAt && this.sim.time >= this.chaseAt) {
      this.chaseAt = 0;
      if (players.length) this.telegraph('rain', this.state.x, this.state.z, 2.3, 1100, { targets: players.map((p) => [p.x, p.z] as [number, number]), side: true });
    }
  }

  protected onAwaken() {
    this.state.z = BOSS_ARENA.z - 4;
    this.tollCd = 3.5;
    this.slamCd = 2;
    this.rainCd = 7;
    this.chaseAt = 0;
  }

  protected circleDamage(kind: string) {
    return kind === 'toll' ? 24 : kind === 'slam' ? 20 : 18;
  }

  protected onPhase(p: BossPhase) {
    const s = this.state;
    // Procession: penitents file in from the side aisles.
    const spawns: [number, number][] = [
      [-11, -110],
      [11, -110],
      [-11, -123],
      [11, -123],
    ];
    // Prelate Echoes II: the procession is longer and its first two walkers are elite.
    const echoes = this.sim.vowFx.echoes;
    const count = (p === 2 ? 4 : 6) + (echoes >= 2 ? 2 : 0);
    for (let i = 0; i < count; i++) {
      const [x, z] = spawns[i % spawns.length];
      this.spawnAdd(i % 2 ? 'penitent' : 'risen', x + (i > 3 ? 1.5 : 0), z, echoes >= 2 && i < 2);
    }
    this.sim.emit({ t: 'boss', kind: 'summon', x: s.x, z: s.z, phase: p, targets: spawns, boss: this.id });
  }

  protected think(dt: number, players: PlayerBody[]) {
    const s = this.state;
    const fast = s.phase === 3 ? 0.62 : s.phase === 2 ? 0.82 : 1;
    this.tollCd -= dt;
    this.slamCd -= dt;
    this.rainCd -= dt;
    const { nearest, nd } = this.nearest(players);
    const busy = this.busy;
    if (!busy) {
      if (this.tollCd <= 0) {
        this.tollCd = 9 * fast;
        const ms = 1500 * (s.phase === 3 ? 0.8 : 1);
        this.telegraph('toll', s.x, s.z, 6.5, ms);
        // Prelate Echoes I, the second bell: a smaller toll answers on whoever stands farthest from the first, a moment later.
        if (this.sim.vowFx.echoes >= 1 && players.length) {
          const far = players.reduce((a, b) => (Math.hypot(b.x - s.x, b.z - s.z) > Math.hypot(a.x - s.x, a.z - s.z) ? b : a));
          this.telegraph('toll', far.x, far.z, 3.6, 1300, { side: true }, ms + 600);
        }
      } else if (this.rainCd <= 0 && s.phase >= 2) {
        this.rainCd = 8 * fast;
        const targets: [number, number][] = players.map((p) => [p.x, p.z]);
        const extra = s.phase === 3 ? 4 : 2;
        for (let i = 0; i < extra; i++) {
          const a = this.sim.rand() * Math.PI * 2;
          const r = 3 + this.sim.rand() * (BOSS_ARENA.r - 4);
          targets.push([BOSS_ARENA.x + Math.cos(a) * r, BOSS_ARENA.z + Math.sin(a) * r]);
        }
        this.telegraph('rain', s.x, s.z, 2.3, 1400, { targets });
        // Prelate Echoes III, chasing rain: a second volley is aimed at wherever each player has run to a moment later (see tick).
        if (this.sim.vowFx.echoes >= 3) this.chaseAt = this.sim.time + 1.6;
      } else if (this.slamCd <= 0 && nd < 4.5) {
        this.slamCd = 3.2 * fast;
        const dirX = (nearest.x - s.x) / (nd || 1);
        const dirZ = (nearest.z - s.z) / (nd || 1);
        this.telegraph('slam', s.x + dirX * 2.6, s.z + dirZ * 2.6, 2.6, 900 * (s.phase === 3 ? 0.8 : 1));
      }
    }
    const speed = (s.phase === 3 ? 2.6 : s.phase === 2 ? 2 : 1.6) * (busy ? 0.25 : 1);
    // `busy` from before this tick's attack choice, exactly as the single-boss build did.
    this.chase(nearest, nd, speed, dt, 2, 3, busy);
  }
}

/**
 * The Gravedigger King (Hollow Graves). Spade Sweep (cone) and Burial (a grave outline under you: leave it or be
 * Buried — rooted, casting allowed). P2 digs Barrow Ghouls up at the rim; P3 opens four pits that bury whoever walks in.
 */
export class GravediggerBrain extends BossBrain {
  private sweepCd = 2.5;
  private buryCd = 4;
  private exhumeCd = 0;
  private eliteDone = false;
  private pits: [number, number][] = [];
  private pitCd = new Map<string, number>();

  constructor(sim: WorldSim) {
    super(sim, 'gravedigger');
  }

  protected onAwaken() {
    this.sweepCd = 2.5;
    this.buryCd = 4;
    this.exhumeCd = 4;
    this.eliteDone = false;
    this.pits = [];
    this.pitCd.clear();
  }

  protected onPhase(p: BossPhase) {
    const s = this.state;
    if (p === 3) {
      // Open Graves: four pits at fixed points around the arena.
      this.pits = GRAVEDIGGER_PITS.map(([x, z]) => [x, z] as [number, number]);
      this.sim.emit({ t: 'boss', kind: 'pits', x: s.x, z: s.z, phase: p, targets: this.pits, r: GRAVEDIGGER.pits.r, boss: this.id });
    }
  }

  protected onDefeat() {
    this.pits = [];
  }

  /** Host migration: the pits are open again if he was already in his last phase. */
  resume() {
    this.pits = this.state.phase >= 3 ? GRAVEDIGGER_PITS.map(([x, z]) => [x, z] as [number, number]) : [];
    this.eliteDone = this.state.hp / this.state.maxHp <= 0.45;
  }

  protected tick(dt: number, players: PlayerBody[]) {
    // Walking into an open grave buries you (per-player cooldown so it can't chain-lock).
    if (!this.pits.length) return;
    const G = GRAVEDIGGER;
    for (const pl of players) {
      const cd = (this.pitCd.get(pl.id) ?? 0) - dt;
      this.pitCd.set(pl.id, cd);
      if (cd > 0) continue;
      const pit = this.pits.find(([x, z]) => Math.hypot(pl.x - x, pl.z - z) <= G.pits.r);
      if (!pit) continue;
      this.pitCd.set(pl.id, G.pits.reburyS);
      this.sim.emit({ t: 'hurt', player: pl.id, dmg: this.dmg(G.burial.dmg * 0.6), from: 'boss', x: pit[0], z: pit[1] });
      this.sim.emit({ t: 'boss', kind: 'bury', x: pit[0], z: pit[1], phase: this.state.phase, ms: 0, players: [pl.id], root: G.burial.rootS, boss: this.id });
    }
  }

  protected resolve(p: Pending, players: PlayerBody[]) {
    const G = GRAVEDIGGER;
    const s = this.state;
    if (p.kind === 'sweep') {
      const ids = this.strikePlayers(players, (pl) => Math.hypot(pl.x - p.x, pl.z - p.z) <= G.sweep.r + 0.3 && angleDiff(angleTo(p.x, p.z, pl.x, pl.z), p.dir!) <= (G.sweep.halfDeg * Math.PI) / 180, G.sweep.dmg, p.x, p.z);
      this.hurtThralls((t) => Math.hypot(t.x - p.x, t.z - p.z) <= G.sweep.r && angleDiff(angleTo(p.x, p.z, t.x, t.z), p.dir!) <= (G.sweep.halfDeg * Math.PI) / 180);
      this.sim.emit({ t: 'boss', kind: 'sweep', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, players: ids, boss: this.id });
      return;
    }
    if (p.kind === 'bury') {
      const caught = new Set<string>();
      for (const [gx, gz] of p.targets ?? []) {
        for (const pl of players) {
          if (Math.abs(pl.x - gx) <= G.burial.hw + 0.3 && Math.abs(pl.z - gz) <= G.burial.hd + 0.3) caught.add(pl.id);
        }
      }
      for (const id of caught) this.sim.emit({ t: 'hurt', player: id, dmg: this.dmg(G.burial.dmg), from: 'boss', x: p.x, z: p.z });
      this.sim.emit({ t: 'boss', kind: 'bury', x: p.x, z: p.z, phase: s.phase, targets: p.targets, ms: 0, players: [...caught], root: G.burial.rootS, boss: this.id });
      return;
    }
    super.resolve(p, players);
  }

  protected think(dt: number, players: PlayerBody[]) {
    const G = GRAVEDIGGER;
    const s = this.state;
    const fast = s.phase === 3 ? 0.75 : s.phase === 2 ? 0.88 : 1;
    this.sweepCd -= dt;
    this.buryCd -= dt;
    const { nearest, nd } = this.nearest(players);
    if (s.phase >= 2) {
      this.exhumeCd -= dt;
      if (this.exhumeCd <= 0) {
        // Exhumation: Barrow Ghouls dug up at the rim (they climb out burrowed).
        this.exhumeCd = G.exhume.everyS;
        const spots: [number, number][] = [];
        for (let i = 0; i < G.exhume.ghouls; i++) {
          const at = this.rim(this.sim.rand() * Math.PI * 2);
          spots.push(at);
          this.spawnAdd('ghoul', at[0], at[1]);
        }
        this.sim.emit({ t: 'boss', kind: 'summon', x: s.x, z: s.z, phase: s.phase, targets: spots, boss: this.id });
      }
      if (!this.eliteDone && s.hp / s.maxHp <= 0.45) {
        this.eliteDone = true;
        const at = this.rim(angleTo(this.arena.x, this.arena.z, nearest.x, nearest.z) + Math.PI);
        this.spawnAdd('robber', at[0], at[1], true);
      }
    }
    if (!this.busy) {
      if (this.buryCd <= 0) {
        this.buryCd = G.burial.cd * fast;
        // Up to two players (every player in P3) get a grave outline under their feet.
        const marked = s.phase === 3 ? players : [...players].sort((a, b) => Math.hypot(a.x - s.x, a.z - s.z) - Math.hypot(b.x - s.x, b.z - s.z)).slice(0, 2);
        this.telegraph('bury', s.x, s.z, G.burial.hd, G.burial.windupMs, { targets: marked.map((pl) => [pl.x, pl.z]) });
      } else if (this.sweepCd <= 0 && nd < G.sweep.r + 1) {
        this.sweepCd = G.sweep.cd * fast;
        const dir = angleTo(s.x, s.z, nearest.x, nearest.z);
        this.telegraph('sweep', s.x, s.z, G.sweep.r, G.sweep.windupMs, { dir });
        if (s.phase === 3) this.telegraph('sweep', s.x, s.z, G.sweep.r, G.sweep.windupMs, { dir: dir + Math.PI / 3 }, 650);
      }
    }
    this.chase(nearest, nd, (s.phase === 3 ? 2.6 : s.phase === 2 ? 2.2 : 1.8) * (this.busy ? 0.3 : 1), dt, 2, 2.5);
  }
}

/**
 * The Bone Abbess (Marrow Ossuary). Four skull niches (targetable enemies) heal her and fire Bone Lances; breaking
 * one hurts and Fractures her. Ossuary Chorus radiates eight spokes (twice in P2). P3 rebuilds two niches once and
 * channels Bone Communion: every corpse in the arena crawls to her and heals her — spend them first.
 */
export class AbbessBrain extends BossBrain {
  private niches: number[] = [];
  private nicheSpots: [number, number][] = [];
  private broken = new Set<number>();
  private lanceCd = 4;
  private chorusCd = 5;
  private graspCd = 2;
  private communionCd = 6;
  private rebuilt = false;

  constructor(sim: WorldSim) {
    super(sim, 'abbess');
  }

  get nicheIds() {
    return this.niches;
  }

  private spawnNiche(i: number) {
    const [x, z] = this.nicheSpots[i];
    const e = this.sim.spawnEnemy('niche', this.def.area, x, z, false, false);
    e.maxHp = e.hp = this.state.maxHp * ABBESS.nicheHpFrac;
    this.niches[i] = e.id;
    this.broken.delete(i);
  }

  protected onAwaken() {
    this.nicheSpots = ABBESS_NICHE_SPOTS.map(([x, z]) => [x, z] as [number, number]);
    this.niches = [];
    this.broken.clear();
    this.rebuilt = false;
    this.lanceCd = 4;
    this.chorusCd = 5;
    this.graspCd = 2;
    this.communionCd = 6;
    for (let i = 0; i < ABBESS.niches; i++) this.spawnNiche(i);
  }

  protected onDefeat() {
    // The niches crumble with her. Removed outright (like adds), so no death event pays out a kill.
    for (const id of this.niches) this.sim.enemies.delete(id);
    this.niches = [];
  }

  /** Host migration: re-find the standing niches by their fixed spots. */
  resume() {
    this.nicheSpots = ABBESS_NICHE_SPOTS.map(([x, z]) => [x, z] as [number, number]);
    this.niches = [];
    this.broken.clear();
    this.nicheSpots.forEach(([x, z], i) => {
      const e = [...this.sim.enemies.values()].find((o) => o.def === 'niche' && Math.hypot(o.x - x, o.z - z) < 1.5);
      if (e) this.niches[i] = e.id;
      else {
        this.niches[i] = -1;
        this.broken.add(i);
      }
    });
    this.rebuilt = this.state.phase >= 3;
  }

  private alive(i: number) {
    const e = this.sim.enemies.get(this.niches[i]);
    return !!e && e.state !== 'dead' && e.hp > 0;
  }

  protected onPhase(p: BossPhase) {
    if (p === 3 && !this.rebuilt) {
      // Rebuild: two broken niches re-form, once.
      this.rebuilt = true;
      let n = 0;
      for (let i = 0; i < this.nicheSpots.length && n < 2; i++) if (!this.alive(i)) (this.spawnNiche(i), n++);
      if (n) this.sim.emit({ t: 'boss', kind: 'summon', x: this.state.x, z: this.state.z, phase: p, targets: this.nicheSpots, boss: this.id });
    }
  }

  protected tick(dt: number, players: PlayerBody[]) {
    const s = this.state;
    let standing = 0;
    for (let i = 0; i < this.niches.length; i++) {
      if (this.alive(i)) {
        standing++;
        continue;
      }
      if (this.broken.has(i)) continue;
      // A niche broke: it tears at her (4% max health) and Fractures her.
      this.broken.add(i);
      s.hp -= s.maxHp * ABBESS.nicheBreakFrac;
      s.flash = 1;
      s.fracture = Math.min(FRACTURE.maxStacks, s.fracture + 1);
      s.fractureT = FRACTURE.durationMs / 1000;
      const [x, z] = this.nicheSpots[i];
      this.sim.emit({ t: 'boss', kind: 'nicheBreak', x, z, phase: s.phase, boss: this.id });
    }
    if (standing > 0) {
      s.hp = Math.min(s.maxHp, s.hp + s.maxHp * ABBESS.regenPerS * dt);
      this.lanceCd -= dt;
      if (this.lanceCd <= 0 && players.length) {
        // A Bone Lance from a standing niche at a random player.
        this.lanceCd = ABBESS.lance.everyS;
        const up = this.nicheSpots.filter((_, i) => this.alive(i));
        const [nx, nz] = up[Math.floor(this.sim.rand() * up.length)];
        const pl = players[Math.floor(this.sim.rand() * players.length)];
        this.telegraph('lance', nx, nz, ABBESS.lance.len, ABBESS.lance.windupMs, { dir: angleTo(nx, nz, pl.x, pl.z), side: true });
      }
    }
  }

  get standingNiches() {
    return this.niches.filter((_, i) => this.alive(i)).length;
  }

  protected resolve(p: Pending, players: PlayerBody[]) {
    const A = ABBESS;
    const s = this.state;
    const tip = (len: number, dir: number): [number, number] => [p.x + Math.sin(dir) * len, p.z + Math.cos(dir) * len];
    if (p.kind === 'lance') {
      const [bx, bz] = tip(A.lance.len, p.dir!);
      this.strikePlayers(players, (pl) => segDist(pl.x, pl.z, p.x, p.z, bx, bz) <= A.lance.halfWidth, A.lance.dmg, p.x, p.z);
      this.hurtThralls((t) => segDist(t.x, t.z, p.x, p.z, bx, bz) <= A.lance.halfWidth);
      this.sim.emit({ t: 'boss', kind: 'lance', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    if (p.kind === 'chorus') {
      const spokes = Array.from({ length: A.chorus.spokes }, (_, i) => p.dir! + (i * Math.PI * 2) / A.chorus.spokes);
      const onSpoke = (x: number, z: number) => spokes.some((d) => {
        const [bx, bz] = tip(A.chorus.len, d);
        return segDist(x, z, p.x, p.z, bx, bz) <= A.chorus.halfWidth;
      });
      this.strikePlayers(players, (pl) => onSpoke(pl.x, pl.z), A.chorus.dmg, p.x, p.z);
      this.hurtThralls((t) => onSpoke(t.x, t.z));
      this.sim.emit({ t: 'boss', kind: 'chorus', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    if (p.kind === 'grasp') {
      this.strikePlayers(players, (pl) => Math.hypot(pl.x - p.x, pl.z - p.z) <= A.grasp.r + 0.3 && angleDiff(angleTo(p.x, p.z, pl.x, pl.z), p.dir!) <= (A.grasp.halfDeg * Math.PI) / 180, A.grasp.dmg, p.x, p.z);
      this.sim.emit({ t: 'boss', kind: 'grasp', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    if (p.kind === 'communion') {
      // Every corpse still in the arena crawls to her and feeds her.
      let fed = 0;
      for (const c of [...this.sim.corpses.values()]) {
        if (c.area !== this.def.area || Math.hypot(c.x - this.arena.x, c.z - this.arena.z) > this.arena.r) continue;
        this.sim.removeCorpse(c, 'devoured');
        fed++;
      }
      s.hp = Math.min(s.maxHp, s.hp + s.maxHp * A.communion.healPerCorpse * fed);
      this.sim.emit({ t: 'boss', kind: 'communion', x: p.x, z: p.z, phase: s.phase, ms: 0, r: fed, boss: this.id });
      return;
    }
    super.resolve(p, players);
  }

  protected think(dt: number, players: PlayerBody[]) {
    const A = ABBESS;
    const s = this.state;
    const fast = s.phase === 3 ? 0.8 : s.phase === 2 ? 0.9 : 1;
    this.chorusCd -= dt;
    this.graspCd -= dt;
    if (s.phase === 3) this.communionCd -= dt;
    const { nearest, nd } = this.nearest(players);
    if (!this.busy) {
      if (s.phase === 3 && this.communionCd <= 0) {
        this.communionCd = A.communion.cd;
        const corpses: [number, number][] = [...this.sim.corpses.values()]
          .filter((c) => c.area === this.def.area && Math.hypot(c.x - this.arena.x, c.z - this.arena.z) <= this.arena.r)
          .map((c) => [c.x, c.z]);
        this.telegraph('communion', s.x, s.z, this.arena.r, A.communion.channelS * 1000, { targets: corpses });
      } else if (this.chorusCd <= 0) {
        this.chorusCd = A.chorus.cd * fast;
        const dir = this.sim.rand() * Math.PI * 2;
        this.telegraph('chorus', s.x, s.z, A.chorus.len, A.chorus.windupMs, { dir });
        if (s.phase >= 2) this.telegraph('chorus', s.x, s.z, A.chorus.len, A.chorus.windupMs, { dir: dir + (A.chorus.rotateDeg * Math.PI) / 180 }, 900);
      } else if (this.graspCd <= 0 && nd < A.grasp.r + 0.5) {
        this.graspCd = A.grasp.cd * fast;
        this.telegraph('grasp', s.x, s.z, A.grasp.r, A.grasp.windupMs, { dir: angleTo(s.x, s.z, nearest.x, nearest.z) });
      }
    }
    this.chase(nearest, nd, (s.phase === 3 ? 2 : s.phase === 2 ? 1.7 : 1.4) * (this.busy ? 0.25 : 1), dt, 2.5, 2.8);
  }
}

/**
 * The Drowned Congregation (Drowned Nave). Flood Hymn sweeps a 120° arc from her: a pew between you and her is the
 * only cover. Drowning Grasp rings root whoever stays in them. Each phase the water rises (players slow outside the
 * dais; Soaked in P3 takes more from the Hymn) and the congregation — wraiths and penitents — climbs out.
 */
export class CongregationBrain extends BossBrain {
  private hymnCd = 6;
  private graspCd = 3;
  private meleeCd = 2;

  constructor(sim: WorldSim) {
    super(sim, 'congregation');
  }

  protected onAwaken() {
    this.hymnCd = 6;
    this.graspCd = 3;
    this.meleeCd = 2;
  }

  protected onPhase(p: BossPhase) {
    const s = this.state;
    const spots: [number, number][] = [];
    for (let i = 0; i < 6; i++) {
      const at = this.rim((i / 6) * Math.PI * 2 + 0.3);
      spots.push(at);
      this.spawnAdd(i < 4 ? 'wraith' : 'penitent', at[0], at[1]);
    }
    this.sim.emit({ t: 'boss', kind: 'summon', x: s.x, z: s.z, phase: p, targets: spots, boss: this.id });
  }

  /** Is the player sheltered from her by a pew? */
  covered(px: number, pz: number, fromX = this.state.x, fromZ = this.state.z) {
    return this.sim.cover.some((b) => segmentHitsBox(fromX, fromZ, px, pz, b));
  }

  protected resolve(p: Pending, players: PlayerBody[]) {
    const C = CONGREGATION;
    const s = this.state;
    if (p.kind === 'hymn') {
      const inArc = (x: number, z: number) => Math.hypot(x - p.x, z - p.z) <= C.hymn.reach && angleDiff(angleTo(p.x, p.z, x, z), p.dir!) <= (C.hymn.halfDeg * Math.PI) / 180;
      for (const pl of players) {
        if (!inArc(pl.x, pl.z) || this.covered(pl.x, pl.z, p.x, p.z)) continue;
        const soaked = s.phase === 3 && Math.hypot(pl.x - this.arena.x, pl.z - this.arena.z) > C.water.dais;
        this.sim.emit({ t: 'hurt', player: pl.id, dmg: this.dmg(C.hymn.base * C.hymn.dmgMult * (soaked ? C.hymn.soakedMult : 1)), from: 'boss', x: p.x, z: p.z, chillMs: 2000 });
      }
      this.hurtThralls((t) => inArc(t.x, t.z) && !this.covered(t.x, t.z, p.x, p.z));
      this.sim.emit({ t: 'boss', kind: 'hymn', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    if (p.kind === 'grasp') {
      const caught = new Set<string>();
      for (const [cx, cz] of p.targets ?? []) for (const pl of players) if (Math.hypot(pl.x - cx, pl.z - cz) <= C.grasp.r + 0.2) caught.add(pl.id);
      for (const id of caught) this.sim.emit({ t: 'hurt', player: id, dmg: this.dmg(C.grasp.dmg), from: 'boss', x: p.x, z: p.z });
      this.sim.emit({ t: 'boss', kind: 'grasp', x: p.x, z: p.z, phase: s.phase, targets: p.targets, r: p.r, ms: 0, players: [...caught], root: C.grasp.rootS, boss: this.id });
      return;
    }
    if (p.kind === 'maul') {
      this.strikePlayers(players, (pl) => Math.hypot(pl.x - p.x, pl.z - p.z) <= C.melee.r + 0.3 && angleDiff(angleTo(p.x, p.z, pl.x, pl.z), p.dir!) <= (C.melee.halfDeg * Math.PI) / 180, C.melee.dmg, p.x, p.z);
      this.sim.emit({ t: 'boss', kind: 'maul', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    super.resolve(p, players);
  }

  protected think(dt: number, players: PlayerBody[]) {
    const C = CONGREGATION;
    const s = this.state;
    const fast = s.phase === 3 ? 0.78 : s.phase === 2 ? 0.9 : 1;
    this.hymnCd -= dt;
    this.graspCd -= dt;
    this.meleeCd -= dt;
    const { nearest, nd } = this.nearest(players);
    if (!this.busy) {
      if (this.hymnCd <= 0) {
        this.hymnCd = C.hymn.cd * fast;
        this.telegraph('hymn', s.x, s.z, C.hymn.reach, C.hymn.windupMs, { dir: angleTo(s.x, s.z, nearest.x, nearest.z) });
      } else if (this.graspCd <= 0) {
        this.graspCd = C.grasp.cd * fast;
        const [lo, hi] = C.grasp.rings;
        const n = lo + Math.floor(this.sim.rand() * (hi - lo + 1));
        const targets: [number, number][] = players.map((pl) => [pl.x, pl.z]);
        while (targets.length < n) {
          const pl = players[Math.floor(this.sim.rand() * players.length)];
          const a = this.sim.rand() * Math.PI * 2;
          targets.push([pl.x + Math.sin(a) * 2.5, pl.z + Math.cos(a) * 2.5]);
        }
        this.telegraph('grasp', s.x, s.z, C.grasp.r, C.grasp.windupMs, { targets: targets.slice(0, Math.max(n, players.length)) });
      } else if (this.meleeCd <= 0 && nd < C.melee.r + 0.5) {
        this.meleeCd = C.melee.cd * fast;
        this.telegraph('maul', s.x, s.z, C.melee.r, C.melee.windupMs, { dir: angleTo(s.x, s.z, nearest.x, nearest.z) });
      }
    }
    // She keeps to the dais and turns to face the nearest singer.
    this.chase(nearest, nd, 1.1 * (this.busy ? 0.2 : 1), dt, this.arena.r - C.water.dais, 2.5);
  }
}

/**
 * The Plague Saint (Plague Cloister, level-scaled). Rot Rain marks circles that turn into rot pools; she heals while
 * she stands in one, so the fight is about kiting her out of the rot you've been dodging. A censer swing up close;
 * P2 brings Plague Doctors and Flagellants, P3 heavier rain, longer pools and a rat swarm.
 */
export class SaintBrain extends BossBrain {
  private rainCd = 4;
  private swingCd = 2;
  private blessFx = 0;
  private linkFx = 0;

  constructor(sim: WorldSim) {
    super(sim, 'saint');
  }

  protected onAwaken() {
    this.rainCd = 4;
    this.swingCd = 2;
  }

  protected onPhase(p: BossPhase) {
    const s = this.state;
    const spots: [number, number][] = [];
    const wave: EnemyId[] = p === 2 ? ['plague_doctor', 'plague_doctor', 'flagellant'] : ['rat', 'rat', 'rat', 'flagellant'];
    wave.forEach((def, i) => {
      const at = this.rim((i / wave.length) * Math.PI * 2 + 0.4);
      spots.push(at);
      this.spawnAdd(def, at[0], at[1]);
    });
    this.sim.emit({ t: 'boss', kind: 'summon', x: s.x, z: s.z, phase: p, targets: spots, boss: this.id });
  }

  /** Standing in her own rot? */
  private inRot() {
    const s = this.state;
    for (const z of this.sim.zones.values()) if (z.hostile && z.kind === 'toxic' && Math.hypot(z.x - s.x, z.z - s.z) <= z.r + 0.6) return true;
    return false;
  }

  /** Plague Doctors standing in her arena (the summoned ones and any that wandered in). */
  private linkedDoctors() {
    const out: { x: number; z: number }[] = [];
    for (const e of this.sim.enemies.values()) {
      if (e.def !== 'plague_doctor' || e.hp <= 0 || e.area !== this.def.area) continue;
      if (Math.hypot(e.x - this.arena.x, e.z - this.arena.z) <= this.arena.r + 2) out.push({ x: e.x, z: e.z });
    }
    return out;
  }

  protected tick(dt: number) {
    const s = this.state;
    // Doctors' link: every doctor in the arena feeds her, and the view draws a beam from each.
    const docs = this.linkedDoctors();
    if (docs.length) {
      s.hp = Math.min(s.maxHp, s.hp + s.maxHp * SAINT.doctors.healPerS * docs.length * dt);
      if ((this.linkFx -= dt) <= 0) {
        this.linkFx = SAINT.doctors.beatS;
        this.sim.emit({ t: 'boss', kind: 'link', x: s.x, z: s.z, phase: s.phase, targets: docs.map((d) => [d.x, d.z] as [number, number]), ms: 0, boss: this.id });
      }
    }
    if (!this.inRot()) return;
    // Pestilent Blessing: the rot feeds her.
    s.hp = Math.min(s.maxHp, s.hp + s.maxHp * SAINT.blessing.healPerS * dt);
    if ((this.blessFx -= dt) <= 0) {
      this.blessFx = 0.8;
      this.sim.emit({ t: 'boss', kind: 'blessed', x: s.x, z: s.z, phase: s.phase, boss: this.id });
    }
  }

  protected resolve(p: Pending, players: PlayerBody[]) {
    const S = SAINT;
    const s = this.state;
    if (p.kind === 'rotRain') {
      super.resolve(p, players);
      for (const [x, z] of p.targets ?? []) this.sim.addHostilePool(x, z, S.rain.r, this.dmg(S.rain.dmg) * S.rain.poolDpsMult, s.phase === 3 ? S.rain.poolSP3 : S.rain.poolS);
      return;
    }
    if (p.kind === 'swing') {
      this.strikePlayers(players, (pl) => Math.hypot(pl.x - p.x, pl.z - p.z) <= S.swing.r + 0.3 && angleDiff(angleTo(p.x, p.z, pl.x, pl.z), p.dir!) <= (S.swing.halfDeg * Math.PI) / 180, S.swing.dmg, p.x, p.z);
      this.hurtThralls((t) => Math.hypot(t.x - p.x, t.z - p.z) <= S.swing.r && angleDiff(angleTo(p.x, p.z, t.x, t.z), p.dir!) <= (S.swing.halfDeg * Math.PI) / 180);
      this.sim.emit({ t: 'boss', kind: 'swing', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    super.resolve(p, players);
  }

  protected circleDamage() {
    return SAINT.rain.dmg;
  }

  protected think(dt: number, players: PlayerBody[]) {
    const S = SAINT;
    const s = this.state;
    const fast = s.phase === 3 ? 0.75 : s.phase === 2 ? 0.88 : 1;
    this.rainCd -= dt;
    this.swingCd -= dt;
    const { nearest, nd } = this.nearest(players);
    if (!this.busy) {
      if (this.rainCd <= 0) {
        this.rainCd = S.rain.cd * fast;
        const [lo, hi] = S.rain.circles;
        const n = lo + Math.floor(this.sim.rand() * (hi - lo + 1)) + (s.phase === 3 ? 2 : 0);
        const targets: [number, number][] = players.map((pl) => [pl.x, pl.z]);
        while (targets.length < n) {
          const a = this.sim.rand() * Math.PI * 2;
          const r = 2 + this.sim.rand() * (this.arena.r - 3);
          targets.push([this.arena.x + Math.sin(a) * r, this.arena.z + Math.cos(a) * r]);
        }
        this.telegraph('rotRain', s.x, s.z, S.rain.r, S.rain.windupMs, { targets });
      } else if (this.swingCd <= 0 && nd < S.swing.r + 0.5) {
        this.swingCd = S.swing.cd * fast;
        this.telegraph('swing', s.x, s.z, S.swing.r, S.swing.windupMs, { dir: angleTo(s.x, s.z, nearest.x, nearest.z) });
      }
    }
    this.chase(nearest, nd, (s.phase === 3 ? 2.1 : s.phase === 2 ? 1.8 : 1.5) * (this.busy ? 0.3 : 1), dt, 2, 2.8);
  }
}

/**
 * The Cinder Regent (Cinder Pyre, level-scaled). Coals mark burning circles, Cinder Cleave lays a firebreak down its
 * line, and Conflagration burns the whole arena except a few ash circles (marked for the entire windup). P2 brings
 * Husks and Priests, P3 hounds, fewer ash circles and a faster cadence.
 */
export class RegentBrain extends BossBrain {
  private coalsCd = 3;
  private cleaveCd = 2;
  private conflCd = 9;

  constructor(sim: WorldSim) {
    super(sim, 'regent');
  }

  protected onAwaken() {
    this.coalsCd = 3;
    this.cleaveCd = 2;
    this.conflCd = 9;
  }

  protected onPhase(p: BossPhase) {
    const s = this.state;
    const wave = p === 2 ? REGENT.adds.p2 : p === 3 ? REGENT.adds.p3 : [];
    const spots: [number, number][] = [];
    wave.forEach((def, i) => {
      const at = this.rim((i / wave.length) * Math.PI * 2 + 0.5);
      spots.push(at);
      this.spawnAdd(def, at[0], at[1]);
    });
    if (spots.length) this.sim.emit({ t: 'boss', kind: 'summon', x: s.x, z: s.z, phase: p, targets: spots, boss: this.id });
  }

  protected circleDamage(kind: string) {
    return kind === 'coals' ? REGENT.coals.dmg : 20;
  }

  /** Ash circles for a Conflagration: spread over the arena, never on top of one another. */
  private ashSpots(players: PlayerBody[]): [number, number][] {
    const s = this.state;
    const C = REGENT.conflagration;
    const extra = Math.floor(Math.max(0, players.length - 1) / 3);
    const n = C.safe[s.phase - 1] + extra;
    const spots: [number, number][] = [];
    for (let tries = 0; spots.length < n && tries < 80; tries++) {
      const a = this.sim.rand() * Math.PI * 2;
      const r = Math.sqrt(this.sim.rand()) * (this.arena.r - C.safeR - 0.6);
      const x = this.arena.x + Math.sin(a) * r;
      const z = this.arena.z + Math.cos(a) * r;
      if (spots.every(([sx, sz]) => Math.hypot(sx - x, sz - z) > C.safeR * 2 + 1)) spots.push([x, z]);
    }
    return spots;
  }

  protected resolve(p: Pending, players: PlayerBody[]) {
    const R = REGENT;
    const s = this.state;
    if (p.kind === 'coals') {
      super.resolve(p, players);
      for (const [x, z] of p.targets ?? []) this.sim.emberPool(x, z, R.coals.r, R.coals.poolS, this.dmg(R.coals.dmg) * R.coals.poolDpsMult);
      return;
    }
    if (p.kind === 'cleave') {
      const inCone = (x: number, z: number) => Math.hypot(x - p.x, z - p.z) <= R.cleave.r + 0.3 && angleDiff(angleTo(p.x, p.z, x, z), p.dir!) <= (R.cleave.halfDeg * Math.PI) / 180;
      this.strikePlayers(players, (pl) => inCone(pl.x, pl.z), R.cleave.dmg, p.x, p.z);
      this.hurtThralls((t) => inCone(t.x, t.z));
      // The firebreak: burning ground down the line of the blow.
      for (const d of R.cleave.trail) this.sim.emberPool(p.x + Math.sin(p.dir!) * d, p.z + Math.cos(p.dir!) * d, R.cleave.trailR, R.cleave.trailS, this.dmg(R.cleave.dmg) * R.cleave.trailDpsMult);
      this.sim.emit({ t: 'boss', kind: 'cleave', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    if (p.kind === 'conflagration') {
      const C = R.conflagration;
      const safe = p.targets ?? [];
      const onAsh = (x: number, z: number) => safe.some(([sx, sz]) => Math.hypot(x - sx, z - sz) <= C.safeR);
      const inArena = (x: number, z: number) => Math.hypot(x - this.arena.x, z - this.arena.z) <= this.arena.r + 0.5;
      for (const pl of players) {
        if (inArena(pl.x, pl.z) && !onAsh(pl.x, pl.z)) this.sim.emit({ t: 'hurt', player: pl.id, dmg: this.dmg(C.dmg), from: 'ember', x: this.arena.x, z: this.arena.z });
      }
      this.hurtThralls((t) => inArena(t.x, t.z) && !onAsh(t.x, t.z), C.dmg * 0.5);
      // What is left of the floor smoulders in a few places (never on the ash).
      for (let i = 0; i < C.embers; i++) {
        const a = this.sim.rand() * Math.PI * 2;
        const r = Math.sqrt(this.sim.rand()) * (this.arena.r - 2);
        const x = this.arena.x + Math.sin(a) * r;
        const z = this.arena.z + Math.cos(a) * r;
        if (!onAsh(x, z)) this.sim.emberPool(x, z, 1.8, C.emberS, this.dmg(REGENT.coals.dmg) * REGENT.coals.poolDpsMult);
      }
      this.sim.emit({ t: 'boss', kind: 'conflagration', x: this.arena.x, z: this.arena.z, phase: s.phase, targets: safe, r: this.arena.r, ms: 0, boss: this.id });
      return;
    }
    super.resolve(p, players);
  }

  protected think(dt: number, players: PlayerBody[]) {
    const R = REGENT;
    const s = this.state;
    const fast = s.phase === 3 ? 0.75 : s.phase === 2 ? 0.88 : 1;
    this.coalsCd -= dt;
    this.cleaveCd -= dt;
    this.conflCd -= dt;
    const { nearest, nd } = this.nearest(players);
    if (!this.busy) {
      if (this.conflCd <= 0) {
        this.conflCd = R.conflagration.cd * fast;
        this.telegraph('conflagration', this.arena.x, this.arena.z, this.arena.r, R.conflagration.windupMs, { targets: this.ashSpots(players) });
      } else if (this.coalsCd <= 0) {
        this.coalsCd = R.coals.cd * fast;
        const [lo, hi] = R.coals.circles;
        const n = lo + Math.floor(this.sim.rand() * (hi - lo + 1)) + (s.phase === 3 ? 2 : 0);
        const targets: [number, number][] = players.map((pl) => [pl.x, pl.z]);
        while (targets.length < n) {
          const a = this.sim.rand() * Math.PI * 2;
          const r = 2 + this.sim.rand() * (this.arena.r - 3);
          targets.push([this.arena.x + Math.sin(a) * r, this.arena.z + Math.cos(a) * r]);
        }
        this.telegraph('coals', s.x, s.z, R.coals.r, R.coals.windupMs, { targets });
      } else if (this.cleaveCd <= 0 && nd < R.cleave.r + 0.5) {
        this.cleaveCd = R.cleave.cd * fast;
        this.telegraph('cleave', s.x, s.z, R.cleave.r, R.cleave.windupMs, { dir: angleTo(s.x, s.z, nearest.x, nearest.z) });
      }
    }
    this.chase(nearest, nd, (s.phase === 3 ? 2.2 : s.phase === 2 ? 1.9 : 1.6) * (this.busy ? 0.3 : 1), dt, 2, 2.8);
  }
}

/**
 * The Mire Mother (Mourning Fen, level-scaled). Phase 1: she sinks and resurfaces under a hummock: a ripple ring marks the spot
 * for the whole windup, and she is winded (staggered) when she comes up. Drowned Hands root anyone wading the open water.
 * Phase 2 floods the arena (the hummocks shrink, leeches climb out). Phase 3 she raises a Risen from every corpse in the Fen:
 * a player who spent their corpses first starves the rite (it fails and she staggers).
 */
export class MireMotherBrain extends BossBrain {
  private surfaceCd = 6;
  private maulCd = 2;
  private handsCd = 4;
  private riteCd = 10;
  /** The hummock she is surfacing under (index into FEN_HUMMOCKS), or -1 while she walks. */
  private spot = -1;

  constructor(sim: WorldSim) {
    super(sim, 'mire');
  }

  protected onAwaken() {
    this.surfaceCd = 6;
    this.maulCd = 2;
    this.handsCd = 4;
    this.riteCd = 10;
    this.spot = -1;
    // She rises on the central hummock.
    this.state.x = FEN_HUMMOCKS[1].x;
    this.state.z = FEN_HUMMOCKS[1].z;
  }

  resume() {
    this.spot = -1;
    if (this.state.state === 'sunk') this.state.state = 'idle';
    this.surfaceCd = 6;
    this.handsCd = 4;
    this.riteCd = 10;
  }

  /** Nothing hurts her while she is under the water. */
  damage(amount: number, by: string, fracture: number) {
    if (this.state.state === 'sunk') return;
    super.damage(amount, by, fracture);
  }

  protected onDefeat() {
    this.spot = -1;
  }

  protected onPhase(p: BossPhase) {
    const s = this.state;
    const wave = p === 2 ? MIRE.adds.p2 : p === 3 ? MIRE.adds.p3 : [];
    const spots: [number, number][] = [];
    wave.forEach((def, i) => {
      const at = this.rim((i / wave.length) * Math.PI * 2 + 0.35, 0.9);
      spots.push(at);
      this.spawnAdd(def, at[0], at[1]);
    });
    // The flood itself is read from the phase (content/fen.ts FEN_FLOOD_SCALE): the event is the moment to show it.
    this.sim.emit({ t: 'boss', kind: 'flood', x: s.x, z: s.z, phase: p, targets: spots, boss: this.id });
  }

  /** Corpses lying in the Fen right now (a corpse may be claimed by anything: Exhume, Litany, Offering, a detonation). */
  private fenCorpses() {
    return [...this.sim.corpses.values()].filter((c) => c.area === this.def.area).sort((a, b) => Math.hypot(a.x - this.arena.x, a.z - this.arena.z) - Math.hypot(b.x - this.arena.x, b.z - this.arena.z)).slice(0, MIRE.rite.maxCorpses);
  }

  protected resolve(p: Pending, players: PlayerBody[]) {
    const M = MIRE;
    const s = this.state;
    if (p.kind === 'surface') {
      const h = FEN_HUMMOCKS[this.spot] ?? FEN_HUMMOCKS[1];
      this.spot = -1;
      s.x = h.x;
      s.z = h.z;
      s.state = 'idle';
      s.stateT = 0;
      this.strikePlayers(players, (pl) => Math.hypot(pl.x - h.x, pl.z - h.z) <= M.surface.r + 0.3, M.surface.dmg, h.x, h.z);
      this.hurtThralls((t) => Math.hypot(t.x - h.x, t.z - h.z) <= M.surface.r, M.surface.dmg * 0.6);
      this.sim.emit({ t: 'boss', kind: 'surface', x: h.x, z: h.z, phase: s.phase, r: M.surface.r, ms: 0, boss: this.id });
      // Winded: a real window to hit her (the brain pauses while staggered).
      this.stagger(M.surface.windedS);
      return;
    }
    if (p.kind === 'hands') {
      const caught = new Set<string>();
      for (const [cx, cz] of p.targets ?? []) for (const pl of players) if (Math.hypot(pl.x - cx, pl.z - cz) <= M.hands.r + 0.2) caught.add(pl.id);
      for (const id of caught) this.sim.emit({ t: 'hurt', player: id, dmg: this.dmg(M.hands.dmg), from: 'boss', x: p.x, z: p.z });
      this.hurtThralls((t) => (p.targets ?? []).some(([cx, cz]) => Math.hypot(t.x - cx, t.z - cz) <= M.hands.r), M.hands.dmg);
      this.sim.emit({ t: 'boss', kind: 'hands', x: p.x, z: p.z, phase: s.phase, targets: p.targets, r: p.r, ms: 0, players: [...caught], root: M.hands.rootS, boss: this.id });
      return;
    }
    if (p.kind === 'maul') {
      this.strikePlayers(players, (pl) => Math.hypot(pl.x - p.x, pl.z - p.z) <= M.maul.r + 0.3 && angleDiff(angleTo(p.x, p.z, pl.x, pl.z), p.dir!) <= (M.maul.halfDeg * Math.PI) / 180, M.maul.dmg, p.x, p.z);
      this.hurtThralls((t) => Math.hypot(t.x - p.x, t.z - p.z) <= M.maul.r && angleDiff(angleTo(p.x, p.z, t.x, t.z), p.dir!) <= (M.maul.halfDeg * Math.PI) / 180);
      this.sim.emit({ t: 'boss', kind: 'maul', x: p.x, z: p.z, phase: s.phase, r: p.r, ms: 0, dir: p.dir, boss: this.id });
      return;
    }
    if (p.kind === 'rite') {
      // Drowned thralls rise from whatever corpses are still lying in the Fen.
      const corpses = this.fenCorpses();
      const at: [number, number][] = [];
      for (const c of corpses) {
        at.push([c.x, c.z]);
        this.sim.removeCorpse(c, 'raised');
        this.spawnAdd('risen', c.x, c.z);
      }
      this.sim.emit({ t: 'boss', kind: 'rite', x: s.x, z: s.z, phase: s.phase, targets: at, r: at.length, ms: 0, boss: this.id });
      if (!at.length) this.stagger(M.rite.failStaggerS);
      return;
    }
    super.resolve(p, players);
  }

  protected think(dt: number, players: PlayerBody[]) {
    const M = MIRE;
    const s = this.state;
    if (s.state === 'sunk') return; // under the water until the ripple ring fills
    const ph = s.phase - 1;
    const fast = s.phase === 3 ? 0.8 : s.phase === 2 ? 0.9 : 1;
    this.surfaceCd -= dt;
    this.maulCd -= dt;
    this.handsCd -= dt;
    if (s.phase === 3) this.riteCd -= dt;
    const { nearest, nd } = this.nearest(players);
    if (!this.busy) {
      if (s.phase === 3 && this.riteCd <= 0) {
        this.riteCd = M.rite.cd * fast;
        // The beams are drawn to the corpses that exist right now; whatever is gone by the end of the windup is denied her.
        this.telegraph('rite', s.x, s.z, this.arena.r, M.rite.windupMs, { targets: this.fenCorpses().map((c) => [c.x, c.z] as [number, number]) });
      } else if (this.surfaceCd <= 0) {
        this.surfaceCd = M.surface.cd[ph];
        // She hunts: usually the hummock a player is standing on, otherwise any of the ring.
        const scale = FEN_FLOOD_SCALE[s.phase];
        const standing = FEN_SURFACE_SPOTS.filter((i) => players.some((pl) => Math.hypot(pl.x - FEN_HUMMOCKS[i].x, pl.z - FEN_HUMMOCKS[i].z) <= FEN_HUMMOCKS[i].r * scale + 0.5));
        const pool = standing.length && this.sim.rand() < M.surface.huntChance ? standing : FEN_SURFACE_SPOTS;
        this.spot = pool[Math.floor(this.sim.rand() * pool.length)];
        const h = FEN_HUMMOCKS[this.spot];
        this.telegraph('surface', h.x, h.z, M.surface.r, M.surface.windupMs[ph]);
        // She slips under now; the ring fills over her new hummock.
        s.state = 'sunk';
        s.stateT = 0;
        s.x = h.x;
        s.z = h.z;
        return;
      } else if (this.handsCd <= 0) {
        this.handsCd = M.hands.cd[ph];
        const [lo, hi] = M.hands.rings;
        const n = lo + Math.floor(this.sim.rand() * (hi - lo + 1));
        // Hands reach for anyone wading the open water (players on dry ground are safe from them).
        const wading = players.filter((pl) => inBog(pl.x, pl.z) && !hummockAt(pl.x, pl.z, FEN_FLOOD_SCALE[s.phase]));
        const targets: [number, number][] = wading.map((pl) => [pl.x, pl.z]);
        while (targets.length < n) {
          const a = this.sim.rand() * Math.PI * 2;
          const r = 2 + this.sim.rand() * (this.arena.r - 3);
          targets.push([this.arena.x + Math.sin(a) * r, this.arena.z + Math.cos(a) * r]);
        }
        this.telegraph('hands', s.x, s.z, M.hands.r, M.hands.windupMs, { targets: targets.slice(0, Math.max(n, wading.length)) });
      } else if (this.maulCd <= 0 && nd < M.maul.r + 0.5) {
        this.maulCd = M.maul.cd * fast;
        this.telegraph('maul', s.x, s.z, M.maul.r, M.maul.windupMs, { dir: angleTo(s.x, s.z, nearest.x, nearest.z) });
      }
    }
    this.chase(nearest, nd, (s.phase === 3 ? 2 : s.phase === 2 ? 1.75 : 1.5) * (this.busy ? 0.3 : 1), dt, 2.5, 2.8);
  }
}

export function makeBossBrains(sim: WorldSim): Record<BossId, BossBrain> {
  return {
    prelate: new PrelateBrain(sim),
    gravedigger: new GravediggerBrain(sim),
    abbess: new AbbessBrain(sim),
    congregation: new CongregationBrain(sim),
    saint: new SaintBrain(sim),
    regent: new RegentBrain(sim),
    mire: new MireMotherBrain(sim),
  };
}
