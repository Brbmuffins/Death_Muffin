/**
 * Exports ALL game content to godot/data/content/*.json from the real TS modules (never retyped).
 * Run: npx vite-node tools/godot/export-content.ts
 *
 * One JSON per source module: { "<ExportName>": value, ... } (every non-function export). Functions are dropped (the
 * logic is ported in GDScript); where content is computed by functions, the result lands in computed.json.
 * Deterministic: insertion order of the TS objects is kept (it is meaningful), nothing time- or random-dependent is written.
 * Numbers: JSON has no int/float split and Godot parses every number as float; use int() in GDScript where the TS means an integer.
 */
import { execSync } from 'node:child_process';
import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const OUT = resolve('godot/data/content');

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
const dropped: string[] = [];
const warnings: string[] = [];

function clean(v: unknown, path: string, seen: Set<object>): Json | undefined {
  if (v === undefined) return undefined;
  if (v === null) return null;
  const t = typeof v;
  if (t === 'function') { dropped.push(path); return undefined; }
  if (t === 'boolean' || t === 'string') return v as boolean | string;
  if (t === 'bigint') return Number(v);
  if (t === 'number') {
    const n = v as number;
    if (!Number.isFinite(n)) { warnings.push(`${path}: non-finite number ${n} exported as null`); return null; }
    return Object.is(n, -0) ? 0 : n;
  }
  if (t === 'symbol') return undefined;
  const o = v as object;
  if (seen.has(o)) { warnings.push(`${path}: cycle skipped`); return undefined; }
  seen.add(o);
  let r: Json;
  if (Array.isArray(o)) {
    r = o.map((x, i) => clean(x, `${path}[${i}]`, seen) ?? null);
  } else if (o instanceof Set) {
    r = [...o].map((x, i) => clean(x, `${path}{${i}}`, seen) ?? null);
  } else if (o instanceof Map) {
    const m: { [k: string]: Json } = {};
    for (const [k, x] of o) { const c = clean(x, `${path}.${String(k)}`, seen); if (c !== undefined) m[String(k)] = c; }
    r = m;
  } else if (o instanceof RegExp) {
    r = o.source;
  } else {
    const m: { [k: string]: Json } = {};
    for (const [k, x] of Object.entries(o)) { const c = clean(x, `${path}.${k}`, seen); if (c !== undefined) m[k] = c; }
    r = m;
  }
  seen.delete(o);
  return r;
}

function exportNamespace(ns: Record<string, unknown>, name: string): Record<string, Json> {
  const out: Record<string, Json> = {};
  for (const [k, v] of Object.entries(ns)) {
    if (k === 'default') continue;
    const c = clean(v, `${name}.${k}`, new Set());
    if (c !== undefined) out[k] = c;
  }
  return out;
}

const count = (j: Json): number => (Array.isArray(j) ? j.length : j && typeof j === 'object' ? Object.keys(j).length : 1);

