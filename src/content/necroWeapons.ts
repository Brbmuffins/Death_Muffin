import type { AreaId } from './areas';
import type { ItemType, Rarity } from '../net/types';

/**
 * The necromancer weapon line (docs/ALCHEMY-AND-WORLDS-PLAN.md N1): four main-hand kinds and three
 * off-hands in five material tiers. A weapon swaps what the LMB Bone Needle does and adds one passive,
 * so changing weapon is a build choice rather than a stat stick. Only the four necromancer disciplines
 * get the mechanics; every other class simply wears the stats.
 *
 * One catalogue drives everything: server rows + icons (tools/generate-necro-weapons.mjs), the offline
 * backend, loot tables, tooltips, Codex text and the in-hand models (graphics/gearProps.ts).
 * Item ids are chosen so the regexes in content/gear.ts classify them (weaponKind / offhandKind / gearTier).
 */

export const NECRO_TIERS = ['bone', 'iron', 'gold', 'hell', 'moon'] as const;
export type NecroTier = (typeof NECRO_TIERS)[number];

export const NECRO_MAIN_KINDS = ['staff', 'scythe', 'wand', 'sickle'] as const;
export type NecroMainKind = (typeof NECRO_MAIN_KINDS)[number];
export const NECRO_OFF_KINDS = ['skull_focus', 'grimoire', 'mourning_bell'] as const;
export type NecroOffKind = (typeof NECRO_OFF_KINDS)[number];
export type NecroKind = NecroMainKind | NecroOffKind;

/** The four disciplines that get weapon mechanics (client discipline ids, content/disciplines.ts). */
export const NECRO_DISCIPLINES: readonly string[] = ['ossuary', 'gravecaller', 'mourner', 'rotweaver'];

/**
 * Every number the weapon line uses. Tooltips, Codex text and the tests read it, so the prose cannot drift.
 * Only Bone Needle (the default LMB primary) changes; Bone Fan and Rot Lance keep their own rules.
 */
export const NECRO_WEAPON_TUNING = {
  staff: {
    /** Needle reach: +25%. */
    needleRangeMult: 1.25,
    /** Extra enemies the needle passes through behind its target, and what they take relative to the first. */
    pierce: 1,
    pierceDamageMult: 0.8,
    /** The pierced enemy must be within this distance of the needle's line, and this far behind the target. */
    pierceLane: 1.1,
    pierceReach: 4.5,
    /** Passive: +10% spell damage (folded into derived Spell power, so the stats line shows it). */
    spellDamageMult: 1.1,
  },
  scythe: {
    /** LMB becomes a close reaping arc: full cone angle (degrees), reach (metres), targets hit. */
    arcDeg: 100,
    reach: 3,
    maxHits: 3,
    /** Per-target damage relative to a Needle hit, cooldown and lock (a heavier, slower swing), essence per target struck. */
    damageMult: 1.15,
    cooldownMs: 520,
    lockMs: 110,
    gestureSeconds: 0.3,
    essencePerHit: 4,
    /** Bonus souls for a kill the arc delivered, on top of the normal soul every kill gives. */
    soulsPerKill: 1,
    /** How long (ms) a struck enemy still counts as reaped when it dies. */
    reapWindowMs: 1200,
  },
  wand: {
    /** Needle cooldown and cast lock are divided by this (+30% cadence). */
    cadenceMult: 1.3,
    /** Needle damage: -15%. */
    damageMult: 0.85,
  },
  sickle: {
    /** Each needle adds this many Withered stacks (up to the discipline's cap). */
    witheredStacks: 1,
    /** Passive: Exhume gives back this share of its essence cost. */
    exhumeRefund: 0.2,
  },
  skull_focus: {
    /** Thrall cap bonus at or above this tier. */
    thrallCap: 1,
    minTier: 'gold' as NecroTier,
  },
  grimoire: {
    /** Every rite (not the LMB primary) recovers 10% sooner. */
    riteCooldownMult: 0.9,
  },
  mourning_bell: {
    /** A Mourner's wraith hit heals every ally in this range by this share of their max health. */
    allyHealFrac: 0.02,
    allyHealRange: 14,
  },
} as const;

