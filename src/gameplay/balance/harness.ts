import { ABILITIES, DETONATE, LITANY_PER_CORPSE } from '../../content/abilities';
import { AREAS, type AreaId } from '../../content/areas';
import { disciplineFor } from '../../content/disciplines';
import { deriveStats, xpToNext } from '../characterStats';
import { rollKill } from '../loot';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import type { Corpse, Enemy, SimEvent } from '../sim/types';
import { WorldSim } from '../sim/WorldSim';
import { generateLayout } from '../../content/layout';
import type { Character } from '../../net/types';
import type { Difficulty } from '../../content/difficulty';

/**
 * Headless balance harness: drives the real WorldSim with a scripted
 * necromancer bot for N minutes and reports farming rates and danger.
 * Used by `npm run balance` and the balance sanity tests. The bot is
 * deliberately "competent but not perfect" — it doesn't dodge telegraphs.
 */
export interface BalanceRun {
  area: AreaId;
  level: number;
  classIndex: number;
  damageTier: number;
  waveTier: number;
  minutes: number;
  seed?: number;
  /** Stat points per stat beyond base 5 (gear stand-in). */
  gearStats?: number;
  difficulty?: Difficulty;
}

export interface BalanceResult {
  run: BalanceRun;
  killsPerMin: number;
  goldPerMin: number;
  xpPerMin: number;
  shardsPerHour: number;
  deaths: number;
  damageTakenPerMin: number;
  /** Damage taken per minute as a percentage of starting max HP (level-independent danger). */
  dmgPctPerMin: number;
  /** Lowest HP reached, as a percentage of max HP (100 = never touched). */
  minHpPct: number;
  avgHpPct: number;
  surgesCleared: number;
  surgesFailed: number;
  avgTtkSec: number;
  peakEnemies: number;
  levelsGained: number;
  /** Seconds until the first death (-1 = survived the whole run). */
  firstDeathSec: number;
}

const SP_NEEDLE = ABILITIES.bone_needle;
const CRYPTS = generateLayout().crypts;
/** Death sends you to the Chapterhouse (4 s), then a waystone hop and a short walk back in. */
const RESPAWN_S = 4;
const RETURN_S = 8;

/** The bot's character sheet: `gear` stat points per stat beyond base (a gear stand-in). */
export function botCharacter(classIndex: number, level: number, gear: number): Character {
  return {
    id: 1,
    class_index: classIndex,
    class_name: '',
    level,
    experience: 0,
    gold: 0,
    stat_str: 5 + Math.round(gear * 0.3),
    stat_agi: 5,
    stat_int: 7 + gear,
    stat_vit: 5 + gear,
  };
}

