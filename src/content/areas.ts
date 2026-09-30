import type { EnemyId } from './enemies';
import { armorLoot } from './armorSets';

/**
 * One connected world (audit: "one continuous farming space assembled from
 * reusable rooms"). Coordinates are world units; +x is east, −z is north
 * (up-screen). Areas are walkable rectangles joined by door corridors that
 * stay sealed until the unlock threshold is met.
 */
export type AreaId = 'chapterhouse' | 'acre' | 'graves' | 'ossuary' | 'nave' | 'sanctum' | 'cloister' | 'pyre' | 'warren' | 'coliseum';
export type Theme = 'chapter' | 'acre' | 'graveyard' | 'ossuary' | 'nave' | 'sanctum' | 'cloister' | 'pyre' | 'warren' | 'coliseum';

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
  /**
   * Level-scaled area (the Plague Cloister): its dead match the highest-level player in it, never below `minLevel`,
   * so XP per kill keeps pace with any character (docs/GRIND-LOOP.md §2). `level` is then only the floor shown in UI.
   */
  scaling?: { minLevel: number };
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
      { id: 'robber', weight: 52 },
      { id: 'hound', weight: 24 },
      { id: 'penitent', weight: 11 },
      { id: 'sac', weight: 7 },
      { id: 'moth', weight: 6 },
      { id: 'bat', weight: 5 },
      { id: 'ghoul', weight: 6 },
    ],
    cap: 28,
    waveSize: 9,
    waveIntervalMs: 6500,
    eliteChance: 0.035,
    loot: [
      ...armorLoot('graves'),
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
    interactables: [
      { id: 'waystone_graves', kind: 'waystone', label: 'Waystone', x: -5.5, z: 1 },
      // Area bosses (content/bosses.ts summonSpot: each arena's north edge).
      { id: 'kings_grave', kind: 'boss', label: "The King's Grave", x: -14, z: -30.5 },
    ],
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
      { id: 'moth', weight: 5 },
      { id: 'bat', weight: 4 },
      { id: 'ghoul', weight: 4 },
    ],
    cap: 32,
    waveSize: 10,
    waveIntervalMs: 6200,
    eliteChance: 0.045,
    unlock: { area: 'graves', kills: 300 },
    loot: [
      ...armorLoot('ossuary'),
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
    interactables: [
      { id: 'waystone_ossuary', kind: 'waystone', label: 'Waystone', x: 35.5, z: -6 },
      { id: 'abbess_reliquary', kind: 'boss', label: "The Abbess's Reliquary", x: 48, z: -32.5 },
    ],
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
      { id: 'gargoyle', weight: 8 },
      { id: 'bat', weight: 7 },
      { id: 'acolyte', weight: 8 },
      { id: 'templar', weight: 3 },
    ],
    cap: 34,
    waveSize: 11,
    waveIntervalMs: 6000,
    eliteChance: 0.055,
    unlock: { area: 'ossuary', kills: 420 },
    loot: [
      ...armorLoot('nave'),
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
    interactables: [
      { id: 'waystone_nave', kind: 'waystone', label: 'Waystone', x: 6, z: -47.5 },
      { id: 'drowned_font', kind: 'boss', label: 'The Drowned Font', x: 0, z: -70.35 },
    ],
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
      { id: 'gargoyle', weight: 8 },
      { id: 'seraph', weight: 7 },
      { id: 'acolyte', weight: 8 },
      { id: 'templar', weight: 6 },
    ],
    cap: 26,
    waveSize: 8,
    waveIntervalMs: 6500,
    eliteChance: 0.07,
    unlock: { area: 'nave', kills: 520 },
    loot: [
      ...armorLoot('sanctum'),
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
  cloister: {
    id: 'cloister',
    name: 'The Plague Cloister',
    subtitle: 'Where the blight grows with you',
    theme: 'cloister',
    rect: { x0: 24, z0: -134, x1: 64, z1: -98 },
    safe: false,
    level: 20,
    scaling: { minLevel: 20 },
    enemies: [
      { id: 'plague_doctor', weight: 22 },
      { id: 'flagellant', weight: 24 },
      { id: 'sac', weight: 14 },
      { id: 'rat', weight: 10 },
      { id: 'acolyte', weight: 8 },
      { id: 'censer', weight: 8 },
      { id: 'moth', weight: 6 },
      { id: 'templar', weight: 5 },
      { id: 'golem', weight: 3 },
    ],
    cap: 28,
    waveSize: 9,
    waveIntervalMs: 6000,
    eliteChance: 0.08,
    unlock: { area: 'sanctum', kills: 600 },
    loot: [
      ...armorLoot('cloister'),
      { item: 'ore_steel', weight: 14 },
      { item: 'ore_hell', weight: 12 },
      { item: 'ore_moon', weight: 6 },
      { item: 'ingot_steel', weight: 6 },
      { item: 'gem_grave_garnet', weight: 6 },
      { item: 'gem_bone_opal', weight: 3 },
      { item: 'flask_hp_major', weight: 10 },
      { item: 'flask_damage', weight: 6 },
      { item: 'flask_void_resist', weight: 5 },
      { item: 'helm_gold', weight: 5 },
      { item: 'chest_iron', weight: 5 },
    ],
    itemChance: 0.14,
    breaches: [[27, -101], [61, -101], [27, -131], [61, -131], [44, -100.5], [62, -116]],
    interactables: [
      { id: 'waystone_cloister', kind: 'waystone', label: 'Waystone', x: 27.5, z: -108 },
      { id: 'saints_litter', kind: 'boss', label: "The Saint's Litter", x: 44, z: -129.5 },
    ],
    ambient: { fog: 0x0a1008, hemiSky: 0x2c3a24, hemiGround: 0x070a05, moon: 0x9cc48a },
  },
  // The Cinder Pyre (2026-09-30): the fire realm past the Plague Cloister, level-scaled like it but harder.
  pyre: {
    id: 'pyre',
    name: 'The Cinder Pyre',
    subtitle: 'Where the Covenant burns what it cannot bury',
    theme: 'pyre',
    rect: { x0: 70, z0: -134, x1: 110, z1: -98 },
    safe: false,
    level: 30,
    scaling: { minLevel: 30 },
    enemies: [
      { id: 'cinder_husk', weight: 30 },
      { id: 'pyre_priest', weight: 20 },
      { id: 'cinderhound', weight: 22 },
      { id: 'slag_brute', weight: 8 },
    ],
    cap: 28,
    waveSize: 9,
    waveIntervalMs: 6000,
    eliteChance: 0.09,
    unlock: { area: 'cloister', kills: 700 },
    loot: [
      ...armorLoot('pyre'),
      { item: 'ore_hell', weight: 22 },
      { item: 'ingot_hell', weight: 6 },
      { item: 'ore_steel', weight: 12 },
      { item: 'ingot_steel', weight: 6 },
      { item: 'ore_moon', weight: 5 },
      { item: 'gem_grave_garnet', weight: 8 },
      { item: 'gem_bone_opal', weight: 4 },
      { item: 'flask_hp_major', weight: 10 },
      { item: 'flask_damage', weight: 7 },
      { item: 'flask_void_resist', weight: 5 },
      { item: 'helm_gold', weight: 5 },
      { item: 'chest_iron', weight: 5 },
    ],
    itemChance: 0.15,
    breaches: [[73, -101], [107, -101], [73, -131], [107, -131], [90, -100.5], [108, -116], [86.5, -131.5]],
    interactables: [
      { id: 'waystone_pyre', kind: 'waystone', label: 'Waystone', x: 73.5, z: -108 },
      // Boss summon at the arena's north edge (content/bosses.ts summonSpot).
      { id: 'ember_altar', kind: 'boss', label: 'The Ember Altar', x: 90, z: -126.35 },
    ],
    ambient: { fog: 0x140806, hemiSky: 0x4a2412, hemiGround: 0x0c0403, moon: 0xd88a4a },
  },
  // The Catacomb Warren (2026-09-30): a chambered side dungeon off the Hollow Graves. Half-walls divide nine chambers;
  // they break Penitent cones and Ossuary-style line of sight, so the rooms are the fun.
  warren: {
    id: 'warren',
    name: 'The Catacomb Warren',
    subtitle: 'Nine chambers, and something is digging in each',
    theme: 'warren',
    rect: { x0: -72, z0: -52, x1: -32, z1: -8 },
    safe: false,
    level: 4,
    enemies: [
      { id: 'rat', weight: 30 },
      { id: 'robber', weight: 22 },
      { id: 'ghoul', weight: 14 },
      { id: 'bat', weight: 12 },
      { id: 'sac', weight: 10 },
      { id: 'hound', weight: 8 },
      { id: 'penitent', weight: 4 },
    ],
    cap: 26,
    waveSize: 8,
    waveIntervalMs: 6400,
    eliteChance: 0.045,
    unlock: { area: 'graves', kills: 150 },
    loot: [
      { item: 'bones_old', weight: 20 },
      { item: 'bones_barrow', weight: 12 },
      { item: 'ore_tin', weight: 18 },
      { item: 'ore_iron', weight: 14 },
      { item: 'material_copper_bar', weight: 10 },
      { item: 'seed_mourning_moss', weight: 8 },
      { item: 'flask_hp_minor', weight: 12 },
      { item: 'augment_copper', weight: 5 },
      { item: 'plate_copper', weight: 4 },
      { item: 'helm_iron', weight: 3 },
    ],
    itemChance: 0.1,
    breaches: [[-65, -45], [-52, -45], [-39, -45], [-65, -30], [-55.5, -30], [-65, -15], [-52, -15], [-39, -15]],
    interactables: [{ id: 'waystone_warren', kind: 'waystone', label: 'Waystone', x: -35.5, z: -27 }],
    ambient: { fog: 0x0c0a08, hemiSky: 0x3a3226, hemiGround: 0x0a0806, moon: 0xa89a7a },
  },
  // The Bone Coliseum (2026-09-30): a wave-gauntlet pit east of the Ossuary. Four gates, fast surges, elites everywhere,
  // the best drops before the Sanctum: for players who want a fight, not a walk.
  coliseum: {
    id: 'coliseum',
    name: 'The Bone Coliseum',
    subtitle: 'The dead cheer for whoever is still standing',
    theme: 'coliseum',
    rect: { x0: 70, z0: -46, x1: 112, z1: -10 },
    safe: false,
    level: 11,
    enemies: [
      { id: 'rat', weight: 18 },
      { id: 'hound', weight: 16 },
      { id: 'robber', weight: 14 },
      { id: 'deacon', weight: 10 },
      { id: 'bat', weight: 8 },
      { id: 'acolyte', weight: 9 },
      { id: 'wraith', weight: 8 },
      { id: 'gargoyle', weight: 8 },
      { id: 'templar', weight: 6 },
      { id: 'censer', weight: 5 },
      { id: 'seraph', weight: 5 },
      { id: 'golem', weight: 3 },
    ],
    cap: 36,
    waveSize: 14,
    waveIntervalMs: 4200,
    eliteChance: 0.16,
    unlock: { area: 'ossuary', kills: 350 },
    loot: [
      { item: 'ore_silver', weight: 18 },
      { item: 'ore_gold', weight: 12 },
      { item: 'ingot_silver', weight: 6 },
      { item: 'flask_hp_major', weight: 12 },
      { item: 'flask_damage', weight: 6 },
      { item: 'gem_grave_garnet', weight: 6 },
      { item: 'gem_bone_opal', weight: 3 },
      { item: 'augment_iron', weight: 6 },
      { item: 'helm_iron', weight: 6 },
      { item: 'chest_iron', weight: 5 },
      { item: 'kit_iron_warden', weight: 4 },
    ],
    itemChance: 0.17,
    breaches: [[91, -44], [91, -12], [110, -28], [78, -43], [78, -13], [104, -42], [104, -14], [100, -28]],
    interactables: [{ id: 'waystone_coliseum', kind: 'waystone', label: 'Waystone', x: 73.5, z: -20 }],
    ambient: { fog: 0x100c0a, hemiSky: 0x4a3a30, hemiGround: 0x0c0806, moon: 0xd0b890 },
  },
};

