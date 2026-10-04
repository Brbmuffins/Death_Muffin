/**
 * Death Muffin -> Godot data export. Imports the REAL game modules and writes JSON into godot/data/slice/.
 * Godot loads these at runtime; nothing is hand-copied. Run: npx vite-node tools/godot/export-slice.ts
 *
 * Wave 2: the WHOLE connected world (every area of AREAS, every door/gate, the Depths' sample floor), all creature/boss/NPC models and every
 * prop/node model the layout uses. The output folder keeps its wave-1 name (godot/data/slice/, assets in godot/assets/slice/) so no other
 * track's paths move; read it as "the world".
 */
import { mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AREAS, AREA_ORDER, DOORS, PLAYER_SPAWN, CHAPTERHOUSE_RETURN, DEPTHS_STAIR, isAlwaysOpen, doorTarget, type AreaId, type Rect } from '../../src/content/areas';
import { generateLayout, PROPS, WING_FLOOR, wallObstacle, placementObstacle, NODE_COLLIDER, type WallSegment } from '../../src/content/layout';
import { ENEMIES, type EnemyId } from '../../src/content/enemies';
import { BOSSES } from '../../src/content/bosses';
import { NPCS, NPC_IDS } from '../../src/content/npcs';
import { DISCIPLINES } from '../../src/content/disciplines';
import { ABILITIES } from '../../src/content/abilities';
import { CREATURE_MODELS, PROP_URL } from '../../src/graphics/modelPaths';
import { deriveStats, STAT_EFFECTS } from '../../src/gameplay/characterStats';
import { ITEMS } from '../../src/content/items';
import { NODES } from '../../src/gameplay/gatheringRules';
import { FEN_HUMMOCKS, FEN_BOG } from '../../src/content/fen';
import { generateFloor, floorSeed, FLOOR_WALL_H, STAIR_R, CHEST_R } from '../../src/gameplay/depthsFloor';
import { STRIDES } from '../../src/graphics/locomotion';
import CLIP_TIMINGS from '../../src/content/clipTimings.json';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = resolve(ROOT, 'godot/data/slice');
mkdirSync(OUT, { recursive: true });
const write = (name: string, data: unknown) => writeFileSync(resolve(OUT, name), JSON.stringify(data) + '\n');
const src = (rel: string) => readFileSync(resolve(ROOT, rel), 'utf8');

/** Constants that are module-private in the TS are mirrored below; each mirror is verified against the source text so drift fails loudly. */
function mirrorCheck(file: string, snippets: string[]) {
  const text = src(file);
  const bad = snippets.filter((s) => !text.includes(s));
  if (bad.length) throw new Error(`mirror drift in ${file}: ${bad.join(' | ')}`);
}

const THEME_FLOOR: Record<string, { tex: string; tile: number; color: number; rough: number; glow?: number }> = {
  chapter: { tex: 'flagstone', tile: 7, color: 0x9a92a8, rough: 0.62 },
  acre: { tex: 'grave_soil', tile: 5, color: 0xe6f0d4, rough: 0.97, glow: 0x4a5a3c },
  graveyard: { tex: 'grave_soil', tile: 6, color: 0xb8aab8, rough: 0.95 },
  ossuary: { tex: 'ossuary_floor', tile: 6, color: 0xb0a4ae, rough: 0.9 },
  nave: { tex: 'flagstone', tile: 8, color: 0x8c86a8, rough: 0.45 },
  sanctum: { tex: 'flagstone', tile: 7, color: 0x9a86aa, rough: 0.5 },
  cloister: { tex: 'cloister_floor', tile: 6, color: 0xa8b4a0, rough: 0.8 },
  warren: { tex: 'warren_floor', tile: 6, color: 0xb8ac98, rough: 0.9 },
  depths: { tex: 'warren_floor', tile: 6, color: 0x8a8070, rough: 0.9 },
  coliseum: { tex: 'coliseum_floor', tile: 7, color: 0xc8bca8, rough: 0.9 },
  pyre: { tex: 'pyre_floor', tile: 6, color: 0xd8b498, rough: 0.85 },
  fen: { tex: 'fen_floor', tile: 6, color: 0xa8c0bc, rough: 0.8 },
  wing: { tex: 'wing_floor', tile: 6, color: 0xe8dcc8, rough: 0.75 },
};
mirrorCheck('src/graphics/WorldView.ts', Object.entries(THEME_FLOOR).map(([k, f]) => `${k}: { url: 'art/textures/${f.tex}.webp', tile: ${f.tile}, color: 0x${f.color.toString(16)}, rough: ${f.rough}${f.glow ? `, glow: 0x${f.glow.toString(16)}` : ''} }`));
const WALL_COLOR: Record<string, number> = { stone_wall: 0x9a92a4, skull_wall: 0xc2b8ae, wing_wall: 0xd8ccb8 };
mirrorCheck('src/graphics/WorldView.ts', ["tex === 'skull_wall' ? 0xc2b8ae : tex === 'wing_wall' ? 0xd8ccb8 : 0x9a92a4"]);

