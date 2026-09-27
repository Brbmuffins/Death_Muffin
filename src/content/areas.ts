import type { EnemyId } from './enemies';

/**
 * One connected world (audit: "one continuous farming space assembled from
 * reusable rooms"). Coordinates are world units; +x is east, −z is north
 * (up-screen). Areas are walkable rectangles joined by door corridors that
 * stay sealed until the unlock threshold is met.
 */
export type AreaId = 'chapterhouse' | 'acre' | 'graves' | 'ossuary' | 'nave' | 'sanctum';
export type Theme = 'chapter' | 'acre' | 'graveyard' | 'ossuary' | 'nave' | 'sanctum';

export interface Rect {
  x0: number;
  z0: number;
  x1: number;
  z1: number;
}

/** kiln / sawpit / fire are the Sexton's Acre processing stations (docs/PROFESSIONS-ROADMAP.md §6). */
export type InteractKind = 'inventory' | 'forge' | 'professions' | 'upgrades' | 'waystone' | 'boss' | 'kiln' | 'sawpit' | 'fire' | 'lectern';

export interface Interactable {
  id: string;
  kind: InteractKind;
  label: string;
  x: number;
  z: number;
}

export interface AreaDef {
  id: AreaId;
  name: string;
  subtitle: string;
  theme: Theme;
  rect: Rect;
  safe: boolean;
  level: number;
  enemies: { id: EnemyId; weight: number }[];
  /** Base simultaneous-enemy ceiling before wave-speed scaling. */
  cap: number;
  waveSize: number;
  waveIntervalMs: number;
  eliteChance: number;
  unlock?: { area: AreaId; kills: number };
  loot: { item: string; weight: number }[];
  itemChance: number;
  breaches: [number, number][];
  interactables: Interactable[];
  ambient: { fog: number; hemiSky: number; hemiGround: number; moon: number };
}

export interface DoorDef {
  id: string;
  a: AreaId;
  b: AreaId;
  rect: Rect;
  /** Corridor runs along this axis; the gate spans the other one. */
  axis: 'x' | 'z';
}

