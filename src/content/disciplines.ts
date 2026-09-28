/**
 * The four necromantic disciplines. The server still stores the legacy class
 * indices (1–4); this manifest is the client-side presentation + tuning layer
 * (audit: "reframe the current four server class indices as necromantic
 * disciplines in a client content manifest"). Index 0 (legacy Engineer, no
 * model) plays as a Gravecaller.
 */
export type DisciplineId = 'ossuary' | 'gravecaller' | 'mourner' | 'rotweaver' | 'hollow_knight';

/**
 * Which kit a discipline plays. The four necromantic disciplines share the
 * `necromancer` family (Grimoire, Grave Essence, thralls, corpse rites); each
 * Release 0.3 class is its own family with its own kit and resource.
 * The union lists all six up front so the framework is general — a family only
 * becomes reachable once its kit exists and its discipline is added to
 * `PLAYABLE_DISCIPLINES`.
 */
export type ClassFamily = 'necromancer' | 'warden' | 'monk' | 'witch' | 'knight' | 'veil';
/** warrior/shieldbearer/wraith come from the discipline; hound, archer, bonemage and plaguebearer from the corpse. */
export type ThrallKind = 'warrior' | 'shieldbearer' | 'wraith' | 'hound' | 'archer' | 'bonemage' | 'plaguebearer';

export interface DisciplineMods {
  thrallCap: number;
  thrallKind: ThrallKind;
  thrallHpMult: number;
  thrallDamageMult: number;
  thrallAttackSpeedMult: number;
  maxHpMult: number;
  essenceRegenMult: number;
  miasmaRadiusMult: number;
  witheredMaxStacks: number;
  /** Fraction of max HP restored per corpse consumed (Exhume / Litany). */
  corpseHeal: number;
  /** Damage reduction per active thrall. */
  wardPerThrall: number;
  /** Litany grants a barrier = fraction of max HP per consumed corpse/thrall. */
  litanyBarrier: number;
  /** Sacrificed thralls leave a fresh corpse. */
  sacrificeLeavesCorpse: boolean;
  /** Corpses inside Miasma burst (Carrion Bloom). */
  miasmaBurstsCorpses: boolean;
}

export interface Discipline {
  classIndex: number;
  id: DisciplineId;
  /** Which kit and resource this discipline plays (see ClassFamily). */
  family: ClassFamily;
  name: string;
  epithet: string;
  description: string;
  passive: { name: string; text: string };
  color: string;
  portrait: string;
  /** Generated discipline hero (graphics/modelPaths CREATURE_MODELS); falls back to the base necromancer. */
  modelSlug: 'hero_ossuary' | 'hero_gravecaller' | 'hero_mourner' | 'hero_rotweaver' | 'hero_hollow_knight';
  mods: DisciplineMods;
}

const BASE: DisciplineMods = {
  thrallCap: 3,
  thrallKind: 'warrior',
  thrallHpMult: 1,
  thrallDamageMult: 1,
  thrallAttackSpeedMult: 1,
  maxHpMult: 1,
  essenceRegenMult: 1,
  miasmaRadiusMult: 1,
  witheredMaxStacks: 5,
  corpseHeal: 0,
  wardPerThrall: 0,
  litanyBarrier: 0,
  sacrificeLeavesCorpse: false,
  miasmaBurstsCorpses: false,
};