const layout = generateLayout();
const colorHex = (n: number) => '#' + n.toString(16).padStart(6, '0');
const rectsOverlap = (a: Rect, b: Rect) => a.x0 < b.x1 && a.x1 > b.x0 && a.z0 < b.z1 && a.z1 > b.z0;

// ---------------------------------------------------------------- doors, gates, corridor side walls
// Walkable space in the web is the union of unlocked area rects and open door rects (Nav.walkables); the sealed door is a portcullis.
// The Godot hero is a physics body, so corridors also get low side walls (the web only needs the nav), and a closed door a gate collider.
const walls: (WallSegment & { kind?: string })[] = layout.walls.map((w) => ({ ...w }));
const doors = DOORS.map((d) => {
  const ra = AREAS[d.a].rect;
  const rb = AREAS[d.b].rect;
  const cx = (d.rect.x0 + d.rect.x1) / 2;
  const cz = (d.rect.z0 + d.rect.z1) / 2;
  const width = d.axis === 'z' ? d.rect.x1 - d.rect.x0 : d.rect.z1 - d.rect.z0;
  // The corridor between the two rooms (door rects overlap each room by a metre; the walls' gap is exactly the door's width).
  if (d.axis === 'z') {
    const zs = [ra.z0, ra.z1, rb.z0, rb.z1].sort((a, b) => a - b);
    for (const x of [d.rect.x0, d.rect.x1]) walls.push({ x0: x, z0: zs[1], x1: x, z1: zs[2], height: 1.3, thickness: 0.3, texture: 'stone_wall', area: d.a, kind: 'doorside' });
  } else {
    const xs = [ra.x0, ra.x1, rb.x0, rb.x1].sort((a, b) => a - b);
    for (const z of [d.rect.z0, d.rect.z1]) walls.push({ x0: xs[1], z0: z, x1: xs[2], z1: z, height: 1.3, thickness: 0.3, texture: 'stone_wall', area: d.a, kind: 'doorside' });
  }
  return { id: d.id, a: d.a, b: d.b, rect: d.rect, axis: d.axis, cx, cz, width, target: doorTarget(d), open: isAlwaysOpen(d.a) && isAlwaysOpen(d.b) };
});
const wallsOut = walls.map((w) => ({ ...w, color: WALL_COLOR[w.texture], box: wallObstacle(w) }));

// ---------------------------------------------------------------- props / nodes
const props = layout.props.map((p) => ({ prop: p.prop, x: p.x, z: p.z, rot: p.rot, scale: p.scale, y: p.y ?? 0, tilt: p.tilt ?? 0, area: p.area, group: p.group ?? null, obstacle: placementObstacle(p) }));