export const AREAS: Record<AreaId, AreaDef> = {
  chapterhouse: {
    id: 'chapterhouse',
    name: 'The Chapterhouse',
    subtitle: 'Sanctuary of the Ossuary Covenant',
    theme: 'chapter',
    rect: { x0: -13, z0: 8, x1: 13, z1: 32 },
    safe: true,
    level: 1,
    enemies: [],
    cap: 0,
    waveSize: 0,
    waveIntervalMs: 0,
    eliteChance: 0,
    loot: [],
    itemChance: 0,
    breaches: [],
    interactables: [
      { id: 'reliquary', kind: 'inventory', label: 'Reliquary', x: -8.5, z: 14 },
      { id: 'workbench', kind: 'forge', label: 'Ossuary Workbench', x: 8.5, z: 14 },
      { id: 'niches', kind: 'professions', label: 'Rite Niches', x: -10.8, z: 26.5 },
      { id: 'altar', kind: 'upgrades', label: 'Altar of Ascension', x: 0, z: 21 },
      { id: 'waystone_chapterhouse', kind: 'waystone', label: 'Waystone', x: 9, z: 26.5 },
    ],
    ambient: { fog: 0x0b0810, hemiSky: 0x3b2a52, hemiGround: 0x0a0710, moon: 0x8f9ed1 },
  },
  // The non-combat gathering zone: every tier of every gathering node, no waves (roadmap §6).
  acre: {
    id: 'acre',
    name: "The Sexton's Acre",
    subtitle: "Where the Covenant's dead are tended",
    theme: 'acre',
    rect: { x0: -62, z0: 6, x1: -20, z1: 38 },
    safe: true,
    level: 1,
    enemies: [],
    cap: 0,
    waveSize: 0,
    waveIntervalMs: 0,
    eliteChance: 0,
    loot: [],
    itemChance: 0,
    breaches: [],
    interactables: [
      { id: 'waystone_acre', kind: 'waystone', label: 'Waystone', x: -23, z: 25.5 },
      { id: 'sawpit', kind: 'sawpit', label: 'Sawpit', x: -23.5, z: 12.5 },
      { id: 'bone_kiln', kind: 'kiln', label: 'Bone Kiln', x: -23.5, z: 31.6 },
      { id: 'cooking_fire', kind: 'fire', label: 'Cooking Fire', x: -26.5, z: 28.5 },
      { id: 'lectern', kind: 'lectern', label: 'Covenant Lectern', x: -24.2, z: 17.8 },
    ],
    ambient: { fog: 0x0c0f10, hemiSky: 0x4b5864, hemiGround: 0x232820, moon: 0xbbcbd8 },
  },
  graves: {
    id: 'graves',
    name: 'The Hollow Graves',
    subtitle: 'Where the Covenant buries what it cannot keep',
    theme: 'graveyard',
    rect: { x0: -26, z0: -36, x1: 26, z1: 4 },
    safe: false,
    level: 1,
    enemies: [
      { id: 'robber', weight: 58 },
      { id: 'hound', weight: 24 },
      { id: 'penitent', weight: 11 },
      { id: 'sac', weight: 7 },
    ],
    cap: 28,
    waveSize: 9,
    waveIntervalMs: 6500,
    eliteChance: 0.035,
    loot: [
      { item: 'material_copper_shard', weight: 30 },
      { item: 'ore_copper', weight: 24 },
      { item: 'ore_tin', weight: 14 },
      { item: 'flask_hp_minor', weight: 12 },
      { item: 'log_oak', weight: 8 },
      { item: 'ring_copper', weight: 4 },
      { item: 'helm_copper', weight: 4 },
      { item: 'staff_oak', weight: 3 },
    ],
    itemChance: 0.08,
    breaches: [
      [-18, -29], [0, -31], [18, -29], [-21, -13], [21, -11], [9, -19], [-9, -21], [20, -24], [-14, -3], [14, -4],
    ],
    interactables: [{ id: 'waystone_graves', kind: 'waystone', label: 'Waystone', x: -5.5, z: 1 }],
    ambient: { fog: 0x0d0a14, hemiSky: 0x3a2d55, hemiGround: 0x0b0810, moon: 0x9aa6d4 },
  },
  ossuary: {
    id: 'ossuary',
    name: 'The Marrow Ossuary',
    subtitle: 'Ten thousand skulls, and all of them listening',
    theme: 'ossuary',
    rect: { x0: 32, z0: -38, x1: 64, z1: -2 },
    safe: false,
    level: 5,
    enemies: [
      { id: 'robber', weight: 30 },
      { id: 'hound', weight: 30 },
      { id: 'sac', weight: 18 },
      { id: 'deacon', weight: 12 },
      { id: 'penitent', weight: 10 },
      { id: 'rat', weight: 10 },
      { id: 'golem', weight: 2 },
    ],
    cap: 32,
    waveSize: 10,
    waveIntervalMs: 6200,
    eliteChance: 0.045,
    unlock: { area: 'graves', kills: 300 },
    loot: [
      { item: 'ore_iron', weight: 24 },
      { item: 'ore_copper', weight: 14 },
      { item: 'material_copper_bar', weight: 14 },
      { item: 'ore_bronze', weight: 10 },
      { item: 'flask_hp_minor', weight: 10 },
      { item: 'augment_copper', weight: 5 },
      { item: 'sword_copper', weight: 4 },
      { item: 'plate_copper', weight: 4 },
      { item: 'helm_iron', weight: 3 },
    ],
    itemChance: 0.09,
    breaches: [[38, -33], [50, -35], [60, -27], [60, -9], [46, -6], [39, -18], [54, -19], [44, -27]],
    interactables: [{ id: 'waystone_ossuary', kind: 'waystone', label: 'Waystone', x: 35.5, z: -6 }],
    ambient: { fog: 0x0e0b0c, hemiSky: 0x40334a, hemiGround: 0x0d0909, moon: 0xb7a98e },
  },
  nave: {
    id: 'nave',
    name: 'The Drowned Nave',
    subtitle: 'The congregation never stopped kneeling',
    theme: 'nave',
    rect: { x0: -15, z0: -96, x1: 15, z1: -44 },
    safe: false,
    level: 9,
    enemies: [
      { id: 'penitent', weight: 23 },
      { id: 'robber', weight: 27 },
      { id: 'deacon', weight: 15 },
      { id: 'sac', weight: 16 },
      { id: 'hound', weight: 19 },
      { id: 'wraith', weight: 12 },
      { id: 'censer', weight: 6 },
    ],
    cap: 34,
    waveSize: 11,
    waveIntervalMs: 6000,
    eliteChance: 0.055,
    unlock: { area: 'ossuary', kills: 420 },
    loot: [
      { item: 'ore_silver', weight: 20 },
      { item: 'ore_iron', weight: 20 },
      { item: 'ore_gold', weight: 8 },
      { item: 'flask_hp_major', weight: 10 },
      { item: 'augment_iron', weight: 5 },
      { item: 'helm_iron', weight: 6 },
      { item: 'chest_iron', weight: 4 },
    ],
    itemChance: 0.1,
    breaches: [[-11, -91], [11, -91], [-11, -72], [11, -72], [-11, -53], [11, -53], [0, -82], [0, -62]],
    interactables: [{ id: 'waystone_nave', kind: 'waystone', label: 'Waystone', x: 6, z: -47.5 }],
    ambient: { fog: 0x0b0914, hemiSky: 0x33285a, hemiGround: 0x08060f, moon: 0x8f86d8 },
  },
  sanctum: {
    id: 'sanctum',
    name: 'The Bell Sanctum',
    subtitle: 'Seat of the Bell-Sworn Prelate',
    theme: 'sanctum',
    rect: { x0: -18, z0: -130, x1: 18, z1: -102 },
    safe: false,
    level: 13,
    enemies: [
      { id: 'penitent', weight: 30 },
      { id: 'deacon', weight: 20 },
      { id: 'robber', weight: 20 },
      { id: 'hound', weight: 20 },
      { id: 'sac', weight: 10 },
      { id: 'censer', weight: 10 },
      { id: 'wraith', weight: 10 },
      { id: 'golem', weight: 4 },
    ],
    cap: 26,
    waveSize: 8,
    waveIntervalMs: 6500,
    eliteChance: 0.07,
    unlock: { area: 'nave', kills: 520 },
    loot: [
      { item: 'ore_gold', weight: 18 },
      { item: 'ore_steel', weight: 14 },
      { item: 'ingot_gold', weight: 8 },
      { item: 'flask_hp_major', weight: 10 },
      { item: 'chest_iron', weight: 7 },
      { item: 'helm_gold', weight: 5 },
      { item: 'kit_iron_warden', weight: 5 },
    ],
    itemChance: 0.12,
    breaches: [[-14, -126], [14, -126], [-15, -109], [15, -109]],
    interactables: [
      { id: 'waystone_sanctum', kind: 'waystone', label: 'Waystone', x: 6, z: -105 },
      { id: 'sundered_bell', kind: 'boss', label: 'The Sundered Bell', x: 0, z: -123.4 },
    ],
    ambient: { fog: 0x100814, hemiSky: 0x3d2352, hemiGround: 0x0c060c, moon: 0xa58ad8 },
  },
};

