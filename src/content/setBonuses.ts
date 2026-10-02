import { ARMOR_PIECES, ARMOR_SETS, ASCENDED_ARMOR_SETS } from './armorSets';

/**
 * Armor set bonuses: 2, 4 and 5 pieces of one set. Every effect is one the game already reads, so a bonus
 * never needs new sim code:
 *  - `stats` are flat STR/AGI/INT/VIT, added to the gear stat totals (gameplay/stats.ts computeStats);
 *  - `mult` and `add` fold into the discipline `mods` the scene builds (WorldScene.applyBoons, the same place
 *    Covenant boons and a skull focus do), so deriveStats, the abilities and the HUD all see them.
 * Bonuses are cumulative: five pieces gives the 2, 4 and 5 piece lines together.
 */

/** Discipline mods that multiply (1.05 = +5%). */
export type SetMultKey = 'thrallHpMult' | 'thrallDamageMult' | 'thrallAttackSpeedMult' | 'maxHpMult' | 'essenceRegenMult' | 'miasmaRadiusMult';
/** Discipline mods that add. */
export type SetAddKey = 'thrallCap' | 'witheredMaxStacks' | 'corpseHeal' | 'wardPerThrall' | 'litanyBarrier';
export type SetStatKey = 'stat_str' | 'stat_agi' | 'stat_int' | 'stat_vit';

export interface SetEffect {
  mult?: Partial<Record<SetMultKey, number>>;
  add?: Partial<Record<SetAddKey, number>>;
  stats?: Partial<Record<SetStatKey, number>>;
}

export type SetTier = 2 | 4 | 5;
export const SET_TIERS: SetTier[] = [2, 4, 5];

export interface SetBonusDef {
  pieces: SetTier;
  /** The five-piece signature has a name; the others read as plain lines. */
  name?: string;
  effect: SetEffect;
}

const pct = (x: number) => `${+(x * 100).toFixed(1)}%`;

/** Plain-language lines for one effect ("Thralls have +5% health"). Generated, so words follow the numbers. */
export function describeEffect(e: SetEffect): string[] {
  const out: string[] = [];
  const m = e.mult ?? {};
  const a = e.add ?? {};
  const up = (x: number) => pct(x - 1);
  if (e.stats) for (const [k, v] of Object.entries(e.stats)) out.push(`+${v} ${k.replace('stat_', '').toUpperCase()}`);
  if (m.maxHpMult) out.push(`+${up(m.maxHpMult)} maximum health`);
  if (m.essenceRegenMult) out.push(`+${up(m.essenceRegenMult)} essence regeneration`);
  if (m.thrallHpMult) out.push(`Thralls have +${up(m.thrallHpMult)} health`);
  if (m.thrallDamageMult) out.push(`Thralls hit +${up(m.thrallDamageMult)} harder`);
  if (m.thrallAttackSpeedMult) out.push(`Thralls attack +${up(m.thrallAttackSpeedMult)} faster`);
  if (m.miasmaRadiusMult) out.push(`Miasma is +${up(m.miasmaRadiusMult)} wider`);
  if (a.thrallCap) out.push(`+${a.thrallCap} thrall cap`);
  if (a.witheredMaxStacks) out.push(`+${a.witheredMaxStacks} max Withered stacks`);
  if (a.wardPerThrall) out.push(`${pct(a.wardPerThrall)} less damage taken per thrall`);
  if (a.corpseHeal) out.push(`Consumed corpses heal +${pct(a.corpseHeal)} max health`);
  if (a.litanyBarrier) out.push(`Black Litany barrier +${pct(a.litanyBarrier)} max health per corpse`);
  return out;
}

const stat = (s: SetEffect['stats']): SetEffect => ({ stats: s });