// The Catacomb Depths: a per-run generated floor (gameplay/depthsFloor.ts). The world carries one sample floor (run seed 1337, depth 1) so the
// instance has a real, walkable interior to look at; generating floors per run is the sim track's job.
const df = generateFloor(floorSeed(1337, 1), 1);
const depths = {
  seed: df.seed, depth: df.depth, rect: df.rect, wallHeight: FLOOR_WALL_H, stairR: STAIR_R, chestR: CHEST_R,
  rooms: df.rooms.map((r) => ({ id: r.id, rect: r.rect, active: r.active, kind: r.kind, cx: r.cx, cz: r.cz })),
  doors: df.doors, stairUp: df.stairUp, stairDown: df.stairDown, start: df.start, chest: df.chest, breaches: df.breaches,
  walls: df.walls.map((w) => ({ ...w, color: WALL_COLOR[w.texture], box: wallObstacle(w) })),
  props: df.props.map((p) => ({ prop: p.prop, x: p.x, z: p.z, rot: p.rot, scale: p.scale, y: p.y ?? 0, tilt: p.tilt ?? 0, area: p.area, group: p.group ?? null, obstacle: placementObstacle(p) })),
  stairWeb: DEPTHS_STAIR,
};

const usedProps = [...new Set([...props, ...depths.props].map((p) => p.prop))].sort();
const publicHas = (url: string) => existsSync(resolve(ROOT, 'public', url));
const missingProps = usedProps.filter((id) => !publicHas(PROP_URL(id)));
const propSpecs = Object.fromEntries(usedProps.map((id) => [id, { ...PROPS[id], url: publicHas(PROP_URL(id)) ? PROP_URL(id) : null }]));

// NodeViews.ts MODEL map is module-private: mirrored here and verified against the source.
const NODE_MODEL: Record<string, { live?: string; spent?: string; height: number; spentHeight: number }> = {
  coffin_oak: { live: 'prop_node_coffin_oak', spent: 'prop_node_stump', height: 4.4, spentHeight: 0.9 },
  hangman_elm: { live: 'prop_node_hangman_elm', spent: 'prop_node_stump', height: 5, spentHeight: 0.9 },
  bleeding_willow: { live: 'prop_node_bleeding_willow', spent: 'prop_node_stump', height: 4.8, spentHeight: 0.9 },
  churchyard_yew: { live: 'prop_node_churchyard_yew', spent: 'prop_node_stump', height: 5.4, spentHeight: 1 },
  blackthorn: { live: 'prop_node_blackthorn', spent: 'prop_node_stump', height: 4.6, spentHeight: 0.9 },
  ghostwood: { live: 'prop_node_ghostwood', spent: 'prop_node_stump', height: 5.2, spentHeight: 1 },
  bone_elder: { live: 'prop_node_bone_elder', spent: 'prop_node_stump', height: 6, spentHeight: 1.1 },
  geode_hell: { live: 'prop_node_ore_geode', spent: 'prop_node_ore_spent', height: 1.5, spentHeight: 0.6 },
  geode_moon: { live: 'prop_node_ore_geode', spent: 'prop_node_ore_spent', height: 1.6, spentHeight: 0.6 },
  grave_crypt: { live: 'prop_node_crypt_collapse', spent: 'prop_node_dug_grave', height: 1.2, spentHeight: 0.5 },
  grave_barrow_king: { live: 'prop_node_barrow_tomb', spent: 'prop_node_dug_grave', height: 2, spentHeight: 0.5 },
};
mirrorCheck('src/graphics/NodeViews.ts', Object.entries(NODE_MODEL).map(([k, m]) => `${k}: { live: '${m.live}', spent: '${m.spent}', height: ${m.height}, spentHeight: ${m.spentHeight} }`));
mirrorCheck('src/graphics/NodeViews.ts', [
  "const seamModel = { live: 'prop_node_ore_seam', spent: 'prop_node_ore_spent', height: 1.2, spentHeight: 0.6 };",
  "const graveModel = { live: 'prop_node_burial_mound', spent: 'prop_node_dug_grave', height: 0.6, spentHeight: 0.5 };",
]);
const nodeModelFor = (type: string, kind: string) => NODE_MODEL[type] ?? (kind === 'seam' ? { live: 'prop_node_ore_seam', spent: 'prop_node_ore_spent', height: 1.2, spentHeight: 0.6 } : kind === 'grave' ? { live: 'prop_node_burial_mound', spent: 'prop_node_dug_grave', height: 0.6, spentHeight: 0.5 } : { height: 1, spentHeight: 0.5 });
const nodes = layout.nodes.map((n) => {
  const def = NODES[n.type];
  const kind = def.kind;
  const nm = nodeModelFor(n.type, kind);
  const liveUrl = nm.live && publicHas(PROP_URL(nm.live)) ? PROP_URL(nm.live) : null;
  const spentUrl = nm.spent && publicHas(PROP_URL(nm.spent)) ? PROP_URL(nm.spent) : null;
  return { ...n, kind, collider: (NODE_COLLIDER as Record<string, number>)[kind] ?? 0.5, name: def.name, level: def.level, tint: colorHex(def.tint), model: liveUrl, modelHeight: nm.height, spentModel: spentUrl, spentHeight: nm.spentHeight };
});

