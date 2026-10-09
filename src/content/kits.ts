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
import type { ClassFamily, DisciplineId } from '../../server/rules/content/disciplines';
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
  /** Class rites in the Grimoire; the default right-click rite is added to the swappable pool. */
  grimoire: AbilityId[];
  /** Keys 1–4 for a fresh character; rmb supplies slot 5. */
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
 * Hollow Knight (Release 0.3). Seven rites, no Grimoire alternatives yet — the
 * four keys are fixed, so `grimoire` is exactly `defaultLoadout`. Its one
 * primary is Hollow Cut; the signature is keyed to the single knight discipline.
 */
const KNIGHT_KIT: Kit = {
  family: 'knight',
  hotbar: ['shield_bash', 'grave_slam', 'bulwark', 'corpse_vigil', 'grave_brand'],
  grimoire: ['shield_bash', 'grave_slam', 'bulwark', 'corpse_vigil'],
  defaultLoadout: ['shield_bash', 'grave_slam', 'bulwark', 'corpse_vigil'],
  primaries: ['hollow_cut'],
  defaultPrimary: 'hollow_cut',
  rmb: 'grave_brand',
  signatures: { hollow_knight: 'oath_unbroken' },
};

function newBloodKit(family: ClassFamily, discipline: DisciplineId, rites: [AbilityId, AbilityId, AbilityId, AbilityId, AbilityId, AbilityId, AbilityId]): Kit {
  const [primary, one, two, three, four, rmb, signature] = rites;
  return { family, hotbar: [one, two, three, four, rmb], grimoire: [one, two, three, four],
    defaultLoadout: [one, two, three, four], primaries: [primary], defaultPrimary: primary,
    rmb, signatures: { [discipline]: signature } };
}

/**
 * Families without a kit yet fall back to the necromancer's, matching
 * `resourceRulesFor`: an unexpected `discipline_index` stays playable rather
 * than loading a class with no rites. Each is replaced when its kit lands.
 */
const KITS: Record<ClassFamily, Kit> = {
  necromancer: NECROMANCER_KIT,
  knight: KNIGHT_KIT,
  warden: newBloodKit('warden', 'grave_warden', ['flail_swing', 'lantern_cone', 'chain_pull', 'burn_the_dead', 'watchmans_ward', 'cremate', 'last_light']),
  monk: newBloodKit('monk', 'bell_monk', ['palm_strike', 'toll', 'resonant_step', 'knell', 'choir_of_one', 'sound_the_corpse', 'great_toll']),
  witch: newBloodKit('witch', 'carrion_witch', ['hook_throw', 'harvest', 'crow_swarm', 'hook_pull', 'hex_charm', 'butcher', 'murder_of_crows']),
  veil: newBloodKit('veil', 'veilwalker', ['spirit_bolt', 'veil_form', 'echo', 'veil_tear', 'crossing', 'lay_to_rest', 'between_worlds']),
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
