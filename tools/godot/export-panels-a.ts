/**
 * Panel data for the Godot "panels A" track (Codex, Gear Atlas), computed by the real TS so the words and numbers follow the game.
 * Run: npx vite-node tools/godot/export-panels-a.ts   ->  godot/data/panels_a/{codex_rows,atlas}.json (small, committed)
 *
 * The Codex and the Atlas are built from functions (codexSetRows(), getAtlas(), sourcesFor(), fitBand() ...), not from plain
 * constants, so godot/data/content/codex.json (constants only) is not enough. This evaluates those functions once.
 * Deterministic: nothing here is time- or random-dependent.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import * as codex from '../../src/content/codex';
import { AREAS, AREA_ORDER } from '../../src/content/areas';
import { DISCIPLINES } from '../../src/content/disciplines';
import { ITEMS } from '../../src/content/items';
import { NECRO_WEAPONS } from '../../src/content/necroWeapons';
import { generateLayout } from '../../src/content/layout';
import { GATHER_SKILLS, SKILLS, actionMs, nodesForSkill, xpPerHour } from '../../src/gameplay/gatheringRules';
import {
  affixCountOdds, areaQuality, fmtChance, fmtQty, oneIn, cosmeticsInfo, fitBand, fitTable, getAtlas, isRecommendedKind, itemLevelAt, placesFor, rollPotential, sourcesFor,
} from '../../src/gameplay/atlas';
import { salvagePreview } from '../../src/gameplay/salvageRules';
import { orderInfo } from '../../src/gameplay/contractRules';
import { STAT_PRIMER, STAT_PRIORITY, lookingFor, statSheet } from '../../src/gameplay/gearStats';
import { DISCIPLINES as DISC } from '../../src/content/disciplines';

const OUT = resolve('godot/data/panels_a');
mkdirSync(OUT, { recursive: true });
// sheet_sample.json is TEST/MOCK data (the dev gallery's stat sheet): it goes under godot/tests/, never godot/data/.
const MOCK_OUT = resolve('godot/tests/panels_a');
const write = (name: string, v: unknown, dir = OUT) => {
  const s = JSON.stringify(v);
  mkdirSync(dir, { recursive: true });
  writeFileSync(resolve(dir, name), s + '\n');
  console.log(`${name}: ${(s.length / 1024).toFixed(0)} KB`);
};
const round = (n: number, d = 6) => (Number.isFinite(n) ? +n.toFixed(d) : n);
const sig = (n: number) => (Number.isFinite(n) && n !== 0 ? +n.toPrecision(6) : n);
const deepRound = (v: any): any => (typeof v === 'number' ? sig(v) : Array.isArray(v) ? v.map(deepRound) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, deepRound(x)])) : v);

// ---------------------------------------------------------------- Codex rows
const nodes = generateLayout().nodes;
const where = (type: string) => [...new Set(nodes.filter((n) => n.type === type).map((n) => (n.rich ? `${AREAS[n.area].name} (rich)` : AREAS[n.area].name)))].join(', ');
const professions = GATHER_SKILLS.map((skill) => ({
  skill, name: SKILLS[skill].name, rite: SKILLS[skill].rite, color: SKILLS[skill].color,
  rows: nodesForSkill(skill).map((n) => ({ level: n.level, name: n.name, xp: n.xp, cycle: +(actionMs(n) / 1000).toFixed(1), yields: ITEMS[n.item]?.name ?? n.item, xph: Math.round(xpPerHour(n, n.level) / 100) / 10, where: where(n.id) })),
}));

write('codex_rows.json', deepRound({
  rite_swatch: Object.fromEntries(codex.RITE_ORDER.map((id) => [id, codex.riteSwatch(id)])),
  area_unlock: Object.fromEntries(AREA_ORDER.map((id) => [id, codex.areaUnlockText(id)])),
  sets: codex.codexSetRows(),
  affixes: codex.codexAffixRows(),
  legion_examples: codex.codexLegionExamples(),
  legion_tiers: codex.codexLegionTiers(),
  runes: codex.codexRuneRows(),
  altar: codex.codexAltarRows(),
  brews: codex.codexBrewRows(),
  reagents: codex.codexReagentRows(),
  reagent_recipes: codex.codexReagentRecipes(),
  salvage: codex.codexSalvageRows(),
  empower: codex.codexEmpowerRows(),
  people: codex.codexPeopleRows(),
  professions,
  weapon_tiers: codex.CODEX_WEAPON_TIERS,
  skills_salvaging: { name: SKILLS.salvaging.name, rite: SKILLS.salvaging.rite, color: SKILLS.salvaging.color },
}));

// ---------------------------------------------------------------- Gear Atlas
const atlas = getAtlas();
const discs = Object.keys(DISCIPLINES);
const BASE = 'gravecaller';
const items: Record<string, unknown> = {};
for (const [id, it] of atlas.items) {
  const m = ITEMS[id];
  items[id] = {
    id, name: it.name, type: it.type, rarity: it.rarity, slot: it.slot, stats: it.stats, lore: it.lore ?? m?.lore ?? '', icon: it.icon ?? m?.icon ?? '',
    gear: it.gear, set_id: it.setId ?? '', weapon_kind: it.weaponKind ?? '', level: it.level, sell: m?.sell ?? 0,
    weapon_effect: NECRO_WEAPONS.find((w) => w.id === id)?.effect ?? '',
    fit: fitTable(id),
    salvage: it.gear || m?.type === 'rune' ? salvagePreview({ id, item_type: m.type, rarity: m.rarity }) : null,
    order: !it.gear ? orderInfo(id) : null,
    affix_odds: it.gear ? { elite: affixCountOdds(it.rarity, 'elite'), boss: affixCountOdds(it.rarity, 'boss'), first_kill: affixCountOdds(it.rarity, 'first_kill') } : null,
  };
}
/** A drop source as a row: [kind, placeId, place, event, chance, qtyLo, qtyHi, area, ilvlSource, note] (unpacked by DmAtlasData). */
const packSrc = (s: any) => [s.kind, s.placeId, s.place, s.event, s.chance, s.qty[0], s.qty[1], s.area ?? '', s.ilvlSource ?? '', s.note ?? ''];
const baseRaw = Object.fromEntries([...atlas.items.keys()].map((id) => [id, sourcesFor(id, BASE)]));
const baseSources = Object.fromEntries(Object.entries(baseRaw).map(([id, l]) => [id, l.map(packSrc)]));
/** Smart loot tilts tables per discipline: identical diffs are stored once (variants) and referenced by key. */
const variants: Record<string, Record<string, unknown>> = {};
const by_disc: Record<string, unknown> = {};
for (const d of discs) {
  const sourcesDiff: Record<string, unknown> = {};
  const band: Record<string, string> = {};
  const rec: string[] = [];
  const roll: Record<string, unknown> = {};
  for (const id of atlas.items.keys()) {
    const s = sourcesFor(id, d);
    if (JSON.stringify(s) !== JSON.stringify(baseRaw[id])) sourcesDiff[id] = s.map(packSrc);
    const it = atlas.items.get(id)!;
    if (it.gear) {
      const b = fitBand(id, d);
      if (b) band[id] = b;
      if (isRecommendedKind(id, d)) rec.push(id);
      const dropAt = s.find((x) => x.area && x.ilvlSource);
      const pot = rollPotential(id, d, dropAt?.area && dropAt.ilvlSource ? itemLevelAt(AREAS[dropAt.area].level, dropAt.ilvlSource) : 20);
      if (pot) roll[id] = pot;
    }
  }
  const quality: Record<string, unknown> = {};
  for (const a of AREA_ORDER) { const q = areaQuality(a, d); if (q) quality[a] = q; }
  const vkey = JSON.stringify(sourcesDiff);
  const found = Object.entries(variants).find(([, v]) => JSON.stringify(v) === vkey);
  const variant = found ? found[0] : `v${Object.keys(variants).length}`;
  variants[variant] = sourcesDiff;
  by_disc[d] = {
    name: DISCIPLINES[d as keyof typeof DISCIPLINES].name,
    priority: (STAT_PRIORITY as any)[d]?.order ?? [],
    sources_variant: variant, band, recommended: rec, roll, quality,
    places: placesFor(d).map((p) => ({ id: p.id, name: p.name, kind: p.kind, level: p.level, rank: p.rank, items: p.items })),
  };
}
const cos = cosmeticsInfo();
write('atlas.json', deepRound({
  item_order: [...atlas.items.keys()],
  items,
  source_cols: ['kind', 'placeId', 'place', 'event', 'chance', 'qty_lo', 'qty_hi', 'area', 'ilvl_source', 'note'],
  sources: baseSources,
  made_by: Object.fromEntries(atlas.madeBy),
  used_in: Object.fromEntries(atlas.usedIn),
  sets: atlas.sets,
  source_variants: variants,
  by_disc,
  cosmetics: { capes: cos.capes, notes: cos.notes, pets: cos.pets.map((p) => ({ ...p, sources: p.sources.map(packSrc) })) },
  area_names: Object.fromEntries(AREA_ORDER.map((a) => [a, { name: AREAS[a].name, level: AREAS[a].level }])),
}));

