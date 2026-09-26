import { AREAS, AREA_ORDER, GLOBAL_ENEMY_CAP, type AreaId } from '../../content/areas';
import {
  AFFIX_ORDER,
  AFFIX_TUNING,
  ELITE,
  ENEMIES,
  SURGE,
  enemyDamageScale,
  enemyHpScale,
  type EliteAffix,
  type EnemyId,
} from '../../content/enemies';
import {
  DETONATE,
  FRACTURE,
  LITANY_MAX_MULT,
  LITANY_PER_CORPSE,
  LITANY_PER_RESONANT,
  LITANY_PER_THRALL,
  MIASMA_SLOW,
  ABILITIES,
} from '../../content/abilities';
import { NIGHTFALL_SHROUD_CHANCE, RESTLESS_SURGE_MULT, milestoneActive, waveModifiers } from '../../content/upgrades';
import { DIFFICULTIES, type Difficulty } from '../../content/difficulty';
import { CHILL, HEMORRHAGE, SANCTIFIED } from '../../content/statuses';
import type { Nav } from '../nav';
import { pickWeighted } from '../rng';
import { BossBrain, BOSS_ARENA, BOSS_RADIUS } from './BossBrain';
import type {
  BossState,
  Corpse,
  CorpseGoneReason,
  Enemy,
  Intent,
  PlayerBody,
  SimEvent,
  SurgeState,
  Thrall,
  Zone,
} from './types';

const AGGRO_RANGE = 15;
const CORPSE_LIFETIME = 26;
const TOXIC_RUPTURE = 5;
const MAX_CORPSES = 45;
const THRALL_LEASH = 13;
const THRALL_TELEPORT = 24;
const PLAYER_RADIUS = 0.45;
const SPAWN_MIN_DIST = 9;
const SPAWN_MAX_DIST = 30;
const RISE_TIME = 1.1;
const THRALL_RISE_TIME = 0.9;

const THRALL_BASE = {
  warrior: { range: 1.3, interval: 1.0, speed: 5.6 },
  shieldbearer: { range: 1.3, interval: 1.25, speed: 5.2 },
  hound: { range: 1.2, interval: 0.7, speed: 7.2 },
  wraith: { range: 5.5, interval: 1.1, speed: 5.8 },
} as const;

/**
 * The authoritative world. Runs on the room host (or solo). Everything that
 * isn't a player body lives here: enemies, thralls, corpses, zones, waves and
 * the Prelate. Clients talk to it through Intents; it answers with Events.
 */
export class WorldSim {
  readonly enemies = new Map<number, Enemy>();
  readonly thralls = new Map<number, Thrall>();
  readonly corpses = new Map<number, Corpse>();
  readonly zones = new Map<number, Zone>();
  readonly players = new Map<string, PlayerBody>();
  readonly boss: BossBrain;

  /** Host's active wave-speed tier (drives every area this sim runs). */
  waveTier = 0;
  /** Host's session difficulty: scales enemy/boss HP and damage for new spawns. */
  difficulty: Difficulty = 'medium';
  time = 0;
  /** The running Grave Surge, if any. */
  surge: SurgeState | null = null;
  /** Combat seconds until the next Grave Surge (only counts down while someone fights). */
  surgeIn = SURGE.firstDelayS;

  private events: SimEvent[] = [];
  private nextId = 1;
  private waveTimers = new Map<AreaId, number>();
  /** Regular waves spawned per area (Elite Vanguard alternates). */
  private waveCounts = new Map<AreaId, number>();
  /** Surge origins in front of crypt props (from the layout); breaches are the fallback. */
  private crypts: { area: AreaId; x: number; z: number }[] = [];
  private dotAccum = new Map<number, number>();
  private bloomed = new Set<number>();

  constructor(
    private nav: Nav,
    readonly rand: () => number = Math.random,
  ) {
    this.boss = new BossBrain(this);
  }

  id() {
    return this.nextId++;
  }

  /** After seeding from a mirror (host migration) keep new ids above the old ones. */
  reserveIds(maxUsed: number) {
    this.nextId = Math.max(this.nextId, maxUsed + 1);
  }

  emit(ev: SimEvent) {
    this.events.push(ev);
  }

  drain(): SimEvent[] {
    const out = this.events;
    this.events = [];
    return out;
  }

  get bossState(): BossState {
    return this.boss.state;
  }

  // --- Players ---

  setPlayer(body: PlayerBody) {
    this.players.set(body.id, body);
  }

  removePlayer(id: string) {
    this.players.delete(id);
    for (const t of [...this.thralls.values()]) if (t.owner === id) this.killThrall(t, 'crumbled');
  }

  playersIn(area: AreaId) {
    return [...this.players.values()].filter((p) => p.alive && p.area === area);
  }

  // --- Intents ---

  apply(intent: Intent) {
    switch (intent.t) {
      case 'hit':
        return this.applyHit(intent);
      case 'miasma':
        return this.applyMiasma(intent);
      case 'exhume':
        return this.applyExhume(intent);
      case 'litany':
        return this.applyLitany(intent);
      case 'summonBoss':
        return this.boss.awaken(intent.by);
      case 'detonate':
        return this.applyDetonate(intent);
      case 'recallThralls':
        for (const t of this.thralls.values()) {
          if (t.owner !== intent.by) continue;
          t.x = intent.x + (this.rand() - 0.5) * 2;
          t.z = intent.z + (this.rand() - 0.5) * 2;
          t.target = null;
        }
    }
  }

  damageEnemy(e: Enemy, amount: number, by: string) {
    if (e.state === 'dead' || e.hp <= 0) return 0;
    const dmg = amount * (1 + FRACTURE.perStack * e.fracture) * this.damageTakenMult(e);
    e.hp -= dmg;
    e.flash = 1;
    e.lastHitBy = by;
    return dmg;
  }

  /** Shrouded elites shrug off half of everything unless they stand in a player's rot. */
  damageTakenMult(e: Enemy) {
    const shroud = e.affix === 'shrouded' && !this.inFriendlyMiasma(e) ? AFFIX_TUNING.shrouded.damageTakenMult : 1;
    return shroud * ((e.sanctT ?? 0) > 0 ? SANCTIFIED.damageTakenMult : 1);
  }

  /** Inside a player-owned Miasma circle (or the rot pool a Corpse Explosion leaves)? */
  inFriendlyMiasma(e: { x: number; z: number; radius: number }) {
    for (const z of this.zones.values()) {
      if (z.hostile || (z.kind !== 'miasma' && z.kind !== 'rot')) continue;
      if (Math.hypot(e.x - z.x, e.z - z.z) <= z.r + e.radius) return true;
    }
    return false;
  }

