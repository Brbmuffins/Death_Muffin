import type { AreaId } from '../../content/areas';
import { isDifficulty, type Difficulty } from '../../content/difficulty';
import { AFFIX_ORDER, type EliteAffix } from '../../content/enemies';
import type { EnemyRow, ThrallRow, WorldSnapshot } from '../../net/contracts';
import type { BossState, Corpse, Enemy, EnemyState, SimEvent, Thrall, ThrallState, Zone } from './types';
import type { WorldSim } from './WorldSim';

const E_STATES: EnemyState[] = ['rising', 'move', 'windup', 'recover', 'channel', 'dead'];
const T_STATES: ThrallState[] = ['rising', 'idle', 'move', 'attack', 'dead'];
const r2 = (n: number) => Math.round(n * 100) / 100;
const affixCode = (a: EliteAffix | undefined) => (a ? AFFIX_ORDER.indexOf(a) + 1 : 0);
const affixFrom = (code: number | undefined): EliteAffix | undefined => (code ? AFFIX_ORDER[code - 1] : undefined);

export function makeSnapshot(sim: WorldSim, full: boolean): WorldSnapshot {
  const enemies: EnemyRow[] = [];
  for (const e of sim.enemies.values()) {
    // Bit 3 chill, 12 bleed, 13 sanctified, 14 bone hex (older clients ignore unknown bits).
    const flags = (e.elite ? 1 : 0) | (e.moving ? 2 : 0) | (e.slowT > 0 ? 4 : 0) | ((e.chillT ?? 0) > 0 ? 8 : 0) | ((e.bleedT ?? 0) > 0 ? 4096 : 0) | ((e.sanctT ?? 0) > 0 ? 8192 : 0) | ((e.hexT ?? 0) > 0 ? 16384 : 0);
    enemies.push([e.id, e.def, r2(e.x), r2(e.z), r2(e.facing), Math.round(e.hp), Math.round(e.maxHp), E_STATES.indexOf(e.state), flags | (e.fracture << 4) | (e.withered << 8), r2(e.stateT), r2(e.speed), r2(e.scale), e.area, affixCode(e.affix)]);
  }
  const thralls: ThrallRow[] = [];
  for (const t of sim.thralls.values()) {
    thralls.push([t.id, t.owner, t.kind, r2(t.x), r2(t.z), r2(t.facing), Math.round(t.hp), Math.round(t.maxHp), T_STATES.indexOf(t.state) | (t.moving ? 16 : 0), r2(t.stateT), t.empowered ? 1 : 0, t.speed]);
  }
  return {
    t: sim.time,
    waveTier: sim.waveTier,
    difficulty: sim.difficulty,
    enemies,
    thralls,
    boss: { ...sim.bossState },
    ...(full ? { corpses: [...sim.corpses.values()], zones: [...sim.zones.values()] } : {}),
  };
}

function blankEnemy(row: EnemyRow): Enemy {
  return {
    id: row[0],
    def: row[1],
    area: row[12] as AreaId,
    level: 1,
    elite: false,
    x: row[2],
    z: row[3],
    facing: row[4],
    hp: row[5],
    maxHp: row[6],
    damage: 0,
    speed: row[10],
    radius: 0.5,
    scale: row[11],
    state: 'move',
    stateT: 0,
    attackCd: 0,
    targetPlayer: null,
    targetThrall: null,
    aimX: 0,
    aimZ: 0,
    channelCorpse: null,
    flankSide: 1,
    fracture: 0,
    fractureT: 0,
    withered: 0,
    witheredT: 0,
    witheredDps: 0,
    witheredOwner: '',
    slowT: 0,
    lastHitBy: '',
    flash: 0,
    gait: 0,
    moving: false,
    affix: affixFrom(row[13]),
  };
}

interface Target {
  x: number;
  z: number;
  facing: number;
}

/**
 * Read-side replica of the host's WorldSim for non-host clients. Snapshots
 * arrive at ~10Hz; positions are eased toward them every frame. Corpses and
 * zones arrive as reliable events, with a full list every few snapshots to
 * heal drift.
 */
export class WorldMirror {
  readonly enemies = new Map<number, Enemy>();
  readonly thralls = new Map<number, Thrall>();
  readonly corpses = new Map<number, Corpse>();
  readonly zones = new Map<number, Zone>();
  bossState: BossState | null = null;
  waveTier = 0;
  difficulty: Difficulty = 'medium';
  time = 0;
  private targets = new Map<string, Target>();

