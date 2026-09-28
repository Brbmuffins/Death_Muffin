import { ABILITIES, DETONATE } from '../../content/abilities';
import { disciplineFor } from '../../content/disciplines';
import { HEALING_FLASKS } from '../../content/items';
import { deriveStats } from '../characterStats';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { BOSS_ARENA, BOSS_RADIUS } from '../sim/BossBrain';
import type { Enemy, SimEvent } from '../sim/types';
import { WorldSim } from '../sim/WorldSim';
import { botCharacter } from './harness';
import type { Difficulty } from '../../content/difficulty';

/**
 * Headless Prelate fight: the same scripted necromancer as the farming
 * harness, summoning the Bell-Sworn Prelate with a legion already raised and
 * fighting until the Prelate dies, the bot dies (solo death resets the boss),
 * or time runs out. Unlike the farming bot it can dodge the Prelate's
 * telegraphs after a human-ish reaction delay, so both a careful and a
 * careless player can be measured.
 */
export interface BossRun {
  level: number;
  classIndex: number;
  damageTier: number;
  gearStats: number;
  /** Step out of boss telegraphs (after `reactionS`). */
  dodge: boolean;
  reactionS?: number;
  /** Major healing flasks carried (70% each, 1.5 s cooldown). */
  flasks?: number;
  maxMinutes?: number;
  seed?: number;
  difficulty?: Difficulty;
  ascension?: number;
}

export interface BossResult {
  run: BossRun;
  outcome: 'win' | 'wipe' | 'timeout';
  seconds: number;
  /** Seconds at which phase 2 / 3 began (-1 = never). */
  phase2At: number;
  phase3At: number;
  bossHpLeftPct: number;
  bossMaxHp: number;
  dmgPctPerMin: number;
  /** Damage taken by source, as % of max HP over the whole fight. */
  bySource: Record<string, number>;
  minHpPct: number;
  flasksUsed: number;
  /** Player-side damage per second into the boss (all sources). */
  dps: number;
}

interface Danger {
  x: number;
  z: number;
  r: number;
  at: number;
  seenAt: number;
}

const DT = 0.05;