const paths = layout.paths;
const decals = layout.decals.map((d) => ({ ...d, color: colorHex(d.color) }));
const crypts = layout.crypts;
const wingFloor = WING_FLOOR.map((f) => ({ ...f, color: colorHex(f.color), alt: f.alt === undefined ? null : colorHex(f.alt) }));

// ---------------------------------------------------------------- creatures
const glbJson = (url: string) => {
  const d = readFileSync(resolve(ROOT, 'public', url));
  const len = d.readUInt32LE(12);
  return JSON.parse(d.subarray(20, 20 + len).toString('utf8'));
};
const RIG_YAW: Record<string, number> = { bone_hound: Math.PI, cinderhound: Math.PI };
mirrorCheck('src/graphics/Creature.ts', ['const RIG_YAW: Partial<Record<string, number>> = { bone_hound: Math.PI, cinderhound: Math.PI };']);
/** Same rule as Creature.ts: heroes -90deg; a biped (has a Hip bone) -90deg; named overrides; else 0. */
function yawFor(slug: string, hero = false) {
  if (hero) return -Math.PI / 2;
  if (RIG_YAW[slug] !== undefined) return RIG_YAW[slug];
  const nodes: { name?: string }[] = glbJson(`models/${slug}/character.glb`).nodes;
  return nodes.some((n) => n.name === 'Hip') ? -Math.PI / 2 : 0;
}
type Slug = keyof typeof CREATURE_MODELS;
const modelEntry = (slug: Slug, hero = false) => {
  const m = CREATURE_MODELS[slug];
  const isRigged = m.url.endsWith('/character.glb');
  const j = glbJson(m.url);
  return {
    slug, url: m.url, height: m.height, rigged: isRigged, yaw: isRigged ? yawFor(slug, hero) : 0,
    clips: (j.animations ?? []).map((a: { name: string }) => a.name),
    timings: (CLIP_TIMINGS as Record<string, unknown>)[slug] ?? {},
    stride: (STRIDES as Record<string, unknown>)[slug] ?? null,
  };
};
// EntityViews.ts: ENEMY_SLUG is module-private, but every EnemyDef carries modelSlug; this checks they agree where both exist.
const enemyIds = Object.keys(ENEMIES) as EnemyId[];
const CASTERS = ['penitent', 'deacon', 'wraith', 'censer', 'moth', 'seraph', 'acolyte', 'plague_doctor', 'pyre_priest', 'bog_hag', 'fen_wisp'];
mirrorCheck('src/graphics/EntityViews.ts', [`const CASTERS = new Set<EnemyId>([${CASTERS.map((c) => `'${c}'`).join(', ')}]);`, 'const HOVER = { wraith: 0.45 } as Partial<Record<EnemyId, number>>;']);
// EntityViews.ts ENEMY_SLUG (module-private; EnemyDef.modelSlug is optional and missing for the three oldest enemies): mirrored and verified.
const ENEMY_SLUG: Record<string, string> = {
  robber: 'grave_robber', hound: 'bone_hound', penitent: 'penitent', sac: 'carrion_sac', deacon: 'deacon', risen: 'skeleton_thrall', censer: 'censer_bearer', wraith: 'choir_wraith', rat: 'skull_rat',
  golem: 'bone_golem', gargoyle: 'belfry_gargoyle', moth: 'shroud_moth', bat: 'tithe_bat', seraph: 'weeping_seraph', ghoul: 'barrow_ghoul', acolyte: 'lich_acolyte', templar: 'bell_templar', niche: 'skull_niche',
  plague_doctor: 'plague_doctor', flagellant: 'flagellant', cinder_husk: 'cinder_husk', pyre_priest: 'pyre_priest', cinderhound: 'cinderhound', slag_brute: 'slag_brute', bog_hag: 'bog_hag',
  mire_leech: 'mire_leech', fen_wisp: 'fen_wisp', drowned_sexton: 'drowned_sexton',
};
mirrorCheck('src/graphics/EntityViews.ts', Object.entries(ENEMY_SLUG).map(([k, v]) => `  ${k}: '${v}',`));
const slugOf = (id: EnemyId) => ENEMIES[id].modelSlug ?? ENEMY_SLUG[id];
const enemyDefs = Object.fromEntries(enemyIds.map((id) => [id, { ...ENEMIES[id], model: slugOf(id), caster: CASTERS.includes(id), hover: id === 'wraith' ? 0.45 : 0 }]));
const modelsForEnemies = Object.fromEntries([...new Set(enemyIds.map((id) => slugOf(id)))].map((m) => [m, modelEntry(m as Slug)]));
const bosses = Object.fromEntries(Object.values(BOSSES).map((b) => [b.id, { id: b.id, name: b.name, title: b.title, area: b.area, arena: b.arena, summonId: b.summonId, model: b.modelSlug, color: colorHex(b.color) }]));
const bossModels = Object.fromEntries(Object.values(BOSSES).map((b) => [b.modelSlug, modelEntry(b.modelSlug as Slug)]));
const npcModels = Object.fromEntries(NPC_IDS.map((n) => [`npc_${n}`, modelEntry(`npc_${n}` as Slug)]));
const npcs = NPC_IDS.map((n) => ({ id: n, name: NPCS[n].name, title: NPCS[n].title, area: NPCS[n].area, x: NPCS[n].x, z: NPCS[n].z, rest: NPCS[n].rest, model: `npc_${n}`, accent: colorHex(NPCS[n].accent) }));

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
const heroModels = Object.fromEntries((Object.keys(CREATURE_MODELS) as Slug[]).filter((s) => s.startsWith('hero_') || s === 'necromancer').map((s) => [s, modelEntry(s, true)]));

