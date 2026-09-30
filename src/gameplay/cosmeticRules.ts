import { ALL_SKILLS, LEVEL_CAP, type SkillId } from './gatheringRules';
import { CAPES, PETS, capeDef, petDef, petForCharm, type CapeDef } from '../content/cosmetics';

export { CAPES, PETS, capeDef, petDef, petForCharm };
export { GARDEN_PET_CHANCE, petChance } from '../content/cosmetics';

/**
 * Cosmetic unlock rules shared by the client (panel + offline mock) and the Death Muffin backend (`npm run build:server-rules` bundles
 * this into gathering/cosmetic-rules.cjs). Pure and DOM-free.
 */

export type Levels = Partial<Record<SkillId, number>>;

const lvl = (levels: Levels, s: SkillId) => Math.max(1, Math.min(LEVEL_CAP, levels[s] ?? 1));

/** Total level across every skill (each is at least 1). */
export const totalLevel = (levels: Levels) => ALL_SKILLS.reduce((n, s) => n + lvl(levels, s), 0);

export interface CapeProgress {
  unlocked: boolean;
  /** What you have and what it takes, for the panel ("74 / 99" or "212 / 300"). */
  have: number;
  need: number;
}

export function capeProgress(cape: CapeDef, levels: Levels): CapeProgress {
  if (cape.skill) {
    const have = lvl(levels, cape.skill);
    return { unlocked: have >= LEVEL_CAP, have, need: LEVEL_CAP };
  }
  const have = totalLevel(levels);
  const need = cape.total ?? Infinity;
  return { unlocked: have >= need, have, need };
}

export const capeUnlocked = (id: string, levels: Levels) => {
  const c = capeDef(id);
  return !!c && capeProgress(c, levels).unlocked;
};
export const unlockedCapes = (levels: Levels) => CAPES.filter((c) => capeProgress(c, levels).unlocked).map((c) => c.id);

/** What may be shown on a hero: a real cape id or a real pet id (used to sanitise what other players broadcast). */
export const isCape = (id: unknown): id is string => typeof id === 'string' && !!capeDef(id);
export const isPet = (id: unknown): id is string => typeof id === 'string' && !!petDef(id);
