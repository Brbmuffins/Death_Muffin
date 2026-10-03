import { ABILITIES, DETONATE, LITANY_PER_CORPSE, SOUL_HARVEST } from '../../content/abilities';
import { bogMult } from '../../content/fen';
import { AREAS, type AreaId } from '../../content/areas';
import { chestBonus, depthLootArea, floorBonus, hasChest } from '../../content/depths';
import { disciplineFor } from '../../content/disciplines';
import { deriveStats, xpToNext } from '../characterStats';
import { rollKill } from '../loot';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { Player } from '../Player';
import { LEGEND, colossusActive, damageTakenMult, effectiveWitheredCap, shatterDamage, simLegendActive, simLegendOf, wardReflectDamage } from '../legendary';
import { resourceRulesFor } from '../resources';
import type { Corpse, Enemy, SimEvent } from '../sim/types';
import { WorldSim, thrallWeight } from '../sim/WorldSim';
import { generateLayout } from '../../content/layout';
import type { Character, InventorySlot } from '../../net/types';
import { EQUIP_SLOTS, equippedBySlot } from '../../content/gear';
import { foldEffect, withSetBonuses } from '../setBonuses';
import type { SetEffect } from '../../content/setBonuses';
import { abilityCooldownMs, abilityRange, pierceTargets, reapTargets, resolveWeaponLoadout, NO_LOADOUT } from '../weaponLine';
import { NECRO_WEAPON_TUNING } from '../../content/necroWeapons';
import { resolveKit, type KitName, type KitRequest } from './kits';
import type { Difficulty } from '../../content/difficulty';
import { RUNE_TUNING, type RuneId, type RuneRite } from '../../content/runes';
import { corpsesWithin, impaleTarget, ringHits, splinterTarget, volleyTargets } from '../runeCast';

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
  /**
   * Gear kit worn by the bot (balance/kits.ts). `none` / absent = the harness as it always was. A kit replaces the share of
   * the `gearStats` stand-in that its slots cover (the stand-in is "ordinary gear in all nine slots"), so a kit is judged
   * against the gear it displaces rather than stacked on top of it.
   */
  kit?: KitName;
  /** Explicit worn rows (experiments); wins over `kit`. */
  slots?: InventorySlot[];
  /** Experiments: change the kit's weapon pair, tier or lever list (balance/kits.ts KitRequest.override). */
  kitOverride?: KitRequest['override'];
  /** Regression: skip the corpse-heal and Litany-barrier effects the bot gained in the gear pass (the pre-2026-10-02 bot never applied them). */
  noRiteEffects?: boolean;
  /** Experiments: one extra effect (a lever, a stat) folded on top of whatever is worn, to measure what a single number is worth. */
  effect?: SetEffect;
  /** The Catacomb Depths (`area: 'depths'`): the floor depth to hold. A cleared floor re-rolls the same depth, so the row measures that depth alone. */
  depth?: number;
  /** Relic runes socketed in the necromancer's rites (content/runes.ts): the bot casts each rite the way AbilitySystem does with that rune. */
  runes?: Partial<Record<RuneRite, RuneId>>;
  /**
   * Model Soul Harvest (50 kills fill the meter; the next Marrow Spear / Miasma / Black Litany is free and 50% larger). Off by default
   * because the long-standing baselines never modelled it; the Requiem legendary set (fill rate, wraith nova) only means something with it on.
   */
  soulHarvest?: boolean;
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
  /** Mean number of living thralls while the bot is alive, and the thrall cap it fought with (0 for other families). */
  avgThralls: number;
  thrallCap: number;
  /** Catacomb Depths rows: floors cleared per simulated minute (0 elsewhere). */
  floorsPerMin: number;
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
  nav.setUnlocked(['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'warren', 'coliseum', 'fen']);
  const sim = new WorldSim(nav, rand);
  sim.waveTier = run.waveTier;
  sim.difficulty = run.difficulty ?? 'medium';
  sim.ascension = run.ascension ?? 0;
  sim.setCrypts(CRYPTS);
  const baseDisc = disciplineFor(run.classIndex);
  const worn: InventorySlot[] = run.slots ?? resolveKit({ kit: run.kit ?? 'none', discipline: baseDisc.id, area: run.area, override: run.kitOverride, seed: run.seed });
  const loadout = baseDisc.family === 'necromancer' ? resolveWeaponLoadout(equippedBySlot(worn), baseDisc.id) : NO_LOADOUT;
  // The discipline as the scene builds it: set bonuses and worn affixes folded into the mods, then the skull focus's thrall.
  const withGear = withSetBonuses(baseDisc, worn);
  const geared = loadout.thrallBonus ? { ...withGear, mods: { ...withGear.mods, thrallCap: withGear.mods.thrallCap + loadout.thrallBonus } } : withGear;
  const disc = run.effect ? { ...geared, mods: foldEffect(geared.mods, run.effect) } : geared;
  const resource = resourceRulesFor(disc.family);
  const covered = new Set(Object.keys(equippedBySlot(worn))).size;
  const standIn = (run.gearStats ?? 0) * (1 - covered / EQUIP_SLOTS.length);
  const character = botCharacter(run.classIndex, run.level, standIn);
  for (const [k, v] of Object.entries(run.effect?.stats ?? {})) (character as unknown as Record<string, number>)[k] += v as number;
  let stats = deriveStats(character, worn, disc, run.damageTier);
  const area = AREAS[run.area];
  let home = { x: (area.rect.x0 + area.rect.x1) / 2, z: area.rect.z1 - 4 };
  // The Catacomb Depths: a held floor of the given depth (sim.startDepths builds it and opens its ground to the bot).
  if (run.area === 'depths') {
    const floor = sim.startDepths('bot', (run.seed ?? 42) * 7919 + 13, run.depth ?? 1, true);
    home = { x: floor.start.x, z: floor.start.z };
  }
  const p = { id: 'bot', x: home.x, z: home.z, hp: stats.maxHp, essence: resource.initial(resource.max(stats)), alive: true };
  // New families use the real Player body for resource drift and defensive
  // rites. Keep the established necromancer bot untouched for baseline parity.
  // Legendary set mechanics the shared sim runs (death burst, Champions, spear rally, Contagion, Chain Plague): no-op unless a mod is on.
  const legendMods = simLegendOf(disc.mods);
  if (simLegendActive(legendMods)) sim.apply({ t: 'legend', by: p.id, mods: legendMods });
  const body = disc.family === 'necromancer' ? null : new Player(stats, nav, disc.family);
  if (body) { body.x = p.x; body.z = p.z; body.area = run.area; }
  const runes = disc.family === 'necromancer' ? (run.runes ?? {}) : {};
  const cds = new Map<string, number>();
  let needleCasts = 0;
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
  let thrallAccum = 0;
  let peak = 0;
  let levels = 0;
  let minHp = 1;
  let surgesCleared = 0;
  let surgesFailed = 0;
  let floorsCleared = 0;
  let firstDeath = -1;
  const startMaxHp = stats.maxHp;
  const born = new Map<number, number>();
  const ttks: number[] = [];

  // The Mourning Fen's bog slows the bot exactly as it slows a hero (hummocks are dry).
  const bog = () => (run.area === 'fen' ? bogMult(p.x, p.z) : 1);
  const dt = 0.05;
  const steps = Math.round((run.minutes * 60) / dt);
  const ready = (id: string, t: number) => (cds.get(id) ?? 0) <= t;
  const use = (id: keyof typeof ABILITIES, t: number) => {
    const a = ABILITIES[id];
    if (!ready(id, t) || p.essence < a.essenceCost) return false;
    p.essence -= a.essenceCost;
    // A grimoire shortens every rite (the left click is exempt), exactly as the player's cooldowns do.
    cds.set(id, t + abilityCooldownMs(id, a.cooldownMs, loadout, id === 'bone_needle') / 1000);
    return true;
  };
  /** Damage barrier (Black Litany with a Reliquary set): absorbs hits first and melts at 4% of max health per second. */
  let barrier = 0;
  /** Legendary: the Litany barrier at its largest (Litany Shatter), the Soul Harvest meter (opt-in model), and Requiem wisps (expiry times). */
  let barrierPeak = 0;
  let souls = 0;
  let soulAcc = 0;
  const wisps: number[] = [];
  const M = disc.mods;
  const strike = (x: number, z: number, r: number, dmg: number) => {
    const ids = [...sim.enemies.values()].filter((e) => e.state !== 'dead' && e.state !== 'burrow' && Math.hypot(e.x - x, e.z - z) <= r + e.radius).map((e) => e.id);
    if (ids.length) sim.apply({ t: 'hit', by: p.id, ids, dmg });
  };
  const consumed = (t: number) => {
    if (!(M.corpseWisp > 0)) return;
    if (wisps.length >= LEGEND.wispCap) wisps[wisps.indexOf(Math.min(...wisps))] = t + M.corpseWisp;
    else wisps.push(t + M.corpseWisp);
  };
  /** Soul Harvest: charged meter makes the next spear/miasma/litany free and larger; returns whether this cast is empowered. */
  const useRite = (id: keyof typeof ABILITIES, t: number) => {
    if (run.soulHarvest && souls >= SOUL_HARVEST.souls && SOUL_HARVEST.spells.includes(id) && ready(id, t)) {
      cds.set(id, t + abilityCooldownMs(id, ABILITIES[id].cooldownMs, loadout, false) / 1000);
      return 'empowered' as const;
    }
    return use(id, t) ? ('normal' as const) : null;
  };
  const release = (t: number) => {
    souls = 0;
    if (!(M.wraithNova > 0)) return;
    const src: { x: number; z: number }[] = wisps.filter((u) => u > t).map(() => ({ x: p.x, z: p.z }));
    for (const th of sim.thralls.values()) if (th.owner === p.id && th.kind === 'wraith' && th.state !== 'rising') src.push({ x: th.x, z: th.z });
    for (const sx of src.slice(0, LEGEND.novaMax)) strike(sx.x, sx.z, LEGEND.novaR, stats.spellPower * M.wraithNova);
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
      if (barrier > 0) barrier = Math.max(0, barrier - stats.maxHp * 0.04 * dt);
      else barrierPeak = 0;
      if (wisps.length) {
        for (let w = wisps.length - 1; w >= 0; w--) if (wisps[w] <= t) wisps.splice(w, 1);
        p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * LEGEND.wispHealFrac * wisps.length * dt);
      }
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
      const everyone = [...sim.enemies.values()].filter((e) => e.state !== 'dead' && (e.state !== 'rising' && e.state !== 'burrow') && e.area === run.area);
      peak = Math.max(peak, everyone.length);
      // On a Depths floor the bot (like a player) only fights what it can see: the walls stop its eyes, and it walks the doorways toward the rest.
      const enemies = run.area === 'depths' ? everyone.filter((e) => !nav.sightBlocked(p.x, p.z, e.x, e.z)) : everyone;
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
            const step = stats.moveSpeed * dt * bog();
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
      let rite: 'empowered' | 'normal' | null = null;
      if (corpsesNear.length + myThralls.length * 1.5 >= 5 && near(7).length >= 3 && (rite = useRite('black_litany', t))) {
        const litanyR = rite === 'empowered' ? 7 * SOUL_HARVEST.areaMult : 7;
        sim.apply({ t: 'litany', by: p.id, x: p.x, z: p.z, r: runes.black_litany === 'rune_requiem' ? litanyR * RUNE_TUNING.requiem.radiusMult : litanyR,
          spellPower: sp * (runes.black_litany === 'rune_hollow_choir' ? RUNE_TUNING.hollowChoir.powerMult : 1), leaveCorpses: disc.mods.sacrificeLeavesCorpse,
          ...(runes.black_litany === 'rune_hollow_choir' ? { spare: true } : {}), ...(runes.black_litany === 'rune_requiem' ? { delayMs: RUNE_TUNING.requiem.delayMs } : {}) });
        if (rite === 'empowered') release(t);
      }
      // Keep the legion topped up.
      else if (corpsesNear.length && myThralls.reduce((n, th) => n + thrallWeight(th.kind), 0) < disc.mods.thrallCap && ready('exhume', t) && p.essence >= ABILITIES.exhume.essenceCost) {
        const c = corpsesNear[0];
        // Relic runes: a Colossus when three corpses lie together and none stands; Mass Grave takes up to three at once.
        const company = runes.exhume === 'rune_bone_colossus' ? corpsesWithin(c, RUNE_TUNING.colossus.pickRadius, sim.corpses.values()).slice(0, RUNE_TUNING.colossus.corpses) : [];
        const colossus = company.length >= RUNE_TUNING.colossus.minCorpses && !myThralls.some((th) => th.kind === 'colossus');
        use('exhume', t);
        if (colossus) cds.set('exhume', t + (ABILITIES.exhume.cooldownMs * RUNE_TUNING.colossus.cooldownMult) / 1000);
        sim.apply({ t: 'exhume', by: p.id, x: c.x, z: c.z, r: colossus ? RUNE_TUNING.colossus.pickRadius : runes.exhume === 'rune_mass_grave' ? RUNE_TUNING.massGrave.pickRadius : 0.8, kind: disc.mods.thrallKind, cap: disc.mods.thrallCap, hp: stats.thrallHp, damage: stats.thrallDamage, attackSpeedMult: disc.mods.thrallAttackSpeedMult,
          ...(loadout.bellAllyHeal > 0 ? { allyHeal: loadout.bellAllyHeal } : {}), ...(runes.exhume === 'rune_mass_grave' ? { count: RUNE_TUNING.massGrave.count } : {}), ...(colossus ? { colossus: true } : {}) });
        // Sickle: Exhume gives back part of its essence. Funeral Rites: a consumed corpse heals (WorldScene 'exhumed').
        if (loadout.exhumeRefund > 0) p.essence = Math.min(stats.maxEssence, p.essence + ABILITIES.exhume.essenceCost * loadout.exhumeRefund);
        if (disc.mods.corpseHeal && !run.noRiteEffects) p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * disc.mods.corpseHeal);
        consumed(t);
      }
      // Corpse Explosion when a body lies under a pack (and the legion is full, or bodies are plentiful).
      else if (
        (myThralls.length >= disc.mods.thrallCap || corpsesNear.length >= 3) &&
        (burst = bestBurst(enemies)) &&
        use('corpse_explosion', t)
      ) {
        sim.apply({ t: 'detonate', by: p.id, corpseId: burst.id, dmg: sp * ABILITIES.corpse_explosion.power });
        consumed(t);
      }
      // Miasma on a clump.
      else if (nearest && near(4, nearest.x, nearest.z).length >= 4 && (rite = useRite('miasma', t))) {
        sim.apply({ t: 'miasma', by: p.id, x: nearest.x, z: nearest.z, r: ABILITIES.miasma.radius * disc.mods.miasmaRadiusMult * (rite === 'empowered' ? SOUL_HARVEST.areaMult : 1) * (runes.miasma === 'rune_creeping_rot' ? RUNE_TUNING.creepingRot.radiusMult : 1), dps: sp * ABILITIES.miasma.power, durationMs: 6000, witheredCap: effectiveWitheredCap(disc.mods), bloom: disc.mods.miasmaBurstsCorpses,
          ...(runes.miasma === 'rune_creeping_rot' ? { creep: RUNE_TUNING.creepingRot.speed } : {}), ...(runes.miasma === 'rune_contagion' ? { contagion: true } : {}) });
        if (rite === 'empowered') release(t);
      }
      // Spear when three line up (approximation: three within 8 m in a 60° cone). Relic runes: a Ring where three stand within it, an Impale on the nearest.
      else if (nearest && nd < 10) {
        const dx = (nearest.x - p.x) / (nd || 1);
        const dz = (nearest.z - p.z) / (nd || 1);
        const inLine = enemies.filter((e) => {
          const rx = e.x - p.x;
          const rz = e.z - p.z;
          const along = rx * dx + rz * dz;
          return along > 0 && along < ABILITIES.marrow_spear.range && Math.abs(rx * dz - rz * dx) < 1.3 + e.radius;
        });
        if (runes.marrow_spear === 'rune_ossuary_ring') {
          // The ring sits on the enemy that has the most company inside it.
          let best: Enemy[] = [];
          for (const e of enemies) {
            if (Math.hypot(e.x - p.x, e.z - p.z) > RUNE_TUNING.ring.maxCastRange) continue;
            const hit = ringHits(e, RUNE_TUNING.ring.radius, enemies);
            if (hit.length > best.length) best = hit;
          }
          if (best.length >= 3 && (rite = useRite('marrow_spear', t))) sim.apply({ t: 'hit', by: p.id, ids: best.map((e) => e.id), dmg: sp * ABILITIES.marrow_spear.power * RUNE_TUNING.ring.damageMult, fracture: 1, ...(disc.mods.spearRally > 0 ? { spear: true } : {}) });
        } else if (runes.marrow_spear === 'rune_impale') {
          const first = impaleTarget(p, dx, dz, ABILITIES.marrow_spear.range, 1.3, enemies);
          // A player impales what matters, not every trash mob: the bot spends the essence only when it has plenty.
          if (first && p.essence >= 50 && (rite = useRite('marrow_spear', t))) sim.apply({ t: 'hit', by: p.id, ids: [first.foe.id], dmg: sp * ABILITIES.marrow_spear.power * RUNE_TUNING.impale.damageMult, fracture: 1, root: true, rootS: RUNE_TUNING.impale.rootS, ...(disc.mods.spearRally > 0 ? { spear: true } : {}) });
        } else if (inLine.length >= 3 && (rite = useRite('marrow_spear', t))) {
          sim.apply({ t: 'hit', by: p.id, ids: inLine.map((e) => e.id), dmg: sp * ABILITIES.marrow_spear.power, fracture: 1, ...(disc.mods.spearRally > 0 ? { spear: true } : {}) });
        }
        if (rite === 'empowered') release(t);
      }
      // Needle the nearest; close distance if out of range, back off if swarmed. The weapon line changes what the left click is:
      // a staff reaches farther and pierces, a scythe reaps a close arc, a wand fires faster and softer, a sickle withers.
      if (nearest) {
        const reach = abilityRange('bone_needle', SP_NEEDLE.range, loadout);
        if (nd > reach - 0.5) {
          const step = stats.moveSpeed * dt * bog();
          [p.x, p.z] = nav.resolve(p.x + ((nearest.x - p.x) / nd) * step, p.z + ((nearest.z - p.z) / nd) * step, 0.45);
        } else if (near(1.6).length >= 3 && p.hp < stats.maxHp * 0.5) {
          const step = stats.moveSpeed * dt * bog();
          // An enemy standing exactly on the bot (nd = 0) used to make this 0/0: a NaN position froze the bot
          // forever (no kills, no damage taken), which hid whole rows of the max band behind "0 deaths".
          const ux = nd > 1e-6 ? (nearest.x - p.x) / nd : 1;
          const uz = nd > 1e-6 ? (nearest.z - p.z) / nd : 0;
          [p.x, p.z] = nav.resolve(p.x - ux * step, p.z - uz * step, 0.45);
        }
        if (nd <= reach + 0.4 && ready('bone_needle', t)) {
          cds.set('bone_needle', t + abilityCooldownMs('bone_needle', SP_NEEDLE.cooldownMs, loadout, true) / 1000);
          const crit = rand() < 0.08 ? 1.8 : 1;
          if (loadout.reap) {
            // Bone Needle runes ride the arc once per swing (AbilitySystem.reap): Marrow-Tap softens the swing and tops up essence once, Splinters throws one shard to a foe the arc missed.
            const reapRune = runes.bone_needle;
            const tap = reapRune === 'rune_marrow_tap';
            const struck = reapTargets(p, nearest, enemies);
            const swing = sp * SP_NEEDLE.power * NECRO_WEAPON_TUNING.scythe.damageMult * (tap ? RUNE_TUNING.marrowTap.damageMult : 1) * crit;
            if (struck.length) sim.apply({ t: 'hit', by: p.id, ids: struck.map((e) => e.id), dmg: swing });
            if (reapRune === 'rune_splinter' && struck.length) {
              const next = splinterTarget(struck[0], enemies.filter((e) => e === struck[0] || !struck.includes(e)));
              if (next) sim.apply({ t: 'hit', by: p.id, ids: [next.id], dmg: swing * RUNE_TUNING.splinter.damageFrac });
            }
            p.essence = Math.min(stats.maxEssence, p.essence + NECRO_WEAPON_TUNING.scythe.essencePerHit * struck.length + (tap && struck.length ? RUNE_TUNING.marrowTap.essenceBonus : 0));
          } else {
            const wither = loadout.needleWithered > 0 ? { withered: loadout.needleWithered, witheredCap: effectiveWitheredCap(disc.mods) } : {};
            // Relic runes (AbilitySystem.needle): Marrow-Tap trades damage for essence, the Volley fires three half-strength needles every 4th cast, Splinters sends half to the next foe.
            const needle = runes.bone_needle;
            const volley = needle === 'rune_volley' && ++needleCasts % RUNE_TUNING.volley.every === 0;
            const runeMult = needle === 'rune_marrow_tap' ? RUNE_TUNING.marrowTap.damageMult : volley ? RUNE_TUNING.volley.damageFrac : 1;
            const dmg = sp * SP_NEEDLE.power * loadout.needleDamageMult * runeMult * crit;
            const essence = 6 + (needle === 'rune_marrow_tap' ? RUNE_TUNING.marrowTap.essenceBonus : 0);
            if (volley) {
              const aim = volleyTargets(p, nearest, enemies);
              for (let k = 0; k < RUNE_TUNING.volley.needles; k++) {
                sim.apply({ t: 'hit', by: p.id, ids: [aim[k % aim.length].id], dmg, ...wither });
                p.essence = Math.min(stats.maxEssence, p.essence + essence / RUNE_TUNING.volley.needles);
              }
            } else {
              sim.apply({ t: 'hit', by: p.id, ids: [nearest.id], dmg, ...wither });
              if (needle === 'rune_splinter') {
                const next = splinterTarget(nearest, enemies);
                if (next) sim.apply({ t: 'hit', by: p.id, ids: [next.id], dmg: dmg * RUNE_TUNING.splinter.damageFrac });
              }
              p.essence = Math.min(stats.maxEssence, p.essence + essence);
            }
            if (loadout.needlePierce > 0) {
              const behind = pierceTargets(p, nearest, enemies, loadout.needlePierce);
              if (behind.length) sim.apply({ t: 'hit', by: p.id, ids: behind.map((e) => e.id), dmg: sp * SP_NEEDLE.power * loadout.needleDamageMult * NECRO_WEAPON_TUNING.staff.pierceDamageMult * crit, ...wither });
            }
          }
        }
      } else {
        // Wander toward the area's middle when idle (on a Depths floor: toward the nearest of the dead, through the doorways).
        let cx = (area.rect.x0 + area.rect.x1) / 2;
        let cz = (area.rect.z0 + area.rect.z1) / 2;
        if (run.area === 'depths' && everyone.length) {
          const near = everyone.reduce((a, b) => (Math.hypot(a.x - p.x, a.z - p.z) <= Math.hypot(b.x - p.x, b.z - p.z) ? a : b));
          const hop = nav.depthsHop(p.x, p.z, near.x, near.z);
          cx = hop ? hop.x : near.x;
          cz = hop ? hop.z : near.z;
        }
        const d = Math.hypot(cx - p.x, cz - p.z);
        if (d > 3) {
          const step = stats.moveSpeed * dt * bog();
          [p.x, p.z] = nav.resolve(p.x + ((cx - p.x) / d) * step, p.z + ((cz - p.z) / d) * step, 0.45);
        }
      }
      }
    }

    // --- Step the world ---
    const events: SimEvent[] = sim.step(dt);
    for (const ev of events) {
      if (ev.t === 'depthsClear') {
        // A floor cleared pays its bonus (and a chest every fifth), then the bot goes down: a held depth re-rolls the same floor.
        const lvl = sim.areaLevel('depths');
        const fb = floorBonus(ev.depth, lvl);
        const cb = hasChest(ev.depth) ? chestBonus(ev.depth, lvl) : { gold: 0, xp: 0 };
        gold += fb.gold + cb.gold;
        xp += fb.xp + cb.xp;
        character.experience += fb.xp + cb.xp;
        floorsCleared++;
        const next = sim.descendDepths();
        if (next) {
          p.x = next.start.x;
          p.z = next.start.z;
          home = { x: next.start.x, z: next.start.z };
        }
      } else if (ev.t === 'surgeCleared') surgesCleared++;
      else if (ev.t === 'surgeFailed') surgesFailed++;
      else if (ev.t === 'spawn') born.set(ev.id, t);
      else if (ev.t === 'death') {
        const b = born.get(ev.id);
        if (b !== undefined) ttks.push(t - b);
        born.delete(ev.id);
        if (!p.alive) continue;
        kills++;
        if (run.soulHarvest && souls < SOUL_HARVEST.souls) {
          soulAcc += M.soulHarvestRateMult;
          const whole = Math.floor(soulAcc);
          soulAcc -= whole;
          souls = Math.min(SOUL_HARVEST.souls, souls + whole);
        }
        const r = rollKill(ev.def, ev.area === 'depths' ? depthLootArea(sim.depths?.depth ?? 1) : ev.area, ev.level, ev.elite, run.waveTier, rand, sim.difficulty);
        gold += r.gold;
        xp += r.xp;
        shards += r.shards;
        character.experience += r.xp;
        while (character.experience >= xpToNext(character.level)) {
          character.experience -= xpToNext(character.level);
          character.level++;
          levels++;
          stats = deriveStats(character, worn, disc, run.damageTier);
          if (body) { body.hp = p.hp; body.essence = p.essence; body.setStats(stats); p.hp = body.hp; p.essence = body.essence; }
        }
      } else if (ev.t === 'newBlood' && ev.by === p.id && ev.ok) {
        if (ev.kind === 'burn_the_dead' || ev.kind === 'cremate' || ev.kind === 'harvest') {
          p.essence = Math.min(resource.max(stats), p.essence + (ev.amount ?? 0));
          lastResourceGain = t;
        }
        if (ev.kind === 'harvest') { crowsUntil = t + 6; nextCrowPeck = t; }
        if (ev.kind === 'heal' && ev.player === p.id && ev.amount) p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * ev.amount);
      } else if (ev.t === 'litanyResult' && ev.by === p.id && p.alive) {
        // Reliquary barrier per body consumed, and the Mourner's corpse heal (AbilitySystem.onLitany).
        if (run.noRiteEffects) { /* pre-gear-pass bot */ } else {
        if (disc.mods.litanyBarrier) {
          barrier += stats.maxHp * disc.mods.litanyBarrier * (ev.corpses + ev.resonant + ev.thralls);
          barrierPeak = Math.max(barrierPeak, barrier);
        }
        if (ev.corpses + ev.resonant > 0) consumed(t);
        if (disc.mods.corpseHeal) p.hp = Math.min(stats.maxHp, p.hp + stats.maxHp * disc.mods.corpseHeal * (ev.corpses + ev.resonant) * 0.5);
        }
      } else if (ev.t === 'heal' && ev.player === p.id && p.alive) {
        p.hp = Math.min(stats.maxHp, p.hp + ev.amount + (ev.frac ? stats.maxHp * ev.frac : 0));
      } else if (ev.t === 'hurt' && ev.player === p.id && p.alive) {
        const myThralls = [...sim.thralls.values()].filter((th) => th.owner === p.id).length;
        const lanternWard = [...sim.zones.values()].some((z) => z.kind === 'warden_ward' && Math.hypot(z.x - p.x, z.z - p.z) <= z.r) ? 0.2 : 0;
        const ward = disc.mods.wardPerThrall * myThralls + lanternWard;
        const guard = colossusActive(disc.mods, myThralls) ? disc.mods.colossusGuard : 0;
        let dmg: number;
        if (body) {
          body.x = p.x; body.z = p.z; body.hp = p.hp; body.essence = p.essence;
          dmg = body.takeDamage(ev.dmg, ward, t * 1000, { x: ev.x, z: ev.z }, ev.from, guard);
          p.hp = body.hp; p.essence = body.essence;
        } else {
          dmg = ev.dmg * damageTakenMult(ward, guard);
          const absorbed = Math.min(barrier, dmg);
          const barrierBefore = barrier;
          barrier -= absorbed;
          // Colossus Mantle: damage broke the Litany barrier, so it shatters around the bot.
          if (barrierBefore > 0 && barrier <= 0 && barrierPeak > 0) {
            if (M.litanyShatter > 0) strike(p.x, p.z, LEGEND.shatterR, shatterDamage(barrierPeak, M.litanyShatter));
            barrierPeak = 0;
          }
          p.hp -= dmg - absorbed;
          dmg -= absorbed;
        }
        // Colossus Mantle: Bone Ward reflects part of what it prevented at whatever struck (the enemy standing at the blow's origin).
        if (M.wardReflect > 0) {
          const back = wardReflectDamage(ev.dmg, Math.min(LEGEND.wardCap, M.wardPerThrall * myThralls), M.wardReflect);
          if (back > 0) {
            let tgt: Enemy | null = null;
            let td = 0.6;
            for (const e of sim.enemies.values()) if (e.state !== 'dead') { const d = Math.hypot(e.x - ev.x, e.z - ev.z); if (d <= td + e.radius * 0.5) { td = d; tgt = e; } }
            if (tgt) sim.apply({ t: 'hit', by: p.id, ids: [(tgt as Enemy).id], dmg: back });
          }
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
      if (disc.family === 'necromancer') for (const th of sim.thralls.values()) if (th.owner === p.id) thrallAccum++;
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
    avgThralls: hpSamples ? thrallAccum / hpSamples : 0,
    thrallCap: disc.family === 'necromancer' ? disc.mods.thrallCap : 0,
    floorsPerMin: floorsCleared / mins,
  };
}

/** Litany value helper kept here so the report can explain Litany scaling. */
export const litanyMultiplier = (corpses: number) => 1.5 + LITANY_PER_CORPSE * corpses;