/** Tier ladder: level, rarity and economy. The server has no equip-level gate (like armor), so the level is a recommendation. */
export const NECRO_TIER_INFO: Record<NecroTier, { label: string; level: number; rarity: Rarity; sellMult: number; area: AreaId[] }> = {
  bone: { label: 'Bone', level: 1, rarity: 'common', sellMult: 1, area: ['graves', 'warren'] },
  iron: { label: 'Iron', level: 15, rarity: 'uncommon', sellMult: 2.4, area: ['ossuary', 'coliseum'] },
  gold: { label: 'Gold', level: 30, rarity: 'rare', sellMult: 5.5, area: ['nave', 'sanctum'] },
  hell: { label: 'Hell', level: 45, rarity: 'epic', sellMult: 11, area: ['cloister', 'pyre'] },
  moon: { label: 'Moon', level: 60, rarity: 'epic', sellMult: 22, area: ['pyre'] },
};

export interface NecroWeaponDef {
  id: string;
  kind: NecroKind;
  tier: NecroTier;
  name: string;
  type: ItemType;
  slot: 'main_hand' | 'off_hand';
  twoHanded: boolean;
  rarity: Rarity;
  /** Recommended character level (display only). */
  level: number;
  stats: Record<string, number>;
  sell: number;
  lore: string;
  /** One line that states what the item does for a necromancer (tooltip, Codex). */
  effect: string;
  /** Icon tint for the generated SVG. */
  color: number;
  accent: number;
}

/** Tier palette for icons: body colour and trim, echoing the in-hand gearTier tints. */
const PALETTE: Record<NecroTier, { color: number; accent: number }> = {
  bone: { color: 0xd8cfbd, accent: 0xf3ecd9 },
  iron: { color: 0x7a7d86, accent: 0xc3c7d2 },
  gold: { color: 0xd9a441, accent: 0xffe39a },
  hell: { color: 0x8a2a1a, accent: 0xff7a3d },
  moon: { color: 0xaab8e8, accent: 0xe4ebff },
};

interface KindDef {
  label: string;
  type: ItemType;
  slot: 'main_hand' | 'off_hand';
  twoHanded: boolean;
  names: Record<NecroTier, string>;
  /** [int, second stat key, second stat per tier]. */
  int: number[];
  second?: { key: string; values: number[] };
  sell: number;
  lore: Record<NecroTier, string>;
  effect: string;
}

const T = NECRO_WEAPON_TUNING;
const pct = (n: number) => `${Math.round(n * 100)}%`;