export const AREA_ORDER: AreaId[] = ['chapterhouse', 'acre', 'graves', 'ossuary', 'nave', 'sanctum'];

/** Areas with no seal (`unlock`) are open to everyone from the start. */
export const isAlwaysOpen = (id: AreaId) => !AREAS[id].unlock;

export const DOORS: DoorDef[] = [
  { id: 'chapter_graves', a: 'chapterhouse', b: 'graves', rect: { x0: -3.5, z0: 3, x1: 3.5, z1: 9 }, axis: 'z' },
  // Overlaps both rooms by a metre, like every door, so bodies can cross the seam.
  { id: 'chapter_acre', a: 'chapterhouse', b: 'acre', rect: { x0: -21, z0: 17, x1: -12, z1: 23 }, axis: 'x' },
  { id: 'graves_ossuary', a: 'graves', b: 'ossuary', rect: { x0: 25, z0: -22, x1: 33, z1: -14 }, axis: 'x' },
  { id: 'graves_nave', a: 'graves', b: 'nave', rect: { x0: -4, z0: -45, x1: 4, z1: -35 }, axis: 'z' },
  { id: 'nave_sanctum', a: 'nave', b: 'sanctum', rect: { x0: -4, z0: -103, x1: 4, z1: -95 }, axis: 'z' },
];

/** A door is open when its far-side area is unlocked. */
export function doorTarget(door: DoorDef): AreaId {
  return AREAS[door.b].unlock ? door.b : door.a;
}

// A fixed, safe starting point beside the Acre's entrance and beginner nodes.
export const PLAYER_SPAWN = { x: -26, z: 20 };
export const CHAPTERHOUSE_RETURN = { x: 0, z: 24 };

/** Soul shards required at the Sundered Bell to awaken the Prelate. */
export const BOSS_SUMMON_SHARDS = 5;
export const GLOBAL_ENEMY_CAP = 72;
