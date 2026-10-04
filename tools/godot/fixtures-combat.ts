/**
 * Golden fixtures for godot/rules/combat (run: npx vite-node tools/godot/fixtures-combat.ts).
 * Every expected value is produced by calling the REAL TS modules (characterStats, setBonuses, legionKit, Player, WorldSim ...).
 * Where the TS logic is private inside a class (WorldScene.applyBoons, AbilitySystem.cast bookkeeping) the few lines are transcribed
 * here from the source, calling the real exported helpers they use (marked "transcribed").
 * Format per file: { fn, cases: [{ in, out }] } ; the GDScript runner (tests/rules-combat/run.gd) maps fn -> a Callable.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { DISCIPLINES, disciplineFor } from '../../src/content/disciplines';
import { ARMOR_PIECES } from '../../src/content/armorSets';
import { NECRO_WEAPONS, NECRO_WEAPON_TUNING } from '../../src/content/necroWeapons';
import { AFFIXES, affixAcceptRange, affixRange, affixEffect, addInstanceTotals, emptyAffixTotals } from '../../src/gameplay/affixRules';
import { deriveStats, xpToNext } from '../../src/gameplay/characterStats';
import { computeStats } from '../../src/gameplay/stats';
import { equippedBySlot, equipSlotOf } from '../../src/content/gear';
import { resolveWeaponLoadout, abilityRange, abilityCooldownMs, abilityLockMs, reapTargets, pierceTargets } from '../../src/gameplay/weaponLine';
import { applySetMods, resolveSetBonuses, withSetBonuses, withoutSetBonuses, foldEffect, setSignature, outfitSignature, diffSetBonuses, effectRelevant } from '../../src/gameplay/setBonuses';
import { wornAffixTotals, affixSignature } from '../../src/gameplay/affixes';
import { legionBonus, pieceBonus, reinforceBonus, NO_LEGION } from '../../src/gameplay/legionRules';
import { legionOf, applyLegionMods, legionSignature, thrallRefresh, pieceValue, pieceOf } from '../../src/gameplay/legionKit';
import { vowEffects, boonEffects, vowHeat, worldVows, ascensionRewardMult, ascensionLevels, legacyVows, ashesForRun, boonBlocked, boonCost, VOW_ORDER, BOON_ORDER, VOWS, BOONS, sanitizeVows } from '../../src/content/ascension';
import { waveModifiers, DAMAGE_UPGRADE, WAVE_UPGRADE, LEGION_UPGRADE, damageBonusPct, milestones } from '../../src/content/upgrades';
import { damageCost, waveCost, legionCost, blankState } from '../../src/gameplay/necroRules';
import { BREWS, brewValue, brewWard, applyBrew, lifestealHeal, emptyBrews, type ActiveBrews } from '../../src/content/brews';
import { HEALING_FLASKS } from '../../src/content/items';
import { RESOURCE_RULES } from '../../src/gameplay/resources';
import { Player } from '../../src/gameplay/Player';
import { Nav } from '../../src/gameplay/nav';
import { WorldSim } from '../../src/gameplay/sim/WorldSim';
import { ABILITIES, unlockLevel, PRIMARIES, SOUL_HARVEST, NEEDLE_ESSENCE, LITANY_PER_CORPSE, LITANY_PER_RESONANT, LITANY_PER_THRALL, LITANY_MAX_MULT, DETONATE, BONE_MANTLE, GRAVE_HANDS, BONE_STORM, WAILING_SKULL, GRIMOIRE } from '../../src/content/abilities';
import { CAST_FLOW } from '../../src/content/combatFlow';
import { RUNE_TUNING, RUNE_RITES } from '../../src/content/runes';
import { splinterTarget, volleyTargets, ringHits, ringCenter, impaleTarget, corpsesWithin } from '../../src/gameplay/runeCast';
import { socketsOf, ownedRunes, runeFits, runeSlotRite } from '../../src/gameplay/runeRules';
import { clampSimLegend, damageTakenMult, wardReflectDamage, shatterDamage, effectiveWitheredCap, colossusActive, simLegendOf } from '../../src/gameplay/legendary';
import { ENEMIES, enemyHpScale, enemyDamageScale, type EnemyId } from '../../src/content/enemies';
import { AREAS, type AreaId } from '../../src/content/areas';
import { DIFFICULTIES } from '../../src/content/difficulty';
import { killXpBase, killGoldMax } from '../../src/gameplay/killRules';
import { newBloodXpMult, newBloodDamageMult } from '../../src/gameplay/newBloodTuning';
import { depthEnemyLevel } from '../../src/content/depths';
import { damageTakenScale } from '../../src/gameplay/hitNumber';
import { brewWard as _bw } from '../../src/content/brews';
import type { InventorySlot } from '../../src/net/types';

const OUT = 'godot/tests/rules-combat/fixtures';
mkdirSync(OUT, { recursive: true });
const counts: Record<string, number> = {};
const w = (fn: string, cases: { in: unknown; out: unknown }[]) => {
  writeFileSync(`${OUT}/${fn}.json`, JSON.stringify({ fn, cases }) + '\n');
  counts[fn] = cases.length;
};

const rand = mulberry32(20261004);
const R = (n: number) => Math.floor(rand() * n);
const pick = <T>(a: readonly T[]): T => a[R(a.length)];
const chance = (p: number) => rand() < p;
const range = (lo: number, hi: number) => lo + R(hi - lo + 1);
const J = <T>(x: T): T => JSON.parse(JSON.stringify(x)); // strip undefined / functions, like the Godot side sees it

// ---------------------------------------------------------------------------------------------------------------------
// Random characters and gear
// ---------------------------------------------------------------------------------------------------------------------
const character = () => ({ id: 1, class_index: range(0, 10), class_name: 'x', level: chance(0.05) ? 0 : range(1, 120), experience: 0, gold: 0, stat_str: range(0, 60), stat_agi: range(0, 60), stat_int: range(0, 90), stat_vit: range(0, 80) });

const NECRO_MAIN = NECRO_WEAPONS.filter((x) => x.slot === 'main_hand');
const NECRO_OFF = NECRO_WEAPONS.filter((x) => x.slot === 'off_hand');
const STATS = ['stat_str', 'stat_agi', 'stat_int', 'stat_vit'];
const randStats = () => Object.fromEntries(STATS.filter(() => chance(0.5)).map((k) => [k, range(1, 14)]));

function inst(): { id: number; ilvl: number; affixes: { id: string; v: number }[] } | undefined {
  if (chance(0.4)) return undefined;
  const ilvl = range(1, 99);
  const groups = new Set<string>();
  const affixes: { id: string; v: number }[] = [];
  for (let i = 0, n = range(1, 3); i < n; i++) {
    const a = pick(AFFIXES);
    if (groups.has(a.group)) continue;
    groups.add(a.group);
    const [lo, hi] = affixAcceptRange(a.id, ilvl)!;
    affixes.push({ id: a.id, v: range(lo, hi) });
  }
  return { id: R(1e6), ilvl, affixes };
}

let slotId = 1;
function row(item_id: string, item_type: string, equipped: 0 | 1, slot_index: number, stat_bonus: Record<string, number> | null, eq?: string): InventorySlot {
  const r: Record<string, unknown> = { id: slotId++, slot_index, quantity: 1, equipped, item_id, name: item_id, rarity: 'common', item_type, stat_bonus, icon_id: null, sell_value: 1, crafted: 0 };
  if (eq !== undefined) r.equipped_slot = eq;
  if (chance(0.25)) r.item_equipment_slot = null;
  const i = inst();
  if (i) r.inst = i;
  return r as unknown as InventorySlot;
}
const PARTS = ['head', 'chest', 'hands', 'legs', 'feet'];
function randomOutfit(): InventorySlot[] {
  const slots: InventorySlot[] = [];
  // Often commit to one set so 2/4/5 piece bonuses actually trigger.
  const setPieces = chance(0.7) ? ARMOR_PIECES.filter((p) => p.setId === pick(ARMOR_PIECES).setId) : [];
  for (const part of PARTS) {
    if (!chance(0.8)) continue;
    const p = (setPieces.length && chance(0.85) ? setPieces.find((x) => x.part === part) : undefined) ?? pick(ARMOR_PIECES.filter((x) => x.part === part));
    slots.push(row(p.id, p.type, 1, 100 + slots.length, p.stats, chance(0.7) ? part : undefined));
  }
  if (chance(0.7)) { const m = chance(0.8) ? pick(NECRO_MAIN) : null; slots.push(row(m?.id ?? 'sword_iron', 'weapon', 1, 105, m?.stats ?? randStats(), chance(0.6) ? 'main_hand' : undefined)); }
  if (chance(0.6)) { const o = chance(0.8) ? pick(NECRO_OFF) : null; slots.push(row(o?.id ?? 'shield_wood', 'offhand', 1, 106, o?.stats ?? randStats(), chance(0.6) ? 'off_hand' : undefined)); }
  if (chance(0.5)) slots.push(row('ring_bone', 'ring', 1, 107, randStats(), 'ring'));
  if (chance(0.4)) slots.push(row('trinket_x', 'trinket', 1, 108, randStats(), chance(0.5) ? 'trinket' : undefined));
  if (chance(0.1)) { const p = pick(ARMOR_PIECES); slots.push(row(p.id, p.type, 1, 109, p.stats, p.part)); } // two items in one slot: the later one wins
  // bag clutter (not equipped) and an equipped item with no slot (a material)
  for (let i = 0, n = range(0, 4); i < n; i++) slots.push(row(pick(ARMOR_PIECES).id, 'armor_chest', 0, i, randStats()));
  if (chance(0.1)) slots.push(row('material_copper_bar', 'material', 1, 3, null));
  // Legion kit rows: stats must never reach the wearer
  if (chance(0.5)) { const x = chance(0.5) ? pick(NECRO_MAIN) : null; slots.push(row(x?.id ?? 'sword_iron', 'weapon', 1, 120, x?.stats ?? randStats(), 'kit_weapon')); }
  if (chance(0.5)) { const p = pick(ARMOR_PIECES); slots.push(row(p.id, p.type, 1, 121, p.stats, 'kit_armor')); }
  return slots;
}
const local = () => ({
  damageTier: range(0, 25),
  legionTier: range(0, 13),
  boons: Object.fromEntries(BOON_ORDER.filter(() => chance(0.4)).map((b) => [b, range(0, BOONS[b].maxRank + 1)])),
  vows: Object.fromEntries(VOW_ORDER.filter(() => chance(0.3)).map((v) => [v, range(0, VOWS[v].maxRank + 1)])),
});

// ---------------------------------------------------------------------------------------------------------------------
// 1. The whole pipeline (transcribed WorldScene.applyBoons + refreshStats, over real functions)
// ---------------------------------------------------------------------------------------------------------------------
function build(c: ReturnType<typeof character>, slots: InventorySlot[], l: ReturnType<typeof local>) {
  const base = disciplineFor(c.class_index);
  const fx = boonEffects(l.boons);
  const vow = vowEffects(l.vows);
  const loadout = resolveWeaponLoadout(equippedBySlot(slots), base.id);
  const legion = legionOf(slots, l.legionTier);
  let discipline = {
    ...base,
    mods: {
      ...base.mods,
      thrallCap: base.mods.thrallCap + fx.extraThralls + loadout.thrallBonus,
      maxHpMult: base.mods.maxHpMult * fx.maxHpMult * vow.maxHpMult,
      essenceRegenMult: base.mods.essenceRegenMult * fx.essenceRegenMult * vow.essenceRegenMult,
      thrallHpMult: base.mods.thrallHpMult * vow.thrallHpMult,
      corpseHeal: base.mods.corpseHeal + fx.corpseHeal,
      wardPerThrall: base.mods.wardPerThrall + fx.wardPerThrall,
      sacrificeLeavesCorpse: base.mods.sacrificeLeavesCorpse || fx.sacrificeLeavesCorpse,
      miasmaBurstsCorpses: base.mods.miasmaBurstsCorpses || fx.miasmaBurstsCorpses,
    },
  };
  if (base.family === 'necromancer') discipline = { ...discipline, mods: applyLegionMods(discipline.mods, legion) };
  discipline = { ...discipline, mods: applySetMods(discipline.mods, resolveSetBonuses(slots).totals) };
  const stats = deriveStats(c as never, slots, discipline, l.damageTier);
  return { mods: discipline.mods, stats, loadout, legion, boons: fx, vows: vow };
}
{
  const cases = [];
  for (let i = 0; i < 1500; i++) {
    const c = character(); const slots = randomOutfit(); const l = local();
    cases.push({ in: J({ character: c, slots, local: l }), out: J(build(c, slots, l)) });
  }
  w('build', cases);
}

// derive_stats / compute_stats directly on a plain discipline, with and without set bonuses re-based (the gearStats pattern)
{
  const cases = [];
  for (let i = 0; i < 600; i++) {
    const c = character(); const a = randomOutfit(); const b = chance(0.5) ? randomOutfit() : a;
    const d0 = disciplineFor(c.class_index);
    const pre = chance(0.5);
    const d = pre ? { ...d0, mods: applySetMods(d0.mods, resolveSetBonuses(a).totals) } : d0;
    const d1 = withSetBonuses(d, b);
    const tier = range(0, 25);
    cases.push({ in: J({ character: c, slotsA: a, slotsB: b, pre, tier }), out: J({ mods: d1.mods, stats: deriveStats(c as never, b, d1, tier), computed: computeStats(c as never, b), bare: withoutSetBonuses(d1).mods, resolvedEq: d1 === d }) });
  }
  w('with_set_bonuses', cases);
}

// set resolution, signatures, diffs, fold effects
{
  const cases = [];
  for (let i = 0; i < 500; i++) {
    const a = randomOutfit(); const b = randomOutfit();
    const r = resolveSetBonuses(a);
    const fam = pick(['necromancer', 'knight', 'warden', 'monk', 'witch', 'veil']);
    const aff = pick(AFFIXES); const roll = { id: aff.id, v: range(...(affixAcceptRange(aff.id, 40) as [number, number])) };
    cases.push({ in: J({ a, b, fam, roll, classIndex: range(1, 9) }), out: J({
      totals: r.totals, setTotals: r.setTotals, affixTotals: r.affixTotals,
      active: r.active.map((x) => ({ setId: x.setId, pieces: x.pieces })), sets: r.sets.map((s) => ({ setId: s.setId, worn: s.worn, wornParts: s.wornParts, next: s.next })),
      setSig: setSignature(a), outfitSig: outfitSignature(a), affixSig: affixSignature(a), diff: diffSetBonuses(a, b, { family: fam } as never),
      relevant: effectRelevant(affixEffect(roll), { family: fam } as never), wornAffix: wornAffixTotals(a),
      fold: foldEffect(disciplineFor(1).mods, affixEffect(roll)),
    }) });
  }
  w('set_bonuses', cases);
}

// weapon line
{
  const cases = [];
  const ids = [...NECRO_MAIN.map((x) => x.id), ...NECRO_OFF.map((x) => x.id), 'sword_iron', 'shield_wood'];
  for (let i = 0; i < 800; i++) {
    const worn: Record<string, { item_id: string }> = {};
    if (chance(0.8)) worn.main_hand = { item_id: pick(ids) };
    if (chance(0.7)) worn.off_hand = { item_id: pick(ids) };
    const disc = pick(Object.keys(DISCIPLINES));
    const l = resolveWeaponLoadout(worn, disc);
    const id = pick(['bone_needle', 'marrow_spear', 'exhume', 'black_litany']);
    const baseRange = ABILITIES[id as never].range;
    cases.push({ in: { worn, disc, id, boss: chance(0.5), primary: chance(0.5) }, out: J({ l, range: abilityRange(id, baseRange, l, false), rangeBoss: abilityRange(id, baseRange, l, true), cd: abilityCooldownMs(id, ABILITIES[id as never].cooldownMs, l, false), cdP: abilityCooldownMs(id, ABILITIES[id as never].cooldownMs, l, true), lock: abilityLockMs(id, CAST_FLOW[id as never].lockMs, l) }) });
  }
  w('weapon_line', cases);
  const g = [];
  for (let i = 0; i < 300; i++) {
    const caster = { x: rand() * 10 - 5, z: rand() * 10 - 5 };
    const aim = { x: rand() * 10 - 5, z: rand() * 10 - 5 };
    const foes = Array.from({ length: range(0, 9) }, (_, k) => ({ id: k + 1, x: Math.round((rand() * 12 - 6) * 2) / 2, z: Math.round((rand() * 12 - 6) * 2) / 2, radius: pick([0.4, 0.6, 1])}));
    const tgt = foes.length ? pick(foes) : { id: 99, x: 3, z: 3, radius: 0.5 };
    g.push({ in: { caster, aim, foes, tgt, count: range(0, 3), reach: chance(0.5) ? 4 : null }, out: J({ reap: reapTargets(caster, aim, foes, chance(0) ? 1 : undefined).map((e) => e.id), pierce: pierceTargets(caster, tgt, foes, range(0, 3) && 1).map((e) => e.id) }) });
  }
  // recompute with the exact parameters stored in `in` (avoid the throwaway random calls above)
  for (const c of g) {
    const i = c.in as { caster: never; aim: never; foes: never[]; tgt: never; count: number; reach: number | null };
    c.out = J({ reap: reapTargets(i.caster, i.aim, i.foes, i.reach ?? undefined).map((e: { id: number }) => e.id), pierce: pierceTargets(i.caster, i.tgt, i.foes, i.count).map((e: { id: number }) => e.id) });
  }
  w('weapon_geometry', g);
}

// legion kit
{
  const cases = [];
  for (let i = 0; i < 500; i++) {
    const wp = chance(0.8) ? { itemType: pick(['weapon', 'offhand', 'armor_head', 'ring']), statBonus: chance(0.8) ? randStats() : null, affixes: inst()?.affixes ?? null } : null;
    const ar = chance(0.8) ? { itemType: pick(['armor_chest', 'armor_feet', 'weapon', 'trinket']), statBonus: chance(0.8) ? randStats() : null, affixes: inst()?.affixes ?? null } : null;
    const tier = range(-2, 15);
    const before = { hp: range(0, 400), damage: range(0, 300), speedMult: 1 + rand() * 0.3 };
    const after = { hp: before.hp * (1 + rand() * 0.4), damage: chance(0.2) ? 0 : before.damage * (1 + rand() * 0.4), speedMult: before.speedMult * (chance(0.5) ? 1 : 1 + rand() * 0.1) };
    const mods = J(disciplineFor(range(1, 4)).mods);
    const lb = legionBonus({ weapon: wp, armor: ar }, tier);
    cases.push({ in: J({ wp, ar, tier, before, after, mods }), out: J({ lb, pw: pieceBonus('weapon', wp), pa: pieceBonus('armor', ar), rb: reinforceBonus(tier), refresh: thrallRefresh(before, after), applied: applyLegionMods(mods, lb), value: pieceValue(pieceBonus('weapon', wp)), noLegion: NO_LEGION }) });
  }
  w('legion', cases);
  const s = [];
  for (let i = 0; i < 200; i++) { const slots = randomOutfit(); const t = range(0, 12); s.push({ in: J({ slots, t }), out: J({ lo: legionOf(slots, t), sig: legionSignature(slots, t) }) }); }
  w('legion_slots', s);
}

// vows / boons / costs / waves
{
  const cases = [];
  for (let i = 0; i < 400; i++) {
    const l = local();
    const rank = range(-1, 60); const heat = range(-1, 60);
    const run = { prelateKills: range(0, 6), peakWaveTier: range(0, 12), kills: range(0, 6000) };
    const id = pick(BOON_ORDER); const best = range(0, 4);
    const unl = chance(0.5) ? VOW_ORDER.concat(BOON_ORDER).filter(() => chance(0.5)).map((k) => (VOWS[k as never] ? `vow:${k}` : `boon:${k}`)) : undefined;
    const tier = range(0, 30);
    cases.push({ in: J({ best, vows: l.vows, boons: l.boons, rank, heat, run, id, unl, tier, dmgTier: range(0, 26), waveTier: range(0, 9), legTier: range(0, 13) }), out: J({
      vowFx: vowEffects(l.vows), boonFx: boonEffects(l.boons), heat: vowHeat(l.vows), world: worldVows(l.vows), reward: ascensionRewardMult(heat), levels: ascensionLevels(rank), legacy: legacyVows(rank),
      ashes: ashesForRun(run, heat), blocked: boonBlocked(id, l.boons, best, unl), cost: boonCost(id, l.boons), wave: waveModifiers(tier), pct: damageBonusPct(tier), miles: milestones(tier, 8), san: sanitizeVows(l.vows),
    }) });
  }
  // costs use necroRules with a blank state
  for (const c of cases) {
    const i = c.in as { boons: never; dmgTier: number; waveTier: number; legTier: number };
    const s = { ...blankState(), boons: i.boons, damageTier: i.dmgTier, waveTierOwned: i.waveTier, legionTier: i.legTier };
    (c.out as Record<string, unknown>).costs = J({ damage: damageCost(s), wave: waveCost(s), legion: legionCost(s) });
  }
  w('vows_boons', cases);
}

// brews, lifesteal, flasks
{
  const ids = Object.keys(BREWS);
  const cases = [];
  for (let i = 0; i < 400; i++) {
    const brews: ActiveBrews = emptyBrews();
    let now = 0; const log = [];
    const drinks = [];
    for (let k = 0, n = range(1, 8); k < n; k++) {
      now += range(0, 80000);
      const id = pick(ids);
      drinks.push({ id, now });
      const r = applyBrew(brews, id, now);
      log.push(J({ r, brews: J(brews) }));
    }
    const at = now + range(0, 100000);
    const from = pick(['ember', 'burn', 'toxic', 'dust', 'cone', 'boss']);
    const kinds = ['damage', 'ward', 'lifesteal', 'haste', 'resist_fire', 'resist_rot', 'speed', 'essence', 'wisdom', 'fortune'] as const;
    cases.push({ in: J({ drinks, at, from, dmg: range(-5, 5000), targets: range(-1, 9), frac: rand() * 0.3, maxHp: range(50, 9000) }), out: J({ log, values: Object.fromEntries(kinds.map((k) => [k, brewValue(brews, k, at)])), ward: brewWard(brews, from, at), brews: J(brews) }) });
  }
  for (const c of cases) { const i = c.in as { dmg: number; targets: number; frac: number; maxHp: number }; (c.out as Record<string, unknown>).lifesteal = lifestealHeal(i.dmg, i.targets, i.frac, i.maxHp); }
  w('brews', cases);
  w('flasks', Object.entries(HEALING_FLASKS).map(([k, v]) => ({ in: { id: k }, out: v })));
}

// resources
{
  const cases = [];
  for (const fam of Object.keys(RESOURCE_RULES)) for (let i = 0; i < 40; i++) {
    const r = RESOURCE_RULES[fam as never] as never as { max(s: unknown): number; initial(m: number): number; onRevive(m: number): number; passive(c: unknown): number; kind: string; label: string; color: string };
    const stats = { level: 1, maxHp: 100, spellPower: 10, maxEssence: range(50, 400), essenceRegen: rand() * 20, moveSpeed: 5, thrallHp: 1, thrallDamage: 1, damageBonusPct: 0 };
    const ctx = { stats, value: rand() * 100, max: 100, sinceHurtMs: range(0, 9000), sinceResourceGainMs: range(0, 9000) };
    cases.push({ in: { fam, stats, ctx }, out: { kind: r.kind, label: r.label, color: r.color, max: r.max(stats), initial: r.initial(stats.maxEssence), revive: r.onRevive(stats.maxEssence), passive: r.passive(ctx) } });
  }
  w('resources', cases);
}

// ---------------------------------------------------------------------------------------------------------------------
// Player (the REAL class) driven through random action sequences
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases = [];
  const fams = ['necromancer', 'knight', 'warden', 'monk', 'witch', 'veil'] as const;
  for (let i = 0; i < 500; i++) {
    const fam = pick(fams);
    const stats = { level: range(1, 60), maxHp: range(60, 3000), spellPower: 10 + rand() * 200, maxEssence: range(80, 600), essenceRegen: 3 + rand() * 20, moveSpeed: 5.4 + rand(), thrallHp: 50, thrallDamage: 10, damageBonusPct: 0 };
    const p = new Player(stats, new Nav(), fam);
    const acts: Record<string, unknown>[] = []; const snaps: unknown[] = [];
    let now = 1000;
    const snap = () => J({ hp: p.hp, alive: p.alive, res: p.resource, barrier: p.barrier, peak: p.barrierPeak, broke: p.barrierBroke, lastBlock: p.lastBlock, souls: p.souls, veil: p.veilForm, lastHurtAt: p.lastHurtAt, chilledUntil: p.chilledUntil });
    for (let k = 0, n = range(3, 25); k < n; k++) {
      now += range(1, 3000);
      const kind = pick(['hit', 'hit', 'hit', 'tick', 'heal', 'barrier', 'bulwark', 'oath', 'souls', 'veil', 'brew', 'revive', 'stats', 'res', 'speed']);
      const a: Record<string, unknown> = { kind, now };
      switch (kind) {
        case 'hit': Object.assign(a, { raw: rand() * stats.maxHp * 0.4, ward: rand() * 1.2, from: pick([{ x: 5, z: 0 }, { x: -3, z: 2 }, { x: 0, z: 0 }]), source: pick(['cone', 'toxic', 'burn', 'boss', '']), guard: chance(0.3) ? rand() : 0 }); p.takeDamage(a.raw as number, a.ward as number, now, a.from as never, a.source as string, a.guard as number); break;
        case 'tick': a.dt = rand() * 0.3; p.update(a.dt as number, now, null); break;
        case 'heal': a.amount = rand() * 300; p.heal(a.amount as number); break;
        case 'barrier': a.amount = rand() * 200; p.barrier += a.amount as number; p.barrierPeak = Math.max(p.barrierPeak, p.barrier); if (chance(0.5)) { a.hold = now + 3000; p.barrierHoldUntil = now + 3000; } break;
        case 'bulwark': p.bulwarkUntil = now + 2000; p.bulwarkPerfectUntil = chance(0.5) ? now + 250 : 0; a.perfect = p.bulwarkPerfectUntil; p.facing = rand() * 6; a.facing = p.facing; break;
        case 'oath': p.unbreakableUntil = now + range(0, 4000); a.until = p.unbreakableUntil; break;
        case 'souls': a.n = range(1, 6); a.rate = chance(0.5) ? 1 : 1 + rand(); p.soulRateMult = a.rate as number; a.ret = p.addSouls(a.n as number); a.spend = chance(0.2); if (a.spend) p.spendSouls(); break;
        case 'veil': p.veilForm = chance(0.5); a.v = p.veilForm; p.betweenUntil = chance(0.3) ? now + 2000 : 0; a.between = p.betweenUntil; break;
        case 'brew': { const id = pick(Object.keys(BREWS)); a.id = id; applyBrew(p.brews, id, now); break; }
        case 'revive': p.revive(); break;
        case 'stats': { const s2 = { ...stats, maxHp: range(60, 3000), maxEssence: range(80, 600) }; a.stats = s2; p.setStats(s2 as never); break; }
        case 'res': a.amount = (rand() - 0.5) * 80; p.addResource(a.amount as number); break;
        case 'speed': a.moveMult = chance(0.5) ? 1 : 0.8; p.moveMult = a.moveMult as number; a.chill = chance(0.5) ? now + 1000 : 0; p.chilledUntil = a.chill as number; break;
      }
      acts.push(J(a)); snaps.push(snap());
    }
    cases.push({ in: J({ fam, stats, acts }), out: J({ snaps }) });
  }
  w('player', cases);
}

// ---------------------------------------------------------------------------------------------------------------------
// Legend maths, rune geometry / sockets, kill rewards, scaling helpers (all real exports)
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases = [];
  for (let i = 0; i < 400; i++) {
    const raw = chance(0.2) ? undefined : { thrallDeathBurst: pick([0, 0.8, 5, -1, NaN as never, 1.5]), championEvery: pick([0, 4, 25, -3, 7.9]), spearRally: pick([0, 1, 9]), miasmaSpreadsWithered: pick([0, 1, 0.4, 7]), witheredBurstAt: pick([0, 8, 40, 3.7]) };
    const mods = { ...J(disciplineFor(range(1, 4)).mods), colossusGuard: pick([0, 0.2, 0.3]), witheredBurstAt: pick([0, 8, 10]), litanyShatter: pick([0, 4]) };
    const ward = rand() * 1.3; const guard = pick([0, rand(), 2, -1]);
    const thr = range(0, 6); const raw2 = rand() * 500;
    cases.push({ in: J({ raw: raw === undefined ? null : J(raw), mods, ward, guard, thr, raw2, bw: rand() * 1.2, refl: pick([0, 0.4, 0.6]), barrier: pick([0, rand() * 300]), shat: pick([0, 4]) }), out: J({
      clamp: clampSimLegend(raw as never), simOf: simLegendOf(mods), dtm: damageTakenMult(ward, guard), cap: effectiveWitheredCap(mods), col: colossusActive(mods, thr),
      refl: wardReflectDamage(raw2, 0, 0),
    }) });
  }
  for (const c of cases) { const i = c.in as { raw2: number; bw: number; refl: number; barrier: number; shat: number }; (c.out as Record<string, unknown>).refl = wardReflectDamage(i.raw2, i.bw, i.refl); (c.out as Record<string, unknown>).shatter = shatterDamage(i.barrier, i.shat); }
  w('legend', cases);
}
{
  const cases = [];
  for (let i = 0; i < 300; i++) {
    const caster = { x: rand() * 8 - 4, z: rand() * 8 - 4 }, aim = { x: rand() * 20 - 10, z: rand() * 20 - 10 };
    const foes = Array.from({ length: range(0, 10) }, (_, k) => ({ id: k + 1, x: Math.round((rand() * 16 - 8) * 2) / 2, z: Math.round((rand() * 16 - 8) * 2) / 2, radius: pick([0.4, 0.6, 1]) }));
    const first = foes.length ? pick(foes) : { id: 99, x: 1, z: 1, radius: 0.5 };
    const corpses = foes.map((f, k) => ({ ...f, echoOwner: chance(0.2) ? 'p' : undefined, id: 100 + k }));
    const ang = rand() * Math.PI * 2; const d = { dx: Math.sin(ang), dz: Math.cos(ang) };
    const rows = [
      ...Array.from({ length: range(0, 8) }, () => ({ slot_index: range(125, 136), item_id: pick(['rune_splinter', 'rune_marrow_tap', 'rune_volley', 'rune_impale', 'rune_mass_grave', 'rune_requiem', 'junk']), quantity: pick([0, 1, 3]) })),
      ...Array.from({ length: range(0, 5) }, () => ({ slot_index: range(-1, 110), item_id: pick(['rune_splinter', 'rune_volley', 'junk']), quantity: range(1, 5), equipped: pick([0, 1]) })),
    ];
    const rite = pick(RUNE_RITES); const rid = pick(['rune_splinter', 'rune_impale', 'rune_requiem', 'junk']);
    cases.push({ in: J({ caster, aim, foes, first, corpses, d, rows, rite, rid, ringR: rand() * 5, reach: pick([6, 12, 18]), pt: { x: rand() * 8 - 4, z: rand() * 8 - 4 }, r: rand() * 8 }), out: J({
      splinter: splinterTarget(first, foes)?.id ?? null, volley: volleyTargets(caster, first, foes).map((e) => e.id), ring: ringHits(caster, 3, foes).map((e) => e.id),
      centre: ringCenter(caster, aim, 12), impale: ((r) => (r ? { id: r.foe.id, along: r.along } : null))(impaleTarget(caster, d.dx, d.dz, 12, 1.1, foes)),
      within: corpsesWithin(caster, 6, corpses).map((e) => e.id), sockets: socketsOf(rows), owned: ownedRunes(rows as never), fits: runeFits(rid, rite),
    }) });
  }
  for (const c of cases) { const i = c.in as { caster: never; aim: never; reach: number; pt: never; r: number; ringR: number; foes: never[]; corpses: never[] }; Object.assign(c.out as object, { centre2: ringCenter(i.caster, i.aim, i.reach), ring2: ringHits(i.pt, i.ringR, i.foes).map((e: { id: number }) => e.id), within2: corpsesWithin(i.pt, i.r, i.corpses).map((e: { id: number }) => e.id) }); }
  w('runes', cases);
}
{
  const cases = [];
  const ids = Object.keys(ENEMIES) as EnemyId[];
  for (let i = 0; i < 600; i++) {
    const def = pick(ids); const lvl = range(1, 150); const elite = chance(0.4); const tier = range(0, 8) + (chance(0.3) ? 0.5 : 0); const diff = pick(Object.keys(DIFFICULTIES));
    const fam = pick(['necromancer', 'knight', 'warden', 'monk', 'witch', 'veil']);
    const f = { fracture: range(0, 3), sanct: chance(0.5), shrouded: chance(0.5), rot: chance(0.5) };
    cases.push({ in: J({ def, lvl, elite, tier, diff, fam, f, depth: range(0, 60), hero: range(0, 150), amount: rand() * 900 }), out: J({
      xp: killXpBase(def, lvl, elite, tier, diff as never), gold: killGoldMax(def, lvl, elite, tier, diff as never), nbx: newBloodXpMult(fam, lvl + (chance(0.5) ? 0.7 : 0)), nbd: newBloodDamageMult(fam),
      hp: enemyHpScale(lvl), dm: enemyDamageScale(lvl), dl: depthEnemyLevel(range(0, 60), range(0, 150)),
      hn: damageTakenScale({ fracture: f.fracture, sanctT: f.sanct ? 2 : 0, affix: f.shrouded ? 'shrouded' : undefined }, f.rot),
    }) });
  }
  for (const c of cases) {
    const i = c.in as { depth: number; hero: number; fam: string; lvl: number };
    Object.assign(c.out as object, { dl: depthEnemyLevel(i.depth, i.hero), nbx: newBloodXpMult(i.fam, i.lvl) });
  }
  w('scaling', cases);
}

// ---------------------------------------------------------------------------------------------------------------------
// The real WorldSim: enemy spawns, thrall raising, Litany, Corpse Explosion, damageEnemy
// ---------------------------------------------------------------------------------------------------------------------
type Any = any; // eslint-disable-line @typescript-eslint/no-explicit-any
const areaIds = (Object.keys(AREAS) as AreaId[]).filter((a) => a !== 'depths');
{
  const cases = [];
  for (let i = 0; i < 700; i++) {
    const sim: Any = new WorldSim(new Nav(), mulberry32(range(1, 1e6)));
    const area = pick(areaIds); const def = pick(Object.keys(ENEMIES) as EnemyId[]); const elite = chance(0.4);
    sim.difficulty = pick(Object.keys(DIFFICULTIES)); sim.waveTier = pick([0, 1, 3, 5, 8]);
    const vows = Object.fromEntries(VOW_ORDER.filter(() => chance(0.3)).map((v) => [v, range(0, VOWS[v].maxRank)]));
    sim.vows = vows;
    const since = chance(0.3) ? range(0, 40) : 1e9;
    sim.arrivedAt.set(area, sim.time - since);
    const players = Array.from({ length: range(0, 4) }, (_, k) => ({ id: `p${k}`, x: 0, z: 0, alive: chance(0.8), area: chance(0.8) ? area : pick(areaIds), level: range(1, 150) }));
    for (const p of players) sim.setPlayer(p);
    const e = sim.spawnEnemy(def, area, 0, 0, elite, false);
    const hero = players.filter((p) => p.alive && p.area === area).map((p) => p.level);
    const adopt = sim.adoptEnemy({ ...e, level: chance(0.5) ? 1 : e.level });
    cases.push({ in: J({ def, area, elite, difficulty: sim.difficulty, waveTier: sim.waveTier, vows, since: since > 1e8 ? null : since, nplayers: Math.max(1, players.length), hero, adoptLevel: adopt.level }), out: J({
      level: e.level, hp: e.hp, damage: e.damage, radius: e.radius, scale: e.scale, areaLevel: sim.areaLevel(area), ramp: sim.rampTier(area), adoptDamage: adopt.damage, adoptRadius: adopt.radius, blow: sim.blow({ damage: e.damage, hexT: 1 }), blow0: sim.blow({ damage: e.damage }),
    }) });
  }
  w('enemy_spawn', cases);
}
{
  const cases = [];
  for (let i = 0; i < 500; i++) {
    const sim: Any = new WorldSim(new Nav(), mulberry32(range(1, 1e6)));
    const def = pick(['robber', 'templar', 'penitent', 'wraith', 'risen']) as EnemyId;
    const e = sim.spawnEnemy(def, 'graves', 3, 4, chance(0.3), false);
    e.hp = e.maxHp = 1e8;
    e.fracture = range(0, 3); if (chance(0.4)) e.sanctT = 3; if (chance(0.4)) e.affix = 'shrouded';
    e.facing = rand() * 12 - 6;
    const rot = chance(0.5);
    if (rot) sim.zones.set(999, { id: 999, kind: chance(0.5) ? 'miasma' : 'rot', owner: 'p', hostile: false, x: 3, z: 4, r: 2, until: 1e9, bornAt: 0, tick: 0, dps: 1, slow: 1, witheredCap: 5, bloom: false });
    const from = chance(0.7) ? { x: rand() * 10 - 5, z: rand() * 10 - 5 } : undefined;
    const amount = rand() * 800;
    const dealt = sim.damageEnemy(e, amount, 'p', from);
    cases.push({ in: J({ def, ex: e.x, ez: e.z, facing: e.facing, fracture: e.fracture, sanct: !!e.sanctT, shrouded: e.affix === 'shrouded', rot, from, amount }), out: J({ dealt, takenMult: sim.damageTakenMult(e) }) });
  }
  w('damage_enemy', cases);
}
{
  const cases = [];
  const kindsC = ['normal', 'normal', 'resonant', 'swift', 'toxic'] as const;
  const enemiesC = ['robber', 'robber', 'penitent', 'deacon', 'sac', 'risen'] as const;
  for (let i = 0; i < 400; i++) {
    const sim: Any = new WorldSim(new Nav(), mulberry32(range(1, 1e6)));
    sim.setPlayer({ id: 'p1', x: 0, z: 0, alive: true, area: 'graves' });
    const every = chance(0.4) ? pick([0, 3, 4]) : 0;
    if (every) sim.apply({ t: 'legend', by: 'p1', mods: { championEvery: every } });
    const ncorp = range(1, 12);
    const corpses = [];
    for (let k = 0; k < ncorp; k++) {
      const x = Math.round((rand() * 8 - 4) * 4) / 4, z = Math.round((rand() * 8 - 4) * 4) / 4;
      const kind = pick(kindsC), enemy = pick(enemiesC), elite = chance(0.2);
      sim.addCorpse(x, z, kind, enemy, elite, 0, 1, 'graves');
      corpses.push({ x, z, kind, enemy, elite, echoOwner: null });
    }
    const steps = [];
    for (let s = 0, n = range(1, 8); s < n; s++) {
      const kind = pick(['warrior', 'shieldbearer', 'wraith', 'bogus', 'hound']);
      const intent: Any = { t: 'exhume', by: 'p1', x: Math.round((rand() * 8 - 4) * 4) / 4, z: Math.round((rand() * 8 - 4) * 4) / 4, r: pick([0.8, 3, 0.2]), kind, cap: range(1, 7), hp: 10 + rand() * 900, damage: 5 + rand() * 300, attackSpeedMult: 1 + rand() * 0.5 };
      if (chance(0.3)) intent.count = pick([1, 2, 3, 9, -2, 2.7]);
      if (kind === 'wraith' && chance(0.5)) intent.allyHeal = rand() * 0.06;
      if (chance(0.2)) { intent.colossus = true; intent.r = pick([6, 3, 10]); }
      const refresh = chance(0.2) ? { t: 'refreshThralls', by: 'p1', hpMult: pick([1, 1.1, 2, 0.5, NaN as never]), damageMult: pick([1, 1.2, 3]), speedMult: pick([1, 1.05]) } : null;
      sim.apply(intent);
      if (refresh) sim.apply(refresh);
      const th = [...sim.thralls.values()].filter((t: Any) => t.state !== 'dead').map((t: Any) => ({ id: t.id, kind: t.kind, hp: t.hp, maxHp: t.maxHp, damage: t.damage, attackInterval: t.attackInterval, range: t.range, speed: t.speed, empowered: t.empowered, champion: !!t.champion, allyHeal: t.allyHeal ?? 0 }));
      steps.push({ intent, refresh, after: th });
    }
    cases.push({ in: J({ corpses, every, steps: steps.map((s) => ({ intent: s.intent, refresh: s.refresh })) }), out: J({ steps: steps.map((s) => s.after.map(({ id: _id, ...rest }: Any) => rest)) }) });
  }
  w('thralls', cases);
}
{
  const cases = [];
  for (let i = 0; i < 400; i++) {
    const sim: Any = new WorldSim(new Nav(), mulberry32(range(1, 1e6)));
    sim.setPlayer({ id: 'p1', x: 0, z: 0, alive: true, area: 'graves' });
    const corpses = Array.from({ length: range(0, 10) }, () => ({ x: rand() * 12 - 6, z: rand() * 12 - 6, kind: pick(['normal', 'resonant', 'toxic', 'swift']), elite: chance(0.2) }));
    const ids: number[] = [];
    for (const c of corpses) { sim.addCorpse(c.x, c.z, c.kind, 'robber', c.elite, 0, pick([1, 1, 1.6]), 'graves'); ids.push([...sim.corpses.values()].at(-1).id); }
    const nth = range(0, 6);
    const thr = [];
    for (let k = 0; k < nth; k++) { sim.addCorpse(7 + k, 0, 'normal', 'robber', false, 0, 1, 'graves'); const c = [...sim.corpses.values()].at(-1); sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 9, hp: 50, damage: 5, attackSpeedMult: 1 }); }
    for (const t of sim.thralls.values()) { t.x = rand() * 8 - 4; t.z = rand() * 8 - 4; t.state = 'idle'; thr.push({ x: t.x, z: t.z }); }
    for (const c of [...sim.corpses.values()].filter((c: Any) => c.x >= 7)) sim.removeCorpse(c, 'expired', 'p1');
    const foes = Array.from({ length: range(1, 5) }, () => { const e = sim.spawnEnemy('robber', 'graves', rand() * 10 - 5, rand() * 10 - 5, false, false); e.hp = e.maxHp = 1e6; return e; });
    const spell = 1 + rand() * 60; const lit = { t: 'litany', by: 'p1', x: rand() * 4 - 2, z: rand() * 4 - 2, r: pick([7, 7 * 1.5, 3]), spellPower: spell, leaveCorpses: chance(0.5), spare: chance(0.2) };
    const foePos = foes.map((e: Any) => ({ x: e.x, z: e.z, radius: e.radius }));
    sim.apply(lit);
    const res = sim.drain().find((e: Any) => e.t === 'litanyResult');
    const litDmg = foes.map((e: Any) => 1e6 - e.hp);
    // Corpse Explosion on the first corpse (if any), after resetting enemy hp
    let det = null;
    if (ids.length && sim.corpses.has(ids[0])) {
      for (const e of foes) e.hp = e.maxHp = 1e8;
      const claim = pick([rand() * 900, 5e5, -4, NaN as never]);
      const c0 = sim.corpses.get(ids[0]);
      sim.apply({ t: 'detonate', by: 'p1', corpseId: c0.id, dmg: claim });
      const ev = sim.drain().find((e: Any) => e.t === 'detonated');
      const zone = [...sim.zones.values()].find((z: Any) => z.kind === 'rot');
      det = { claim, corpse: { kind: c0.kind, elite: c0.elite, scale: c0.scale, x: c0.x, z: c0.z }, r: ev.r, targets: ev.targets, dmg: ev.dmg, zone: zone ? { r: zone.r, dps: zone.dps } : null };
    }
    cases.push({ in: J({ corpses, thr, foePos, lit, det: det && { claim: det.claim, corpse: det.corpse } }), out: J({ res: res && { corpses: res.corpses, resonant: res.resonant, thralls: res.thralls, spared: res.spared ?? 0, targets: res.targets }, litDmg, det: det && { r: det.r, targets: det.targets, dmg: det.dmg, zone: det.zone } }) });
  }
  w('litany_detonate', cases);
}

// ---------------------------------------------------------------------------------------------------------------------
// Ability bookkeeping and damage expressions (transcribed from AbilitySystem / NewBloodSystem over the real constants)
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases = [];
  const ids = Object.keys(ABILITIES);
  for (let i = 0; i < 800; i++) {
    const stats = { level: range(1, 60), maxHp: range(60, 3000), spellPower: 10 + rand() * 300, maxEssence: range(80, 600), essenceRegen: 5, moveSpeed: 5.4, thrallHp: 50, thrallDamage: 10, damageBonusPct: 0 };
    const fam = pick(['necromancer', 'knight', 'warden', 'monk', 'witch', 'veil'] as const);
    const worn: Record<string, { item_id: string }> = {};
    if (chance(0.7)) worn.main_hand = { item_id: pick(NECRO_MAIN).id };
    if (chance(0.5)) worn.off_hand = { item_id: pick(NECRO_OFF).id };
    const loadout = resolveWeaponLoadout(worn, pick(['ossuary', 'mourner', 'gravecaller', 'rotweaver']));
    const p: Any = new Player(stats, new Nav(), fam);
    p.loadout = loadout;
    const now = range(1000, 100000);
    p.resource.value = rand() * stats.maxEssence;
    if (chance(0.3)) p.castUntil = now + range(-50, 50);
    const id = pick(ids) as never as keyof typeof ABILITIES;
    if (chance(0.3)) p.cooldowns.set(id, now + range(-100, 100));
    p.souls = chance(0.3) ? p.soulsMax : range(0, 10);
    if (chance(0.3)) p.brews.elixir = { id: 'flask_damage', until: now + 1000 };
    if (chance(0.3)) { p.brews.tonic = null; p.brews.elixir = Object.keys(BREWS).find((k) => BREWS[k].effects[0].kind === 'haste') ? { id: Object.keys(BREWS).find((k) => BREWS[k].effects[0].kind === 'haste')!, until: now + 5000 } : null; }
    p.unbreakableUntil = chance(0.2) ? now + 100 : 0;
    p.alive = chance(0.95);
    const level = range(1, 40);
    // checks: AbilitySystem.cast (transcribed)
    const check = () => {
      const def = ABILITIES[id];
      if (!p.alive) return 'dead';
      if (level < unlockLevel(id)) return 'locked';
      if (now < p.castUntil) return 'busy';
      if (p.onCooldown(id, now)) return 'cooldown';
      const empowered = p.soulsCharged && SOUL_HARVEST.spells.includes(id);
      if (!empowered && p.essence < def.essenceCost) return 'essence';
      return 'ok';
    };
    const verdict = check();
    const empowered = p.soulsCharged && SOUL_HARVEST.spells.includes(id);
    const colossus = chance(0.3);
    const before = { essence: p.essence };
    const inState = J({ stats, fam, worn, now, resource: p.resource.value, castUntil: p.castUntil, cooldown: p.cooldowns.get(id) ?? 0, souls: p.souls, brews: p.brews, unbreakableUntil: p.unbreakableUntil, alive: p.alive, rooted: p.rootedUntil, id, level, colossus, disc: p.loadout.main });
    const sp = stats.spellPower * (now < p.unbreakableUntil ? 1.3 : 1) * (1 + p.brewValue('damage', now));
    const nbPower = stats.spellPower * 1.5 * (p.veilForm && now >= p.betweenUntil ? 0.7 : 1);
    if (verdict === 'ok') {
      p.castUntil = now + abilityLockMs(id, CAST_FLOW[id].lockMs, p.loadout);
      p.rootedUntil = Math.max(p.rootedUntil, p.castUntil);
      if (empowered) p.spendSouls(); else p.essence -= ABILITIES[id].essenceCost;
      if (id === 'exhume' && !empowered && p.loadout.exhumeRefund > 0) p.essence = Math.min(p.stats.maxEssence, p.essence + ABILITIES[id].essenceCost * p.loadout.exhumeRefund);
      const runeCool = id === 'exhume' && colossus ? RUNE_TUNING.colossus.cooldownMult : 1;
      p.cooldowns.set(id, now + (abilityCooldownMs(id, ABILITIES[id].cooldownMs, p.loadout, PRIMARIES.includes(id)) * runeCool) / (1 + p.brewValue('haste', now)));
    }
    cases.push({ in: { ...inState, worn, loadout }, out: J({ verdict, empowered, castUntil: p.castUntil, rootedUntil: p.rootedUntil, essence: p.essence, cooldown: p.cooldowns.get(id) ?? 0, souls: p.souls, sp, nbPower, unlock: unlockLevel(id), before }) });
  }
  w('ability_cast', cases);
}
{
  const cases = [];
  for (let i = 0; i < 500; i++) {
    const sp = 5 + rand() * 600; const jitter = rand();
    const worn: Record<string, { item_id: string }> = {};
    if (chance(0.7)) worn.main_hand = { item_id: pick(NECRO_MAIN).id };
    const loadout = resolveWeaponLoadout(worn, 'ossuary');
    const rune = pick(['', 'rune_volley', 'rune_marrow_tap', 'rune_splinter', 'rune_ossuary_ring', 'rune_impale', 'rune_creeping_rot', 'rune_hollow_choir']);
    const castIdx = range(1, 12);
    const T = RUNE_TUNING; const D = ABILITIES;
    const volley = rune === 'rune_volley' && castIdx % T.volley.every === 0;
    const runeMult = rune === 'rune_marrow_tap' ? T.marrowTap.damageMult : volley ? T.volley.damageFrac : 1;
    const dmg = sp * D.bone_needle.power * loadout.needleDamageMult * runeMult * (0.9 + jitter * 0.2);
    const essence = NEEDLE_ESSENCE + (rune === 'rune_marrow_tap' ? T.marrowTap.essenceBonus : 0);
    const scythe = NECRO_WEAPON_TUNING.scythe;
    const landed = range(0, 4);
    const reapDmg = sp * D.bone_needle.power * scythe.damageMult * (rune === 'rune_marrow_tap' ? T.marrowTap.damageMult : 1) * (0.9 + jitter * 0.2);
    const reapEss = landed ? scythe.essencePerHit * landed + (rune === 'rune_marrow_tap' ? T.marrowTap.essenceBonus : 0) : 0;
    const mult = chance(0.5) ? 1 : SOUL_HARVEST.areaMult;
    const mods = { ...J(disciplineFor(range(1, 4)).mods) };
    const caster = { x: rand() * 6, z: rand() * 6 }; const aim = { x: rand() * 30 - 10, z: rand() * 30 - 10 };
    let mx = aim.x, mz = aim.z; const md = Math.hypot(mx - caster.x, mz - caster.z);
    if (md > D.miasma.range) { mx = caster.x + ((mx - caster.x) / md) * D.miasma.range; mz = caster.z + ((mz - caster.z) / md) * D.miasma.range; }
    const mr = D.miasma.radius * mods.miasmaRadiusMult * mult * (rune === 'rune_creeping_rot' ? T.creepingRot.radiusMult : 1);
    const corp = range(0, 12), res = range(0, 4), thr = range(0, 8);
    const litMult = Math.min(LITANY_MAX_MULT, D.black_litany.power + LITANY_PER_CORPSE * corp + LITANY_PER_RESONANT * res + LITANY_PER_THRALL * thr);
    const mm = { ...mods, litanyBarrier: pick([0, 0.04, 0.06]), corpseHeal: pick([0, 0.03, 0.1]) };
    const maxHp = range(60, 3000);
    const gcorp = range(0, 9);
    const G = GRAVE_HANDS; const gc = Math.min(G.maxCorpses, gcorp);
    const M = BONE_MANTLE; const mantleCorp = range(0, 8);
    const hop = range(1, 5);
    const claim = sp * D.corpse_explosion.power;
    cases.push({ in: J({ sp, jitter, loadout, rune, castIdx, landed, mult, mods, caster, aim, corp, res, thr, mm, maxHp, gcorp, mantleCorp, hop }), out: J({
      needle: { volley, runeMult, dmg, essence }, reap: { dmg: reapDmg, essence: reapEss },
      spear: { range: D.marrow_spear.range * mult, radius: D.marrow_spear.radius * mult, dmg: sp * D.marrow_spear.power, ring: rune === 'rune_ossuary_ring' ? { radius: T.ring.radius * mult, dmg: sp * D.marrow_spear.power * T.ring.damageMult, maxCastRange: T.ring.maxCastRange * mult } : null, impaleDmg: sp * D.marrow_spear.power * T.impale.damageMult },
      miasma: { x: mx, z: mz, r: mr, dps: sp * D.miasma.power, durationMs: 6000, witheredCap: Math.max(mods.witheredMaxStacks, mods.witheredBurstAt ?? 0), bloom: mods.miasmaBurstsCorpses },
      litMult, litDmg: sp * litMult, litSp: sp * (rune === 'rune_hollow_choir' ? T.hollowChoir.powerMult : 1),
      gains: { barrier: mm.litanyBarrier ? maxHp * mm.litanyBarrier * (corp + res + thr) : 0, heal: mm.corpseHeal ? maxHp * mm.corpseHeal * (corp + res) * 0.5 : 0 },
      hands: { corpses: gc, hands: Math.min(G.maxHands, G.hands + gc * G.handsPerCorpse), dmg: sp * D.grave_hands.power * (1 + G.perCorpse * gc) },
      storm: BONE_STORM.durationS + Math.min(BONE_STORM.maxExtraS, gcorp * BONE_STORM.perCorpseS),
      mantle: Math.min(M.barrierCap, M.barrierBase + M.barrierPerCorpse * mantleCorp),
      skull: sp * D.wailing_skull.power * Math.pow(WAILING_SKULL.falloff, hop - 1) * 1, claim,
    }) });
  }
  w('ability_damage', cases);
}
{
  const cases = [];
  for (let i = 0; i < 300; i++) {
    const stats = { level: 10, maxHp: range(60, 3000), spellPower: 10 + rand() * 300, maxEssence: 100, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 50, thrallDamage: 10, damageBonusPct: 0 };
    const fam = pick(['warden', 'monk', 'witch', 'veil', 'knight'] as const);
    const p: Any = new Player(stats, new Nav(), fam);
    p.veilForm = chance(0.4); p.betweenUntil = chance(0.4) ? range(0, 200) : 0;
    p.resource.value = rand() * 100;
    const now = range(0, 5000);
    const power = p.stats.spellPower * 1.5 * (p.veilForm && now >= p.betweenUntil ? 0.7 : 1);
    const id = pick(['toll', 'great_toll', 'last_light']);
    const spend = id === 'toll' && p.resource.value >= 25 ? 25 : id === 'great_toll' ? p.resource.value : 0;
    const phase = ((now % 1200) + 1200) % 1200; const beat = phase <= 150 || phase >= 1050;
    cases.push({ in: J({ stats, fam, veilForm: p.veilForm, between: p.betweenUntil, value: p.resource.value, now, id }), out: J({
      power, toll: { spend, power: power * (1 + spend / 100), duration: id === 'toll' && spend ? 0.6 : -1 },
      palm: { beat, damage: power * ABILITIES.palm_strike.power * (beat ? 1.4 : 1), resonance: beat ? 12 : 8 },
      hook: { damage: power * ABILITIES.hook_throw.power, bleed: power * 0.14 }, choir: power * 0.5, crow: power * 0.35,
    }) });
  }
  w('new_blood', cases);
}
console.log('fixtures written', counts);
