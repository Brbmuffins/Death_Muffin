import { SKILLS, type NodeKind } from '../../server/rules/gameplay/gatheringRules';

/**
 * The sound of one work cycle: the skill's own, except where the map has a finer one (ore rings, herbs rustle, a bed is tended, a
 * brew bubbles, the grinder grinds). Kept out of gatheringRules.ts, which the server rules are generated from.
 */
export function gatherSfx(skill: string, kind?: NodeKind): 'chop' | 'pick' | 'splash' | 'shovel' | 'pickOre' | 'gatherHerb' | 'gardenTend' | 'brewTick' | 'grind' {
  if (skill === 'mining' && kind === 'seam') return 'pickOre';
  if (kind === 'herb') return 'gatherHerb';
  if (skill === 'gardening') return 'gardenTend';
  if (skill === 'alchemy') return 'brewTick';
  if (skill === 'salvaging') return 'grind';
  return (SKILLS as Record<string, { sfx: 'chop' | 'pick' | 'splash' | 'shovel' }>)[skill]?.sfx ?? 'shovel';
}