  private applyHit(h: Extract<Intent, { t: 'hit' }>) {
    if (h.boss) {
      this.boss.damage(h.dmg, h.by, h.fracture ?? 0);
      return;
    }
    for (const id of h.ids) {
      const e = this.enemies.get(id);
      if (!e) continue;
      this.damageEnemy(e, h.dmg, h.by);
      if (h.bleed && h.bleed > 0) {
        // Hemorrhage: the strongest bleed wins; the host caps what a hit may claim.
        const dps = Math.min(h.bleed, h.dmg * HEMORRHAGE.maxFrac);
        if (dps >= (e.bleedDps ?? 0) || (e.bleedT ?? 0) <= 0) {
          e.bleedDps = dps;
          e.bleedOwner = h.by;
        }
        e.bleedT = HEMORRHAGE.durationS;
      }
      if (h.fracture) {
        e.fracture = Math.min(FRACTURE.maxStacks, e.fracture + h.fracture);
        e.fractureT = FRACTURE.durationMs / 1000;
      }
    }
  }

  private applyMiasma(m: Extract<Intent, { t: 'miasma' }>) {
    const zone: Zone = {
      id: this.id(),
      kind: 'miasma',
      owner: m.by,
      x: m.x,
      z: m.z,
      r: m.r,
      until: this.time + m.durationMs / 1000,
      bornAt: this.time,
      tick: 0,
      dps: m.dps,
      slow: MIASMA_SLOW,
      witheredCap: m.witheredCap,
      bloom: m.bloom,
      hostile: false,
    };
    this.zones.set(zone.id, zone);
    this.emit({ t: 'zone', zone });
  }

  private ownedThralls(owner: string) {
    return [...this.thralls.values()].filter((t) => t.owner === owner && t.state !== 'dead');
  }

  private applyExhume(x: Extract<Intent, { t: 'exhume' }>) {
    let best: Corpse | null = null;
    let bestD = Infinity;
    for (const c of this.corpses.values()) {
      const d = Math.hypot(c.x - x.x, c.z - x.z);
      if (d <= x.r && d < bestD) {
        best = c;
        bestD = d;
      }
    }
    if (!best) {
      this.emit({ t: 'exhumed', by: x.by, ok: false, x: x.x, z: x.z });
      return;
    }
    this.removeCorpse(best, 'consumed', x.by);
    let crumbled: number | undefined;
    const owned = this.ownedThralls(x.by).sort((a, b) => a.bornAt - b.bornAt);
    if (owned.length >= x.cap) {
      crumbled = owned[0].id;
      this.killThrall(owned[0], 'crumbled');
    }
    const kind = x.kind === 'wraith' ? 'wraith' : best.kind === 'swift' ? 'hound' : x.kind;
    const empowered = best.kind === 'resonant' || best.elite;
    const base = THRALL_BASE[kind];
    const slotsUsed = new Set(this.ownedThralls(x.by).map((t) => t.slot));
    let slot = 0;
    while (slotsUsed.has(slot)) slot++;
    const t: Thrall = {
      id: this.id(),
      owner: x.by,
      kind,
      x: best.x,
      z: best.z,
      facing: best.facing,
      hp: x.hp * (empowered ? 1.5 : 1) * (kind === 'hound' ? 0.75 : 1),
      maxHp: x.hp * (empowered ? 1.5 : 1) * (kind === 'hound' ? 0.75 : 1),
      damage: x.damage * (empowered ? 1.5 : 1),
      attackInterval: base.interval / x.attackSpeedMult,
      range: base.range,
      speed: base.speed,
      state: 'rising',
      stateT: 0,
      attackCd: 0.4,
      target: null,
      slot,
      bornAt: this.time,
      empowered,
      flash: 0,
      gait: 0,
      moving: false,
    };
    this.thralls.set(t.id, t);
    this.emit({ t: 'thrall', id: t.id, owner: t.owner, kind, x: t.x, z: t.z, empowered });
    this.emit({ t: 'exhumed', by: x.by, ok: true, corpseKind: best.kind, x: best.x, z: best.z, crumbled });
  }

