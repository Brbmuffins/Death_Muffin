/**
 * New Blood catch-up (owner, 3 Oct 2026: "apply the 1.5x damage and early xp for new blood"). The five New Blood disciplines fight
 * without a legion, so in the balance harness they killed and levelled 3-6x slower than the necromancers (the New Blood
 * leveling audit). Two levers, both off for necromancers:
 * - every New Blood primary, rite and signature hits 1.5x harder (NewBloodSystem.power);
 * - experience is multiplied for the early levels: x2 at level 1, fading in a straight line to x1 at level 15.
 */
export const NEW_BLOOD_DAMAGE_MULT = 1.5;
export const NEW_BLOOD_XP_CATCHUP = { startMult: 2, fadeLevel: 15 };

export const isNewBlood = (family: string) => family !== 'necromancer';

/** Damage multiplier for a discipline family. */
export const newBloodDamageMult = (family: string) => (isNewBlood(family) ? NEW_BLOOD_DAMAGE_MULT : 1);

/** Experience multiplier for a discipline family at a character level. */
export function newBloodXpMult(family: string, level: number): number {
  if (!isNewBlood(family)) return 1;
  const { startMult, fadeLevel } = NEW_BLOOD_XP_CATCHUP;
  const l = Math.max(1, Math.trunc(level) || 1);
  if (l >= fadeLevel) return 1;
  return startMult + ((1 - startMult) * (l - 1)) / (fadeLevel - 1);
}