async function main() {
  // Pure-data modules. content/* all; gameplay/* only the rule-constant ones (ported rules read these tables).
  const contentMods = [
    'abilities', 'alchemy', 'areas', 'armorSets', 'ascension', 'audioMap', 'bosses', 'brews', 'castClips', 'codex', 'combatFlow',
    'cosmetics', 'depths', 'dialogue', 'difficulty', 'disciplines', 'enemies', 'fen', 'fenItems', 'gardening', 'gear', 'items', 'kits',
    'layout', 'legendarySets', 'necroWeapons', 'npcSpots', 'npcs', 'omens', 'processing', 'reagents', 'recipes', 'runes', 'setBonuses',
    'statuses', 'tradeGoods', 'upgrades', 'wing',
  ];
  const gameplayMods = [
    'affixRules', 'atlas', 'authorityRules', 'beltRules', 'characterStats', 'classes', 'contractRules', 'craftQuantity', 'depthsFloor',
    'gatherPlan', 'gatherReport', 'gatheringRules', 'gearStats', 'goldSinkRules', 'guidance', 'keybinds', 'killChain', 'killCredit',
    'killRules', 'laborRules', 'legendary', 'legionRules', 'loadout', 'loadoutRules', 'loot', 'lootFilter', 'milestones', 'necroRules',
    'newBloodTuning', 'resources', 'runeRules', 'salvageRules', 'smartLoot', 'stats', 'vaultRules',
  ];

  const files: Record<string, Record<string, Json>> = {};
  for (const m of contentMods) files[m] = exportNamespace(await import(`../../src/content/${m}.ts`), m);
  for (const m of gameplayMods) files[`gameplay_${m}`] = exportNamespace(await import(`../../src/gameplay/${m}.ts`), `gameplay/${m}`);
  files['gameplay_sim'] = {
    ...exportNamespace(await import('../../src/gameplay/sim/BossBrain.ts'), 'sim/BossBrain'),
    ...exportNamespace(await import('../../src/gameplay/sim/WorldSim.ts'), 'sim/WorldSim'),
  };
  // Onboarding tips (Covenant counsel) + cadence tables: text and timing data only (the Onboarding class is DOM, dropped).
  const onboarding = await import('../../src/ui/Onboarding.ts');
  files['onboarding'] = exportNamespace({ TIPS: onboarding.TIPS, TIP_ANCHOR: onboarding.TIP_ANCHOR }, 'ui/Onboarding');
  const cadence = await import('../../src/ui/counselCadence.ts');
  files['counselCadence'] = exportNamespace(cadence, 'ui/counselCadence');
  files['counselCadence'].tipMeta = exportNamespace(
    Object.fromEntries(Object.keys(onboarding.TIPS).map((id) => [id, { kind: cadence.kindOf(id), group: cadence.groupOf(id), priority: cadence.priorityOf(id) }])), 'tipMeta') as Json;
  // Exclude non-data leakage (loot.ts re-exports etc. are fine; dev-only accounts must not ship).
  delete files['gameplay_loot']?.['devAccess'];

  // ---- computed content (results of functions over content) ----
  const { AREAS, AREA_ORDER } = await import('../../src/content/areas.ts');
  const { DISCIPLINES } = await import('../../src/content/disciplines.ts');
  const { smartTable } = await import('../../src/gameplay/smartLoot.ts');
  const { kitFor } = await import('../../src/content/kits.ts');
  const { ABILITIES, unlockLevel } = await import('../../src/content/abilities.ts');
  const { depthRoster, depthLootArea, chestRunePool } = await import('../../src/content/depths.ts');
  const { armorLoot } = await import('../../src/content/armorSets.ts');
  const { necroWeaponLoot } = await import('../../src/content/necroWeapons.ts');
  const { generateLayout } = await import('../../src/content/layout.ts');
  const { allClipNames } = await import('../../src/content/audioMap.ts');
  const { brewSummary } = await import('../../src/content/brews.ts');
  const { itemMeta, ITEMS } = await import('../../src/content/items.ts');

  const { DAMAGE_UPGRADE, WAVE_UPGRADE, LEGION_UPGRADE } = await import('../../src/content/upgrades.ts');
  const { AFFIXES, ILVL_MAX } = await import('../../src/gameplay/affixRules.ts');
  const costs = (u: { maxTier: number; cost: (t: number) => number }) => Array.from({ length: u.maxTier + 1 }, (_, t) => u.cost(t));
  const areaIds = Object.keys(AREAS);
  const discIds = Object.keys(DISCIPLINES);
  const families = [...new Set(Object.values(DISCIPLINES).map((d) => (d as { family: string }).family))];
  const computed: Record<string, unknown> = {
    // smartLoot.smartTable(area, discipline) for every area x discipline
    smartTables: Object.fromEntries(areaIds.map((a) => [a, Object.fromEntries(discIds.map((d) => [d, smartTable(a as never, d)]))])),
    kits: Object.fromEntries(families.map((f) => [f, kitFor(f as never)])),
    abilityUnlockLevels: Object.fromEntries(Object.keys(ABILITIES).map((a) => [a, unlockLevel(a as never)])),
    depthRosters: Object.fromEntries(Array.from({ length: 60 }, (_, i) => [i + 1, depthRoster(i + 1)])),
    depthLootAreas: Object.fromEntries(Array.from({ length: 60 }, (_, i) => [i + 1, depthLootArea(i + 1)])),
    depthChestRunePools: Object.fromEntries(Array.from({ length: 60 }, (_, i) => [i + 1, chestRunePool(i + 1)])),
    armorLootByArea: Object.fromEntries(areaIds.map((a) => [a, armorLoot(a as never)])),
    necroWeaponLootByArea: Object.fromEntries(areaIds.map((a) => [a, necroWeaponLoot(a as never)])),
    brewSummaries: Object.fromEntries(Object.keys((await import('../../src/content/brews.ts')).BREWS).map((b) => [b, brewSummary(b)])),
    // cost(tier) for tier 0..maxTier (the TS is Math.round(base * ratio^tier)); upgrades.json holds base data
    upgradeCosts: { damage: costs(DAMAGE_UPGRADE), wave: costs(WAVE_UPGRADE), legion: costs(LEGION_UPGRADE) },
    // AFFIXES[i].range(ilvl) for ilvl 1..ILVL_MAX, indexed by ilvl-1: [min, max]
    affixRanges: Object.fromEntries(AFFIXES.map((a) => [a.id, Array.from({ length: ILVL_MAX }, (_, i) => a.range(i + 1))])),
    allClipNames: allClipNames(),
    areaOrder: AREA_ORDER,
    itemIds: Object.keys(ITEMS),
    itemMetaSample: itemMeta('definitely_not_an_item'),
    worldLayout1337: generateLayout(1337),
  };
  files['computed'] = exportNamespace(computed, 'computed');

  // ---- write ----
  mkdirSync(OUT, { recursive: true });
  for (const f of readdirSync(OUT)) if (f.endsWith('.json')) rmSync(resolve(OUT, f));
  const manifest: Record<string, Json> = {};
  let totalBytes = 0;
  for (const name of Object.keys(files).sort()) {
    const body = JSON.stringify(files[name], null, 1) + '\n';
    writeFileSync(resolve(OUT, `${name}.json`), body);
    totalBytes += body.length;
    manifest[name] = { keys: Object.keys(files[name]).length, counts: Object.fromEntries(Object.entries(files[name]).map(([k, v]) => [k, count(v)])) };
  }
  const sha = execSync('git rev-parse HEAD').toString().trim();
  const srcTree = execSync('git rev-parse HEAD:src').toString().trim();
  const summary = {
    items: count(files['items'].ITEMS), enemies: count(files['enemies'].ENEMIES), areas: count(files['areas'].AREAS),
    abilities: count(files['abilities'].ABILITIES), disciplines: count(files['disciplines'].DISCIPLINES),
  };
  writeFileSync(resolve(OUT, 'manifest.json'), JSON.stringify({
    sourceSha: sha, sourceSrcTree: srcTree, files: manifest, summary,
    droppedFunctions: dropped.length, droppedPaths: dropped.filter((p) => p.split('.').length > 2 || /\.[A-Z_0-9]+/.test(p)), warnings,
  }, null, 1) + '\n');
  console.log(`wrote ${Object.keys(files).length} files, ${(totalBytes / 1e6).toFixed(2)} MB; dropped ${dropped.length} functions; warnings ${warnings.length}`);
  for (const w of warnings.slice(0, 30)) console.log('  warn:', w);
  console.log(summary);
}
main().catch((e) => { console.error(e); process.exit(1); });