const KINDS: Record<NecroKind, KindDef> = {
  staff: {
    label: 'Staff', type: 'weapon', slot: 'main_hand', twoHanded: true,
    names: { bone: 'Vertebral Staff', iron: 'Crypt-Iron Crozier', gold: 'Reliquary Staff', hell: 'Hellcoal Crozier', moon: 'Staff of the Pale Moon' },
    int: [5, 9, 15, 22, 30], second: { key: 'stat_vit', values: [0, 1, 2, 4, 6] }, sell: 16,
    lore: {
      bone: 'Fused vertebrae, still warm from the hand that carried it. Bone Needles fly farther and pierce a second body.',
      iron: 'A grave-watch crozier with a bell-metal cap. Bone Needles fly farther and pierce a second body.',
      gold: 'Tithe-gold wound round a reliquary shaft. Bone Needles fly farther and pierce a second body.',
      hell: 'Quenched in pyre-coal; the skull at its head never stops smoking. Bone Needles fly farther and pierce a second body.',
      moon: 'Cut from a bone that never touched the ground. Bone Needles fly farther and pierce a second body.',
    },
    effect: `Bone Needle: +${pct(T.staff.needleRangeMult - 1)} range, pierces ${T.staff.pierce} extra target. Passive: +${pct(T.staff.spellDamageMult - 1)} spell damage. Two-handed.`,
  },
  scythe: {
    label: 'Scythe', type: 'weapon', slot: 'main_hand', twoHanded: true,
    names: { bone: "Gleaner's Scythe", iron: "Sexton's Scythe", gold: 'Tithe-Reaper', hell: 'Pyre Reaper', moon: 'Moonreaper' },
    int: [4, 8, 13, 19, 26], second: { key: 'stat_vit', values: [2, 3, 5, 8, 11] }, sell: 18,
    lore: {
      bone: 'A gleaner cuts what the living left standing. Your left click becomes a reaping arc; kills in it yield a soul.',
      iron: 'The sexton swings it at dusk, in rows. Your left click becomes a reaping arc; kills in it yield a soul.',
      gold: 'Every swing tolls a coin against the dead. Your left click becomes a reaping arc; kills in it yield a soul.',
      hell: 'Its edge glows where it has drunk ash. Your left click becomes a reaping arc; kills in it yield a soul.',
      moon: 'The last harvest is always by moonlight. Your left click becomes a reaping arc; kills in it yield a soul.',
    },
    effect: `Left click becomes a ${T.scythe.arcDeg}° reaping arc (${T.scythe.reach} m, hits up to ${T.scythe.maxHits}); kills in the arc give +${T.scythe.soulsPerKill} soul. Two-handed.`,
  },
  wand: {
    label: 'Wand', type: 'weapon', slot: 'main_hand', twoHanded: false,
    names: { bone: 'Knucklebone Wand', iron: 'Iron Mourning Wand', gold: 'Gilded Censer Wand', hell: 'Emberthorn Wand', moon: 'Wand of Quiet Stars' },
    int: [3, 6, 10, 15, 21], second: { key: 'stat_agi', values: [0, 1, 2, 3, 5] }, sell: 12,
    lore: {
      bone: 'Finger bones, bound in a hurry. Bone Needles come faster and strike softer.',
      iron: 'A mourner flicks it like a hand-bell. Bone Needles come faster and strike softer.',
      gold: 'A censer chain wound round the grip. Bone Needles come faster and strike softer.',
      hell: 'Thorned, and warm to the touch. Bone Needles come faster and strike softer.',
      moon: 'It weighs nothing, and is never quite still. Bone Needles come faster and strike softer.',
    },
    effect: `Bone Needle: +${pct(T.wand.cadenceMult - 1)} cadence, -${pct(1 - T.wand.damageMult)} damage. One-handed: pair it with an off-hand.`,
  },
  sickle: {
    label: 'Ritual Sickle', type: 'weapon', slot: 'main_hand', twoHanded: false,
    names: { bone: 'Barrow Sickle', iron: 'Plague Sickle', gold: "Sexton's Gilded Sickle", hell: 'Blightfire Sickle', moon: 'Moonrot Sickle' },
    int: [3, 6, 10, 14, 20], second: { key: 'stat_vit', values: [1, 2, 3, 5, 7] }, sell: 13,
    lore: {
      bone: 'A curved rib, sharpened on a headstone. Bone Needles leave the target Withered; Exhume returns essence.',
      iron: 'The plague priests cut herbs and throats with it. Bone Needles leave the target Withered; Exhume returns essence.',
      gold: 'Gilded for rites nobody admits to. Bone Needles leave the target Withered; Exhume returns essence.',
      hell: 'The rot burns instead of festering. Bone Needles leave the target Withered; Exhume returns essence.',
      moon: 'Its blade is etched with a blight the moon forgave. Bone Needles leave the target Withered; Exhume returns essence.',
    },
    effect: `Bone Needle applies ${T.sickle.witheredStacks} Withered stack. Passive: Exhume refunds ${pct(T.sickle.exhumeRefund)} of its essence. One-handed.`,
  },
  skull_focus: {
    label: 'Skull Focus', type: 'offhand', slot: 'off_hand', twoHanded: false,
    names: { bone: "Pauper's Skull Focus", iron: 'Iron-Jawed Skull Focus', gold: 'Gilded Skull Focus', hell: 'Cinder Skull Focus', moon: 'Moon Skull Focus' },
    int: [1, 3, 5, 8, 11], second: { key: 'stat_vit', values: [2, 3, 5, 8, 11] }, sell: 10,
    lore: {
      bone: 'A nameless skull that still listens. (Gold and better skulls hold one more thrall.)',
      iron: 'Its jaw is wired shut so it cannot argue. (Gold and better skulls hold one more thrall.)',
      gold: 'It remembers a legion. Hold it and command one more thrall.',
      hell: 'The eyes glow like coals in a cold hearth. Hold it and command one more thrall.',
      moon: 'It was a king, once; it still expects to be obeyed. Hold it and command one more thrall.',
    },
    effect: `Off-hand. Gold tier and above: +${T.skull_focus.thrallCap} thrall cap.`,
  },
  grimoire: {
    label: 'Grimoire', type: 'offhand', slot: 'off_hand', twoHanded: false,
    names: { bone: "Gravedigger's Grimoire", iron: 'Iron-Clasped Grimoire', gold: 'Gilt Reliquary Grimoire', hell: 'Hellbound Grimoire', moon: 'Moonlit Grimoire' },
    int: [2, 4, 7, 10, 14], sell: 11,
    lore: {
      bone: 'A gravedigger\'s ledger of names and their uses. Rites recover sooner.',
      iron: 'Chained shut, and opened only from the inside. Rites recover sooner.',
      gold: 'Every page is gilt, every margin a warning. Rites recover sooner.',
      hell: 'Its binding is singed along the spine. Rites recover sooner.',
      moon: 'The pages turn themselves to the rite you need. Rites recover sooner.',
    },
    effect: `Off-hand. Rites (your other spells, not the left click) recover ${pct(1 - T.grimoire.riteCooldownMult)} faster.`,
  },
  mourning_bell: {
    label: 'Mourning Bell', type: 'offhand', slot: 'off_hand', twoHanded: false,
    names: { bone: "Pauper's Mourning Bell", iron: 'Iron Mourning Bell', gold: 'Gilded Mourning Bell', hell: 'Cinder Mourning Bell', moon: 'Moon Mourning Bell' },
    int: [1, 3, 5, 8, 11], second: { key: 'stat_agi', values: [1, 2, 3, 5, 7] }, sell: 10,
    lore: {
      bone: 'Rung once for each name you could not save. A Mourner\'s wraith hits mend allies.',
      iron: 'Its note is flat on purpose. A Mourner\'s wraith hits mend allies.',
      gold: 'The clapper is wrapped in widow\'s silk. A Mourner\'s wraith hits mend allies.',
      hell: 'It tolls for the ones who should have stayed buried. A Mourner\'s wraith hits mend allies.',
      moon: 'You hear it a moment before it rings. A Mourner\'s wraith hits mend allies.',
    },
    effect: `Off-hand. Mourner: each wraith hit heals allies in ${T.mourning_bell.allyHealRange} m for ${pct(T.mourning_bell.allyHealFrac)} of their max health.`,
  },
};