// ---------------------------------------------------------------- Character sheet sample (for the gallery and the tests)
// The sheet panel is pure display of statSheet()/lookingFor() output; this bakes one real sample so the layout is verified against real text.
{
  let id = 1;
  const mk = (item_id: string, slot_index: number, bonus: Record<string, number>, equipped: 0 | 1 = 1) => ({
    id: id++, slot_index, quantity: 1, equipped, item_id, name: ITEMS[item_id]?.name ?? item_id, rarity: ITEMS[item_id]?.rarity ?? 'common',
    item_type: ITEMS[item_id]?.type ?? 'armor_head', stat_bonus: bonus, icon_id: null, sell_value: 1, crafted: 0,
  });
  const slots: any[] = [mk('set_gravecaller_head', 0, { stat_int: 4, stat_vit: 2 }), mk('set_gravecaller_chest', 1, { stat_vit: 6, stat_int: 2 }), mk('set_gravecaller_legs', 2, { stat_vit: 3 })];
  const ctx: any = { character: { id: 1, class_index: 2, class_name: '', level: 12, experience: 0, gold: 0, stat_str: 6, stat_agi: 6, stat_int: 9, stat_vit: 8 }, slots, discipline: DISC.gravecaller, damageTier: 1 };
  write('sheet_sample.json', deepRound({ primer: STAT_PRIMER, looking: lookingFor(ctx), sections: statSheet(ctx) }), MOCK_OUT);
}