  private applyLitany(l: Extract<Intent, { t: 'litany' }>) {
    let corpses = 0;
    let resonant = 0;
    const tethers: [number, number][] = [];
    for (const c of [...this.corpses.values()]) {
      if (Math.hypot(c.x - l.x, c.z - l.z) > l.r) continue;
      if (c.kind === 'resonant') resonant++;
      else corpses++;
      tethers.push([c.x, c.z]);
      this.removeCorpse(c, 'litany', l.by);
    }
    let thralls = 0;
    for (const t of this.ownedThralls(l.by)) {
      if (Math.hypot(t.x - l.x, t.z - l.z) > l.r) continue;
      thralls++;
      tethers.push([t.x, t.z]);
      this.killThrall(t, 'sacrificed');
      if (l.leaveCorpses) this.addCorpse(t.x, t.z, 'normal', 'risen', false, t.facing, 1, this.nav.areaAt(t.x, t.z) ?? 'graves');
    }
    const mult = Math.min(
      LITANY_MAX_MULT,
      ABILITIES.black_litany.power + LITANY_PER_CORPSE * corpses + LITANY_PER_RESONANT * resonant + LITANY_PER_THRALL * thralls,
    );
    const dmg = l.spellPower * mult;
    let targets = 0;
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - l.x, e.z - l.z) > l.r + e.radius) continue;
      this.damageEnemy(e, dmg, l.by);
      targets++;
    }
    if (this.boss.state.active && Math.hypot(this.boss.state.x - l.x, this.boss.state.z - l.z) <= l.r + BOSS_RADIUS) {
      this.boss.damage(dmg, l.by, 0);
      targets++;
    }
    this.emit({ t: 'litanyResult', by: l.by, x: l.x, z: l.z, r: l.r, corpses, resonant, thralls, targets, tethers });
    if (targets) this.emit({ t: 'dmg', x: l.x, z: l.z, amount: Math.round(dmg), kind: 'litany', by: l.by });
  }

  /**
   * Corpse Explosion. The host owns the blast radius and the corpse modifiers;
   * the client only names the corpse and its own damage (clamped here too).
   */
  private applyDetonate(d: Extract<Intent, { t: 'detonate' }>) {
    const c = this.corpses.get(d.corpseId);
    if (!c) {
      // Claimed by someone else first (the caster refunds on ok:false).
      this.emit({ t: 'detonated', by: d.by, ok: false, corpseId: d.corpseId, x: 0, z: 0, r: 0 });
      return;
    }
    const base = Math.min(DETONATE.maxDamage, Math.max(0, Number.isFinite(d.dmg) ? d.dmg : 0));
    const r = DETONATE.radius * (c.kind === 'resonant' ? DETONATE.resonantRadiusMult : 1);
    const dmg = base * (c.elite ? DETONATE.eliteDamageMult : 1);
    let targets = 0;
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - c.x, e.z - c.z) > r + e.radius) continue;
      this.damageEnemy(e, dmg, d.by);
      targets++;
    }
    const b = this.boss.state;
    if (b.active && Math.hypot(b.x - c.x, b.z - c.z) <= r + BOSS_RADIUS) {
      this.boss.damage(dmg, d.by, 0);
      targets++;
    }
    // Announce before the corpse goes so views shatter the body instead of sinking it.
    this.emit({
      t: 'detonated',
      by: d.by,
      ok: true,
      corpseId: c.id,
      x: c.x,
      z: c.z,
      r,
      corpseKind: c.kind,
      elite: c.elite,
      targets,
      dmg: Math.round(dmg),
    });
    this.removeCorpse(c, 'burst', d.by);
    if (c.kind === 'toxic') {
      // The sac's venom, turned: a friendly rot pool that withers what stays in it.
      const zone: Zone = {
        id: this.id(),
        kind: 'rot',
        owner: d.by,
        x: c.x,
        z: c.z,
        r: DETONATE.rotRadius * Math.max(1, c.scale),
        until: this.time + DETONATE.rotDurationMs / 1000,
        bornAt: this.time,
        tick: 0,
        dps: base * DETONATE.rotDpsShare,
        slow: MIASMA_SLOW,
        witheredCap: DETONATE.rotWitheredCap,
        bloom: false,
        hostile: false,
      };
      this.zones.set(zone.id, zone);
      this.emit({ t: 'zone', zone });
    }
  }

  // --- Corpses / thralls ---

  addCorpse(x: number, z: number, kind: Corpse['kind'], enemy: EnemyId, elite: boolean, facing: number, scale: number, area: AreaId) {
    if (kind === 'none') return;
    if (this.corpses.size >= MAX_CORPSES) {
      const oldest = [...this.corpses.values()].sort((a, b) => a.bornAt - b.bornAt)[0];
      if (oldest) this.removeCorpse(oldest, 'expired');
    }
    const c: Corpse = {
      id: this.id(),
      x,
      z,
      kind,
      enemy,
      elite,
      facing,
      scale,
      area,
      bornAt: this.time,
      expiresAt: this.time + CORPSE_LIFETIME,
      ruptureAt: kind === 'toxic' ? this.time + TOXIC_RUPTURE : Infinity,
    };
    this.corpses.set(c.id, c);
    this.emit({ t: 'corpse', corpse: c });
  }

  removeCorpse(c: Corpse, reason: CorpseGoneReason, by?: string) {
    if (!this.corpses.delete(c.id)) return;
    this.bloomed.delete(c.id);
    this.emit({ t: 'corpseGone', id: c.id, reason, by });
  }

  killThrall(t: Thrall, reason: 'killed' | 'sacrificed' | 'crumbled') {
    if (!this.thralls.delete(t.id)) return;
    t.state = 'dead';
    this.emit({ t: 'thrallGone', id: t.id, owner: t.owner, x: t.x, z: t.z, reason });
  }

  // --- Spawning ---

  /** `affix` forces an elite affix (tests / debug); otherwise elites roll one. */
  spawnEnemy(def: EnemyId, area: AreaId, x: number, z: number, elite: boolean, rising = true, affix?: EliteAffix): Enemy {
    const d = ENEMIES[def];
    const level = AREAS[area].level;
    const wave = waveModifiers(this.waveTier);
    const diff = DIFFICULTIES[this.difficulty];
    const hp = d.hp * enemyHpScale(level) * wave.enemyHpMult * diff.enemyHpMult * (elite ? ELITE.hpMult : 1) * this.partyHpScale();
    const e: Enemy = {
      id: this.id(),
      def,
      area,
      level,
      elite,
      x,
      z,
      facing: this.rand() * Math.PI * 2,
      hp,
      maxHp: hp,
      damage: d.damage * enemyDamageScale(level) * wave.enemyDamageMult * diff.enemyDamageMult * (elite ? ELITE.damageMult : 1),
      speed: d.speed * (0.92 + this.rand() * 0.16),
      radius: d.radius * (elite ? 1.25 : 1),
      scale: d.scale * (elite ? ELITE.scale : 1),
      state: rising ? 'rising' : 'move',
      stateT: 0,
      attackCd: 0.5 + this.rand(),
      targetPlayer: null,
      targetThrall: null,
      aimX: x,
      aimZ: z,
      channelCorpse: null,
      flankSide: this.rand() < 0.5 ? -1 : 1,
      fracture: 0,
      fractureT: 0,
      withered: 0,
      witheredT: 0,
      witheredDps: 0,
      witheredOwner: '',
      slowT: 0,
      lastHitBy: '',
      flash: 0,
      gait: this.rand() * 10,
      moving: false,
    };
    if (elite) e.affix = affix ?? AFFIX_ORDER[Math.floor(this.rand() * AFFIX_ORDER.length)];
    // Common dead only carry an affix when something grants it (Nightfall's Shroud).
    else if (affix) e.affix = affix;
    this.enemies.set(e.id, e);
    this.emit({ t: 'spawn', id: e.id, def, x, z, elite, ...(e.affix ? { affix: e.affix } : {}) });
    return e;
  }

  private partyHpScale() {
    const n = Math.max(1, this.players.size);
    return 1 + 0.5 * (n - 1);
  }

  private aliveIn(area: AreaId) {
    let n = 0;
    for (const e of this.enemies.values()) if (e.area === area && e.state !== 'dead') n++;
    return n;
  }

  private spawnWave(area: AreaId, first = false) {
    const def = AREAS[area];
    const mods = waveModifiers(this.waveTier);
    const cap = Math.round(def.cap * mods.capMult);
    const room = Math.min(cap - this.aliveIn(area), GLOBAL_ENEMY_CAP - this.enemies.size);
    if (room <= 0) return;
    // The arrival wave is a fixed greeting; the Wave Speed dial only shapes what follows.
    let count = Math.round(first ? def.waveSize * 1.3 : def.waveSize * mods.sizeMult);
    count = Math.min(count, room);
    const pool = this.fairBreaches(area);
    // Bigger waves split across breaches so they arrive from more than one side.
    const breachCount = Math.min(pool.length, count > 11 ? 3 : count > 5 ? 2 : 1);
    const chosen: [number, number][] = [];
    for (let i = 0; i < breachCount; i++) chosen.push(pool[Math.floor(this.rand() * pool.length)]);
    // Elite Vanguard: every other wave after the greeting climbs out behind an elite.
    const n = first ? 0 : (this.waveCounts.get(area) ?? 0) + 1;
    if (!first) this.waveCounts.set(area, n);
    const vanguard = !first && n % 2 === 1 && milestoneActive('vanguard', this.waveTier);
    let hasElite = false;
    for (let i = 0; i < count; i++) {
      const [bx, bz] = chosen[i % chosen.length];
      const e = this.spawnAtBreach(area, bx, bz, vanguard && !hasElite && i === count - 1);
      if (e?.elite) hasElite = true;
    }
    for (const [x, z] of chosen) this.emit({ t: 'wave', area, count, x, z });
  }

  /** Breaches at a fair distance from every player; falls back to any breach. */
  private fairBreaches(area: AreaId): [number, number][] {
    const def = AREAS[area];
    const players = this.playersIn(area);
    const ok = def.breaches.filter(([bx, bz]) =>
      players.every((p) => {
        const d = Math.hypot(p.x - bx, p.z - bz);
        return d >= SPAWN_MIN_DIST && d <= SPAWN_MAX_DIST;
      }),
    );
    return ok.length ? ok : def.breaches;
  }

  /** One wave member climbing out beside a breach (area roster, elite roll). */
  private spawnAtBreach(area: AreaId, bx: number, bz: number, forceElite = false): Enemy | null {
    const def = AREAS[area];
    const mods = waveModifiers(this.waveTier);
    const ang = this.rand() * Math.PI * 2;
    const rr = 0.5 + this.rand() * 2.4;
    const [x, z] = this.nav.resolveInArea(area, bx + Math.cos(ang) * rr, bz + Math.sin(ang) * rr, 0.5);
    const pick = pickWeighted(def.enemies, this.rand());
    if (!pick) return null;
    const roll = this.rand() < def.eliteChance + mods.eliteBonus + DIFFICULTIES[this.difficulty].eliteBonus;
    const elite = pick.id !== 'risen' && (forceElite || roll);
    // Nightfall: the common dead climb out Shrouded.
    const shroud = !elite && milestoneActive('nightfall', this.waveTier) && this.rand() < NIGHTFALL_SHROUD_CHANCE ? 'shrouded' : undefined;
    return this.spawnEnemy(pick.id, area, x, z, elite, true, shroud);
  }

  // --- Grave Surges ---

  /**
   * While anyone fights in an open, unsafe area the surge clock runs; when it
   * lapses a crypt cracks open at a breach and pours three rapid waves over
   * 20s. Clearing ≥80% of what it spawned before it closes is a win.
   */
  private updateSurge(dt: number) {
    const s = this.surge;
    if (s) {
      const age = this.time - s.startedAt;
      while (s.wavesSpawned < SURGE.waveAtS.length && age >= SURGE.waveAtS[s.wavesSpawned]) {
        s.wavesSpawned++;
        this.spawnSurgeWave(s);
      }
      const allOut = s.wavesSpawned >= SURGE.waveAtS.length;
      if (allOut && s.spawned > 0 && s.killed >= s.spawned * SURGE.clearFrac) {
        this.emit({ t: 'surgeCleared', area: s.area, x: s.x, z: s.z });
        this.endSurge();
      } else if (this.time >= s.endsAt) {
        this.emit({ t: 'surgeFailed', area: s.area, x: s.x, z: s.z });
        this.endSurge();
      }
      return;
    }
    const eligible = AREA_ORDER.filter(
      (id) =>
        !AREAS[id].safe &&
        AREAS[id].breaches.length > 0 &&
        this.nav.isUnlocked(id) &&
        this.playersIn(id).length > 0 &&
        !(id === 'sanctum' && this.boss.state.active),
    );
    if (!eligible.length) return;
    this.surgeIn -= dt;
    if (this.surgeIn > 0) return;
    this.startSurge(eligible[Math.floor(this.rand() * eligible.length)]);
  }

  setCrypts(crypts: { area: AreaId; x: number; z: number }[]) {
    this.crypts = crypts.map(({ area, x, z }) => ({ area, x, z }));
  }

  /** Open a surge now (also the DEV/QA entry point). */
  startSurge(area: AreaId) {
    if (this.surge || AREAS[area].safe || !AREAS[area].breaches.length) return;
    // A crypt cracks open when one sits at a fair distance from everyone; otherwise a breach.
    const players = this.playersIn(area);
    const crypts = this.crypts.filter(
      (c) => c.area === area && players.every((p) => Math.hypot(p.x - c.x, p.z - c.z) >= SPAWN_MIN_DIST && Math.hypot(p.x - c.x, p.z - c.z) <= SPAWN_MAX_DIST),
    );
    const crypt = crypts.length > 0;
    const pool: [number, number][] = crypt ? crypts.map((c) => [c.x, c.z]) : this.fairBreaches(area);
    const [x, z] = pool[Math.floor(this.rand() * pool.length)];
    this.surge = {
      area,
      x,
      z,
      startedAt: this.time,
      endsAt: this.time + SURGE.durationS,
      wavesSpawned: 0,
      ids: new Set(),
      spawned: 0,
      killed: 0,
    };
    this.emit({ t: 'surge', area, x, z, durationMs: SURGE.durationS * 1000, ...(crypt ? { crypt: true } : {}) });
  }

  private spawnSurgeWave(s: SurgeState) {
    const def = AREAS[s.area];
    const room = GLOBAL_ENEMY_CAP - this.enemies.size;
    const count = Math.min(room, Math.round(def.waveSize * SURGE.waveSizeMult * waveModifiers(this.waveTier).sizeMult));
    if (count <= 0) return;
    for (let i = 0; i < count; i++) {
      const e = this.spawnAtBreach(s.area, s.x, s.z);
      if (!e) continue;
      s.ids.add(e.id);
      s.spawned++;
    }
    this.emit({ t: 'wave', area: s.area, count, x: s.x, z: s.z });
  }

  private endSurge() {
    this.surge = null;
    const restless = milestoneActive('restless', this.waveTier) ? RESTLESS_SURGE_MULT : 1;
    this.surgeIn = (SURGE.minIntervalS + this.rand() * (SURGE.maxIntervalS - SURGE.minIntervalS)) * restless;
  }

  private updateWaves(dt: number) {
    const mods = waveModifiers(this.waveTier);
    for (const id of AREA_ORDER) {
      const def = AREAS[id];
      if (def.safe || !this.nav.isUnlocked(id)) continue;
      if (!this.playersIn(id).length) continue;
      if (id === 'sanctum' && this.boss.state.active) continue;
      let t = this.waveTimers.get(id);
      if (t === undefined) {
        // First visit: open with a heavier wave so the area feels inhabited.
        this.spawnWave(id, true);
        this.waveTimers.set(id, (def.waveIntervalMs / 1000) * mods.intervalMult);
        continue;
      }
      t -= dt;
      if (t <= 0) {
        this.spawnWave(id);
        t = (def.waveIntervalMs / 1000) * mods.intervalMult;
      }
      this.waveTimers.set(id, t);
    }
  }

  // --- Step ---

  step(dt: number): SimEvent[] {
    this.time += dt;
    this.updateWaves(dt);
    this.updateSurge(dt);
    this.updateZones(dt);
    this.updateEnemies(dt);
    this.updateThralls(dt);
    this.separate();
    this.boss.update(dt);
    this.updateCorpses();
    this.collectDead();
    return this.drain();
  }

  private updateZones(dt: number) {
    for (const z of [...this.zones.values()]) {
      if (this.time >= z.until) {
        this.zones.delete(z.id);
        this.emit({ t: 'zoneGone', id: z.id });
        continue;
      }
      z.tick -= dt;
      const pulse = z.tick <= 0;
      if (pulse) z.tick = 1;
      if (!z.hostile) {
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || Math.hypot(e.x - z.x, e.z - z.z) > z.r + e.radius) continue;
          e.slowT = 0.3;
          if (pulse) {
            e.withered = Math.min(z.witheredCap, e.withered + 1);
            e.witheredT = 5;
            e.witheredDps = Math.max(e.witheredDps, z.dps);
            e.witheredOwner = z.owner;
          }
        }
        const b = this.boss.state;
        if (b.active && pulse && Math.hypot(b.x - z.x, b.z - z.z) < z.r + BOSS_RADIUS) {
          b.withered = Math.min(z.witheredCap, b.withered + 1);
          b.witheredT = 5;
          b.witheredDps = Math.max(b.witheredDps, z.dps);
        }
        if (z.bloom) {
          for (const c of [...this.corpses.values()]) {
            if (this.bloomed.has(c.id) || Math.hypot(c.x - z.x, c.z - z.z) > z.r) continue;
            this.bloomed.add(c.id);
            this.removeCorpse(c, 'burst', z.owner);
            this.burst('bloom', c.x, c.z, 2.6, z.dps * 4, z.owner, z.witheredCap);
          }
        }
      } else if (pulse) {
        for (const p of this.players.values()) {
          if (p.alive && Math.hypot(p.x - z.x, p.z - z.z) < z.r + PLAYER_RADIUS) {
            this.emit({ t: 'hurt', player: p.id, dmg: z.dps, from: 'toxic', x: z.x, z: z.z });
          }
        }
        for (const t of this.thralls.values()) {
          if (Math.hypot(t.x - z.x, t.z - z.z) < z.r) this.hurtThrall(t, z.dps);
        }
      }
    }
  }

  burst(kind: 'bloom' | 'toxic', x: number, z: number, r: number, dmg: number, by: string, witheredCap = 5) {
    this.emit({ t: 'burst', kind, x, z, r });
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - x, e.z - z) > r + e.radius) continue;
      this.damageEnemy(e, dmg, by);
      if (kind === 'bloom') {
        e.withered = Math.min(witheredCap, e.withered + 1);
        e.witheredT = 5;
      }
    }
  }

  private updateCorpses() {
    for (const c of [...this.corpses.values()]) {
      if (this.time >= c.ruptureAt) {
        this.removeCorpse(c, 'burst');
        const level = AREAS[c.area].level;
        const zone: Zone = {
          id: this.id(),
          kind: 'toxic',
          owner: '',
          x: c.x,
          z: c.z,
          r: 2.4 * c.scale,
          until: this.time + 5,
          bornAt: this.time,
          tick: 0.4,
          dps: 6 * enemyDamageScale(level),
          slow: 1,
          witheredCap: 0,
          bloom: false,
          hostile: true,
        };
        this.zones.set(zone.id, zone);
        this.emit({ t: 'zone', zone });
        this.emit({ t: 'burst', kind: 'toxic', x: c.x, z: c.z, r: zone.r });
      } else if (this.time >= c.expiresAt) {
        this.removeCorpse(c, 'expired');
      }
    }
  }

  private collectDead() {
    for (const e of [...this.enemies.values()]) {
      if (e.hp > 0 || e.state === 'dead') continue;
      e.state = 'dead';
      this.enemies.delete(e.id);
      this.dotAccum.delete(e.id);
      if (this.surge?.ids.delete(e.id)) this.surge.killed++;
      const def = ENEMIES[e.def];
      this.emit({
        t: 'death',
        id: e.id,
        def: e.def,
        x: e.x,
        z: e.z,
        elite: e.elite,
        area: e.area,
        level: e.level,
        killer: e.lastHitBy,
      });
      this.addCorpse(e.x, e.z, def.corpse, e.def, e.elite, e.facing, e.scale, e.area);
      if (e.affix === 'vengeful') this.vengeance(e);
    }
  }

  // --- Elite affixes ---

  private tickAffix(e: Enemy, dt: number) {
    switch (e.affix) {
      case 'bellTolled': {
        const T = AFFIX_TUNING.bellTolled;
        if (e.tollAt) {
          if (this.time >= e.tollAt.t) {
            const { x, z } = e.tollAt;
            e.tollAt = undefined;
            this.soundToll(e, x, z);
          }
          return;
        }
        e.affixCd = (e.affixCd ?? T.intervalS) - dt;
        if (e.affixCd > 0) return;
        e.affixCd = T.intervalS;
        // The ring is anchored where it was rung — walking out of it is the answer.
        e.tollAt = { t: this.time + T.windupS, x: e.x, z: e.z };
        this.emit({ t: 'telegraph', id: e.id, kind: 'toll', x: e.x, z: e.z, tx: e.x, tz: e.z, ms: T.windupS * 1000, r: T.r });
        return;
      }
      case 'hungering': {
        const T = AFFIX_TUNING.hungering;
        e.affixCd = (e.affixCd ?? T.intervalS) - dt;
        if (e.affixCd > 0) return;
        const c = e.hp < e.maxHp ? this.nearestCorpse(e.x, e.z, T.reach) : null;
        if (!c) {
          e.affixCd = 0.5; // look again shortly
          return;
        }
        e.affixCd = T.intervalS;
        const heal = Math.min(e.maxHp - e.hp, e.maxHp * T.healFrac);
        e.hp += heal;
        this.emit({ t: 'affix', id: e.id, affix: 'hungering', x: e.x, z: e.z, tx: c.x, tz: c.z, amount: Math.round(heal) });
        this.removeCorpse(c, 'devoured');
        return;
      }
    }
  }

  private soundToll(e: Enemy, x: number, z: number) {
    const T = AFFIX_TUNING.bellTolled;
    const dmg = e.damage * T.damageMult;
    for (const p of this.players.values()) {
      if (p.alive && Math.hypot(p.x - x, p.z - z) <= T.r + PLAYER_RADIUS) {
        this.emit({ t: 'hurt', player: p.id, dmg, from: 'toll', x, z });
      }
    }
    for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - x, t.z - z) <= T.r) this.hurtThrall(t, dmg);
    this.emit({ t: 'affix', id: e.id, affix: 'bellTolled', x, z, r: T.r });
  }

  /** Vengeful elites burst into Risen where they fall. */
  private vengeance(e: Enemy) {
    const n = AFFIX_TUNING.vengeful.risen;
    this.emit({ t: 'affix', id: e.id, affix: 'vengeful', x: e.x, z: e.z, r: 1.8 });
    const spin = this.rand() * Math.PI * 2;
    for (let i = 0; i < n; i++) {
      const ang = spin + (i / n) * Math.PI * 2;
      const [x, z] = this.nav.resolveInArea(e.area, e.x + Math.cos(ang) * 1.4, e.z + Math.sin(ang) * 1.4, 0.45);
      this.spawnEnemy('risen', e.area, x, z, false);
    }
  }

  // --- Enemy AI ---

  private pickTarget(e: Enemy): { x: number; z: number; player?: PlayerBody; thrall?: Thrall } | null {
    let best: { x: number; z: number; player?: PlayerBody; thrall?: Thrall } | null = null;
    let bestD = AGGRO_RANGE;
    for (const p of this.players.values()) {
      if (!p.alive || p.area !== e.area) continue;
      const d = Math.hypot(p.x - e.x, p.z - e.z);
      if (d < bestD) {
        bestD = d;
        best = { x: p.x, z: p.z, player: p };
      }
    }
    for (const t of this.thralls.values()) {
      if (t.state === 'dead' || t.state === 'rising') continue;
      // Shieldbearers draw aggression (Bone Ward).
      const d = Math.hypot(t.x - e.x, t.z - e.z) * (t.kind === 'shieldbearer' ? 0.55 : 1.1);
      if (d < bestD) {
        bestD = d;
        best = { x: t.x, z: t.z, thrall: t };
      }
    }
    return best;
  }

  /** The most wounded unblessed non-Deacon ally within reach. */
  private sanctifyTarget(e: Enemy): Enemy | null {
    let best: Enemy | null = null;
    let bestFrac = 0.999;
    for (const o of this.enemies.values()) {
      if (o === e || o.def === 'deacon' || o.state === 'dead' || o.state === 'rising' || (o.sanctT ?? 0) > 0) continue;
      if (Math.hypot(o.x - e.x, o.z - e.z) > SANCTIFIED.range) continue;
      const frac = o.hp / o.maxHp;
      if (frac < bestFrac) {
        bestFrac = frac;
        best = o;
      }
    }
    return best;
  }

  private moveEnemy(e: Enemy, tx: number, tz: number, dt: number, speedMult = 1) {
    const dx = tx - e.x;
    const dz = tz - e.z;
    const d = Math.hypot(dx, dz);
    if (d < 0.05) return;
    const slow = (e.slowT > 0 ? MIASMA_SLOW : 1) * ((e.chillT ?? 0) > 0 ? CHILL.moveMult : 1);
    const step = Math.min(d, e.speed * speedMult * slow * dt);
    [e.x, e.z] = this.nav.resolveInArea(e.area, e.x + (dx / d) * step, e.z + (dz / d) * step, e.radius);
    e.facing = Math.atan2(dx, dz);
    e.moving = true;
    e.gait += step * 2.4;
  }

  private hurtThrall(t: Thrall, dmg: number) {
    t.hp -= dmg;
    t.flash = 1;
    if (t.hp <= 0) this.killThrall(t, 'killed');
  }

  private strike(e: Enemy, kind: 'melee' | 'cone' | 'curse' | 'slam') {
    const def = ENEMIES[e.def];
    if (kind === 'cone') {
      const dirX = e.aimX - e.x;
      const dirZ = e.aimZ - e.z;
      const len = Math.hypot(dirX, dirZ) || 1;
      const hits = (x: number, z: number) => {
        const vx = x - e.x;
        const vz = z - e.z;
        const d = Math.hypot(vx, vz);
        if (d > def.attackRange + 0.4) return false;
        return (vx * dirX + vz * dirZ) / (d * len || 1) > Math.cos((30 * Math.PI) / 180);
      };
      for (const p of this.players.values()) {
        if (p.alive && hits(p.x, p.z)) this.emit({ t: 'hurt', player: p.id, dmg: e.damage, from: 'cone', x: e.x, z: e.z });
      }
      for (const t of [...this.thralls.values()]) if (hits(t.x, t.z)) this.hurtThrall(t, e.damage);
      return;
    }
    const reach = kind === 'slam' ? 1.9 : def.attackRange * 1.35 + 0.4;
    const cx = kind === 'slam' ? e.aimX : e.x;
    const cz = kind === 'slam' ? e.aimZ : e.z;
    const p = e.targetPlayer ? this.players.get(e.targetPlayer) : undefined;
    if (p && p.alive && Math.hypot(p.x - cx, p.z - cz) <= reach) {
      this.emit({ t: 'hurt', player: p.id, dmg: e.damage, from: kind === 'curse' ? 'curse' : 'melee', x: e.x, z: e.z });
    }
    const t = e.targetThrall !== null ? this.thralls.get(e.targetThrall) : undefined;
    if (t && Math.hypot(t.x - cx, t.z - cz) <= reach) this.hurtThrall(t, e.damage);
    if (kind === 'slam') {
      for (const other of this.players.values()) {
        if (other !== p && other.alive && Math.hypot(other.x - cx, other.z - cz) <= reach) {
          this.emit({ t: 'hurt', player: other.id, dmg: e.damage, from: 'melee', x: e.x, z: e.z });
        }
      }
    }
    this.emit({ t: 'melee', id: e.id, x: e.x, z: e.z, tx: cx, tz: cz });
  }

  private tickStatuses(e: Enemy, dt: number) {
    e.flash = Math.max(0, e.flash - dt * 8);
    if (e.slowT > 0) e.slowT -= dt;
    if (e.fractureT > 0) {
      e.fractureT -= dt;
      if (e.fractureT <= 0) e.fracture = 0;
    }
    if ((e.chillT ?? 0) > 0) e.chillT! -= dt;
    if ((e.sanctT ?? 0) > 0) e.sanctT! -= dt;
    if ((e.bleedT ?? 0) > 0 && (e.bleedDps ?? 0) > 0) {
      e.bleedT! -= dt;
      const dmg = e.bleedDps! * dt * this.damageTakenMult(e);
      e.hp -= dmg;
      e.lastHitBy = e.bleedOwner || e.lastHitBy;
      const acc = (this.dotAccum.get(e.id) ?? 0) + dmg;
      if (acc >= Math.max(4, e.maxHp * 0.06)) {
        this.emit({ t: 'dmg', x: e.x, z: e.z, amount: Math.round(acc), kind: 'dot', by: e.bleedOwner ?? '' });
        this.dotAccum.set(e.id, 0);
      } else this.dotAccum.set(e.id, acc);
      if (e.bleedT! <= 0) e.bleedDps = 0;
    }
    if (e.witheredT > 0 && e.withered > 0) {
      e.witheredT -= dt;
      const dmg = e.withered * e.witheredDps * dt * this.damageTakenMult(e);
      e.hp -= dmg;
      e.lastHitBy = e.witheredOwner || e.lastHitBy;
      const acc = (this.dotAccum.get(e.id) ?? 0) + dmg;
      if (acc >= Math.max(4, e.maxHp * 0.06)) {
        this.emit({ t: 'dmg', x: e.x, z: e.z, amount: Math.round(acc), kind: 'dot', by: e.witheredOwner });
        this.dotAccum.set(e.id, 0);
      } else this.dotAccum.set(e.id, acc);
      if (e.witheredT <= 0) {
        e.withered = 0;
        e.witheredDps = 0;
      }
    }
  }

  private updateEnemies(dt: number) {
    const activeAreas = new Set<AreaId>();
    for (const p of this.players.values()) if (p.alive && p.area) activeAreas.add(p.area);
    for (const e of this.enemies.values()) {
      e.moving = false;
      this.tickStatuses(e, dt);
      e.stateT += dt;
      if (e.state === 'rising') {
        if (e.stateT >= RISE_TIME) {
          e.state = 'move';
          e.stateT = 0;
        }
        continue;
      }
      if (!activeAreas.has(e.area)) continue; // dormant: nobody here to hunt
      if (e.affix) this.tickAffix(e, dt);
      e.attackCd -= dt * ((e.chillT ?? 0) > 0 ? CHILL.attackRateMult : 1);
      const def = ENEMIES[e.def];

      if (e.state === 'windup' || e.state === 'channel') {
        const windup = (e.state === 'channel' ? 1.5 : def.windupMs / 1000) * (e.elite ? 0.85 : 1);
        if (e.stateT >= windup) this.release(e);
        continue;
      }
      if (e.state === 'recover') {
        if (e.stateT >= 0.3) {
          e.state = 'move';
          e.stateT = 0;
        }
        continue;
      }

      // Deacons harvest any unclaimed corpse in reach, hunting or not — that
      // corpse competition is why they're the priority kill.
      if (def.behavior === 'support' && e.attackCd <= 0) {
        const corpse = this.nearestCorpse(e.x, e.z, 8);
        if (corpse) {
          e.state = 'channel';
          e.stateT = 0;
          e.channelCorpse = corpse.id;
          e.aimX = corpse.x;
          e.aimZ = corpse.z;
          this.emit({ t: 'telegraph', id: e.id, kind: 'raise', x: e.x, z: e.z, tx: corpse.x, tz: corpse.z, ms: 1500 });
          continue;
        }
        // No corpse to steal: bless the nearest wounded ally instead (Sanctified).
        const ally = this.sanctifyTarget(e);
        if (ally) {
          ally.sanctT = SANCTIFIED.durationS;
          e.attackCd = (def.cooldownMs / 1000) * SANCTIFIED.cooldownMult;
          this.emit({ t: 'sanctify', id: e.id, target: ally.id, x: e.x, z: e.z, tx: ally.x, tz: ally.z });
        }
      }

      const target = this.pickTarget(e);
      e.targetPlayer = target?.player?.id ?? null;
      e.targetThrall = target?.thrall?.id ?? null;
      if (!target) {
        // Shamble toward the nearest breach-side wander point.
        if (this.rand() < dt * 0.3) e.facing += (this.rand() - 0.5) * 2;
        this.moveEnemy(e, e.x + Math.sin(e.facing), e.z + Math.cos(e.facing), dt, 0.3);
        continue;
      }
      const dist = Math.hypot(target.x - e.x, target.z - e.z);

      switch (def.behavior) {
        case 'melee':
        case 'hazard':
        case 'flank': {
          if (dist <= def.attackRange + 0.35 && e.attackCd <= 0) {
            e.state = 'windup';
            e.stateT = 0;
            e.aimX = target.x;
            e.aimZ = target.z;
            e.facing = Math.atan2(target.x - e.x, target.z - e.z);
            if (def.behavior === 'hazard') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'slam', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: def.windupMs });
            }
          } else if (dist > def.attackRange * 0.8) {
            let tx = target.x;
            let tz = target.z;
            if (def.behavior === 'flank' && dist > 2.5) {
              // Curve around the target's side.
              const px = -(target.z - e.z) / dist;
              const pz = (target.x - e.x) / dist;
              const off = Math.min(3, dist * 0.45) * e.flankSide;
              tx += px * off;
              tz += pz * off;
            }
            this.moveEnemy(e, tx, tz, dt);
          }
          break;
        }
        case 'caster': {
          if (dist <= def.attackRange - 0.5 && e.attackCd <= 0) {
            e.state = 'windup';
            e.stateT = 0;
            e.aimX = target.x;
            e.aimZ = target.z;
            e.facing = Math.atan2(target.x - e.x, target.z - e.z);
            this.emit({ t: 'telegraph', id: e.id, kind: 'cone', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: def.windupMs });
          } else if (dist > def.attackRange - 1.5) this.moveEnemy(e, target.x, target.z, dt);
          else if (dist < 3.5) this.moveEnemy(e, e.x * 2 - target.x, e.z * 2 - target.z, dt, 0.8);
          else e.facing = Math.atan2(target.x - e.x, target.z - e.z);
          break;
        }
        case 'support': {
          if (e.attackCd <= 0) {
            const corpse = this.nearestCorpse(e.x, e.z, 8);
            if (corpse) {
              e.state = 'channel';
              e.stateT = 0;
              e.channelCorpse = corpse.id;
              e.aimX = corpse.x;
              e.aimZ = corpse.z;
              this.emit({ t: 'telegraph', id: e.id, kind: 'raise', x: e.x, z: e.z, tx: corpse.x, tz: corpse.z, ms: 1500 });
              break;
            }
            if (dist <= def.attackRange) {
              e.state = 'windup';
              e.stateT = 0;
              e.aimX = target.x;
              e.aimZ = target.z;
              this.emit({ t: 'telegraph', id: e.id, kind: 'curse', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: def.windupMs });
              break;
            }
          }
          if (dist > def.attackRange - 0.5) this.moveEnemy(e, target.x, target.z, dt);
          else if (dist < 4) this.moveEnemy(e, e.x * 2 - target.x, e.z * 2 - target.z, dt, 0.7);
          break;
        }
      }
    }
  }

  private nearestCorpse(x: number, z: number, r: number) {
    let best: Corpse | null = null;
    let bestD = r;
    for (const c of this.corpses.values()) {
      const d = Math.hypot(c.x - x, c.z - z);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  private release(e: Enemy) {
    const def = ENEMIES[e.def];
    e.attackCd = (def.cooldownMs / 1000) * (e.elite ? 0.8 : 1);
    e.state = 'recover';
    e.stateT = 0;
    if (e.channelCorpse !== null) {
      const c = this.corpses.get(e.channelCorpse);
      e.channelCorpse = null;
      if (c) {
        this.removeCorpse(c, 'raised');
        this.spawnEnemy('risen', e.area, c.x, c.z, false);
      }
      return;
    }
    switch (def.behavior) {
      case 'caster':
        return this.strike(e, 'cone');
      case 'support':
        return this.strike(e, 'curse');
      case 'hazard':
        return this.strike(e, 'slam');
      default:
        return this.strike(e, 'melee');
    }
  }

  // --- Thrall AI ---

  private updateThralls(dt: number) {
    for (const t of [...this.thralls.values()]) {
      t.moving = false;
      t.flash = Math.max(0, t.flash - dt * 5);
      t.stateT += dt;
      t.attackCd -= dt;
      const owner = this.players.get(t.owner);
      if (!owner || !owner.alive) {
        this.killThrall(t, 'crumbled');
        continue;
      }
      if (t.state === 'rising') {
        if (t.stateT >= THRALL_RISE_TIME) {
          t.state = 'idle';
          t.stateT = 0;
        }
        continue;
      }
      const ownerDist = Math.hypot(owner.x - t.x, owner.z - t.z);
      if (ownerDist > THRALL_TELEPORT) {
        t.x = owner.x + (this.rand() - 0.5) * 2;
        t.z = owner.z + (this.rand() - 0.5) * 2;
        t.target = null;
      }

      let target = t.target !== null ? this.enemies.get(t.target) : undefined;
      const bossTarget = this.boss.state.active && Math.hypot(this.boss.state.x - owner.x, this.boss.state.z - owner.z) < 16;
      if (!target || target.state === 'dead' || Math.hypot(target.x - owner.x, target.z - owner.z) > THRALL_LEASH) {
        target = undefined;
        t.target = null;
        let bestD = 10;
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || e.state === 'rising') continue;
          if (Math.hypot(e.x - owner.x, e.z - owner.z) > THRALL_LEASH - 2) continue;
          const d = Math.hypot(e.x - t.x, e.z - t.z);
          if (d < bestD) {
            bestD = d;
            target = e;
          }
        }
        if (target) t.target = target.id;
      }

      const engage = (tx: number, tz: number, radius: number, hit: () => void) => {
        const d = Math.hypot(tx - t.x, tz - t.z);
        if (d > t.range + radius) {
          this.moveThrall(t, tx, tz, dt, 1);
          t.state = 'move';
        } else {
          t.facing = Math.atan2(tx - t.x, tz - t.z);
          if (t.attackCd <= 0) {
            t.attackCd = t.attackInterval;
            t.state = 'attack';
            t.stateT = 0;
            hit();
          } else if (t.state !== 'attack' || t.stateT > 0.5) t.state = 'idle';
        }
      };

      if (target) {
        const e = target;
        engage(e.x, e.z, e.radius, () => {
          const dealt = this.damageEnemy(e, t.damage, t.owner);
          if (t.kind === 'wraith') e.chillT = CHILL.durationS;
          this.emit({ t: 'thrallHit', id: t.id, target: e.id, x: t.x, z: t.z, tx: e.x, tz: e.z, kind: t.kind, dmg: Math.round(dealt) });
        });
      } else if (bossTarget) {
        const b = this.boss.state;
        engage(b.x, b.z, BOSS_RADIUS, () => {
          this.boss.damage(t.damage, t.owner, 0);
          this.emit({ t: 'thrallHit', id: t.id, target: -1, x: t.x, z: t.z, tx: b.x, tz: b.z, kind: t.kind, dmg: Math.round(t.damage) });
        });
      } else {
        // Formation ring around the owner.
        const count = Math.max(3, this.ownedThralls(t.owner).length);
        const ang = (t.slot / count) * Math.PI * 2 + Math.PI;
        const fx = owner.x + Math.sin(ang) * 1.9;
        const fz = owner.z + Math.cos(ang) * 1.9;
        const d = Math.hypot(fx - t.x, fz - t.z);
        if (d > 0.5) {
          this.moveThrall(t, fx, fz, dt, d > 6 ? 1.35 : 1);
          t.state = 'move';
        } else if (t.state === 'move') t.state = 'idle';
      }
    }
  }

  private moveThrall(t: Thrall, tx: number, tz: number, dt: number, mult: number) {
    const dx = tx - t.x;
    const dz = tz - t.z;
    const d = Math.hypot(dx, dz);
    if (d < 0.05) return;
    const step = Math.min(d, t.speed * mult * dt);
    [t.x, t.z] = this.nav.resolve(t.x + (dx / d) * step, t.z + (dz / d) * step, 0.4);
    t.facing = Math.atan2(dx, dz);
    t.moving = true;
    t.gait += step * 2.4;
  }

  /** Soft body separation: enemies ↔ enemies/thralls/players, thralls ↔ thralls. */
  private separate() {
    const bodies: { x: number; z: number; r: number; w: number; e?: Enemy; t?: Thrall }[] = [];
    for (const e of this.enemies.values()) if (e.state !== 'rising') bodies.push({ x: e.x, z: e.z, r: e.radius, w: 1, e });
    for (const t of this.thralls.values()) bodies.push({ x: t.x, z: t.z, r: 0.4, w: 0.6, t });
    for (const p of this.players.values()) if (p.alive) bodies.push({ x: p.x, z: p.z, r: PLAYER_RADIUS, w: 0 });
    for (let i = 0; i < bodies.length; i++) {
      const a = bodies[i];
      for (let j = i + 1; j < bodies.length; j++) {
        const b = bodies[j];
        const dx = b.x - a.x;
        const dz = b.z - a.z;
        const min = a.r + b.r;
        if (Math.abs(dx) > min || Math.abs(dz) > min) continue;
        const d = Math.hypot(dx, dz);
        if (d >= min || d < 1e-4) continue;
        const push = (min - d) * 0.5;
        const nx = dx / d;
        const nz = dz / d;
        const total = a.w + b.w || 1;
        const pa = (a.w / total) * push * 2;
        const pb = (b.w / total) * push * 2;
        a.x -= nx * pa;
        a.z -= nz * pa;
        b.x += nx * pb;
        b.z += nz * pb;
      }
    }
    for (const b of bodies) {
      if (b.e) [b.e.x, b.e.z] = this.nav.resolveInArea(b.e.area, b.x, b.z, b.e.radius);
      else if (b.t) [b.t.x, b.t.z] = this.nav.resolve(b.x, b.z, 0.4);
    }
  }

  /** Treat an area as already visited (host migration: no opening wave). */
  markVisited(area: AreaId) {
    if (!this.waveTimers.has(area)) this.waveTimers.set(area, (AREAS[area].waveIntervalMs / 1000) * waveModifiers(this.waveTier).intervalMult);
  }

  /** Development helper: clear an area and reset its wave timer. */
  clearArea(area: AreaId) {
    for (const e of [...this.enemies.values()]) if (e.area === area) this.enemies.delete(e.id);
    this.waveTimers.delete(area);
    if (this.surge?.area === area) this.surge = null;
  }

  arenaCenter() {
    return BOSS_ARENA;
  }
}
