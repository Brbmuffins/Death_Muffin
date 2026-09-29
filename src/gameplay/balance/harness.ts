import { ABILITIES, DETONATE, LITANY_PER_CORPSE } from '../../content/abilities';
import { AREAS, type AreaId } from '../../content/areas';
import { disciplineFor } from '../../content/disciplines';
import { deriveStats, xpToNext } from '../characterStats';
import { rollKill } from '../loot';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { Player } from '../Player';
import { resourceRulesFor } from '../resources';
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
  /** World Ascension rank (enemies run older). */
  ascension?: number;
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
  nav.setUnlocked(['ossuary', 'nave', 'sanctum', 'cloister']);
  const sim = new WorldSim(nav, rand);
  sim.waveTier = run.waveTier;
  sim.difficulty = run.difficulty ?? 'medium';
  sim.ascension = run.ascension ?? 0;
  sim.setCrypts(CRYPTS);
  const disc = disciplineFor(run.classIndex);
  const resource = resourceRulesFor(disc.family);
  const character = botCharacter(run.classIndex, run.level, run.gearStats ?? 0);
  let stats = deriveStats(character, [], disc, run.damageTier);
  const area = AREAS[run.area];
  const home = { x: (area.rect.x0 + area.rect.x1) / 2, z: area.rect.z1 - 4 };
  const p = { id: 'bot', x: home.x, z: home.z, hp: stats.maxHp, essence: resource.initial(resource.max(stats)), alive: true };
  // New families use the real Player body for resource drift and defensive
  // rites. Keep the established necromancer bot untouched for baseline parity.
  const body = disc.family === 'necromancer' ? null : new Player(stats, nav, disc.family);
  if (body) { body.x = p.x; body.z = p.z; body.area = run.area; }
  const cds = new Map<string, number>();
  let deaths = 0;
  let deadUntil = 0;
  let lastHurt = -99;
  let lastResourceGain = -99;
  let crowsUntil = 0;
  let nextCrowPeck = 0;
  let vigilUntil = 0;
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
      if (body) { body.revive(); p.essence = body.essence; }
    }
    if (p.alive) {
      if (body) {
        body.x = p.x; body.z = p.z; body.hp = p.hp; body.essence = p.essence;
        body.lastResourceGainAt = lastResourceGain * 1000;
        body.update(dt, t * 1000, null);
        if (t < vigilUntil) body.heal(stats.maxHp * 0.03 * dt);
        p.hp = body.hp; p.essence = body.essence;
      } else {
        const ooc = t - lastHurt > 5;
        p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * (ooc ? 0.045 : 0.004) * dt);
        p.essence = Math.max(0, Math.min(resource.max(stats), p.essence + resource.passive({ stats, value: p.essence,
          max: resource.max(stats), sinceHurtMs: (t - lastHurt) * 1000, sinceResourceGainMs: (t - lastResourceGain) * 1000 }) * dt));
      }
    }
    sim.setPlayer({ id: p.id, x: p.x, z: p.z, alive: p.alive, area: p.alive ? run.area : null, family: disc.family, level: run.level });

    // --- Bot decisions ---
    if (p.alive) {
      const enemies = [...sim.enemies.values()].filter((e) => e.state !== 'dead' && (e.state !== 'rising' && e.state !== 'burrow') && e.area === run.area);
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
      const corpsesNear = [...sim.corpses.values()].filter((c) => !c.echoOwner && Math.hypot(c.x - p.x, c.z - p.z) <= 7);
      const myThralls = [...sim.thralls.values()].filter((th) => th.owner === p.id);
      const sp = stats.spellPower;
      // The corpse in range whose blast would catch the most enemies (at least 3).
      let burst: Corpse | null = null;
      const bestBurst = (list: Enemy[]) => {
        let best: Corpse | null = null;
        let bestN = 2;
        for (const c of sim.corpses.values()) {
          if (c.echoOwner) continue;
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

      if (disc.family !== 'necromancer') {
        const send = (name: Extract<import('../sim/types').Intent, { t: 'signature' }>['sig'], x: number, z: number,
          power = sp, dur?: number) =>
          sim.apply({ t: 'signature', by: p.id, sig: name, x, z, dx: x - p.x, dz: z - p.z, sp: power,
            ...(dur === undefined ? {} : { dur }) });
        const hit = (id: keyof typeof ABILITIES, range: number, gain = 0, mult = 1, bleed = 0) => {
          if (!nearest || nd > range || !use(id, t)) return false;
          sim.apply({ t: 'hit', by: p.id, ids: [nearest.id], dmg: sp * ABILITIES[id].power * mult,
            ...(bleed ? { bleed } : {}) });
          p.essence = Math.min(resource.max(stats), p.essence + gain); if (gain) lastResourceGain = t;
          return true;
        };
        const arc = (id: 'flail_swing' | 'hollow_cut', range: number, halfDegrees: number, gainPerHit = 0) => {
          if (!nearest || nd > range || !use(id, t)) return false;
          const dx = (nearest.x - p.x) / (nd || 1), dz = (nearest.z - p.z) / (nd || 1);
          const ids = enemies.filter((e) => {
            const ex = e.x - p.x, ez = e.z - p.z, d = Math.hypot(ex, ez);
            return d <= range + e.radius && (ex * dx + ez * dz) / (d || 1) >= Math.cos(halfDegrees * Math.PI / 180);
          }).slice(0, 64).map((e) => e.id);
          if (ids.length) sim.apply({ t: 'hit', by: p.id, ids, dmg: sp * ABILITIES[id].power });
          p.essence = Math.min(resource.max(stats), p.essence + gainPerHit * ids.length);
          return true;
        };
        if (nearest) {
          const range = disc.family === 'witch' ? 8 : disc.family === 'veil' ? 11 : disc.family === 'monk' ? 1.8 : 3;
          if (nd > range - 0.4) {
            const step = stats.moveSpeed * dt;
            [p.x, p.z] = nav.resolve(p.x + (nearest.x - p.x) / nd * step, p.z + (nearest.z - p.z) / nd * step, 0.45);
          }
          if (disc.family === 'warden') {
            if (corpsesNear.length && use('burn_the_dead', t)) send('burn_the_dead', corpsesNear[0].x, corpsesNear[0].z);
            if (run.level >= 5 && near(5).length >= 2 && use('watchmans_ward', t)) send('watchmans_ward', p.x, p.z);
            if (run.level >= 10 && p.hp < stats.maxHp * 0.7 && near(12).length && use('last_light', t)) send('last_light', p.x, p.z);
            if (nd <= 7 && use('lantern_cone', t)) {
              const dx = (nearest.x - p.x) / (nd || 1), dz = (nearest.z - p.z) / (nd || 1);
              const ids = enemies.filter((e) => {
                const ex = e.x - p.x, ez = e.z - p.z, d = Math.hypot(ex, ez);
                return d <= 7 + e.radius && (ex * dx + ez * dz) / (d || 1) >= Math.cos(Math.PI / 5);
              }).slice(0, 64).map((e) => e.id);
              if (ids.length) sim.apply({ t: 'hit', by: p.id, ids, dmg: sp * ABILITIES.lantern_cone.power });
              send('lantern_cone', nearest.x, nearest.z);
            }
            arc('flail_swing', 3, 70);
          } else if (disc.family === 'monk') {
            if (nd <= 4 && use('toll', t)) {
              const spend = p.essence >= 25 ? 25 : 0;
              p.essence -= spend;
              send('toll', p.x, p.z, sp * (1 + spend / 100), spend ? 0.6 : undefined);
            }
            const beat = t % 1.2 <= 0.15 || t % 1.2 >= 1.05;
            hit('palm_strike', 1.8, beat ? 12 : 8, beat ? 1.4 : 1);
          } else if (disc.family === 'witch') {
            if (corpsesNear.length && use('harvest', t)) send('harvest', corpsesNear[0].x, corpsesNear[0].z);
            if (nd <= 7 && use('crow_swarm', t)) send('crow_swarm', nearest.x, nearest.z);
            if (t < crowsUntil && t >= nextCrowPeck && nd <= 3) {
              sim.apply({ t: 'hit', by: p.id, ids: [nearest.id], dmg: sp * 0.35 });
              nextCrowPeck = t + 0.5;
            }
            hit('hook_throw', 8, 0, 1, sp * 0.14);
          } else if (disc.family === 'veil') {
            if (body) {
              if (p.essence > 20 && nd <= 5) body.veilForm = true;
              else if (p.essence <= 8 || nd > 8) body.veilForm = false;
            }
            if (nd <= 8 && use('veil_tear', t)) send('veil_tear', nearest.x, nearest.z);
            hit('spirit_bolt', 11, 0, body?.veilForm ? 0.7 : 1);
          } else {
            if (body && run.level >= 3 && nd <= 2.5 && p.hp < stats.maxHp * 0.85 && use('bulwark', t)) {
              body.face(nearest.x, nearest.z);
              body.bulwarkUntil = (t + 2) * 1000;
              body.bulwarkPerfectUntil = (t + 0.25) * 1000;
            }
            if (body && run.level >= 10 && p.hp < stats.maxHp * 0.35 && use('oath_unbroken', t)) body.unbreakableUntil = (t + 6) * 1000;
            if (run.level >= 5 && p.hp < stats.maxHp * 0.65 && corpsesNear.length && use('corpse_vigil', t)) {
              send('vigil', corpsesNear[0].x, corpsesNear[0].z);
              vigilUntil = t + 4;
            }
            arc('hollow_cut', 2.4, 55, 4);
          }
        }
      } else {
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
          if (body) { body.hp = p.hp; body.essence = p.essence; body.setStats(stats); p.hp = body.hp; p.essence = body.essence; }
        }
      } else if (ev.t === 'newBlood' && ev.by === p.id && ev.ok) {
        if (ev.kind === 'burn_the_dead' || ev.kind === 'cremate' || ev.kind === 'harvest') {
          p.essence = Math.min(resource.max(stats), p.essence + (ev.amount ?? 0));
          lastResourceGain = t;
        }
        if (ev.kind === 'harvest') { crowsUntil = t + 6; nextCrowPeck = t; }
        if (ev.kind === 'heal' && ev.player === p.id && ev.amount) p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * ev.amount);
      } else if (ev.t === 'heal' && ev.player === p.id && p.alive) {
        p.hp = Math.min(stats.maxHp, p.hp + ev.amount);
      } else if (ev.t === 'hurt' && ev.player === p.id && p.alive) {
        const myThralls = [...sim.thralls.values()].filter((th) => th.owner === p.id).length;
        const lanternWard = [...sim.zones.values()].some((z) => z.kind === 'warden_ward' && Math.hypot(z.x - p.x, z.z - p.z) <= z.r) ? 0.2 : 0;
        const ward = disc.mods.wardPerThrall * myThralls + lanternWard;
        let dmg: number;
        if (body) {
          body.x = p.x; body.z = p.z; body.hp = p.hp; body.essence = p.essence;
          dmg = body.takeDamage(ev.dmg, ward, t * 1000, { x: ev.x, z: ev.z }, ev.from);
          p.hp = body.hp; p.essence = body.essence;
        } else {
          dmg = ev.dmg * (1 - Math.min(0.6, ward));
          p.hp -= dmg;
        }
        dmgTaken += dmg;
        if (dmg > 0) lastHurt = t;
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