export const DISCIPLINES: Record<DisciplineId, Discipline> = {
  ossuary: {
    classIndex: 1,
    id: 'ossuary',
    family: 'necromancer',
    name: 'Ossuary',
    epithet: 'Keeper of the Bone Wall',
    description: 'Armours itself in the dead. Raises shield-bearing thralls that hold the line while you work.',
    passive: {
      name: 'Bone Ward',
      text: 'Thralls rise as Shieldbearers (+60% health, draw aggression). You take 6% less damage per active thrall. Black Litany grants a bone barrier.',
    },
    color: '#d8cfbd',
    portrait: 'art/portraits/ossuary.webp',
    modelSlug: 'hero_ossuary',
    mods: { ...BASE, thrallKind: 'shieldbearer', thrallHpMult: 1.6, maxHpMult: 1.2, wardPerThrall: 0.06, litanyBarrier: 0.04 },
  },
  gravecaller: {
    classIndex: 2,
    id: 'gravecaller',
    family: 'necromancer',
    name: 'Gravecaller',
    epithet: 'Marshal of the Restless',
    description: 'Commands the largest legion. Spends thralls freely, because every sacrifice leaves another corpse.',
    passive: {
      name: 'Grave Legion',
      text: 'Thrall cap 5. Thralls attack 20% faster. Thralls sacrificed by Black Litany leave corpses behind.',
    },
    color: '#9b5cff',
    portrait: 'art/portraits/gravecaller.webp',
    modelSlug: 'hero_gravecaller',
    mods: { ...BASE, thrallCap: 5, thrallAttackSpeedMult: 1.2, thrallHpMult: 0.85, sacrificeLeavesCorpse: true },
  },
  mourner: {
    classIndex: 3,
    id: 'mourner',
    family: 'necromancer',
    name: 'Mourner',
    epithet: 'Singer of the Funeral Rite',
    description: 'Binds spirits instead of bones. Wraiths strike from range and every rite mends the living.',
    passive: {
      name: 'Funeral Rites',
      text: 'Exhume binds Wraiths that attack from range. Consuming a corpse heals 6% max health. +25% Grave Essence regeneration.',
    },
    color: '#8f9ed1',
    portrait: 'art/portraits/mourner.webp',
    modelSlug: 'hero_mourner',
    mods: { ...BASE, thrallKind: 'wraith', thrallHpMult: 0.7, corpseHeal: 0.06, essenceRegenMult: 1.25 },
  },
  rotweaver: {
    classIndex: 4,
    id: 'rotweaver',
    family: 'necromancer',
    name: 'Rotweaver',
    epithet: 'Gardener of Decay',
    description: 'Poisons the ground itself. Miasma spreads further, rots deeper, and turns corpses into bombs.',
    passive: {
      name: 'Carrion Bloom',
      text: 'Miasma Circle is 30% wider and Withered stacks to 8. Corpses inside your Miasma burst, damaging and withering nearby enemies.',
    },
    color: '#b58cc7',
    portrait: 'art/portraits/rotweaver.webp',
    modelSlug: 'hero_rotweaver',
    mods: { ...BASE, miasmaRadiusMult: 1.3, witheredMaxStacks: 8, miasmaBurstsCorpses: true },
  },
  /**
   * Release 0.3. Not a necromancer: family 'knight' brings its own kit
   * (content/kits.ts) and resource (Rage, gameplay/resources.ts). The
   * necromancer-only `mods` stay at BASE — the Knight raises no thralls, and its
   * kit never offers the rites that would read them.
   */
  hollow_knight: {
    classIndex: 8,
    id: 'hollow_knight',
    family: 'knight',
    name: 'Hollow Knight',
    epithet: 'Oathbound of the Covenant',
    description: 'An undead knight still keeping its oath. Builds Rage by taking and dealing punishment, then spends it leaping into the dead.',
    passive: {
      name: 'Oathbound',
      text: 'Rage instead of Grave Essence: built by damage taken, by every body Hollow Cut catches, and fastest of all by a perfect block. It drains once you leave the fight.',
    },
    color: '#b8c0cc',
    portrait: 'art/portraits/hollow_knight.webp',
    modelSlug: 'hero_hollow_knight',
    mods: { ...BASE },
  },
};

const BY_INDEX: Record<number, DisciplineId> = { 0: 'gravecaller', 1: 'ossuary', 2: 'gravecaller', 3: 'mourner', 4: 'rotweaver', 8: 'hollow_knight' };

export function disciplineFor(classIndex: number): Discipline {
  return DISCIPLINES[BY_INDEX[classIndex] ?? 'gravecaller'];
}

export const PLAYABLE_DISCIPLINES: Discipline[] = [
  DISCIPLINES.ossuary,
  DISCIPLINES.gravecaller,
  DISCIPLINES.mourner,
  DISCIPLINES.rotweaver,
  DISCIPLINES.hollow_knight,
];