/** setId (ArmorPiece.setId: "ossuary", "ossuary_ascended") -> its three bonuses. */
export const SET_BONUSES: Record<string, SetBonusDef[]> = {
  // --- Necromancer sets: built on the levers each discipline already has ---------------------------
  ossuary: [
    { pieces: 2, effect: { mult: { thrallHpMult: 1.2, maxHpMult: 1.02 } } },
    { pieces: 4, effect: { mult: { thrallHpMult: 1.1 }, add: { wardPerThrall: 0.05 } } },
    { pieces: 5, name: 'Reliquary Bulwark', effect: { mult: { maxHpMult: 1.1 }, add: { litanyBarrier: 0.04 } } },
  ],
  ossuary_ascended: [
    { pieces: 2, effect: { mult: { thrallHpMult: 1.3, maxHpMult: 1.03 } } },
    { pieces: 4, effect: { mult: { thrallHpMult: 1.12 }, add: { wardPerThrall: 0.065 } } },
    { pieces: 5, name: 'Regent’s Ossuary', effect: { mult: { maxHpMult: 1.14 }, add: { litanyBarrier: 0.06 } } },
  ],
  gravecaller: [
    { pieces: 2, effect: { mult: { thrallDamageMult: 1.08 } } },
    { pieces: 4, effect: { mult: { thrallAttackSpeedMult: 1.1 } } },
    { pieces: 5, name: 'Legion Call', effect: { mult: { thrallDamageMult: 1.14 }, add: { thrallCap: 1 } } },
  ],
  gravecaller_ascended: [
    { pieces: 2, effect: { mult: { thrallDamageMult: 1.14 } } },
    { pieces: 4, effect: { mult: { thrallAttackSpeedMult: 1.14, thrallDamageMult: 1.04 } } },
    { pieces: 5, name: 'Sovereign Legion', effect: { mult: { thrallDamageMult: 1.14, thrallAttackSpeedMult: 1.06 }, add: { thrallCap: 1 } } },
  ],
  mourner: [
    { pieces: 2, effect: { mult: { essenceRegenMult: 1.3, maxHpMult: 1.06 } } },
    { pieces: 4, effect: { mult: { thrallHpMult: 1.2, maxHpMult: 1.05 }, add: { corpseHeal: 0.03 } } },
    { pieces: 5, name: 'Widow’s Chorus', effect: { mult: { essenceRegenMult: 1.2, thrallDamageMult: 1.2, maxHpMult: 1.04 } } },
  ],
  mourner_ascended: [
    { pieces: 2, effect: { mult: { essenceRegenMult: 1.45, maxHpMult: 1.12 } } },
    { pieces: 4, effect: { mult: { thrallHpMult: 1.3, maxHpMult: 1.08 }, add: { corpseHeal: 0.05 } } },
    { pieces: 5, name: 'Requiem Hush', effect: { mult: { essenceRegenMult: 1.3, thrallDamageMult: 1.2, maxHpMult: 1.07 }, add: { corpseHeal: 0.02 } } },
  ],
  rotweaver: [
    { pieces: 2, effect: { mult: { miasmaRadiusMult: 1.12 } } },
    { pieces: 4, effect: { mult: { miasmaRadiusMult: 1.08 }, add: { witheredMaxStacks: 2 } } },
    { pieces: 5, name: 'Blight Bloom', effect: { mult: { miasmaRadiusMult: 1.12, maxHpMult: 1.03 }, add: { witheredMaxStacks: 1 } } },
  ],
  rotweaver_ascended: [
    { pieces: 2, effect: { mult: { miasmaRadiusMult: 1.16 } } },
    { pieces: 4, effect: { mult: { miasmaRadiusMult: 1.1 }, add: { witheredMaxStacks: 3 } } },
    { pieces: 5, name: 'Plague Song', effect: { mult: { miasmaRadiusMult: 1.16, maxHpMult: 1.05 }, add: { witheredMaxStacks: 1 } } },
  ],
  // --- Other disciplines: flat stats plus health / essence regeneration (all they have to scale) ------
  warden: [
    { pieces: 2, effect: stat({ stat_vit: 3 }) },
    { pieces: 4, effect: { mult: { maxHpMult: 1.05 } } },
    { pieces: 5, name: 'Lamplight Vigil', effect: { stats: { stat_str: 3 }, mult: { maxHpMult: 1.04 } } },
  ],
  warden_ascended: [
    { pieces: 2, effect: stat({ stat_vit: 4 }) },
    { pieces: 4, effect: { mult: { maxHpMult: 1.07 } } },
    { pieces: 5, name: 'Last Watch', effect: { stats: { stat_str: 4 }, mult: { maxHpMult: 1.05 } } },
  ],
  monk: [
    { pieces: 2, effect: stat({ stat_agi: 3 }) },
    { pieces: 4, effect: stat({ stat_str: 3 }) },
    { pieces: 5, name: 'Measured Toll', effect: stat({ stat_agi: 3, stat_str: 3 }) },
  ],
  monk_ascended: [
    { pieces: 2, effect: stat({ stat_agi: 4 }) },
    { pieces: 4, effect: stat({ stat_str: 4 }) },
    { pieces: 5, name: 'Final Note', effect: stat({ stat_agi: 4, stat_str: 4 }) },
  ],
  witch: [
    { pieces: 2, effect: stat({ stat_int: 2 }) },
    { pieces: 4, effect: { mult: { essenceRegenMult: 1.06 } } },
    { pieces: 5, name: 'Thorn Bloom', effect: { stats: { stat_int: 2 }, mult: { maxHpMult: 1.04 } } },
  ],
  witch_ascended: [
    { pieces: 2, effect: stat({ stat_int: 3 }) },
    { pieces: 4, effect: { mult: { essenceRegenMult: 1.08 } } },
    { pieces: 5, name: 'Rootbound Covenant', effect: { stats: { stat_int: 3 }, mult: { maxHpMult: 1.06 } } },
  ],
  knight: [
    { pieces: 2, effect: stat({ stat_str: 3 }) },
    { pieces: 4, effect: { mult: { maxHpMult: 1.05 } } },
    { pieces: 5, name: 'Broken Vow', effect: stat({ stat_vit: 3, stat_str: 3 }) },
  ],
  knight_ascended: [
    { pieces: 2, effect: stat({ stat_str: 4 }) },
    { pieces: 4, effect: { mult: { maxHpMult: 1.07 } } },
    { pieces: 5, name: 'Shield Remains', effect: stat({ stat_vit: 4, stat_str: 4 }) },
  ],
  veil: [
    { pieces: 2, effect: stat({ stat_agi: 3 }) },
    { pieces: 4, effect: stat({ stat_int: 2 }) },
    { pieces: 5, name: 'Edge of Worlds', effect: { stats: { stat_agi: 3 }, mult: { essenceRegenMult: 1.06 } } },
  ],
  veil_ascended: [
    { pieces: 2, effect: stat({ stat_agi: 4 }) },
    { pieces: 4, effect: stat({ stat_int: 3 }) },
    { pieces: 5, name: 'Shadowless', effect: { stats: { stat_agi: 4 }, mult: { essenceRegenMult: 1.08 } } },
  ],
};

/** Display name of a set by id. */
export const SET_NAMES: Record<string, string> = Object.fromEntries([
  ...Object.entries(ARMOR_SETS).map(([d, s]) => [d, s.name]),
  ...Object.entries(ASCENDED_ARMOR_SETS).map(([d, s]) => [`${d}_ascended`, s.name]),
]);

export const bonusesOf = (setId: string): SetBonusDef[] => SET_BONUSES[setId] ?? [];

/** Every set id that has pieces (kept in step with the catalog by a unit test). */
export const SET_IDS: string[] = [...new Set(ARMOR_PIECES.map((p) => p.setId))];