export const NECRO_KIND_LABEL: Record<NecroKind, string> = Object.fromEntries(Object.entries(KINDS).map(([k, d]) => [k, d.label])) as Record<NecroKind, string>;

function build(): NecroWeaponDef[] {
  const out: NecroWeaponDef[] = [];
  for (const [kind, def] of Object.entries(KINDS) as [NecroKind, KindDef][]) {
    NECRO_TIERS.forEach((tier, i) => {
      const info = NECRO_TIER_INFO[tier];
      const stats: Record<string, number> = { stat_int: def.int[i] };
      if (def.second && def.second.values[i] > 0) stats[def.second.key] = def.second.values[i];
      out.push({
        id: `${kind}_${tier}`,
        kind,
        tier,
        name: def.names[tier],
        type: def.type,
        slot: def.slot,
        twoHanded: def.twoHanded,
        rarity: info.rarity,
        level: info.level,
        stats,
        sell: Math.round(def.sell * info.sellMult),
        lore: def.lore[tier],
        effect: def.effect,
        color: PALETTE[tier].color,
        accent: PALETTE[tier].accent,
      });
    });
  }
  return out;
}

export const NECRO_WEAPONS: NecroWeaponDef[] = build();
export const NECRO_WEAPON_BY_ID: Record<string, NecroWeaponDef> = Object.fromEntries(NECRO_WEAPONS.map((w) => [w.id, w]));

/** True for the item ids of this line. */
export function isNecroWeapon(itemId: string): boolean {
  return itemId in NECRO_WEAPON_BY_ID;
}

/** Whether an item id is two-handed (server `items.two_handed`; the offline mock reads this too). */
export function isTwoHanded(itemId: string): boolean {
  return NECRO_WEAPON_BY_ID[itemId]?.twoHanded ?? false;
}

/**
 * Area drops: each area offers every kind in its tier, at weight 1 each (armor pieces are also weight 1, so
 * these stay a modest share). The Cinder Pyre adds the moon tier at half weight: the rare end.
 */