// ---------------------------------------------------------------- Formatting fixtures (tests/panels_a/fixtures/fmt.json)
{
  const chances: number[] = [0, 1, 0.9999, 0.99995, 0.5, 0.25, 0.123456, 0.1, 0.0999, 0.05, 0.0499, 0.01, 0.00999, 0.0035, 0.001, 0.00099, 0.0001, 0.00005, 0.000031, 1e-6, 2.5e-7];
  for (let i = 0; i < 150; i++) chances.push(+(Math.pow(10, -(i % 60) / 12 - 0.01) * (1 + (i % 7) / 9)).toPrecision(5));
  const pcts = [0, 0.01, 0.03, 0.06, 0.012, 0.0999, 0.125, 0.3456, 1, 0.075, 0.0004];
  const secs = [250, 380, 700, 1000, 1500, 2200, 12000, 333, 4500, 60000];
  const qty: [number, number][] = [[1, 1], [1, 2], [3, 3], [2, 9], [0, 0]];
  const fix = {
    chance: chances.map((p) => ({ p, text: fmtChance(Math.min(1, p)), oneIn: oneIn(Math.min(1, p)) })),
    pct: pcts.map((x) => ({ x, text: `${+(x * 100).toFixed(1)}%` })),
    secs: secs.map((ms) => ({ ms, text: `${+(ms / 1000).toFixed(2)}s` })),
    qty: qty.map((q) => ({ q, text: fmtQty(q) })),
  };
  const dir = resolve('godot/tests/panels_a/fixtures');
  mkdirSync(dir, { recursive: true });
  writeFileSync(resolve(dir, 'fmt.json'), JSON.stringify(fix) + '\n');
  console.log('fmt.json: ' + (JSON.stringify(fix).length / 1024).toFixed(0) + ' KB');
}
