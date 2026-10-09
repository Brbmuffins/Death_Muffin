import { unlockLevel, type AbilityId } from '../content/abilities';
import type { DisciplineId } from '../../server/rules/content/disciplines';

/**
 * First-hour clarity rules (owner decisions, 3 Oct 2026). Pure, so they are unit-tested and cost nothing per frame.
 */

/**
 * The hotbar's swap control stays hidden until the player has something to swap: at least one Grimoire rite that
 * is not part of the level-1 kit has been learned. `grimoire` is the kit's rite pool; `level` is the rite level
 * (dev access already folded in by the caller).
 */
export function swapReady(grimoire: readonly AbilityId[], level: number): boolean {
  return grimoire.some((id) => unlockLevel(id) > 1 && level >= unlockLevel(id));
}

/** The discipline the picker recommends to a player who has never made a character. */
export const FIRST_RUN_DISCIPLINE: DisciplineId = 'gravecaller';

/**
 * "Recommended for your first run" badge. The discipline picker is only reached when the account has no
 * character yet, so it is a first-run screen by construction; changing class later (Class panel in the
 * world) is a veteran's choice and gets no badge. Every discipline stays one click away either way.
 */
export function recommendedForFirstRun(id: DisciplineId, accountHasCharacter: boolean): boolean {
  return id === FIRST_RUN_DISCIPLINE && !accountHasCharacter;
}
