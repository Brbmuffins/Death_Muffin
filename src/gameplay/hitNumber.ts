import { FRACTURE } from '../content/abilities';
import { AFFIX_TUNING, type EliteAffix } from '../../server/rules/content/enemies';
import { SANCTIFIED } from '../content/statuses';

/**
 * What share of a named blow a body really takes. The host applies Fracture (more), Sanctified and Shrouded (less) after a
 * rite has named its damage (WorldSim.damageEnemy), so the number that floats up scales by the same factors: it is what the
 * health bar loses. `inFriendlyRot` = standing in a player's Miasma or Corpse Explosion rot pool (it lifts a Shrouded guard).
 */
export function damageTakenScale(e: { fracture: number; sanctT?: number; affix?: EliteAffix }, inFriendlyRot: boolean): number {
  let m = 1 + FRACTURE.perStack * e.fracture;
  if ((e.sanctT ?? 0) > 0) m *= SANCTIFIED.damageTakenMult;
  if (e.affix === 'shrouded' && !inFriendlyRot) m *= AFFIX_TUNING.shrouded.damageTakenMult;
  return m;
}