export function runBossFight(run: BossRun): BossResult {
  const rand = mulberry32(run.seed ?? 42);
  const nav = new Nav();
  nav.setUnlocked(['ossuary', 'nave', 'sanctum']);
  const sim = new WorldSim(nav, rand);
  sim.difficulty = run.difficulty ?? 'medium';
  sim.ascension = run.ascension ?? 0;
  const disc = disciplineFor(run.classIndex);
  const stats = deriveStats(botCharacter(run.classIndex, run.level, run.gearStats), [], disc, run.damageTier);
  const sp = stats.spellPower;
  const reaction = run.reactionS ?? 0.35;
  const p = { id: 'bot', x: BOSS_ARENA.x, z: BOSS_ARENA.z + 9, hp: stats.maxHp, essence: stats.maxEssence };
  const cds = new Map<string, number>();
  const ready = (id: string, t: number) => (cds.get(id) ?? 0) <= t;
  const use = (id: keyof typeof ABILITIES, t: number) => {
    const a = ABILITIES[id];
    if (!ready(id, t) || p.essence < a.essenceCost) return false;
    p.essence -= a.essenceCost;
    cds.set(id, t + a.cooldownMs / 1000);
    return true;
  };
  const place = (alive = true) => sim.setPlayer({ id: p.id, x: p.x, z: p.z, alive, area: alive ? 'sanctum' : null });

  // Arrive with a full legion (raised during the Sanctum trash).
  place();
  for (let i = 0; i < disc.mods.thrallCap; i++) {
    const cx = p.x - 1.5 + i * 0.8;
    const cz = p.z + 1;
    sim.addCorpse(cx, cz, 'normal', 'robber', false, 0, 1, 'sanctum');
    sim.apply({ t: 'exhume', by: p.id, x: cx, z: cz, r: 0.8, kind: disc.mods.thrallKind, cap: disc.mods.thrallCap, hp: stats.thrallHp, damage: stats.thrallDamage, attackSpeedMult: disc.mods.thrallAttackSpeedMult });
  }
  for (let i = 0; i < 25; i++) sim.step(DT);
  // Clear the trash that climbed out while the legion rose; the fight starts clean.
  for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
  sim.apply({ t: 'summonBoss', by: p.id });
  const b = sim.boss.state;
  const bossMaxHp = b.maxHp;

  const dangers: Danger[] = [];
  const bySource: Record<string, number> = {};
  let minHp = 1;
  let flasks = run.flasks ?? 4;
  let flasksUsed = 0;
  let flaskCd = 0;
  let lastHurt = -99;
  let dmgTaken = 0;
  let phase2At = -1;
  let phase3At = -1;
  let outcome: BossResult['outcome'] = 'timeout';
  const maxSteps = Math.round(((run.maxMinutes ?? 6) * 60) / DT);
  let t = 0;
  let steps = 0;

  const move = (tx: number, tz: number, away = false) => {
    const dx = tx - p.x;
    const dz = tz - p.z;
    const d = Math.hypot(dx, dz) || 1;
    const k = ((away ? -1 : 1) * stats.moveSpeed * DT) / d;
    [p.x, p.z] = nav.resolve(p.x + dx * k, p.z + dz * k, 0.45);
  };

  for (; steps < maxSteps; steps++) {
    t = steps * DT;
    const inCombat = t - lastHurt < 5;
    p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * (inCombat ? 0.004 : 0.045) * DT);
    p.essence = Math.min(stats.maxEssence, p.essence + stats.essenceRegen * DT);
    if (p.hp < stats.maxHp * 0.4 && flasks > 0 && t >= flaskCd) {
      p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * HEALING_FLASKS.flask_hp_major);
      flasks--;
      flasksUsed++;
      flaskCd = t + 1.5;
    }

    // --- Movement: dodge first, otherwise hold a casting distance from the Prelate ---
    const bd = Math.hypot(b.x - p.x, b.z - p.z);
    const threat = run.dodge
      ? dangers.find((d) => t - d.seenAt >= reaction && t < d.at && Math.hypot(p.x - d.x, p.z - d.z) < d.r + 0.9)
      : undefined;
    if (threat) {
      // Step straight out of the circle (sideways if standing on its centre).
      if (Math.hypot(p.x - threat.x, p.z - threat.z) < 0.2) move(p.x + 1, p.z);
      else move(threat.x, threat.z, true);
    } else if (bd > 9) move(b.x, b.z);
    else if (bd < 5.5) move(b.x, b.z, true);

    // --- Spells ---
    const adds = [...sim.enemies.values()].filter((e) => e.state !== 'dead' && (e.state !== 'rising' && e.state !== 'burrow'));
    let nearAdd: Enemy | null = null;
    let nad = 8;
    for (const e of adds) {
      const d = Math.hypot(e.x - p.x, e.z - p.z);
      if (d < nad) {
        nad = d;
        nearAdd = e;
      }
    }
    const corpses = [...sim.corpses.values()];
    const myThralls = [...sim.thralls.values()].filter((th) => th.owner === p.id);
    const corpseNear = corpses.find((c) => Math.hypot(c.x - p.x, c.z - p.z) <= ABILITIES.exhume.range);
    const corpseByBoss = corpses.find((c) => Math.hypot(c.x - b.x, c.z - b.z) <= DETONATE.radius + BOSS_RADIUS);
    if (b.active) {
      if (corpseNear && myThralls.length < disc.mods.thrallCap && use('exhume', t)) {
        sim.apply({ t: 'exhume', by: p.id, x: corpseNear.x, z: corpseNear.z, r: 0.8, kind: disc.mods.thrallKind, cap: disc.mods.thrallCap, hp: stats.thrallHp, damage: stats.thrallDamage, attackSpeedMult: disc.mods.thrallAttackSpeedMult });
      } else if (bd <= 7 && myThralls.length + corpses.length >= 3 && use('black_litany', t)) {
        sim.apply({ t: 'litany', by: p.id, x: p.x, z: p.z, r: 7, spellPower: sp, leaveCorpses: disc.mods.sacrificeLeavesCorpse });
      } else if (corpseByBoss && use('corpse_explosion', t)) {
        sim.apply({ t: 'detonate', by: p.id, corpseId: corpseByBoss.id, dmg: sp * ABILITIES.corpse_explosion.power });
      } else if (bd <= ABILITIES.miasma.range && use('miasma', t)) {
        sim.apply({ t: 'miasma', by: p.id, x: b.x, z: b.z, r: ABILITIES.miasma.radius * disc.mods.miasmaRadiusMult, dps: sp * ABILITIES.miasma.power, durationMs: 6000, witheredCap: disc.mods.witheredMaxStacks, bloom: disc.mods.miasmaBurstsCorpses });
      } else if (bd <= ABILITIES.marrow_spear.range && use('marrow_spear', t)) {
        sim.apply({ t: 'hit', by: p.id, ids: [], dmg: sp * ABILITIES.marrow_spear.power, fracture: 1, boss: true });
      }
      // Needle: adds that walk up first, otherwise the Prelate.
      if (ready('bone_needle', t)) {
        const needle = ABILITIES.bone_needle;
        const crit = rand() < 0.08 ? 1.8 : 1;
        if (nearAdd) {
          cds.set('bone_needle', t + needle.cooldownMs / 1000);
          sim.apply({ t: 'hit', by: p.id, ids: [nearAdd.id], dmg: sp * needle.power * crit });
          p.essence = Math.min(stats.maxEssence, p.essence + 6);
        } else if (bd <= needle.range + BOSS_RADIUS) {
          cds.set('bone_needle', t + needle.cooldownMs / 1000);
          sim.apply({ t: 'hit', by: p.id, ids: [], dmg: sp * needle.power * crit, boss: true });
          p.essence = Math.min(stats.maxEssence, p.essence + 6);
        }
      }
    }

    place();
    const events: SimEvent[] = sim.step(DT);
    for (const ev of events) {
      if (ev.t === 'boss') {
        if (ev.ms) {
          for (const [x, z] of ev.targets ?? [[ev.x, ev.z]]) dangers.push({ x, z, r: ev.r ?? 2, at: t + ev.ms / 1000, seenAt: t });
        }
        if (ev.kind === 'phase' && ev.phase === 2) phase2At = t;
        if (ev.kind === 'phase' && ev.phase === 3) phase3At = t;
        if (ev.kind === 'defeated' && ev.killer) outcome = 'win';
      } else if (ev.t === 'hurt' && ev.player === p.id) {
        const ward = 1 - Math.min(0.6, disc.mods.wardPerThrall * [...sim.thralls.values()].filter((th) => th.owner === p.id).length);
        const dmg = ev.dmg * ward;
        p.hp -= dmg;
        dmgTaken += dmg;
        lastHurt = t;
        const src = ev.from === 'boss' ? 'prelate' : 'adds';
        bySource[src] = (bySource[src] ?? 0) + dmg;
        minHp = Math.min(minHp, Math.max(0, p.hp) / stats.maxHp);
      }
    }
    for (let i = dangers.length - 1; i >= 0; i--) if (dangers[i].at <= t) dangers.splice(i, 1);
    if (outcome === 'win') break;
    if (p.hp <= 0) {
      outcome = 'wipe';
      place(false);
      sim.step(DT);
      break;
    }
  }

  const secs = Math.max(DT, t);
  const pct: Record<string, number> = {};
  for (const [k, v] of Object.entries(bySource)) pct[k] = (v / stats.maxHp) * 100;
  const bossHpLeft = outcome === 'win' ? 0 : Math.max(0, b.hp);
  return {
    run,
    outcome,
    seconds: secs,
    phase2At,
    phase3At,
    bossHpLeftPct: (bossHpLeft / bossMaxHp) * 100,
    bossMaxHp,
    dmgPctPerMin: (dmgTaken / stats.maxHp / (secs / 60)) * 100,
    bySource: pct,
    minHpPct: minHp * 100,
    flasksUsed,
    dps: (bossMaxHp - bossHpLeft) / secs,
  };
}