  applySnapshot(s: WorldSnapshot) {
    this.time = s.t;
    this.waveTier = s.waveTier;
    this.difficulty = isDifficulty(s.difficulty) ? s.difficulty : 'medium';
    const seenE = new Set<number>();
    for (const row of s.enemies) {
      seenE.add(row[0]);
      let e = this.enemies.get(row[0]);
      if (!e) {
        e = blankEnemy(row);
        this.enemies.set(e.id, e);
      }
      const flags = row[8];
      const prevHp = e.hp;
      e.hp = row[5];
      e.maxHp = row[6];
      if (e.hp < prevHp) e.flash = 1;
      const st = E_STATES[row[7]] ?? 'move';
      if (st !== e.state) e.stateT = row[9];
      e.state = st;
      e.elite = !!(flags & 1);
      e.moving = !!(flags & 2);
      e.slowT = flags & 4 ? 0.2 : 0;
      e.chillT = flags & 8 ? 0.2 : 0;
      e.bleedT = flags & 4096 ? 0.2 : 0;
      e.sanctT = flags & 8192 ? 0.2 : 0;
      e.hexT = flags & 16384 ? 0.2 : 0;
      e.fracture = (flags >> 4) & 15;
      e.withered = (flags >> 8) & 15;
      e.speed = row[10];
      e.scale = row[11];
      e.affix = affixFrom(row[13]);
      this.targets.set(`e${e.id}`, { x: row[2], z: row[3], facing: row[4] });
    }
    for (const id of [...this.enemies.keys()]) if (!seenE.has(id)) this.enemies.delete(id);

    const seenT = new Set<number>();
    for (const row of s.thralls) {
      seenT.add(row[0]);
      let t = this.thralls.get(row[0]);
      if (!t) {
        t = {
          id: row[0],
          owner: row[1],
          kind: row[2],
          x: row[3],
          z: row[4],
          facing: row[5],
          hp: row[6],
          maxHp: row[7],
          damage: 0,
          attackInterval: 1,
          range: 1,
          speed: row[11],
          state: 'rising',
          stateT: row[9],
          attackCd: 0,
          target: null,
          slot: 0,
          bornAt: 0,
          empowered: !!row[10],
          flash: 0,
          gait: 0,
          moving: false,
        };
        this.thralls.set(t.id, t);
      }
      if (row[6] < t.hp) t.flash = 1;
      t.hp = row[6];
      t.maxHp = row[7];
      const st = T_STATES[row[8] & 15] ?? 'idle';
      if (st !== t.state) t.stateT = row[9];
      t.state = st;
      t.moving = !!(row[8] & 16);
      this.targets.set(`t${t.id}`, { x: row[3], z: row[4], facing: row[5] });
    }
    for (const id of [...this.thralls.keys()]) if (!seenT.has(id)) this.thralls.delete(id);

    if (s.corpses) {
      this.corpses.clear();
      for (const c of s.corpses) this.corpses.set(c.id, c);
    }
    if (s.zones) {
      this.zones.clear();
      for (const z of s.zones) this.zones.set(z.id, z);
    }
    this.bossState = s.boss;
  }

  applyEvents(events: SimEvent[]) {
    for (const ev of events) {
      if (ev.t === 'corpse') this.corpses.set(ev.corpse.id, ev.corpse);
      else if (ev.t === 'corpseGone') this.corpses.delete(ev.id);
      else if (ev.t === 'zone') this.zones.set(ev.zone.id, ev.zone);
      else if (ev.t === 'zoneGone') this.zones.delete(ev.id);
      else if (ev.t === 'death') this.enemies.delete(ev.id);
      else if (ev.t === 'thrallGone') this.thralls.delete(ev.id);
    }
  }

  update(dt: number) {
    const k = Math.min(1, dt * 12);
    for (const e of this.enemies.values()) {
      e.stateT += dt;
      e.flash = Math.max(0, e.flash - dt * 5);
      const t = this.targets.get(`e${e.id}`);
      if (!t) continue;
      e.x += (t.x - e.x) * k;
      e.z += (t.z - e.z) * k;
      e.facing = t.facing;
    }
    for (const th of this.thralls.values()) {
      th.stateT += dt;
      th.flash = Math.max(0, th.flash - dt * 5);
      const t = this.targets.get(`t${th.id}`);
      if (!t) continue;
      th.x += (t.x - th.x) * k;
      th.z += (t.z - th.z) * k;
      th.facing = t.facing;
    }
  }

  /** Host migration: hand the replicated state to a fresh authoritative sim. */
  seed(sim: WorldSim) {
    for (const e of this.enemies.values()) sim.enemies.set(e.id, { ...e, damage: e.damage || 8, radius: 0.5 });
    for (const t of this.thralls.values()) sim.thralls.set(t.id, { ...t, damage: t.damage || 6, attackInterval: 1, range: t.kind === 'wraith' ? 5.5 : 1.3 });
    for (const c of this.corpses.values()) sim.corpses.set(c.id, { ...c, bornAt: sim.time, expiresAt: sim.time + 20, ruptureAt: c.kind === 'toxic' ? sim.time + 4 : Infinity });
    if (this.bossState?.active) Object.assign(sim.bossState, this.bossState);
    sim.waveTier = this.waveTier;
    sim.difficulty = this.difficulty;
    const ids = [...this.enemies.keys(), ...this.thralls.keys(), ...this.corpses.keys(), ...this.zones.keys()];
    sim.reserveIds(ids.length ? Math.max(...ids) : 0);
  }
}