// --- Loot (display only: drops show as floating text) ---
const lootFor = (id: AreaId) => AREAS[id].loot.map((l) => ({ item: l.item, weight: l.weight, name: ITEMS[l.item]?.name ?? l.item, rarity: ITEMS[l.item]?.rarity ?? 'common' }));

const spawn = { playerSpawnWeb: PLAYER_SPAWN, chapterhouseReturn: CHAPTERHOUSE_RETURN };
const world = {
  seed: 1337,
  order: AREA_ORDER,
  areas: Object.fromEntries(AREA_ORDER.map((id) => {
    const a = AREAS[id];
    return [id, {
      id, name: a.name, subtitle: a.subtitle, theme: a.theme, rect: a.rect, safe: a.safe, level: a.level, instance: !!a.instance, unlock: a.unlock ?? null,
      ambient: { fog: colorHex(a.ambient.fog), hemiSky: colorHex(a.ambient.hemiSky), hemiGround: colorHex(a.ambient.hemiGround), moon: colorHex(a.ambient.moon), fogMult: a.ambient.fogMult ?? 1 },
      breaches: a.breaches, interactables: a.interactables, cap: a.cap, waveSize: a.waveSize, waveIntervalMs: a.waveIntervalMs, eliteChance: a.eliteChance, enemies: a.enemies, loot: lootFor(id), itemChance: a.itemChance,
    }];
  })),
  doors,
  spawn,
  floors: THEME_FLOOR,
  lighting: { // WorldScene.buildScene: hemi 0.95, moon 2.4 (offset -14,30,12), rim 1.6 violet (6,10,-24), FogExp2 0.014, ACES exposure 1.2 (GameRuntime), bg 0x07060a
    background: '#07060a', fogDensity: 0.014, hemiIntensity: 0.95, moonIntensity: 2.4, moonOffset: { x: -14, y: 30, z: 12 }, rimColor: '#7a5cd6', rimIntensity: 1.6, rimOffset: { x: 6, y: 10, z: -24 }, exposure: 1.2,
  },
  camera: { fov: 40, near: 0.5, far: 260, dist: 22, heightFactor: 0.82, backFactor: 0.6, lookAtY: 0.6, lookAheadZ: -1.5, zoomMin: 0.7, zoomMax: 1.45, followRate: 7 },
  walls: wallsOut,
  props,
  propSpecs,
  nodes,
  paths,
  decals,
  puddles: layout.puddles,
  crypts,
  water: layout.water,
  bog: FEN_BOG,
  ponds: layout.ponds,
  hummocks: FEN_HUMMOCKS,
  wingFloor,
  depths,
  npcs,
  missingPropModels: missingProps,
};
mirrorCheck('src/scenes/WorldScene.ts', ['new THREE.HemisphereLight(0x4a3866, 0x0a0710, 0.95)', 'new THREE.DirectionalLight(0x9aa6d4, 2.4)', 'new THREE.DirectionalLight(0x7a5cd6, 1.6)', 'new THREE.FogExp2(0x0b0810, 0.014)']);
mirrorCheck('src/app/GameRuntime.ts', ['renderer.toneMapping = THREE.ACESFilmicToneMapping;', 'renderer.toneMappingExposure = 1.2;']);
write('world.json', world);
write('enemies.json', { defs: enemyDefs, models: { ...modelsForEnemies, ...bossModels }, bosses });
write('npcs.json', { npcs, models: npcModels, heroModels });
write('hero.json', hero);

// --- Asset record: which GLBs/textures the world uses (consumed by tools/godot/sync-slice-assets.mjs) ---
const models = new Set<string>();
for (const id of usedProps) if (propSpecs[id].url) models.add(propSpecs[id].url as string);
for (const n of nodes) {
  if (n.model) models.add(n.model);
  if (n.spentModel) models.add(n.spentModel);
}
for (const m of Object.values(CREATURE_MODELS)) models.add(m.url);
const textures = [...new Set([...Object.values(THEME_FLOOR).map((f) => f.tex), 'stone_wall', 'skull_wall', 'wing_wall'])].map((t) => `art/textures/${t}.webp`);
write('assets_used.json', { models: [...models].sort(), textures: textures.sort() });
console.log(`export ok: ${AREA_ORDER.length} areas, ${doors.length} doors, ${props.length}+${depths.props.length} props (${usedProps.length} kinds, ${missingProps.length} without GLB: ${missingProps.join(',')}), ${wallsOut.length} walls, ${nodes.length} nodes, ${models.size} models, ${textures.length} textures, ${enemyIds.length} enemy defs, ${Object.keys(bosses).length} bosses`);
