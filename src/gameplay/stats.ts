import type { Character, InventorySlot } from '../net/types';
import { setStatTotals } from './setBonuses';

export const STAT_KEYS = ['stat_str', 'stat_agi', 'stat_int', 'stat_vit'] as const;
export type StatKey = (typeof STAT_KEYS)[number];

export const STAT_LABELS: Record<StatKey, string> = {
  stat_str: 'STR',
  stat_agi: 'AGI',
  stat_int: 'INT',
  stat_vit: 'VIT',
};

export interface ComputedStats {
  base: Record<StatKey, number>;
  bonus: Record<StatKey, number>;
  total: Record<StatKey, number>;
}

/**
 * Displayed stats = character base stats + sum of equipped items' stat_bonus
 * JSON + the flat stats of active armor set bonuses (gameplay/setBonuses.ts). Client-side only — the server stores base stats and the equipped
 * flags; it never aggregates.
 */
export function computeStats(character: Character, slots: InventorySlot[]): ComputedStats {
  const base = Object.fromEntries(
    STAT_KEYS.map((k) => [k, character[k] ?? 0]),
  ) as Record<StatKey, number>;
  const bonus = Object.fromEntries(STAT_KEYS.map((k) => [k, 0])) as Record<StatKey, number>;

  for (const slot of slots) {
    if (!slot.equipped || !slot.stat_bonus) continue;
    for (const k of STAT_KEYS) {
      bonus[k] += slot.stat_bonus[k] ?? 0;
    }
  }

  const fromSets = setStatTotals(slots);
  for (const k of STAT_KEYS) bonus[k] += fromSets[k] ?? 0;

  const total = Object.fromEntries(
    STAT_KEYS.map((k) => [k, base[k] + bonus[k]]),
  ) as Record<StatKey, number>;

  return { base, bonus, total };
}
