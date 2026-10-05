/**
 * Death Muffin -> Godot combat data export. Imports the REAL game modules (never retyped) and writes JSON into godot/data/combat/.
 * Run: npx vite-node tools/godot/export-combat.ts
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DISCIPLINES, disciplineFor } from '../../src/content/disciplines';
import { ARMOR_PIECES, ARMOR_PARTS } from '../../src/content/armorSets';
import { SET_BONUSES, SET_NAMES } from '../../src/content/setBonuses';
import { NECRO_WEAPON_TUNING, NECRO_WEAPONS, NECRO_TIERS, NECRO_DISCIPLINES, NECRO_TIER_INFO } from '../../src/content/necroWeapons';
import { AFFIXES, affixRange, affixAcceptRange, ILVL_MAX, MAX_AFFIXES } from '../../src/gameplay/affixRules';
import * as ABIL from '../../src/content/abilities';
import { CAST_FLOW } from '../../src/content/combatFlow';
import { RUNE_TUNING, RUNES, RUNE_RITES, RUNE_IDS } from '../../src/content/runes';
import { BREWS, BREW_EXTEND_CAP, LIFESTEAL_TARGET_CAP, LIFESTEAL_HIT_CAP, FIRE_SOURCES, ROT_SOURCES } from '../../src/content/brews';
import { ALCHEMY_HEALING } from '../../src/content/alchemy';
import { MEALS } from '../../src/content/processing';
import { HEALING_FLASKS } from '../../src/content/items';
import { HEAL_COOLDOWN_S } from '../../src/gameplay/beltRules';
import * as STAT from '../../src/content/statuses';
import { LEGEND } from '../../src/gameplay/legendary';
import * as ENM from '../../src/content/enemies';
import { HAG_HEX } from '../../src/content/fen';
import { DIFFICULTIES } from '../../src/content/difficulty';
import { ASCENSION, VOWS, VOW_ORDER, BOONS, BOON_ORDER } from '../../src/content/ascension';
import { DAMAGE_UPGRADE, WAVE_UPGRADE, LEGION_UPGRADE, THRALL_REFRESH_MAX, WAVE_MILESTONES, NIGHTFALL_SHROUD_CHANCE, RESTLESS_SURGE_MULT } from '../../src/content/upgrades';
import { KIT_RATES, KIT_BASE, KIT_IDS } from '../../src/gameplay/legionRules';
import { AREAS } from '../../src/content/areas';
import { DEPTHS } from '../../src/content/depths';
import { kitFor } from '../../src/content/kits';
import { NEW_BLOOD_DAMAGE_MULT, NEW_BLOOD_XP_CATCHUP } from '../../src/gameplay/newBloodTuning';
import { CHAIN } from '../../src/gameplay/killChain';
import { STAT_EFFECTS } from '../../src/gameplay/characterStats';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = resolve(ROOT, 'godot/data/combat');
mkdirSync(OUT, { recursive: true });
const write = (name: string, data: unknown) => writeFileSync(resolve(OUT, name), JSON.stringify(data, null, 1) + '\n');

// ---- Disciplines (mods only matter to the rules; text stays in the TS UI) ----
const indexMap: Record<string, string> = {};
for (let i = 0; i <= 12; i++) indexMap[String(i)] = disciplineFor(i).id;
write('disciplines.json', {
  disciplines: Object.fromEntries(Object.values(DISCIPLINES).map((d) => [d.id, { id: d.id, classIndex: d.classIndex, family: d.family, name: d.name, mods: d.mods }])),
  by_index: indexMap, // unknown indices fall back to gravecaller (see disciplineFor)
  fallback: 'gravecaller',
});

// ---- Armor sets + bonuses ----
write('armor.json', {
  parts: ARMOR_PARTS,
  pieces: ARMOR_PIECES.map((p) => ({ id: p.id, setId: p.setId, disciplineId: p.disciplineId, collection: p.collection, part: p.part, stats: p.stats, area: p.area, name: p.name, setName: p.setName })),
  set_bonuses: SET_BONUSES,
  set_names: SET_NAMES,
});

// ---- Necro weapon line ----
write('necro_weapons.json', {
  tuning: NECRO_WEAPON_TUNING,
  tiers: NECRO_TIERS,
  tier_info: NECRO_TIER_INFO,
  disciplines: NECRO_DISCIPLINES,
  weapons: NECRO_WEAPONS.map((w) => ({ id: w.id, kind: w.kind, tier: w.tier, twoHanded: w.twoHanded })),
});

// ---- Affixes: effect descriptors inferred from the real effect() fns, plus the real range tables ----
const affixes = AFFIXES.map((a) => {
  const e1 = a.effect(1000);
  let desc: Record<string, unknown>;
  if (e1.stats) { const k = Object.keys(e1.stats)[0]; desc = { type: 'stat', key: k }; }
  else if (e1.mult) { const k = Object.keys(e1.mult)[0]; desc = { type: 'mult', key: k, per: 1000 }; }
  else { const k = Object.keys(e1.add!)[0]; const val = (e1.add as Record<string, number>)[k]; desc = { type: 'add', key: k, per: val === 1000 ? 1 : 1000 }; }
  const ranges: number[][] = [];
  const accept: number[][] = [];
  for (let L = 1; L <= ILVL_MAX; L++) { ranges.push(affixRange(a.id, L)!); accept.push(affixAcceptRange(a.id, L)!); }
  return { id: a.id, kind: a.kind, word: a.word, group: a.group, necro: a.necro, weight: a.weight, unit: a.unit, effect: desc, ranges, accept };
});
write('affixes.json', { ilvl_max: ILVL_MAX, max_affixes: MAX_AFFIXES, affixes });

// ---- Abilities and every tuning constant next to them ----
const constants: Record<string, unknown> = {};
for (const [k, v] of Object.entries(ABIL)) {
  if (typeof v === 'function' || k === 'ABILITIES' || k === 'NEW_BLOOD_ABILITIES' || k === 'SPELL_FX') continue;
  constants[k] = v;
}
write('abilities.json', {
  abilities: ABIL.ABILITIES,
  constants,
  cast_flow: CAST_FLOW,
  kits: Object.fromEntries(['necromancer', 'knight', 'warden', 'monk', 'witch', 'veil'].map((f) => [f, kitFor(f as never)])),
  rune_tuning: RUNE_TUNING,
  rune_rites: RUNE_RITES,
  rune_ids: RUNE_IDS,
  runes: Object.fromEntries(Object.values(RUNES).map((r) => [r.id, { id: r.id, name: r.name, rite: r.rite, rarity: r.rarity, sell: r.sell }])),
  spell_fx: ABIL.SPELL_FX,
});

// ---- Brews, flasks, meals ----
write('brews.json', {
  brews: BREWS, extend_cap: BREW_EXTEND_CAP, lifesteal_target_cap: LIFESTEAL_TARGET_CAP, lifesteal_hit_cap: LIFESTEAL_HIT_CAP,
  fire_sources: FIRE_SOURCES, rot_sources: ROT_SOURCES, healing_flasks: HEALING_FLASKS, alchemy_healing: ALCHEMY_HEALING, meals: MEALS, heal_cooldown_s: HEAL_COOLDOWN_S,
});

// ---- Statuses + legendary + knight etc. ----
const statuses: Record<string, unknown> = {};
for (const [k, v] of Object.entries(STAT)) if (typeof v !== 'function') statuses[k] = v;
write('statuses.json', { ...statuses, LEGEND, HAG_HEX });

// ---- Enemies, difficulty, scaling ----
const enemyConsts: Record<string, unknown> = {};
for (const k of ['CENSER', 'SCREAM', 'DUST', 'BURROW', 'UNBIND', 'TEMPLAR_SHIELD', 'PLAGUE_FLASK', 'EMBER_BOLT', 'EMBER_DEATH', 'SLAG_POOL', 'FRENZY', 'WARD', 'PROCESSION', 'ELITE', 'AFFIX_ORDER', 'AFFIX_TUNING', 'SURGE'] as const) enemyConsts[k] = (ENM as never)[k];
write('enemies.json', {
  enemies: Object.fromEntries(Object.values(ENM.ENEMIES).map((e) => [e.id, { id: e.id, name: e.name, behavior: e.behavior, hp: e.hp, speed: e.speed, radius: e.radius, damage: e.damage, attackRange: e.attackRange, windupMs: e.windupMs, cooldownMs: e.cooldownMs, xp: e.xp, gold: e.gold, corpse: e.corpse, scale: e.scale, pack: e.pack ?? null, deathCorpses: e.deathCorpses ?? 1, shield: !!e.shield, burrow: !!e.burrow, frenzy: !!e.frenzy }])),
  constants: enemyConsts,
  hp_scale: { base: 1, per_level: 0.22 }, damage_scale: { base: 1, per_level: 0.15 },
  difficulties: DIFFICULTIES,
  areas: Object.fromEntries(Object.values(AREAS).map((a) => [a.id, { id: a.id, safe: a.safe, level: a.level, scaling: a.scaling ?? null, cap: a.cap, waveSize: a.waveSize, waveIntervalMs: a.waveIntervalMs, eliteChance: a.eliteChance, instance: !!a.instance }])),
  depths: DEPTHS,
});

// ---- Upgrades, vows, boons, legion, resource tables ----
// Only what content/ does not already carry (upgrade tiers, vows, boons, ascension, chain, stat effects live in godot/data/content/*;
// DmDb.combat('progression') composes them back in). Writing them here again would resurrect a duplicate.
write('progression.json', {
  kit: { base: KIT_BASE, ids: KIT_IDS, rates: KIT_RATES },
  new_blood: { damage_mult: NEW_BLOOD_DAMAGE_MULT, xp_catchup: NEW_BLOOD_XP_CATCHUP },
});
console.log('combat data written to', OUT);
