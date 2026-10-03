/** Full-set effects of the four legendary sets (shared by legendaryReport and bossReport). */
import { SET_BONUSES, type SetEffect } from '../../content/setBonuses';

/** The full-set sum of every tier, read from SET_BONUSES (multipliers multiply, additions add) so the report never drifts from the game. */
export function fullSet(id: string, upTo = 5): SetEffect {
  const out: { mult: Record<string, number>; add: Record<string, number> } = { mult: {}, add: {} };
  for (const tier of SET_BONUSES[id].filter((t) => t.pieces <= upTo)) {
    for (const [k, v] of Object.entries(tier.effect.mult ?? {})) out.mult[k] = (out.mult[k] ?? 1) * (v as number);
    for (const [k, v] of Object.entries(tier.effect.add ?? {})) out.add[k] = (out.add[k] ?? 0) + (v as number);
  }
  return out as SetEffect;
}

export const FULL_SETS: Record<number, { name: string; effect: SetEffect; soul: boolean; id: string; plain: string; asc: string }> = {
  2: { name: 'Gravecaller / Legion of the Unburied', soul: false, effect: fullSet('legion_unburied'), id: 'legion_unburied', plain: 'gravecaller', asc: 'gravecaller_ascended' },
  1: { name: 'Ossuary / Colossus Mantle', soul: false, effect: fullSet('colossus_mantle'), id: 'colossus_mantle', plain: 'ossuary', asc: 'ossuary_ascended' },
  3: { name: 'Mourner / Requiem of Wraiths', soul: true, effect: fullSet('requiem_wraiths'), id: 'requiem_wraiths', plain: 'mourner', asc: 'mourner_ascended' },
  4: { name: 'Rotweaver / Plague Choir', soul: false, effect: fullSet('plague_choir'), id: 'plague_choir', plain: 'rotweaver', asc: 'rotweaver_ascended' },
};