export const AREA_ORDER: AreaId[] = ['chapterhouse', 'acre', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'warren', 'coliseum'];

/** Areas with no seal (`unlock`) are open to everyone from the start. */
export const isAlwaysOpen = (id: AreaId) => !AREAS[id].unlock;

export const DOORS: DoorDef[] = [
  { id: 'chapter_graves', a: 'chapterhouse', b: 'graves', rect: { x0: -3.5, z0: 3, x1: 3.5, z1: 9 }, axis: 'z' },
  // Overlaps both rooms by a metre, like every door, so bodies can cross the seam.
  { id: 'chapter_acre', a: 'chapterhouse', b: 'acre', rect: { x0: -21, z0: 17, x1: -12, z1: 23 }, axis: 'x' },
  { id: 'graves_ossuary', a: 'graves', b: 'ossuary', rect: { x0: 25, z0: -22, x1: 33, z1: -14 }, axis: 'x' },
  { id: 'graves_nave', a: 'graves', b: 'nave', rect: { x0: -4, z0: -45, x1: 4, z1: -35 }, axis: 'z' },
  { id: 'nave_sanctum', a: 'nave', b: 'sanctum', rect: { x0: -4, z0: -103, x1: 4, z1: -95 }, axis: 'z' },
  { id: 'sanctum_cloister', a: 'sanctum', b: 'cloister', rect: { x0: 17, z0: -112, x1: 25, z1: -104 }, axis: 'x' },
  { id: 'graves_warren', a: 'graves', b: 'warren', rect: { x0: -33, z0: -32, x1: -25, z1: -24 }, axis: 'x' },
  { id: 'ossuary_coliseum', a: 'ossuary', b: 'coliseum', rect: { x0: 63, z0: -30, x1: 71, z1: -22 }, axis: 'x' },
  { id: 'cloister_pyre', a: 'cloister', b: 'pyre', rect: { x0: 63, z0: -120, x1: 71, z1: -112 }, axis: 'x' },
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