export function necroWeaponLoot(area: AreaId): { item: string; weight: number }[] {
  const out: { item: string; weight: number }[] = [];
  for (const w of NECRO_WEAPONS) {
    if (!NECRO_TIER_INFO[w.tier].area.includes(area)) continue;
    out.push({ item: w.id, weight: w.tier === 'moon' ? 0.5 : 1 });
  }
  return out;
}

/** The short line an item tooltip shows under the name (null for other items). */
export function necroWeaponTooltip(itemId: string): { effect: string; level: number } | null {
  const w = NECRO_WEAPON_BY_ID[itemId];
  return w ? { effect: w.effect, level: w.level } : null;
}

/**
 * In-hand models (public/models/props/gear_<kind>.glb, baked by tools/build-necro-weapon-glbs.mjs from the raw Tripo
 * output). Lengths are world units along +Y; `grip` is the fraction of the length that sits below the grip
 * (the origin), `tip` the fraction of the length where spells leave the weapon, `yaw` the degrees the raw
 * model is turned about Y so a scythe's blade sweeps forward and a bell faces out, `anchor` where on the raw
 * model the grip axis is measured so the shaft (not the blade) sits on the origin.
 */
export const NECRO_MODEL: Record<NecroKind, { length: number; grip: number; tip: number; yaw: number; anchor: 'bottom' | 'center' | 'top' }> = {
  staff: { length: 1.85, grip: 0.3, tip: 0.94, yaw: 0, anchor: 'bottom' },
  scythe: { length: 1.95, grip: 0.36, tip: 0.93, yaw: 180, anchor: 'bottom' },
  wand: { length: 0.52, grip: 0.24, tip: 1.0, yaw: 0, anchor: 'bottom' },
  sickle: { length: 0.6, grip: 0.24, tip: 0.92, yaw: 180, anchor: 'bottom' },
  skull_focus: { length: 0.44, grip: 0.14, tip: 0.66, yaw: 0, anchor: 'bottom' },
  grimoire: { length: 0.36, grip: 0.12, tip: 1.0, yaw: 0, anchor: 'center' },
  mourning_bell: { length: 0.42, grip: 0.86, tip: 0.3, yaw: 0, anchor: 'center' },
};

/**
 * Crafting (Workbench): Carpentry makes staffs, wands and grimoires from planks; Smithing makes scythes, sickles, skull
 * foci and bells from ingots. Every tier needs the material its zone yields, so a recipe is also a progress marker.
 * Rows use the shared recipe shape ([id, name, profession, skill level, result, qty, ingredients]); the profession ids
 * are the server's existing `woodcutting` (Carpentry) and `mining` (Smithing).
 */
type Ing = [string, number][];
const WOOD_KINDS: readonly NecroKind[] = ['staff', 'wand', 'grimoire'];
const WOOD_RECIPE: Record<NecroTier, { level: number; ing: Ing }> = {
  bone: { level: 3, ing: [['plank_oak', 3], ['bones_old', 2]] },
  iron: { level: 8, ing: [['plank_elm', 3], ['ingot_iron', 1]] },
  gold: { level: 18, ing: [['plank_willow', 3], ['ingot_gold', 1]] },
  hell: { level: 42, ing: [['plank_yew', 3], ['ingot_hell', 1]] },
  moon: { level: 57, ing: [['plank_blackthorn', 3], ['ingot_moon', 1]] },
};
const SMITH_RECIPE: Record<NecroTier, { level: number; ing: Ing }> = {
  bone: { level: 2, ing: [['ingot_copper', 2], ['bones_old', 3]] },
  iron: { level: 10, ing: [['ingot_iron', 3]] },
  gold: { level: 20, ing: [['ingot_gold', 3], ['ingot_iron', 1]] },
  hell: { level: 40, ing: [['ingot_hell', 3], ['ingot_gold', 1]] },
  moon: { level: 55, ing: [['ingot_moon', 3], ['ingot_hell', 1]] },
};

export const NECRO_RECIPES: [string, string, string, number, string, number, [string, number][]][] = NECRO_WEAPONS.map((w) => {
  const wood = WOOD_KINDS.includes(w.kind);
  const r = (wood ? WOOD_RECIPE : SMITH_RECIPE)[w.tier];
  return [`craft_${w.id}`, w.name, wood ? 'woodcutting' : 'mining', r.level, w.id, 1, r.ing];
});