export function runBalance(run: BalanceRun): BalanceResult {
  const rand = mulberry32(run.seed ?? 42);
  const nav = new Nav();
  nav.setUnlocked(['ossuary', 'nave', 'sanctum']);
  const sim = new WorldSim(nav, rand);
  sim.waveTier = run.waveTier;
  sim.difficulty = run.difficulty ?? 'medium';
  sim.setCrypts(CRYPTS);
  const disc = disciplineFor(run.classIndex);
  const character = botCharacter(run.classIndex, run.level, run.gearStats ?? 0);
  let stats = deriveStats(character, [], disc, run.damageTier);
  const area = AREAS[run.area];
  const home = { x: (area.rect.x0 + area.rect.x1) / 2, z: area.rect.z1 - 4 };
  const p = { id: 'bot', x: home.x, z: home.z, hp: stats.maxHp, essence: stats.maxEssence, alive: true };
  const cds = new Map<string, number>();
  let deaths = 0;
  let deadUntil = 0;
  let lastHurt = -99;
  let kills = 0;
  let gold = 0;
  let xp = 0;
  let shards = 0;
  let dmgTaken = 0;
  let hpSamples = 0;
  let hpAccum = 0;
  let peak = 0;
  let levels = 0;
  let minHp = 1;
  let surgesCleared = 0;
  let surgesFailed = 0;
  let firstDeath = -1;
  const startMaxHp = stats.maxHp;
  const born = new Map<number, number>();
  const ttks: number[] = [];

  const dt = 0.05;
  const steps = Math.round((run.minutes * 60) / dt);
  const ready = (id: string, t: number) => (cds.get(id) ?? 0) <= t;
  const use = (id: keyof typeof ABILITIES, t: number) => {
    const a = ABILITIES[id];
    if (!ready(id, t) || p.essence < a.essenceCost) return false;
    p.essence -= a.essenceCost;
    cds.set(id, t + a.cooldownMs / 1000);
    return true;
  };

  for (let i = 0; i < steps; i++) {
    const t = i * dt;
    // --- Player upkeep ---
    if (!p.alive && t >= deadUntil) {
      p.alive = true;
      p.hp = stats.maxHp;
      p.x = home.x;
      p.z = home.z;
    }
    if (p.alive) {
      const ooc = t - lastHurt > 5;
      p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * (ooc ? 0.045 : 0.004) * dt);
      p.essence = Math.min(stats.maxEssence, p.essence + stats.essenceRegen * dt);
    }
    sim.setPlayer({ id: p.id, x: p.x, z: p.z, alive: p.alive, area: p.alive ? run.area : null });

    // --- Bot decisions ---
    if (p.alive) {
      const enemies = [...sim.enemies.values()].filter((e) => e.state !== 'dead' && e.state !== 'rising' && e.area === run.area);
      peak = Math.max(peak, enemies.length);
      let nearest: Enemy | null = null;
      let nd = Infinity;
      for (const e of enemies) {
        const d = Math.hypot(e.x - p.x, e.z - p.z);
        if (d < nd) {
          nd = d;
          nearest = e;
        }
      }
      const near = (r: number, x = p.x, z = p.z) => enemies.filter((e) => Math.hypot(e.x - x, e.z - z) <= r);
      const corpsesNear = [...sim.corpses.values()].filter((c) => Math.hypot(c.x - p.x, c.z - p.z) <= 7);
      const myThralls = [...sim.thralls.values()].filter((th) => th.owner === p.id);
      const sp = stats.spellPower;
      // The corpse in range whose blast would catch the most enemies (at least 3).
      let burst: Corpse | null = null;
      const bestBurst = (list: Enemy[]) => {
        let best: Corpse | null = null;
        let bestN = 2;
        for (const c of sim.corpses.values()) {
          if (Math.hypot(c.x - p.x, c.z - p.z) > ABILITIES.corpse_explosion.range) continue;
          const r = DETONATE.radius * (c.kind === 'resonant' ? DETONATE.resonantRadiusMult : 1);
          const n = list.filter((e) => Math.hypot(e.x - c.x, e.z - c.z) <= r + e.radius).length;
          if (n > bestN) {
            bestN = n;
            best = c;
          }
        }
        return best;
      };

      // Black Litany when the field is rich.
      if (corpsesNear.length + myThralls.length * 1.5 >= 5 && near(7).length >= 3 && use('black_litany', t)) {
        sim.apply({ t: 'litany', by: p.id, x: p.x, z: p.z, r: 7, spellPower: sp, leaveCorpses: disc.mods.sacrificeLeavesCorpse });
      }
      // Keep the legion topped up.
      else if (corpsesNear.length && myThralls.length < disc.mods.thrallCap && use('exhume', t)) {
        const c = corpsesNear[0];
        sim.apply({ t: 'exhume', by: p.id, x: c.x, z: c.z, r: 0.8, kind: disc.mods.thrallKind, cap: disc.mods.thrallCap, hp: stats.thrallHp, damage: stats.thrallDamage, attackSpeedMult: disc.mods.thrallAttackSpeedMult });
      }
      // Corpse Explosion when a body lies under a pack (and the legion is full, or bodies are plentiful).
      else if (
        (myThralls.length >= disc.mods.thrallCap || corpsesNear.length >= 3) &&
        (burst = bestBurst(enemies)) &&
        use('corpse_explosion', t)
      ) {
        sim.apply({ t: 'detonate', by: p.id, corpseId: burst.id, dmg: sp * ABILITIES.corpse_explosion.power });
      }
      // Miasma on a clump.
      else if (nearest && near(4, nearest.x, nearest.z).length >= 4 && use('miasma', t)) {
        sim.apply({ t: 'miasma', by: p.id, x: nearest.x, z: nearest.z, r: ABILITIES.miasma.radius * disc.mods.miasmaRadiusMult, dps: sp * ABILITIES.miasma.power, durationMs: 6000, witheredCap: disc.mods.witheredMaxStacks, bloom: disc.mods.miasmaBurstsCorpses });
      }
      // Spear when three line up (approximation: three within 8 m in a 60° cone).
      else if (nearest && nd < 10) {
        const dx = (nearest.x - p.x) / (nd || 1);
        const dz = (nearest.z - p.z) / (nd || 1);
        const inLine = enemies.filter((e) => {
          const rx = e.x - p.x;
          const rz = e.z - p.z;
          const along = rx * dx + rz * dz;
          return along > 0 && along < ABILITIES.marrow_spear.range && Math.abs(rx * dz - rz * dx) < 1.3 + e.radius;
        });
        if (inLine.length >= 3 && use('marrow_spear', t)) {
          sim.apply({ t: 'hit', by: p.id, ids: inLine.map((e) => e.id), dmg: sp * ABILITIES.marrow_spear.power, fracture: 1 });
        }
      }
      // Needle the nearest; close distance if out of range, back off if swarmed.
      if (nearest) {
        if (nd > SP_NEEDLE.range - 0.5) {
          const step = stats.moveSpeed * dt;
          [p.x, p.z] = nav.resolve(p.x + ((nearest.x - p.x) / nd) * step, p.z + ((nearest.z - p.z) / nd) * step, 0.45);
        } else if (near(1.6).length >= 3 && p.hp < stats.maxHp * 0.5) {
          const step = stats.moveSpeed * dt;
          [p.x, p.z] = nav.resolve(p.x - ((nearest.x - p.x) / nd) * step, p.z - ((nearest.z - p.z) / nd) * step, 0.45);
        }
        if (nd <= SP_NEEDLE.range + 0.4 && ready('bone_needle', t)) {
          cds.set('bone_needle', t + SP_NEEDLE.cooldownMs / 1000);
          const crit = rand() < 0.08;
          sim.apply({ t: 'hit', by: p.id, ids: [nearest.id], dmg: sp * SP_NEEDLE.power * (crit ? 1.8 : 1) });
          p.essence = Math.min(stats.maxEssence, p.essence + 6);
        }
      } else {
        // Wander toward the area's middle when idle.
        const cx = (area.rect.x0 + area.rect.x1) / 2;
        const cz = (area.rect.z0 + area.rect.z1) / 2;
        const d = Math.hypot(cx - p.x, cz - p.z);
        if (d > 3) {
          const step = stats.moveSpeed * dt;
          [p.x, p.z] = nav.resolve(p.x + ((cx - p.x) / d) * step, p.z + ((cz - p.z) / d) * step, 0.45);
        }
      }
    }

    // --- Step the world ---
    const events: SimEvent[] = sim.step(dt);
    for (const ev of events) {
      if (ev.t === 'surgeCleared') surgesCleared++;
      else if (ev.t === 'surgeFailed') surgesFailed++;
      else if (ev.t === 'spawn') born.set(ev.id, t);
      else if (ev.t === 'death') {
        const b = born.get(ev.id);
        if (b !== undefined) ttks.push(t - b);
        born.delete(ev.id);
        if (!p.alive) continue;
        kills++;
        const r = rollKill(ev.def, ev.area, ev.level, ev.elite, run.waveTier, rand, sim.difficulty);
        gold += r.gold;
        xp += r.xp;
        shards += r.shards;
        character.experience += r.xp;
        while (character.experience >= xpToNext(character.level)) {
          character.experience -= xpToNext(character.level);
          character.level++;
          levels++;
          stats = deriveStats(character, [], disc, run.damageTier);
        }
      } else if (ev.t === 'hurt' && ev.player === p.id && p.alive) {
        const myThralls = [...sim.thralls.values()].filter((th) => th.owner === p.id).length;
        const dmg = ev.dmg * (1 - Math.min(0.6, disc.mods.wardPerThrall * myThralls));
        p.hp -= dmg;
        dmgTaken += dmg;
        lastHurt = t;
        minHp = Math.min(minHp, Math.max(0, p.hp) / stats.maxHp);
        if (p.hp <= 0) {
          p.alive = false;
          deaths++;
          deadUntil = t + RESPAWN_S + RETURN_S;
          if (firstDeath < 0) firstDeath = t;
        }
      }
    }
    if (i % 20 === 0 && p.alive) {
      hpSamples++;
      hpAccum += p.hp / stats.maxHp;
    }
  }

  const mins = run.minutes;
  return {
    run,
    killsPerMin: kills / mins,
    goldPerMin: gold / mins,
    xpPerMin: xp / mins,
    shardsPerHour: (shards / mins) * 60,
    deaths,
    damageTakenPerMin: dmgTaken / mins,
    dmgPctPerMin: (dmgTaken / startMaxHp / mins) * 100,
    minHpPct: minHp * 100,
    avgHpPct: hpSamples ? (hpAccum / hpSamples) * 100 : 0,
    surgesCleared,
    surgesFailed,
    avgTtkSec: ttks.length ? ttks.reduce((a, b) => a + b, 0) / ttks.length : 0,
    peakEnemies: peak,
    levelsGained: levels,
    firstDeathSec: firstDeath,
  };
}

/** Litany value helper kept here so the report can explain Litany scaling. */
export const litanyMultiplier = (corpses: number) => 1.5 + LITANY_PER_CORPSE * corpses;
