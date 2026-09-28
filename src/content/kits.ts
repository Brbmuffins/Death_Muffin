/**
 * Per-family kits — which rites a class actually plays.
 *
 * Before the Release 0.3 framework, the necromancer's rite lists were global
 * constants in `abilities.ts` and every consumer imported them directly. A kit
 * is the same data, keyed by family, so the Grimoire, the loadout, the HUD,
 * the spell cards and the Codex can ask "what does *this* class play?".
 *
 * The necromancer kit is built from those same constants, so the four
 * necromantic disciplines are byte-identical — `__tests__/kits.test.ts` pins it.
 */
import type { ClassFamily, DisciplineId } from './disciplines';
import {
  DEFAULT_LOADOUT,
  DEFAULT_PRIMARY,
  GRIMOIRE,
  HOTBAR,
  PRIMARIES,
  SIGNATURE_BY_DISCIPLINE,
  type AbilityId,
} from './abilities';

export interface Kit {
  family: ClassFamily;
  /** HUD hotbar order: index + 1 is the HotbarSlot; slot 5 is the right-click action. */
  hotbar: AbilityId[];
  /** Every rite that may sit on keys 1–4 — this family's Grimoire. */
  grimoire: AbilityId[];
  /** Keys 1–4 for a fresh character. */
  defaultLoadout: AbilityId[];
  /** Left-click options; `defaultPrimary` must be one of them. */
  primaries: AbilityId[];
  defaultPrimary: AbilityId;
  /** Right-click (corpse) action. */
  rmb: AbilityId;
  /** Level-10 signature, per discipline inside this family. */
  signatures: Partial<Record<DisciplineId, AbilityId>>;
}

const NECROMANCER_KIT: Kit = {
  family: 'necromancer',
  hotbar: HOTBAR,
  grimoire: GRIMOIRE,
  defaultLoadout: DEFAULT_LOADOUT,
  primaries: PRIMARIES,
  defaultPrimary: DEFAULT_PRIMARY,
  rmb: 'corpse_explosion',
  signatures: SIGNATURE_BY_DISCIPLINE,
};

/**
 * Families without a kit yet fall back to the necromancer's, matching
 * `resourceRulesFor`: an unexpected `discipline_index` stays playable rather
 * than loading a class with no rites. Each is replaced when its kit lands.
 */
const KITS: Record<ClassFamily, Kit> = {
  necromancer: NECROMANCER_KIT,
  knight: NECROMANCER_KIT,
  warden: NECROMANCER_KIT,
  monk: NECROMANCER_KIT,
  witch: NECROMANCER_KIT,
  veil: NECROMANCER_KIT,
};

export function kitFor(family: ClassFamily): Kit {
  return KITS[family] ?? NECROMANCER_KIT;
}

/** Register a family's kit. Called from the family's own content module. */
export function registerKit(kit: Kit) {
  KITS[kit.family] = kit;
}

/** The level-10 signature for a discipline, or undefined if it has none. */
export function signatureFor(family: ClassFamily, discipline: DisciplineId): AbilityId | undefined {
  return kitFor(family).signatures[discipline];
}
