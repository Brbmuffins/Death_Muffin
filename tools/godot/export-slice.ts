/**
 * Death Muffin -> Godot data export. Imports the REAL game modules and writes JSON into godot/data/.
 * Godot loads these at runtime; nothing is hand-copied. Run: npx vite-node tools/godot/export-slice.ts
 * Slice = the Chapterhouse + the Hollow Graves + the door between them (area ids in SLICE below).
 */
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AREAS, DOORS, PLAYER_SPAWN, CHAPTERHOUSE_RETURN, type AreaId, type Rect } from '../../src/content/areas';
import { generateLayout, PROPS, wallObstacle, placementObstacle, NODE_COLLIDER, type WallSegment } from '../../src/content/layout';
import { ENEMIES, type EnemyId } from '../../src/content/enemies';
import { DISCIPLINES } from '../../src/content/disciplines';
import { ABILITIES } from '../../src/content/abilities';
import { CREATURE_MODELS, PROP_URL } from '../../src/graphics/modelPaths';
import { deriveStats, STAT_EFFECTS } from '../../src/gameplay/characterStats';
import { ITEMS } from '../../src/content/items';
import { NODES } from '../../src/gameplay/gatheringRules';
import CLIP_TIMINGS from '../../src/content/clipTimings.json';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = resolve(ROOT, 'godot/data/slice');
mkdirSync(OUT, { recursive: true });
const write = (name: string, data: unknown) => writeFileSync(resolve(OUT, name), JSON.stringify(data, null, 1) + '\n');

const SLICE: AreaId[] = ['chapterhouse', 'graves'];
const inSlice = (a: AreaId) => SLICE.includes(a);
const THEME_FLOOR: Record<string, { tex: string; tile: number; color: number; rough: number; glow?: number }> = {
  chapter: { tex: 'flagstone', tile: 7, color: 0x9a92a8, rough: 0.62 },
  graveyard: { tex: 'grave_soil', tile: 6, color: 0xb8aab8, rough: 0.95 },
  nave: { tex: 'flagstone', tile: 8, color: 0x8c86a8, rough: 0.45 }, // flagstone paths over the earth
};
const WALL_COLOR: Record<string, number> = { stone_wall: 0x9a92a4, skull_wall: 0xc2b8ae, wing_wall: 0xd8ccb8 };

const layout = generateLayout();

// --- Doors of the slice: chapter_graves is open; every other door out of the slice is sealed by a gate wall ---
const doors = DOORS.filter((d) => inSlice(d.a) || inSlice(d.b));
const openDoor = doors.find((d) => d.id === 'chapter_graves')!;
const walls: (WallSegment & { kind?: string })[] = layout.walls.filter((w) => inSlice(w.area));
const T = 0.8;
for (const d of doors) {
  if (d === openDoor) continue;
  const area = inSlice(d.a) ? d.a : d.b;
  const r = AREAS[area].rect;
  // The gap sits on one edge of the slice room; put a gate wall in it (placeholder for the web's portcullis gates).
  if (d.axis === 'x') {
    const east = Math.abs(d.rect.x0 - r.x1) < Math.abs(d.rect.x1 - r.x0 + 0) && Math.abs(d.rect.x0 - r.x1) < 6;
    const fixed = east ? r.x1 + T / 2 : r.x0 - T / 2;
    walls.push({ x0: fixed, z0: d.rect.z0 + 1, x1: fixed, z1: d.rect.z1 - 1, height: 2.6, thickness: T, texture: 'stone_wall', area, kind: 'gate' });
  } else {
    const south = Math.abs(d.rect.z0 - r.z1) < 6 && Math.abs(d.rect.z0 - r.z1) < Math.abs(d.rect.z1 - r.z0);
    const fixed = south ? r.z1 + T / 2 : r.z0 - T / 2;
    walls.push({ x0: d.rect.x0 + 1, z0: fixed, x1: d.rect.x1 - 1, z1: fixed, height: 2.6, thickness: T, texture: 'stone_wall', area, kind: 'gate' });
  }
}
// The open door's corridor (between the rooms) needs side walls so bodies stay in it (the web nav bounds it by the walkable union).
{
  const gap = { z0: AREAS.graves.rect.z1, z1: AREAS.chapterhouse.rect.z0 };
  const dr = openDoor.rect;
  const edgeX = [dr.x0 + 0, dr.x1 - 0];
  for (const x of edgeX) walls.push({ x0: x, z0: gap.z0, x1: x, z1: gap.z1, height: 1.3, thickness: 0.3, texture: 'stone_wall', area: 'graves', kind: 'doorside' });
}

const wallsOut = walls.map((w) => ({ ...w, color: WALL_COLOR[w.texture], box: wallObstacle(w) }));
const props = layout.props.filter((p) => inSlice(p.area)).map((p) => {
  const spec = PROPS[p.prop];
  return { prop: p.prop, x: p.x, z: p.z, rot: p.rot, scale: p.scale, y: p.y ?? 0, tilt: p.tilt ?? 0, area: p.area, group: p.group ?? null, obstacle: placementObstacle(p) };
});
const usedProps = [...new Set(props.map((p) => p.prop))].sort();
const propSpecs = Object.fromEntries(usedProps.map((id) => [id, { ...PROPS[id], url: PROP_URL(id) }]));
const nodes = layout.nodes.filter((n) => inSlice(n.area)).map((n) => {
  const def = (NODES as Record<string, { kind?: string; name?: string }>)[n.type];
  const kind = def?.kind ?? 'tree';
  // NodeViews.ts MODEL map (module-private; mirrored for the two node types the slice's rich nodes use: keep in sync).
  const nm = n.type === 'coffin_oak' ? { model: 'prop_node_coffin_oak', height: 4.4 } : { model: 'prop_node_burial_mound', height: 0.6 };
  return { ...n, kind, collider: (NODE_COLLIDER as Record<string, number>)[kind] ?? 0.5, name: def?.name ?? n.type, model: PROP_URL(nm.model), modelHeight: nm.height };
});
const rectsOverlap = (a: Rect, b: Rect) => a.x0 < b.x1 && a.x1 > b.x0 && a.z0 < b.z1 && a.z1 > b.z0;
const paths = layout.paths.filter((p) => SLICE.some((a) => rectsOverlap(p, AREAS[a].rect)));
const decals = layout.decals.filter((d) => inSlice(d.area));
const puddles = layout.puddles.filter((p) => inSlice(p.area));
const crypts = layout.crypts.filter((c) => inSlice(c.area));
const colorHex = (n: number) => '#' + n.toString(16).padStart(6, '0');

// --- Enemies of the Graves (the waves' roster) ---
const graves = AREAS.graves;
const GODOT_ENEMIES = ['robber', 'hound', 'penitent', 'sac', 'ghoul'] as EnemyId[]; // rigged GLBs only; moth/bat are static flapping meshes (not in this slice)
const skipped = graves.enemies.filter((e) => !GODOT_ENEMIES.includes(e.id)).map((e) => e.id);
const glbJson = (url: string) => {
  const d = readFileSync(resolve(ROOT, 'public', url));
  const len = d.readUInt32LE(12);
  return JSON.parse(d.subarray(20, 20 + len).toString('utf8'));
};
const RIG_YAW: Record<string, number> = { bone_hound: Math.PI, cinderhound: Math.PI };
/** Same rule as Creature.ts: heroes -90deg; a biped (has a Hip bone) -90deg; named overrides; else 0. */
function yawFor(slug: string, hero = false) {
  if (hero) return -Math.PI / 2;
  if (RIG_YAW[slug] !== undefined) return RIG_YAW[slug];
  const nodes: { name?: string }[] = glbJson(`models/${slug}/character.glb`).nodes;
  return nodes.some((n) => n.name === 'Hip') ? -Math.PI / 2 : 0;
}
const modelEntry = (slug: keyof typeof CREATURE_MODELS, hero = false) => {
  const m = CREATURE_MODELS[slug];
  const j = glbJson(m.url);
  return { slug, url: m.url, height: m.height, yaw: yawFor(slug, hero), clips: (j.animations ?? []).map((a: { name: string }) => a.name), timings: (CLIP_TIMINGS as Record<string, unknown>)[slug] ?? {} };
};
const SLUG_OF: Record<string, keyof typeof CREATURE_MODELS> = { robber: 'grave_robber', hound: 'bone_hound', penitent: 'penitent', sac: 'carrion_sac', ghoul: 'barrow_ghoul' };
const enemyDefs = Object.fromEntries(GODOT_ENEMIES.map((id) => [id, { ...ENEMIES[id], model: SLUG_OF[id] }]));

// --- Hero: the Ossuary necromancer, level 1, base stats 5 (placeholder for a real character's stats) ---
const disc = DISCIPLINES.ossuary;
const character = { id: 0, class_index: disc.classIndex, class_name: '', level: 1, experience: 0, gold: 0, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 } as never;
const stats = deriveStats(character, [], disc, 0);
const THRALL_BASE_SHIELDBEARER = { range: 1.3, interval: 1.25, speed: 5.2 }; // WorldSim.ts THRALL_BASE.shieldbearer (module-private, mirrored here: keep in sync)
const heroModel = disc.modelSlug;
const hero = {
  discipline: { id: disc.id, name: disc.name, family: disc.family, thrallKind: disc.mods.thrallKind, thrallCap: disc.mods.thrallCap, wardPerThrall: disc.mods.wardPerThrall },
  derivedStats: stats,
  statEffects: STAT_EFFECTS,
  baseStatsAssumed: { str: 5, agi: 5, int: 5, vit: 5, level: 1 },
  abilities: { bone_needle: ABILITIES.bone_needle, exhume: ABILITIES.exhume, marrow_spear: ABILITIES.marrow_spear },
  thrall: { model: 'thrall_sentinel', ...THRALL_BASE_SHIELDBEARER, hp: stats.thrallHp, damage: stats.thrallDamage, scaleHeight: CREATURE_MODELS.thrall_sentinel.height },
  model: modelEntry(heroModel, true),
  thrall_model: modelEntry('thrall_sentinel'),
};

// --- Loot ids (display only in this slice; the drops are shown as floating text) ---
const loot = graves.loot.map((l) => ({ item: l.item, weight: l.weight, name: ITEMS[l.item]?.name ?? l.item, rarity: ITEMS[l.item]?.rarity ?? 'common' }));

const spawn = { playerSpawnWeb: PLAYER_SPAWN, chapterhouseReturn: CHAPTERHOUSE_RETURN };
const world = {
  seed: 1337,
  slice: SLICE,
  areas: Object.fromEntries(SLICE.map((id) => {
    const a = AREAS[id];
    return [id, { id, name: a.name, subtitle: a.subtitle, theme: a.theme, rect: a.rect, safe: a.safe, level: a.level, ambient: { fog: colorHex(a.ambient.fog), hemiSky: colorHex(a.ambient.hemiSky), hemiGround: colorHex(a.ambient.hemiGround), moon: colorHex(a.ambient.moon), fogMult: a.ambient.fogMult ?? 1 }, breaches: a.breaches, interactables: a.interactables.filter((i) => i.kind !== 'npc'), cap: a.cap, waveSize: a.waveSize, waveIntervalMs: a.waveIntervalMs, eliteChance: a.eliteChance, enemies: a.enemies }];
  })),
  doors: doors.map((d) => ({ id: d.id, a: d.a, b: d.b, rect: d.rect, axis: d.axis, open: d === openDoor })),
  spawn,
  floors: THEME_FLOOR,
  lighting: { // WorldScene.buildScene: hemi 0.95, moon 2.4 (offset -14,30,12), rim 1.6 violet (6,10,-24), FogExp2 0.014, ACES exposure 1.2, bg 0x07060a
    background: '#07060a', fogDensity: 0.014, hemiIntensity: 0.95, moonIntensity: 2.4, moonOffset: { x: -14, y: 30, z: 12 }, rimColor: '#7a5cd6', rimIntensity: 1.6, rimOffset: { x: 6, y: 10, z: -24 }, exposure: 1.2,
  },
  camera: { fov: 40, near: 0.5, far: 260, dist: 22, heightFactor: 0.82, backFactor: 0.6, lookAtY: 0.6, lookAheadZ: -1.5, zoomMin: 0.7, zoomMax: 1.45, followRate: 7 },
  walls: wallsOut,
  props,
  propSpecs,
  nodes,
  paths,
  decals: decals.map((d) => ({ ...d, color: colorHex(d.color) })),
  puddles,
  crypts,
  loot,
  skippedEnemyIds: skipped,
};
write('world.json', world);
const enemyModels = Object.fromEntries([...new Set(Object.values(enemyDefs).map((d) => d.model))].map((m) => [m, modelEntry(m as keyof typeof CREATURE_MODELS)]));
write('enemies.json', { roster: graves.enemies.filter((e) => GODOT_ENEMIES.includes(e.id)), defs: enemyDefs, models: enemyModels });
write('hero.json', hero);

// --- Asset record: which GLBs/textures the slice uses (consumed by tools/godot/sync-assets.sh) ---
const models = new Set<string>();
for (const id of usedProps) models.add(PROP_URL(id));
for (const n of nodes) if (existsSync(resolve(ROOT, 'public', n.model))) models.add(n.model);
for (const e of Object.values(enemyDefs)) models.add(CREATURE_MODELS[e.model as keyof typeof CREATURE_MODELS].url);
models.add(hero.model.url);
models.add(CREATURE_MODELS.thrall_sentinel.url);
const textures = ['flagstone', 'grave_soil', 'stone_wall'].map((t) => `art/textures/${t}.webp`);
write('assets_used.json', { models: [...models].sort(), textures });
console.log(`export ok: ${props.length} props (${usedProps.length} kinds), ${wallsOut.length} walls, ${nodes.length} nodes, ${models.size} models, enemies ${GODOT_ENEMIES.join(',')}, skipped ${skipped.join(',')}`);
