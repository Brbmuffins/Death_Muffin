import { SET_BONUSES, SET_NAMES, describeEffect } from './setBonuses';
import { ARMOR_PIECES, ARMOR_PARTS } from './armorSets';
import { LEGENDARY_DROP } from './legendarySets';
import { AFFIXES, MAX_AFFIXES } from '../gameplay/affixRules';
import { KIT_RATES, pieceBonus } from '../gameplay/legionRules';
import { LEGION_UPGRADE } from './upgrades';
import { ITEMS } from './items';
import { BOSS_REPEAT_RUNE_CHANCE, ELITE_RUNE_CHANCE, RUNE_RITES, SURGE_RUNE_CHANCE, runeSources, runesFor, type RuneId } from './runes';
import {
  ABILITIES,
  BONE_MANTLE,
  BONE_FAN,
  CARRION_SEED,
  GRAVE_OFFERING,
  IVORY_CLEAVE,
  RALLY,
  ROT_LANCE,
  DETONATE,
  FRACTURE,
  GRAVE_FROST,
  SOUL_SIPHON,
  BONE_PRISON,
  GRAVE_HANDS,
  BONE_STORM,
  GRAVE_STEP,
  WAILING_SKULL,
  LITANY_MAX_MULT,
  LITANY_PER_CORPSE,
  LITANY_PER_RESONANT,
  LITANY_PER_THRALL,
  NEEDLE_ESSENCE,
  SIGNATURE,
  SIGNATURE_LEVEL,
  SPELL_FX,
  type AbilityId,
  KNIGHT_RAGE,
  HOLLOW_CUT,
  SHIELD_BASH,
  GRAVE_SLAM,
  BULWARK,
  CORPSE_VIGIL,
  GRAVE_BRAND,
  OATH_UNBROKEN,
  NEW_BLOOD_ABILITIES,
  type NewBloodId,
} from './abilities';
import { BREWS, brewEffectsText, slotName } from './brews';
import { itemMeta } from './items';
import { SALVAGE_RARITIES, salvagePreview } from '../gameplay/salvageRules';
import { AREA_REAGENT_DROPS, BOSS_ICHOR, ENEMY_REAGENT_DROPS, REAGENT_ITEMS, REAGENT_RECIPES } from './reagents';
import { AREAS, BOSS_SUMMON_SHARDS, type AreaId } from './areas';
import { NPCS, NPC_IDS, type NpcId } from './npcs';
import type { DisciplineId } from './disciplines';
import { ABBESS, BOSSES, CONGREGATION, GRAVEDIGGER, MIRE, REGENT, SAINT, type BossId } from './bosses';
import { BOG, HAG_HEX, SEXTON_HOOK, WISP_PULSE } from './fen';
import { STAT_EFFECTS } from '../gameplay/characterStats';
import { NECRO_KIND_LABEL, NECRO_TIERS, NECRO_TIER_INFO, NECRO_WEAPON_TUNING as WT, type NecroKind } from './necroWeapons';
import { BURROW, CENSER, DUST, EMBER_BOLT, EMBER_DEATH, ENEMIES, FRENZY, PLAGUE_FLASK, SCREAM, SLAG_POOL, TEMPLAR_SHIELD, UNBIND, WARD, type Behavior, type EnemyId } from './enemies';

/**
 * Codex text — the in-game Codex (ui/CodexPanel) and any docs/README tooling
 * read from here, so keep it DOM-free and data-only. Numbers are interpolated
 * from the tuning constants where possible so the prose can't drift from the
 * game. Stats (cost, cooldown, level, unlock thresholds) are read from the
 * content tables at render time rather than duplicated.
 */

// ---------------------------------------------------------------------------
// Rites (the six spells)
// ---------------------------------------------------------------------------

export type SpellFxKey = keyof typeof SPELL_FX;

export interface RiteEntry {
  /** Which SPELL_FX palette is this rite's colour identity. */
  fx: SpellFxKey;
  /** Plain-words name of that colour identity. */
  colour: string;
  /** "How to use it well." */
  tip: string;
}

export const RITE_ORDER: AbilityId[] = [
  'bone_needle',
  'marrow_spear',
  'exhume',
  'miasma',
  'black_litany',
  'corpse_explosion',
  'wailing_skull',
  'grave_step',
  'grave_frost',
  'bone_mantle',
  'bone_fan',
  'rot_lance',
  'grave_offering',
  'ivory_cleave',
  'veil_step',
  'rally_dead',
  'carrion_seed',
  'soul_siphon',
  'bone_prison',
  'grave_hands',
  'bone_storm',
  // Hollow Knight
  'hollow_cut',
  'shield_bash',
  'grave_slam',
  'bulwark',
  'corpse_vigil',
  'grave_brand',
  'oath_unbroken',
  ...Object.keys(NEW_BLOOD_ABILITIES) as NewBloodId[],
  'ossuary_wall',
  'command_rend',
  'dirge',
  'plague_bloom',
];

const NEW_BLOOD_CODEX = Object.fromEntries(Object.entries(NEW_BLOOD_ABILITIES).map(([id, def]) => {
  const fx = id in { flail_swing: 1, lantern_cone: 1, chain_pull: 1, burn_the_dead: 1, watchmans_ward: 1, cremate: 1, last_light: 1 }
    ? 'warden' : id in { palm_strike: 1, toll: 1, resonant_step: 1, knell: 1, choir_of_one: 1, sound_the_corpse: 1, great_toll: 1 }
      ? 'monk' : id in { hook_throw: 1, harvest: 1, crow_swarm: 1, hook_pull: 1, hex_charm: 1, butcher: 1, murder_of_crows: 1 }
        ? 'witch' : 'veilwalker';
  return [id, { fx, colour: { warden: 'Lantern gold and fire', monk: 'Pale gold and sound white', witch: 'Crow black, blood and hex green', veilwalker: 'Spectral cyan and mist' }[fx], tip: def.description }];
})) as Record<NewBloodId, RiteEntry>;

export const CODEX_RITES: Record<AbilityId, RiteEntry> = {
  ...NEW_BLOOD_CODEX,
  bone_needle: {
    fx: 'needle',
    colour: 'Bone white and old gold',
    tip: `Your essence engine. Every hit returns ${NEEDLE_ESSENCE} Grave Essence, so keep a target under attack between rites and the other four pay for themselves. On Easy, Auto (G) engages enemies in your current area and uses equipped rites, including signatures when useful. Click or use movement keys to take control, or hold 1–4 to repeat a rite at the cursor. Shift+Click to stand your ground and cast without walking in.`,
  },
  marrow_spear: {
    fx: 'spear',
    colour: 'Marrow red on cracked bone',
    tip: `Line them up before you throw: the spear pierces everything in its lane. Fracture stacks ${FRACTURE.maxStacks} times, so opening a fight with it makes every needle, thrall and Litany hit ${Math.round(FRACTURE.perStack * FRACTURE.maxStacks * 100)}% harder for ${FRACTURE.durationMs / 1000} seconds.`,
  },
  exhume: {
    fx: 'exhume',
    colour: 'Spirit teal',
    tip: 'Claim bodies fast: corpses rot within half a minute, Carrion Sacs rupture in seconds, and Crypt Deacons steal whatever you leave. Penitent and elite corpses rise empowered, and a corpse remembers what it was: hounds rise as hounds, Penitents as archers, Deacons as bone mages, Carrion Sacs as plague bearers.',
  },
  miasma: {
    fx: 'miasma',
    colour: 'Rot green',
    tip: 'Seed it where the pack is going, not where it stands. The slow holds melee off you while Withered ticks, and a door corridor or a knot of thralls turns it into a killing floor.',
  },
  black_litany: {
    fx: 'litany',
    colour: 'Void violet, kept for the Litany alone',
    tip: `Hoard before you pray. Each corpse in reach adds ${LITANY_PER_CORPSE}× spell power, a resonant corpse ${LITANY_PER_RESONANT}× more, and each thrall you give ${LITANY_PER_THRALL}×, up to ${LITANY_MAX_MULT}×. Pull the pack onto a pile of bodies, then give everything.`,
  },
  corpse_explosion: {
    fx: 'detonate',
    colour: 'Ember and crimson',
    tip: `The rite for bodies you can't use. Burst a corpse under a pack that has reached you. A resonant Penitent corpse blasts ${DETONATE.resonantRadiusMult}× wider, an elite's hits ${DETONATE.eliteDamageMult}× as hard, and a Carrion Sac's leaves a rot pool that works for you. Each one you burst is a thrall you won't raise, and a body the Litany won't count.`,
  },
  wailing_skull: {
    fx: 'skull',
    colour: 'Spirit jade',
    tip: `Grimoire rite (level ${ABILITIES.wailing_skull.unlockLevel}). The skull leaps ${WAILING_SKULL.hops - 1} more times within ${WAILING_SKULL.leapRange}m, each bite ${Math.round((1 - WAILING_SKULL.falloff) * 100)}% weaker, and a killing bite earns another leap (up to ${WAILING_SKULL.maxHops}). Open on the wounded: a Fractured, bleeding pack turns one cast into a chain.`,
  },
  grave_step: {
    fx: 'step',
    colour: 'Blood mist crimson',
    tip: `Grimoire rite (level ${ABILITIES.grave_step.unlockLevel}). Your only blink: step out of a Penitent cone or onto the pile you want to fight on. The re-forming burst bleeds everything within ${GRAVE_STEP.burstRadius}m, and the corpse stays for a Corpse Explosion or Exhume. It never crosses into another area.`,
  },
  grave_frost: {
    fx: 'frost',
    colour: 'Cold grave blue',
    tip: `Grimoire rite (level ${ABILITIES.grave_frost.unlockLevel}). Breathe it twice: the first cone Chills for ${GRAVE_FROST.chillS} seconds, and the second shatters every Chilled enemy for +${Math.round((GRAVE_FROST.shatterMult - 1) * 100)}% damage. Chilled melee swing slower, so it doubles as defence. Mourner wraiths Chill too, so a Mourner can shatter from the first breath.`,
  },
  bone_mantle: {
    fx: 'mantle',
    colour: 'Bone ivory and old gold',
    tip: `Grimoire rite (level ${ABILITIES.bone_mantle.unlockLevel}). Stand on the dead first: each of up to ${BONE_MANTLE.maxCorpses} corpses adds ${Math.round(BONE_MANTLE.barrierPerCorpse * 100)}% of your health to the barrier (${Math.round(BONE_MANTLE.barrierBase * 100)}% with none, ${Math.round(BONE_MANTLE.barrierCap * 100)}% at most), and it holds for ${BONE_MANTLE.durationS} seconds before it wears off. The shards cut anything within ${BONE_MANTLE.orbitRadius}m, so let the pack come to you.`,
  },  bone_fan: {
    fx: 'needle',
    colour: 'Bone ivory / amber',
    tip: `Primary (level ${ABILITIES.bone_fan.unlockLevel}; equip it on the Grimoire's LMB socket). ${BONE_FAN.slivers} slivers each find a different enemy near the one you click, for ${BONE_FAN.essencePerHit} essence apiece (up to ${BONE_FAN.essenceCap} a cast). Brilliant into a pack, weaker than Bone Needle on a lone elite or the Prelate, who only ever takes one sliver.`,
  },
  rot_lance: {
    fx: 'lance',
    colour: 'Rot chartreuse / olive',
    tip: `Primary (level ${ABILITIES.rot_lance.unlockLevel}). Pierces the first ${ROT_LANCE.pierce} enemies in line and stacks Withered on each (up to your Withered cap; Rotweavers go higher), with ${ROT_LANCE.essence} essence on the first hit. Line the dead up and keep lancing: Withered keeps ticking while you move on.`,
  },
  grave_offering: {
    fx: 'exhume',
    colour: 'Spirit jade',
    tip: `Grimoire rite (level ${ABILITIES.grave_offering.unlockLevel}). No cost: a corpse becomes ${GRAVE_OFFERING.essence} essence (+${GRAVE_OFFERING.resonantBonus} from a resonant body, double from an elite) and ${Math.round(GRAVE_OFFERING.healFrac * 100)}% of your health. Spend bodies you won't raise: when your legion is full, or when essence runs dry mid-fight.`,
  },
  ivory_cleave: {
    fx: 'spear',
    colour: 'Bone ivory / marrow ember',
    tip: `Grimoire rite (level ${ABILITIES.ivory_cleave.unlockLevel}). A ${IVORY_CLEAVE.halfAngleDeg * 2}° crescent out to ${IVORY_CLEAVE.reach}m that Fractures everything it cuts. Close play for any discipline: cleave the pack that reaches you, then Spear the Fractured line.`,
  },
  veil_step: {
    fx: 'veil',
    colour: 'Spirit jade / pale',
    tip: `Grimoire rite (level ${ABILITIES.veil_step.unlockLevel}). A short slip toward the cursor with no corpse needed. It stops at walls and never crosses a sealed door or into another hall. Save it for a Penitent cone or a Bell-Tolled ring; auto combat never uses it.`,
  },
  rally_dead: {
    fx: 'rend',
    colour: 'Spirit jade',
    tip: `Grimoire rite (level ${ABILITIES.rally_dead.unlockLevel}). Needs at least one thrall. For ${RALLY.durationS}s (${RALLY.durationS + RALLY.gravecallerBonusS}s for a Gravecaller) your legion hits ${Math.round((RALLY.damageMult - 1) * 100)}% harder and ${Math.round((RALLY.attackSpeedMult - 1) * 100)}% faster, heals ${Math.round(RALLY.healFrac * 100)}%, and turns on the enemy nearest your cursor: point it at the Deacon.`,
  },
  carrion_seed: {
    fx: 'bloom',
    colour: 'Rot chartreuse',
    tip: `Grimoire rite (level ${ABILITIES.carrion_seed.unlockLevel}). Seed a corpse in the pack's path: after ${CARRION_SEED.armS}s it bursts when an enemy comes within ${CARRION_SEED.triggerR}m, hitting everything in ${CARRION_SEED.burstR}m and adding ${CARRION_SEED.withered} Withered. One seed at a time, and it withers after ${CARRION_SEED.lifeS}s. Any other rite that uses the seeded corpse spends the seed with it.`,
  },
  soul_siphon: {
    fx: 'siphon',
    colour: 'Soul jade',
    tip: `Grimoire rite (level ${ABILITIES.soul_siphon.unlockLevel}). Latch onto something sturdy (an elite, a golem) and keep moving: the tether follows it for ${SOUL_SIPHON.durationS}s, healing ${Math.round(SOUL_SIPHON.healFrac * 100)}% of every tick and returning ${SOUL_SIPHON.essencePerTick} essence each time. It snaps if the target gets more than ${Math.round(ABILITIES.soul_siphon.range * SOUL_SIPHON.breakMult)}m away.`,
  },
  bone_prison: {
    fx: 'prison',
    colour: 'Aged bone',
    tip: `Grimoire rite (level ${ABILITIES.bone_prison.unlockLevel}). Drop the cage on a pack as it closes: everything inside is rooted for ${BONE_PRISON.rootS}s and Fractured, which sets up a Marrow Spear, a Corpse Explosion or a Miasma perfectly. Rooted enemies still swing at whatever stands beside them.`,
  },
  grave_hands: {
    fx: 'hands',
    colour: 'Grave earth with a spirit seep',
    tip: `Grimoire rite (level ${ABILITIES.grave_hands.unlockLevel}). Cast it where the dead lie thickest: each corpse in the field adds hands (+${Math.round(GRAVE_HANDS.perCorpse * 100)}% damage, up to ${GRAVE_HANDS.maxCorpses}) and the corpses are not used up. Everything inside is slowed for ${GRAVE_HANDS.durationS}s.`,
  },
  bone_storm: {
    fx: 'storm',
    colour: 'Aged bone and ash',
    tip: `Grimoire rite (level ${ABILITIES.bone_storm.unlockLevel}). Start it on a pile of corpses for a longer storm (+${BONE_STORM.perCorpseS}s each, up to +${BONE_STORM.maxExtraS}s; they are not used up), then let it drift through the pack on its own while you keep casting.`,
  },

  ossuary_wall: {
    fx: 'wall',
    colour: 'Bone ivory and amber',
    tip: `Ossuary signature (level ${SIGNATURE_LEVEL}). Throw it across a door or between you and the Penitents: the dead pile up against it and cones break on it for ${SIGNATURE.wall.durationS} seconds. A wall plus a Miasma behind it is a killing floor.`,
  },
  command_rend: {
    fx: 'rend',
    colour: 'Spirit jade',
    tip: `Gravecaller signature (level ${SIGNATURE_LEVEL}). Costs no essence — it costs your thralls ${Math.round(SIGNATURE.rend.hpCost * 100)}% of their health each. Send the whole legion onto a Deacon or a Penitent line, then Litany the wounded legion for full value.`,
  },
  dirge: {
    fx: 'dirge',
    colour: 'Cold funeral blue',
    tip: `Mourner signature (level ${SIGNATURE_LEVEL}). Sing it when the casters open up: Penitents and Deacons inside the song can't start a spell, and you and your wraiths mend every second for ${SIGNATURE.dirge.durationS} seconds.`,
  },
  plague_bloom: {
    fx: 'bloom',
    colour: 'Chartreuse rot',
    tip: `Rotweaver signature (level ${SIGNATURE_LEVEL}). Plant it next to a corpse pile: every ${SIGNATURE.bloom.spreadEveryS} seconds it seeds a new bloom on the nearest body, up to ${SIGNATURE.bloom.maxGenerations} generations deep. It eats the bodies it spreads through, so bloom what you won't raise.`,
  },
  // ── Hollow Knight ──────────────────────────────────────────────────────────
  hollow_cut: {
    fx: 'knight',
    colour: 'Cold steel',
    tip: `Your Rage engine. It costs nothing and every enemy the arc cuts returns ${HOLLOW_CUT.rage} Rage, so open on a clump rather than a single body — the arc is ${HOLLOW_CUT.reach}m and wide enough to catch three abreast. Rage decays ${KNIGHT_RAGE.decayPerS}/s once you have been out of combat for ${KNIGHT_RAGE.decayAfterS}s, so bank it into Grave Slam before you disengage.`,
  },
  shield_bash: {
    fx: 'knight',
    colour: 'Cold steel',
    tip: `A gap-closer that opens with control rather than damage: the first body you meet is stunned ${SHIELD_BASH.stunS}s (only ${SHIELD_BASH.bossStunS}s on a boss, so do not save it for one). Bash into a caster mid-windup and the cast is lost.`,
  },
  grave_slam: {
    fx: 'knight',
    colour: 'Cold steel with oath crimson',
    tip: `Your one Rage sink at this level, and the only rite that reaches ${GRAVE_SLAM.leapM}m. The landing hits everything within ${GRAVE_SLAM.slamR}m, so leap onto the middle of a pack, not its edge. It will not land anywhere your feet cannot go.`,
  },
  bulwark: {
    fx: 'knight',
    colour: 'Cold steel',
    tip: `Held for ${BULWARK.holdS}s, it cuts damage from the front by ${Math.round(BULWARK.damageCut * 100)}% — turn to face what is hitting you or it does nothing. Time it: a blow inside the first ${BULWARK.perfectWindowS}s is a perfect block that reflects half and pays ${KNIGHT_RAGE.perPerfectBlock} Rage, which is the fastest Rage in the kit.`,
  },
  corpse_vigil: {
    fx: 'knight',
    colour: 'Cold steel over grave dust',
    tip: `Your only heal: stand over a body and it becomes ${Math.round(CORPSE_VIGIL.regenFracPerS * 100)}% of your health a second for ${CORPSE_VIGIL.durationS}s. The corpse is spent, so in co-op say so before you take one a necromancer was saving.`,
  },
  grave_brand: {
    fx: 'knight',
    colour: 'Oath crimson',
    tip: `A trap, not a strike. Brand a body on the path you expect them to take and the first one within ${GRAVE_BRAND.triggerR}m is rooted ${GRAVE_BRAND.rootS}s. Brand behind you when you need to break away, or on a chokepoint before a wave lands.`,
  },
  oath_unbroken: {
    fx: 'knight',
    colour: 'Oath crimson',
    tip: `Hollow Knight signature (level ${SIGNATURE_LEVEL}). For ${OATH_UNBROKEN.durationS}s nothing can drop you below 1 health, you deal ${Math.round((OATH_UNBROKEN.damageMult - 1) * 100)}% more, and your Rage refills. It is a commitment, not an escape — spend the window swinging.`,
  },
};

// ---------------------------------------------------------------------------
// Disciplines
// ---------------------------------------------------------------------------

export interface DisciplineEntry {
  /** One line on how the discipline wants to be played. */
  tip: string;
}

export const CLASS_CHANGE_COUNSEL = 'Change class whenever you like through Settings → Change class. Your level, gold, items and permanent progress stay with the same character; the new discipline begins in the Sexton\'s Acre.';

export const CODEX_DISCIPLINES: Record<DisciplineId, DisciplineEntry> = {
  ossuary: {
    tip: 'Keep your shieldbearers alive and between you and the pack. Every thrall standing is armour you are wearing. At level 10, Ossuary Wall (R) throws a bone wall across a door or a Penitent line.',
  },
  gravecaller: {
    tip: 'Raise to the cap, then spend the legion in a Litany. The corpses your thralls leave behind start the next legion. At level 10, Command: Rend (R) hurls the whole legion onto a Deacon for thrall health instead of essence.',
  },
  mourner: {
    tip: 'Your wraiths fight from range and Chill what they strike, so you can hang back too. Exhume whenever you are hurt; each corpse is a mouthful of health. At level 10, Dirge (R) mends you and silences casters.',
  },
  rotweaver: {
    tip: 'Let the pack die inside your Miasma. Corpses in the rot burst on their own and spread Withered to whatever is still standing. At level 10, Plague Bloom (R) chains rot flowers through the corpse field.',
  },
  hollow_knight: {
    tip: 'You have no thralls and no Grave Essence — you have Rage, and you earn it by being hit. Open with Hollow Cut across two or three bodies, hold Bulwark facing the blow for a perfect block, then spend the Rage leaping in with Grave Slam. Corpse Vigil is your only heal, so keep one body spare. At level 10, Oath Unbroken (R) makes you unkillable for six seconds.',
  },
  grave_warden: { tip: 'Oil refills steadily. Burn bodies to fuel your lamp, pull a dangerous caster into your reach, and plant Watchman’s Ward where your party will hold. Last Light stuns the pack and mends allies.' },
  bell_monk: { tip: 'Your global bell sounds every 1.2 seconds. Strike on the beat for stronger blows and faster Resonance. Sound a corpse where Toll can reach it; Great Toll spends all the Resonance you have saved.' },
  carrion_witch: { tip: 'Offal comes only from corpses. Harvest a body before unleashing Crow Swarm, then hold the pack with Hook Pull and Hex Charm. Butcher makes healing charms for the party.' },
  veilwalker: { tip: 'Veil Form drains Veil while shielding you from enemy blows and speeding your steps. Lay a corpse to rest to create echoes, raise one with Echo, or Cross to it. Return to Life form to refill.' },
};

// ---------------------------------------------------------------------------
// The Dead (enemies + the Prelate)
// ---------------------------------------------------------------------------

/** Enemies plus every boss (bosses double as the Codex trophies: sealed until you have faced them). */
export type DeadId = EnemyId | BossId;

export const DEAD_ORDER: DeadId[] = ['robber', 'hound', 'penitent', 'sac', 'deacon', 'risen', 'censer', 'wraith', 'rat', 'golem', 'bat', 'moth', 'gargoyle', 'seraph', 'ghoul', 'acolyte', 'templar', 'niche', 'plague_doctor', 'flagellant', 'cinder_husk', 'pyre_priest', 'cinderhound', 'slag_brute', 'bog_hag', 'mire_leech', 'fen_wisp', 'drowned_sexton', 'gravedigger', 'abbess', 'congregation', 'saint', 'regent', 'mire', 'prelate'];

export const PRELATE_NAME = 'The Bell-Sworn Prelate';

export const BEHAVIOUR_LABEL: Record<Behavior | 'boss', string> = {
  melee: 'Brawler',
  flank: 'Flanker',
  caster: 'Caster',
  hazard: 'Hazard',
  support: 'Support',
  boss: 'Boss',
};

export interface DeadEntry {
  name: string;
  role: Behavior | 'boss';
  behaviour: string;
  /** What its corpse does. */
  corpse: string;
  /** Counter-play. */
  counter: string;
}

export const CODEX_DEAD: Record<DeadId, DeadEntry> = {
  robber: {
    name: ENEMIES.robber.name,
    role: ENEMIES.robber.behavior,
    behaviour: 'Walks straight at the nearest living thing and swings a spade. A short windup, steady damage, and always in numbers.',
    corpse: 'An ordinary corpse. Exhume it into a thrall or feed it to the Litany.',
    counter: 'Let thralls hold the line while you needle. A Marrow Spear down a line of robbers clears a whole wave.',
  },
  hound: {
    name: ENEMIES.hound.name,
    role: ENEMIES.hound.behavior,
    behaviour: 'Fast and fragile. Hounds never come straight on: they circle wide to your flanks, then close with a quick bite.',
    corpse: 'Swift. Exhumed, it rises as a bone hound of your own: quicker to strike, lighter than a common thrall.',
    counter: 'Do not chase them. Stand behind your thralls and let Miasma pin them in the slow.',
  },
  penitent: {
    name: ENEMIES.penitent.name,
    role: ENEMIES.penitent.behavior,
    behaviour: 'Hangs back at range and tolls a cone of grave-sound after a long, bronze windup. Backs away if you close in.',
    corpse: 'Resonant. The Litany counts it far above a common corpse. Exhumed, it rises an empowered skeleton archer that looses bone arrows from range.',
    counter: 'Step out of the cone before it sounds; the telegraph is long. Then close the gap: at range it hits harder than anything else in the Graves.',
  },
  sac: {
    name: ENEMIES.sac.name,
    role: ENEMIES.sac.behavior,
    behaviour: 'Slow and swollen. It lumbers into reach and slams the ground in front of it.',
    corpse: 'Toxic. It ruptures into a poison pool a few seconds after death unless you claim it first. Exhumed, it rises a plague bearer that bursts into a rot pool of your own when it falls or is sacrificed.',
    counter: 'Kill it away from where you mean to stand, then claim the body at once or step clear before it bursts.',
  },
  deacon: {
    name: ENEMIES.deacon.name,
    role: ENEMIES.deacon.behavior,
    behaviour: 'A support caster. It hunts unclaimed corpses, channels a green beam over them and raises them as Risen. With nothing to steal it Sanctifies a wounded ally (a pale gold halo: 30% less damage taken) or curses you from range.',
    corpse: 'One it can no longer take from you. Exhumed, it rises a bone mage whose amber hex makes enemy blows land softer.',
    counter: 'Kill it first. The green beam is your warning: the raise takes a moment, so claim the body or put the deacon down before it finishes. A Mourner\'s Dirge silences it; kill a Sanctified enemy after the halo fades.',
  },
  risen: {
    name: ENEMIES.risen.name,
    role: ENEMIES.risen.behavior,
    behaviour: 'A corpse a Crypt Deacon claimed before you did. Quick, weak, relentless.',
    corpse: 'Nothing. The deacon already spent it.',
    counter: 'Cheap to kill, but every Risen is a corpse you lost. The answer is the deacon, not the Risen.',
  },
  censer: {
    name: ENEMIES.censer.name,
    role: ENEMIES.censer.behavior,
    behaviour: `Walks with the pack swinging a bronze censer. Every second its incense Incenses the dead within ${CENSER.radius}m (bronze motes): they move ${Math.round((CENSER.moveMult - 1) * 100)}% faster and strike ${Math.round((CENSER.attackRateMult - 1) * 100)}% more often. Its own blows are weak.`,
    corpse: 'An ordinary corpse, rich with old incense.',
    counter: 'Kill it first: a pack without its censer slows back down within a breath. Wailing Skull reaches it through the crowd, and a Marrow Spear aimed at it clears the way.',
  },
  wraith: {
    name: ENEMIES.wraith.name,
    role: ENEMIES.wraith.behavior,
    behaviour: `A drifting chorister. It sings pale song-lines onto the ground where you stand, and ${ENEMIES.wraith.windupMs / 1000}s later the ring (${SCREAM.radius}m) breaks in a scream. It keeps its distance and backs away if you close.`,
    corpse: 'None. It dissolves into mist, so a choir is a fight with no corpses to spend.',
    counter: 'Keep moving while it sings; a single step out of the ring is enough. A Mourner\'s Dirge silences the choir, and Grave Step closes the distance in a blink.',
  },
  rat: {
    name: ENEMIES.rat.name,
    role: ENEMIES.rat.behavior,
    behaviour: `Pours out of the ossuary walls in packs of ${ENEMIES.rat.pack![0]}–${ENEMIES.rat.pack![1]}. Very fast and very fragile, it circles to your flanks and nips.`,
    corpse: 'None. Too small to be worth raising.',
    counter: 'Area rites: a Miasma or a Grave Frost cone ends a whole pack, and so does a Corpse Explosion on any body they swarm past. Needling them one by one is a waste of time.',
  },
  golem: {
    name: ENEMIES.golem.name,
    role: ENEMIES.golem.behavior,
    behaviour: `A walking pile of fused skeletons. It lumbers in slowly, then slams a wide ${ENEMIES.golem.slamRadius}m ring after a long windup.`,
    corpse: `Falls apart into ${ENEMIES.golem.deathCorpses} corpses: its own and the skeletons it was built from. A whole legion, or a whole Litany, in one kill.`,
    counter: 'Step out of the ring, then punish the recovery. Fracture it with Marrow Spear first, and save Black Litany or Exhume for the pile it leaves behind.',
  },
  bat: {
    name: ENEMIES.bat.name,
    role: ENEMIES.bat.behavior,
    behaviour: `Crypt bats in flocks of ${ENEMIES.bat.pack![0]}–${ENEMIES.bat.pack![1]}. Each one darts in, bites, and flits away for a moment before it comes back, so the flock never stands still.`,
    corpse: 'None. Too small to be worth raising.',
    counter: 'Chasing them is a waste of time. Stand your ground and let them come to you, then sweep them with Miasma, a Grave Frost cone, or Bone Mantle shards.',
  },
  moth: {
    name: ENEMIES.moth.name,
    role: ENEMIES.moth.behavior,
    behaviour: `A hound-sized moth that hangs back and shakes grave dust onto where you stand. ${ENEMIES.moth.windupMs / 1000}s later the ring (${DUST.radius}m) bursts, and the ochre cloud chokes anything inside it for ${DUST.cloudS}s more.`,
    corpse: 'A swift corpse: it rises as a quick hound thrall.',
    counter: 'Step out of the ring, then out of the cloud. It is fragile: a Wailing Skull or two needles bring it down, and a Dirge silences it.',
  },
  gargoyle: {
    name: ENEMIES.gargoyle.name,
    role: ENEMIES.gargoyle.behavior,
    behaviour: `A bell-tower gargoyle. From ${ENEMIES.gargoyle.dive!.minRange}–${ENEMIES.gargoyle.dive!.range}m it marks a bronze circle (${ENEMIES.gargoyle.dive!.radius}m) under you and dives onto it. Then it sits grounded in the rubble for ${ENEMIES.gargoyle.dive!.groundedS}s. Up close it rakes with its claws.`,
    corpse: 'An ordinary corpse, for all that it was stone.',
    counter: 'Walk out of the circle when it appears, then turn and punish the landing. Shield Bash or any stun knocks it out of the air mid-dive.',
  },
  seraph: {
    name: ENEMIES.seraph.name,
    role: ENEMIES.seraph.behavior,
    behaviour: `A cathedral angel come loose from its plinth. It weeps a blessing over up to ${WARD.maxTargets} allies within ${WARD.range}m at once: Sanctified, they take less damage. It never steals corpses.`,
    corpse: 'A resonant corpse: Black Litany counts it twice.',
    counter: 'Kill it first, or at least before the pack reaches you. A Dirge silences its blessing, and Wailing Skull reaches it over the crowd.',
  },
  ghoul: {
    name: ENEMIES.ghoul.name,
    role: ENEMIES.ghoul.behavior,
    behaviour: `Climbs out underground and tunnels toward the living, untouchable. Close by, the ground cracks in a ${BURROW.eruptR}m ring and it bursts out for ${BURROW.eruptMult}× damage. The first time it drops below half health it digs back in (still hittable while it digs) and tunnels up to ${BURROW.travelM}m to erupt again.`,
    corpse: 'An ordinary corpse: early fuel for Exhume.',
    counter: 'Step out of the cracking ring, then punish it. Burst it down past half in one go, or be ready while it digs: that is your window to finish it.',
  },
  acolyte: {
    name: ENEMIES.acolyte.name,
    role: ENEMIES.acolyte.behavior,
    behaviour: `A mirror-necromancer that curses from range. Any thrall of yours killed within ${UNBIND.range}m of it rises ${UNBIND.delayS}s later as a hostile Risen (once every ${UNBIND.cooldownS}s, at most ${UNBIND.maxAlive} at a time). A crimson ring shows its reach while your thralls are inside.`,
    corpse: 'An ordinary corpse.',
    counter: 'Kill it before you spend your legion near it. Sacrificed (Litany) and crumbled thralls never rise, so a Litany beside it is safe.',
  },
  templar: {
    name: ENEMIES.templar.name,
    role: ENEMIES.templar.behavior,
    behaviour: `A heavy knight of the Bell. Direct blows from its front ${TEMPLAR_SHIELD.halfArcDeg * 2}° glance off the bronze shield (only ${Math.round(TEMPLAR_SHIELD.passThrough * 100)}% gets through). Area and ground damage ignores the shield, and a Fractured Templar cannot block at all.`,
    corpse: 'A resonant corpse: Black Litany counts it twice.',
    counter: 'Let thralls turn it and strike from the side, or Fracture it first with Marrow Spear or Ivory Cleave. Miasma and rot pools work whatever way it faces.',
  },
  niche: {
    name: ENEMIES.niche.name,
    role: ENEMIES.niche.behavior,
    behaviour: `Four stand around the Bone Abbess while she is awake. While any stands she heals ${ABBESS.regenPerS * 100}% of her health a second, and one fires a Bone Lance at someone every ${ABBESS.lance.everyS}s.`,
    corpse: 'None: it crumbles to dust.',
    counter: `Break them. Each one broken tears ${ABBESS.nicheBreakFrac * 100}% of her health away and Fractures her; thralls can work on them too.`,
  },
  plague_doctor: {
    name: ENEMIES.plague_doctor.name,
    role: ENEMIES.plague_doctor.behavior,
    behaviour: `Keeps its distance and lobs a flask of plague onto where you stand. ${ENEMIES.plague_doctor.windupMs / 1000}s later it bursts (${PLAGUE_FLASK.radius}m) and leaves a rot pool that burns for ${PLAGUE_FLASK.poolS}s.`,
    corpse: 'A toxic corpse: explode or consume it before it ruptures.',
    counter: 'Step out of the green ring, then out of the pool. It is fragile up close; Grave Step or Veil Step closes the gap.',
  },
  flagellant: {
    name: ENEMIES.flagellant.name,
    role: ENEMIES.flagellant.behavior,
    behaviour: `A fast melee penitent. Below ${FRENZY.atFrac * 100}% health it frenzies: ${Math.round((FRENZY.moveMult - 1) * 100)}% faster feet and ${Math.round((FRENZY.attackRateMult - 1) * 100)}% faster blows.`,
    corpse: 'An ordinary corpse.',
    counter: 'Burst it from half to dead in one go (Marrow Spear, Wailing Skull, a Corpse Explosion), or root it in a Bone Prison first.',
  },
  cinder_husk: {
    name: ENEMIES.cinder_husk.name,
    role: ENEMIES.cinder_husk.behavior,
    behaviour: `A sturdy melee corpse. When it dies it bursts and leaves burning ground (${EMBER_DEATH.radius}m) for ${EMBER_DEATH.poolS}s.`,
    corpse: 'An ordinary corpse, lying in its own embers.',
    counter: 'Kill it at range or with a Corpse Explosion, and do not stand where it falls. Corpses that lie in the embers are still yours to take once the fire dies.',
  },
  pyre_priest: {
    name: ENEMIES.pyre_priest.name,
    role: ENEMIES.pyre_priest.behavior,
    behaviour: `Keeps its distance and hurls a coal onto where you stand. ${ENEMIES.pyre_priest.windupMs / 1000}s later it bursts (${EMBER_BOLT.radius}m) and leaves burning ground for ${EMBER_BOLT.poolS}s.`,
    corpse: 'An ordinary corpse.',
    counter: 'Step out of the orange ring, then out of the embers. It is fragile up close; Grave Step or Veil Step closes the gap.',
  },
  cinderhound: {
    name: ENEMIES.cinderhound.name,
    role: ENEMIES.cinderhound.behavior,
    behaviour: 'Fast burning flankers that arrive in packs of two or three, curving around to your side.',
    corpse: 'A swift corpse: it rises as a hound of your own.',
    counter: 'Put your back to a wall or a Bone Ward, and take them with area rites. Veil Step and Grave Step shake a pack.',
  },
  slag_brute: {
    name: ENEMIES.slag_brute.name,
    role: ENEMIES.slag_brute.behavior,
    behaviour: `Slow and heavy. Its slam lands ${ENEMIES.slag_brute.slamRadius}m wide after ${ENEMIES.slag_brute.windupMs / 1000}s and leaves the ring burning for ${SLAG_POOL.poolS}s.`,
    corpse: 'A resonant corpse: the strongest kind to raise.',
    counter: 'Leave the ring when it winds up, kite it in circles, and never fight standing in the last slam.',
  },
  bog_hag: {
    name: ENEMIES.bog_hag.name,
    role: ENEMIES.bog_hag.behavior,
    behaviour: `Stands back and lays a magenta ring (${HAG_HEX.radius}m) on the thickest knot of your thralls. Every thrall inside is hexed for ${HAG_HEX.durationS}s and deals ${Math.round((1 - HAG_HEX.thrallDamageMult) * 100)}% less damage; a sigil shows on each cursed thrall. A player caught in the ring is mired (chilled) and nicked.`,
    corpse: 'A normal corpse.',
    counter: 'Kill her first: she has little health. Or move the legion out before the ring fills (thralls follow you), and keep your corpses for bigger rites while her hex runs.',
  },
  mire_leech: {
    name: ENEMIES.mire_leech.name,
    role: ENEMIES.mire_leech.behavior,
    behaviour: 'Arrive in swarms of four to six and flank fast. Their bites are bog rot, so rot-resist brews cover them.',
    corpse: 'None. Too small to leave a body.',
    counter: 'Miasma, Corpse Explosion on a bigger body, or any area rite. Standing on a hummock keeps you fast while they come to you.',
  },
  fen_wisp: {
    name: ENEMIES.fen_wisp.name,
    role: ENEMIES.fen_wisp.behavior,
    behaviour: `A drifting marsh-light. It pulses a teal ring (${WISP_PULSE.radius}m) onto where you stand that chills you, and when pressed it backs away toward the open water at the heart of the Fen, where wading slows you.`,
    corpse: 'None.',
    counter: 'Step out of the ring, let your thralls and ranged rites catch it, and do not chase it into the water.',
  },
  drowned_sexton: {
    name: ENEMIES.drowned_sexton.name,
    role: ENEMIES.drowned_sexton.behavior,
    behaviour: `A bloated gravedigger. From ${SEXTON_HOOK.minRange}–${SEXTON_HOOK.range}m he throws a grave-hook along a marked line: whoever it catches is dragged ${SEXTON_HOOK.pullM}m toward him and held for a breath, then his slam (${ENEMIES.drowned_sexton.slamRadius}m) lands.`,
    corpse: 'Two corpses.',
    counter: 'Step sideways off the brown line when it draws, then leave the slam ring. Two corpses make him a good source for Exhume.',
  },
  gravedigger: {
    name: BOSSES.gravedigger.name,
    role: 'boss',
    behaviour: `The Hollow Graves' boss. A Spade Sweep cone, and Burial: a grave outline opens under you (${GRAVEDIGGER.burial.windupMs / 1000}s) and anyone still in it is Buried, rooted for ${GRAVEDIGGER.burial.rootS}s (you can still cast). From 60% he digs Barrow Ghouls up at the edge; from 30% four open graves bury whoever walks in, and every player gets an outline.`,
    corpse: 'None. He crawls back into his grave.',
    counter: `Offer ${BOSSES.gravedigger.shards} soul shards at the King's Grave. Step off the outline the moment it appears, and stay out of the open graves in the last phase.`,
  },
  abbess: {
    name: BOSSES.abbess.name,
    role: 'boss',
    behaviour: `The Marrow Ossuary's boss. Four skull niches heal her and fire Bone Lances. Ossuary Chorus throws eight spokes of bone out ${ABBESS.chorus.len}m (twice, rotated, from 60%). From 30% two broken niches re-form once, and Bone Communion drags every corpse in the arena to her, each healing ${ABBESS.communion.healPerCorpse * 100}%.`,
    corpse: 'None. She folds back into her reliquary.',
    counter: `Offer ${BOSSES.abbess.shards} soul shards at the Abbess's Reliquary. Break the niches first, stand between the spokes, and spend the corpses (Exhume, explode, Litany) before the Communion.`,
  },
  congregation: {
    name: BOSSES.congregation.name,
    role: 'boss',
    behaviour: `The Drowned Nave's boss. Flood Hymn sweeps a ${CONGREGATION.hymn.halfDeg * 2}° arc of black water from her (${CONGREGATION.hymn.windupMs / 1000}s): only a pew between you and her keeps you dry. Drowning Grasp rings root whoever stays in them. Each phase the water rises (slower outside her dais; Soaked in the last phase) and wraiths and penitents climb out.`,
    corpse: 'None. It sinks back into the black water.',
    counter: `Offer ${BOSSES.congregation.shards} soul shards at the Drowned Font. When the tide crests start marching, put a pew between you and her.`,
  },
  saint: {
    name: BOSSES.saint.name,
    role: 'boss',
    behaviour: `The Plague Cloister's boss, as strong as you are. Rot Rain marks circles on you and around the garth (${SAINT.rain.windupMs / 1000}s); each one becomes a rot pool. While she stands in a pool she heals. A censer swing covers the ground in front of her. Plague Doctors and Flagellants join in phase 2; phase 3 brings heavier rain, pools that last longer and a rat swarm.`,
    corpse: 'None. The blight carries her back to her litter.',
    counter: `Offer ${BOSSES.saint.shards} soul shards at the Saint's Litter. Kite her out of the rot: every second she spends in a pool undoes your damage. In her second phase the Plague Doctors heal her through a green link, so they are the priority target.`,
  },
  regent: {
    name: BOSSES.regent.name,
    role: 'boss',
    behaviour: `The Cinder Pyre's boss, as strong as you are. Coals mark ${REGENT.coals.circles[0]}–${REGENT.coals.circles[1]} circles on you and around the arena and leave burning ground; Cinder Cleave lays a line of fire down the cone. Every ${REGENT.conflagration.cd}s or so Conflagration begins: the whole arena burns after ${REGENT.conflagration.windupMs / 1000}s except the grey ash circles (${REGENT.conflagration.safe[0]}, then ${REGENT.conflagration.safe[1]}, then ${REGENT.conflagration.safe[2]}, plus one per three extra players). Husks and Priests join in phase 2; phase 3 brings hounds and fewer ash circles.`,
    corpse: 'None. The Regent crumbles to ash.',
    counter: `Offer ${BOSSES.regent.shards} soul shards at the Ember Altar. The moment Conflagration begins, run for an ash circle and stay on it until the fire has passed; use the gaps between to damage him. Kill the Pyre Priests early: their coals cover the ash you need.`,
  },
  mire: {
    name: BOSSES.mire.name,
    role: 'boss',
    behaviour: `The Mourning Fen's boss, as strong as you are. She sinks and resurfaces under a hummock: a ripple ring marks it for ${MIRE.surface.windupMs[0] / 1000}s, and she bursts out for heavy damage, then is winded for ${MIRE.surface.windedS}s. Drowned Hands root anyone wading the open water. At 60% the marsh floods (the hummocks shrink to 72%, the water slows you more, leeches climb out); at 30% she raises a Risen from every corpse lying in the Fen, and hags hex your thralls.`,
    corpse: 'None. She sinks for the last time.',
    counter: `Offer ${BOSSES.mire.shards} soul shards at the Mire Altar. Leave the ringed hummock, then hit her while she is winded; stay on dry ground when hands rise. In phase 3 spend your corpses first (Exhume, Litany, Offering, Corpse Explosion): if none are left the rite fails and she staggers.`,
  },
  prelate: {
    name: PRELATE_NAME,
    role: 'boss',
    behaviour: 'A cathedral corpse fused to a cracked processional bell. It tolls a ring around itself and slams the bell ahead; from its second phase it rains bell shards on marked circles. At 60% and 30% health a procession of Penitents and Risen files in from the aisles.',
    corpse: 'None. It sinks back beneath the Sundered Bell and waits for the next offering.',
    counter: `Offer ${BOSS_SUMMON_SHARDS} soul shards at the Sundered Bell to wake it; elites carry them. Step out of the bronze ring before the toll, and save the Litany for when the procession falls. It is a long fight: carry flasks. Its first fall each run readies the Altar of Ascension.`,
  },
};

// ---------------------------------------------------------------------------
// The Diocese (areas)
// ---------------------------------------------------------------------------

export interface AreaEntry {
  /** Notable dangers. */
  dangers: string;
}

/** Professions tab (docs/PROFESSIONS-ROADMAP.md): counsel above the generated node tables. */
export const CODEX_PROFESSIONS_COUNSEL =
  "Click a tree, ore seam, fishing spot or grave and your necromancer keeps working it until it is spent. Every cycle rolls against your level: higher levels succeed more often, and each success gives skill XP and a find, rolled and stored by the server. The Sexton's Acre, west of the Chapterhouse, has every node and no dead. The warm gold pool marks the Sawpit: click it for wood recipes. Gold-lit rich nodes in the hunting grounds hold more and return twice as fast. Your bag must have room, and moving, casting, opening a panel or taking a hit stops you. Auto gathering (Settings) walks you on to the next node of the same kind. For RuneScape-style AFK work, open Skills (P) in the Acre, choose a node and Start AFK. Gathering tools (hatchet, pickaxe, rod, spade) add +5% success per metal tier, and the best one you carry counts. Hang them on the four-slot tool belt under the paper doll in the Reliquary (I): belted tools count just like tools in your bag and take no bag space, and Skills (P) shows which tool each skill is using. Begin with level-1 Coffin-Oaks, Copper Seams, Still Pools or Pauper’s Graves near the Acre entrance. Keep the game open, including in a background tab: work continues through node changes and respawns until the bag fills. Skills may stay open; movement, casting, other panels or Pause AFK stop work. Closing or reloading the game ends the session. No offline rewards accrue. When work stops, the Sexton’s Ledger opens: time worked, finds and their worth, levels gained, your best find, lifetime milestones and personal bests. Press O for the Sexton’s Contracts: three delivery orders a day, easy to hard, drawn from what your skills can make. Deliver from your bag for gold and sometimes an item, and fill all three for a bonus; the board refreshes at midnight UTC. Press U for Grave Gardening: four Mourning Beds and two Coffin Patches that grow in real time, even while you are away. Seeds and saplings drop from graves and trees; bone meal grows a plot a quarter faster. Herbs sell, feed the Sexton’s orders and are the ground for Alchemy: at the Workbench (C, Alchemy tab) they brew into flasks and elixirs, from Moss Tonic at level 1 to the Grand Healing Flask (58) and the Moonlight Elixir (72). Mobs drop Alchemy reagents too (Grave Dust in the Graves and Warren is enough to start at level 1, no garden needed), and bosses leave ichor for the top elixirs: see Reagents below. Alchemy is its own skill, levelled by brewing. Press H for Grave Laborers: send the raised dead to work a gathering post and they keep at it, slowly, for up to eight hours even while you are away. They gather about an eighth of what you would and earn a quarter of the XP; collect when you like and the Ledger shows what they brought. You command one laborer, and another for every 50 total gathering levels, up to four. In the Sexton's Acre you can watch them work: each stands beside a node of its post with the right tool (hatchet, pickaxe, spade or rod), chopping, digging or fishing; a gold check over one means it is ready to collect, hover it for its post and time, and click it to open the Laborers. Press N for Capes & Pets: a mastery cape for level 99 in each skill, mantles for total level (100, 300, and every skill at 99), and companions (Tithe Bat, Grave Rat, Drowned Pup, Wee Thrall, Shroud Moth) that turn up as rare charms while you work; adopt a charm and the pet is yours for good. Other players see what you wear.";

/** Codex: Elixirs & Tonics (Brew engine). Rows are generated from BREWS so the numbers never drift. */
export const CODEX_BREWS_COUNSEL = 'Two brew slots, one brew each: an Elixir (combat) and a Tonic (utility). A new elixir replaces the old one; drinking the same brew again extends it (up to twice its length). Right-click a brew in the Reliquary to put it on your belt, then press Z for your elixir and X for your tonic. Healing flasks stay on Q. Brews are yours alone; the tray at the left edge shows what is active and for how long.';
export const codexBrewRows = () =>
  Object.entries(BREWS).map(([id, b]) => ({ id, name: itemMeta(id).name, slot: slotName(b.slot), effects: brewEffectsText(b), seconds: b.seconds }));
/** Stats tab: what STR / AGI / INT / VIT do. Numbers come from STAT_EFFECTS, the same table deriveStats uses. */
export const CODEX_STATS_COUNSEL =
  'Gear and levels raise four stats, and each one feeds a few numbers you can feel. Open the Reliquary (I) and every stat on a piece says what it does for you; a bag item wears a green ▲ when it is an upgrade for your discipline and a red ▼ when it is worse (hover it for the reason). Press J for the Character sheet: it lists the stats and weapons your discipline wants, your weakest slots, where each number comes from and which armor set bonuses you have. The arrows weigh damage, toughness, essence and speed for your discipline, with your thralls counted; armor set bonuses count too (an item that finishes a set says so); weapon effects such as the scythe arc get an estimated value.';
const f = (n: number) => String(+n.toFixed(3));
export const CODEX_STATS: { stat: string; name: string; effects: string }[] = [
  { stat: 'VIT', name: 'Vitality', effects: `Each point: +${STAT_EFFECTS.health.perVit} health, and your thralls have ${Math.round(STAT_EFFECTS.thrall.hpShare * 100)}% of it.` },
  { stat: 'INT', name: 'Intellect', effects: `Each point: +${STAT_EFFECTS.spell.perInt} spell power, +${STAT_EFFECTS.essence.perInt} max essence and +${STAT_EFFECTS.essenceRegen.perInt} essence per second.` },
  { stat: 'STR', name: 'Strength', effects: `Each point: +${STAT_EFFECTS.spell.perStr} spell power. A small bonus; most useful on gear you wear for other reasons.` },
  { stat: 'AGI', name: 'Agility', effects: `Each point: +${f(STAT_EFFECTS.moveSpeed.perAgi * 100)}% move speed and +${STAT_EFFECTS.spell.perAgi} spell power.` },
  { stat: 'Level', name: 'Each level', effects: `+${STAT_EFFECTS.health.perLevel} health, +${STAT_EFFECTS.spell.perLevel} spell power and +${STAT_EFFECTS.essence.perLevel} max essence.` },
  { stat: 'Thralls', name: 'Your army', effects: `A thrall's damage is ${Math.round(STAT_EFFECTS.thrall.damageShare * 100)}% of your spell power (before a staff's boost); its health is ${Math.round(STAT_EFFECTS.thrall.hpShare * 100)}% of yours. Your discipline then scales both.` },
];
/** Weapons tab: the necromancer weapon line (content/necroWeapons.ts). Numbers come from NECRO_WEAPON_TUNING. */
export const CODEX_WEAPONS_COUNSEL =
  'Necromancer weapons change your left click (Bone Needle) and add one passive, so a weapon swap is a build choice, not a stat stick. Only the four necromancer disciplines (Ossuary, Gravecaller, Mourner, Rotweaver) gain the effects; other classes wear the stats. Staffs and Scythes are two-handed and push the off-hand back to your bag. Every kind comes in five materials: Bone (Hollow Graves, Bone Warren), Iron (Marrow Ossuary, Coliseum), Gold (Drowned Nave, Bell Sanctum), Hell (Plague Cloister, Cinder Pyre) and Moon (the Pyre, rarely). Carpentry and Smithing at the Workbench craft them too.';

export interface WeaponEntry {
  kind: NecroKind;
  name: string;
  hands: string;
  change: string;
  suits: string;
  tip: string;
}

const pc = (n: number) => `${Math.round(n * 100)}%`;
export const CODEX_WEAPONS: WeaponEntry[] = [
  { kind: 'staff', name: NECRO_KIND_LABEL.staff, hands: 'Two-handed', suits: 'Ossuary and all-rounders',
    change: `Bone Needle flies ${pc(WT.staff.needleRangeMult - 1)} farther and pierces ${WT.staff.pierce} extra enemy behind its target (${pc(WT.staff.pierceDamageMult)} damage). Passive: +${pc(WT.staff.spellDamageMult - 1)} spell damage.`,
    tip: 'Line enemies up: a needle down a corridor hits two. The spell damage bonus lifts every rite, and shows in your Spell stat.' },
  { kind: 'scythe', name: NECRO_KIND_LABEL.scythe, hands: 'Two-handed', suits: 'Gravecaller, fighting beside thralls',
    change: `Your left click becomes a close reaping arc: ${WT.scythe.arcDeg} degrees, ${WT.scythe.reach} m, up to ${WT.scythe.maxHits} enemies, ${pc(WT.scythe.damageMult)} of a needle each. Each target gives back ${WT.scythe.essencePerHit} essence. Kills the arc delivers give +${WT.scythe.soulsPerKill} soul.`,
    tip: 'Stand in the thick of it with your thralls. Filling the Soul Harvest meter sooner makes Marrow Spear, Miasma and Litany free and larger.' },
  { kind: 'wand', name: NECRO_KIND_LABEL.wand, hands: 'One-handed', suits: 'Any class, paired with an off-hand',
    change: `Bone Needle fires ${pc(WT.wand.cadenceMult - 1)} faster and strikes ${pc(1 - WT.wand.damageMult)} softer.`,
    tip: 'More needles means more essence back. Pair it with a Grimoire for faster rites or a Skull Focus for a bigger legion.' },
  { kind: 'sickle', name: NECRO_KIND_LABEL.sickle, hands: 'One-handed', suits: 'Rotweaver',
    change: `Bone Needle leaves ${WT.sickle.witheredStacks} Withered stack per hit, up to your discipline's cap. Passive: Exhume gives back ${pc(WT.sickle.exhumeRefund)} of its essence.`,
    tip: 'Withered stacks tick on their own: a Rotweaver with a Sickle can needle one enemy and walk on. Miasma stacks on top.' },
  { kind: 'skull_focus', name: NECRO_KIND_LABEL.skull_focus, hands: 'Off-hand', suits: 'Gravecaller',
    change: `Gold tier and above: +${WT.skull_focus.thrallCap} thrall cap (Bone and Iron skulls are stat sticks).`,
    tip: 'One more thrall is one more body for Litany and one more blade in the line.' },
  { kind: 'grimoire', name: NECRO_KIND_LABEL.grimoire, hands: 'Off-hand', suits: 'Anyone who lives on rites',
    change: `Every rite (not the left click) recovers ${pc(1 - WT.grimoire.riteCooldownMult)} sooner.`,
    tip: 'The most for the spells with the longest waits: Miasma, Black Litany and your signature rite.' },
  { kind: 'mourning_bell', name: NECRO_KIND_LABEL.mourning_bell, hands: 'Off-hand', suits: 'Mourner',
    change: `Each hit from your wraiths heals every ally within ${WT.mourning_bell.allyHealRange} m for ${pc(WT.mourning_bell.allyHealFrac)} of their max health, you included.`,
    tip: 'More wraiths, more healing. In co-op it heals the whole party, each by their own maximum.' },
];

export const CODEX_WEAPON_TIERS = NECRO_TIERS.map((t) => ({ tier: t, label: NECRO_TIER_INFO[t].label, level: NECRO_TIER_INFO[t].level, areas: NECRO_TIER_INFO[t].area }));

/** Codex: Reagents. Rows are generated from the drop tables and recipes so the numbers never drift. */
export const CODEX_REAGENTS_COUNSEL =
  'You do not need a garden to start Alchemy. Kill the dead and they drop reagents: Grave Dust (Hollow Graves, Catacomb Warren), Wraith Ectoplasm (Choir Wraiths and Weeping Seraphs anywhere), Plague Bile (Plague Cloister) and Cinder Ash (Cinder Pyre). Every area boss always leaves one ichor. Rot-cap and Ash-bloom are foraged from patches in the Cloister and the Pyre (Gardening level 1) and their seeds grow in the Acre. Take it all to the Alchemist’s Wing, east of the Chapterhouse (the Workbench’s Alchemy tab (C) works too). Elites drop reagents four times as often.';
const pctText = (c: number) => `${Math.round(c * 1000) / 10}% per kill`;
export const codexReagentRows = () => {
  const usedIn = (id: string) => REAGENT_RECIPES.filter((r) => r[6].some(([i]) => i === id)).map((r) => itemMeta(r[4]).name);
  const dropText = (id: string): string => {
    const parts: string[] = [];
    for (const [area, list] of Object.entries(AREA_REAGENT_DROPS)) for (const d of list ?? []) if (d.item === id) parts.push(`${AREAS[area as AreaId].name}, ${pctText(d.chance)}`);
    for (const [enemy, list] of Object.entries(ENEMY_REAGENT_DROPS)) for (const d of list ?? []) if (d.item === id) parts.push(`${ENEMIES[enemy as EnemyId].name}, ${pctText(d.chance)}`);
    for (const [boss, ichor] of Object.entries(BOSS_ICHOR)) if (ichor === id) parts.push(`${BOSSES[boss as BossId].name}, always one`);
    if (id === 'herb_rot_cap' || id === 'seed_rot_cap') parts.push('Rot-cap Patches in the Plague Cloister' + (id === 'seed_rot_cap' ? ' (10% per pick); grow at Gardening 35' : ''));
    if (id === 'herb_ash_bloom' || id === 'seed_ash_bloom') parts.push('Ash-bloom Patches in the Cinder Pyre' + (id === 'seed_ash_bloom' ? ' (10% per pick); grow at Gardening 50' : ''));
    return parts.join('; ');
  };
  return Object.keys(REAGENT_ITEMS)
    .filter((id) => !id.startsWith('seed_'))
    .map((id) => ({ id, name: itemMeta(id).name, from: dropText(id), usedIn: usedIn(id).join(', ') }));
};
/** Every brew with its recipe, for the Codex Reagents entry. */
export const codexReagentRecipes = () =>
  REAGENT_RECIPES.map(([, , , level, result, qty, ings]) => ({
    level,
    name: itemMeta(result).name,
    qty,
    ings: ings.map(([i, n]) => `${n} ${itemMeta(i).name}`).join(', '),
    effects: brewEffectsText(BREWS[result]),
    seconds: BREWS[result].seconds,
    slot: slotName(BREWS[result].slot),
  }));

/** Codex: Salvaging and the Ossuary Vault. The yield rows come from salvageRules so the numbers never drift. */
export const CODEX_SALVAGE_COUNSEL =
  "Salvaging is a skill of its own, trained at the Bone Grinder in the Sexton's Acre (by the Bone Kiln). Feed it gear from your bag and it gives back an ingot (or a plank from a staff, wand or grimoire) by rarity, plus Grave Dust and sometimes other reagents. Every level adds a 0.5% chance of one extra material. XP per piece rises with rarity. Worn gear and locked items are never taken (a spare Relic rune can be ground too, one at a time, into reagents only), and if the yield will not fit your bag nothing is ground. Open the Reliquary (I) and use Salvage on an item while you stand at the Grinder, or open the Grinder itself to tick several pieces, or use Salvage all below rare.";
export const codexSalvageRows = () => {
  const nameList = (ids: string[]) => ids.map((id) => itemMeta(id).name).join(' or ');
  return SALVAGE_RARITIES.map((rarity) => {
    const ingot = salvagePreview({ id: 'helm', item_type: 'armor_head', rarity });
    const plank = salvagePreview({ id: 'staff', item_type: 'weapon', rarity });
    const qty = ingot.materialQty[0] === ingot.materialQty[1] ? `${ingot.materialQty[0]}` : `${ingot.materialQty[0]}-${ingot.materialQty[1]}`;
    const extras = ingot.reagents.filter((r) => r.id !== 'reagent_grave_dust').map((r) => `${itemMeta(r.id).name} ${Math.round(r.chance * 100)}%`);
    return { rarity, qty, ingots: nameList(ingot.materials), planks: nameList(plank.materials), reagents: `Grave Dust 1-2${extras.length ? `, ${extras.join(', ')}` : ''}`, xp: ingot.xp };
  });
};
export const CODEX_VAULT_COUNSEL =
  "The Ossuary Vault is a sarcophagus in the Chapterhouse that holds 120 slots, shared by every character on your account. Press V in the Chapterhouse or the Acre (anywhere else the dead are too close). Click an item to move its whole stack across; Deposit materials stores every unlocked material and consumable, Deposit all stores everything unlocked that you are not wearing, and Sort merges stacks and orders the Vault by type, rarity and name. A move stacks first, then fills free slots, and one that will not fit is refused with nothing changed. The padlock in the Reliquary (I) locks an item out of every bulk button: Sell all junk, the Vault's bulk buttons and Salvage all below rare.";

export const CODEX_TRAVEL_COUNSEL = 'Click a walkable spot on the minimap to choose a fixed destination. Travel follows the same paths as ground clicks; locked halls remain closed. The amber marker shows where you are going. Hover or focus a spell icon for detailed rite counsel.';

export const CODEX_AREAS: Record<AreaId, AreaEntry> = {
  chapterhouse: {
    dangers: 'None. The dead cannot follow you here. The Reliquary, the Ossuary Workbench, the Rite Niches, the Altar of Ascension and a waystone wait for you.',
  },
  alchemist_wing: {
    dangers: "None. No waves ever reach the Wing. Through the Chapterhouse's east door: the Great Cauldron and the Alembic brew every flask, tonic and elixir (the Workbench's Alchemy tab still works too), and the Reagent Shelf shows which reagents you have found and how many you hold. The Apothecary keeps the counter.",
  },
  acre: {
    dangers: "None. No waves ever reach the Acre. Trees, ore seams, black-water fishing spots and burial plots of every tier are here to work, with the stronger ones further from the Chapterhouse door. The Sawpit, Bone Kiln and Cooking Fire stand by the entrance.",
  },
  graves: {
    dangers: 'Grave Robbers in numbers, Bone Hounds on the flanks, and the odd Penitent and Carrion Sac. Learn the corpse economy here. Now and then a procession comes through: a kennel of hounds and skull-rats, or Penitents led by a Censer Bearer.',
  },
  ossuary: {
    dangers: 'The first Crypt Deacons. Hounds and Sacs come thicker, and every corpse on the floor is now contested. Skull-rats pour from the walls in packs, and a Bone Golem sometimes wakes in the bone-piles.',
  },
  nave: {
    dangers: 'The aisles are flooded; the pillar walkways stay dry. Penitents are the congregation here, tolling from every pew, and deacons walk among them. Watch for overlapping cones, and for the Choir Wraiths singing rings onto the dry walkways. Censer Bearers quicken the whole congregation.',
  },
  sanctum: {
    dangers: 'The Sundered Bell and the Prelate who serves it. Penitents and deacons hold the aisles, and elites are more common here than anywhere else. Every newer kind of dead walks here too, and the Procession marches behind a Bone Golem.',
  },
  warren: {
    dangers: "Through the Hollow Graves' west door, once 150 of the Graves' dead have fallen. Nine chambers divided by tall half-walls: the walls stop cones (a Penitent cannot hit you round a corner) and rats swarm through the gaps. Barrow Ghouls dig up inside the chambers, so keep moving.",
  },
  depths: {
    dangers: 'An endless descent, reached by the stair in the Warren\'s west chamber. Each floor is a small maze of chambers built from the Warren\'s kit; slay its quota and the stair down opens. Every floor is one level older than the last, every fifth floor gives elites another affix and a chest, and leaving or dying ends the run (what you looted is yours). Solo for now.',
  },
  coliseum: {
    dangers: "East of the Ossuary, once enough of its dead have fallen. Four gates feed a wide sand pit with fast surges, twice the usual elites and every newer kind of dead. Pillar islands and low walls are the only cover. The best drops before the Sanctum.",
  },
  pyre: {
    dangers: "Beyond the Cloister's east arch, sealed until enough of the Cloister's dead have fallen. Level-scaled like the Cloister, never below level 30. Every mob here leaves fire: Pyre Priests hurl coals that burn where they land, Cinder Husks burst into embers when they die, Slag Brutes slam rings that keep burning, and Cinderhounds arrive in fast packs.",
  },
  fen: {
    dangers: `Through the Drowned Nave's west wall, sealed until 800 of the Pyre's dead have fallen. Level-scaled, never below level 45. The marsh floor is bog water: wading slows you (x${BOG.slow}), the pale-rimmed hummocks and the dry landing do not. Bog Hags hex your thralls, Fen Wisps chill you and lure you toward the deep water, Mire Leeches swarm, and Drowned Sextons drag you in with a grave-hook. Bog myrtle and drowned lotus grow here; the Mire Mother waits at the Mire Altar.`,
  },
  cloister: {
    dangers: "Beyond the Sanctum's east door. The blight grows with you: its dead always match the highest-level player inside (never below level 20), so every kill here is worth your level. Plague Doctors lob flasks that leave rot pools, Flagellants frenzy when wounded, and sacs, rats and censers crowd the moss. The Plague Saint waits at the Saint's Litter.",
  },
};

/** Unlock condition, derived from the area table so thresholds stay in sync. */
export function areaUnlockText(id: AreaId): string {
  const a = AREAS[id];
  if (a.instance) return "The stair in the Catacomb Warren's west chamber (open once the Warren is)";
  if (a.safe) return 'Always open: your sanctuary';
  if (!a.unlock) return 'Open from the start';
  return `Slay ${a.unlock.kills} of the dead in ${AREAS[a.unlock.area].name}`;
}

// ---------------------------------------------------------------------------
// Sealed entries + lore
// ---------------------------------------------------------------------------

export const CODEX_SEALED = {
  dead: 'Unknown — slay one to learn more',
  area: 'Unknown — walk its halls to learn more',
} as const;

export const COVENANT_LORE = {
  title: 'The Ossuary Covenant',
  paragraphs: [
    'The Ossuary Covenant was founded to bury the dead properly, and for four hundred years it did. Its grave-workers kept the registers, sealed the crypts and sang the dead down into a sleep that held. Then the diocese stopped paying for candles, and the great bell in the sanctum cracked.',
    'No one agrees on what the Prelate did the night it broke. The registers say only that he rang the Sundered Bell once past breaking, and that every body inside the diocese walls heard it. The dead did not rise all at once. They rose the way damp rises: slowly, from the bottom, through everything.',
    'What is left of the Covenant works from the Chapterhouse beneath the cathedral floor. Its members are no longer priests. They are licensed necromancers, the last who know the old burial rites well enough to perform them backwards: to take a corpse the bell has claimed and make it answer to them instead.',
    'Your charter is short. Go down into the Hollow Graves and take back what the bell has taken, one body at a time. Push on through the Ossuary and the drowned Nave to the Sanctum, where the Prelate still keeps his bell. The dead you raise are not your servants. They are on loan, and the Covenant expects them returned.',
  ],
} as const;

/** Codex: the people who stand in the halls. Where they stand comes from content/npcs.ts, so the two cannot drift. */
export const CODEX_PEOPLE_COUNSEL =
  'Three of the Covenant still stand in the halls and will talk. Click one, or stand close and press E. They advise and never command: ask where to go next, or ask about a subject. A gold ! over a head means they have something new to say. The Next line under the minimap (and its ping on the map) shows one suggestion drawn from the same advice; turn either off in Settings.';
export interface PeopleEntry {
  id: NpcId;
  name: string;
  title: string;
  where: string;
  ask: string;
  blurb: string;
}
export const codexPeopleRows = (): PeopleEntry[] =>
  NPC_IDS.map((id) => ({
    id,
    name: NPCS[id].name,
    title: NPCS[id].title,
    where: `${AREAS[NPCS[id].area].name}${id === 'apothecary' ? ', at her counter' : id === 'prior' ? ', near the Altar' : ', near the Covenant Lectern'}`,
    ask: { prior: 'Where to hunt next, the seals, the kings of the dead, Ascension.', sexton: 'Gathering, Grave Laborers, the Bone Grinder, the Vault, Contracts.', apothecary: 'What to brew, where reagents fall, elixirs and tonics.' }[id],
    blurb: NPCS[id].blurb,
  }));

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function deadName(id: DeadId): string {
  return CODEX_DEAD[id].name;
}

/** 0xRRGGBB → '#rrggbb' (SPELL_FX stores three.js hex numbers). */
export function hexColour(n: number): string {
  return `#${n.toString(16).padStart(6, '0')}`;
}

/** The colour chips shown beside a rite: every colour in its SPELL_FX palette. */
export function riteSwatch(id: AbilityId): string[] {
  return Object.values(SPELL_FX[CODEX_RITES[id].fx] as Record<string, number>).map(hexColour);
}

/** Armor sets tab: every set's bonuses, generated from content/setBonuses.ts so the words follow the numbers. */
export const CODEX_SETS_COUNSEL =
  'Wear 2, 4 or 5 pieces of the same armor set for its bonuses; they stack, so five pieces gives all three lines. Pieces from different sets or collections count separately, so two sets at two pieces each give both first bonuses. Any class can wear any set, but thrall and rite lines only help the four necromancer disciplines. Hover a piece in the Reliquary (I) to see the set, press J for what each set still needs. The ascended sets (second collection) are one step stronger than the first. The four Legendary sets, one per necromancer discipline, are rarer still and change how that discipline plays.';
/** Legendary section of the Armor sets tab. */
export const CODEX_LEGENDARY_COUNSEL = `Legendary sets are the chase gear: one per necromancer discipline, five pieces each. Two pieces are a nudge, four change a mechanic and five define the build. They drop from area bosses (about ${+(LEGENDARY_DROP.bossChance * 100).toFixed(1)}% per kill, from the Marrow Ossuary onward) and very rarely (${+(LEGENDARY_DROP.eliteChance * 100).toFixed(1)}%) from elites in the Plague Cloister, Cinder Pyre and Mourning Fen. About ${Math.round(LEGENDARY_DROP.ownShare * 100)}% of the legendaries that drop for you are your own discipline's set. Hover a piece in the Reliquary to read what each tier does.`;
export interface CodexSetRow {
  setId: string;
  name: string;
  wearer: string;
  collection: 1 | 2 | 3;
  drops: string;
  bonuses: { pieces: number; name?: string; text: string }[];
}
const PART_LABEL: Record<string, string> = { head: 'Crown', chest: 'Vestment', hands: 'Grips', legs: 'Legguards', feet: 'Treads' };
export const codexSetRows = (): CodexSetRow[] => {
  const seen = new Set<string>();
  const rows: CodexSetRow[] = [];
  for (const p of ARMOR_PIECES) {
    if (seen.has(p.setId)) continue;
    seen.add(p.setId);
    const drops = ARMOR_PARTS.map((part) => ARMOR_PIECES.find((q) => q.setId === p.setId && q.part === part)!)
      .map((q) => (q.collection === 3 ? q.name : `${PART_LABEL[q.part]} (${AREAS[q.area].name})`)).join(', ') + (p.collection === 3 ? '. Drops from area bosses.' : '');
    rows.push({
      setId: p.setId, name: SET_NAMES[p.setId], wearer: p.wearer, collection: p.collection, drops,
      bonuses: SET_BONUSES[p.setId].map((b) => ({ pieces: b.pieces, name: b.name, text: describeEffect(b.effect).join(' \u00B7 ') })),
    });
  }
  return rows.sort((a, b) => a.collection - b.collection);
};

/** Item level and affixes tab: rows come from the affix pool (gameplay/affixRules.ts), so the ranges are the ones the server rolls. */
export const CODEX_AFFIX_COUNSEL =
  `Gear drops with an item level (ilvl) and up to ${MAX_AFFIXES} affixes, rolled by the server when it drops, so they cannot be edited. A piece's colour follows its affix count: one affix is green, two blue, three purple (a rarer base item keeps its own colour). The item level is the level of what dropped it, plus 2 from an elite, 4 from a boss and 5 from a boss's first kill; it sets how big the numbers can be. Bosses always leave an affix and a first kill leaves two or more. Violet † lines are necromancer levers (thralls, essence, Miasma, Withered stacks, ward); they work for any class but only matter to the four necromancer disciplines. Affixes are named on the item: the first prefix goes before the name and the first suffix after it. The arrow on a bag item and the Character sheet (J) count affixes. Salvaging and selling pay more for a high item level and for every affix; Sell all junk and Salvage all skip pieces with a necromancer affix.`;
export interface CodexAffixRow {
  word: string;
  kind: string;
  necro: boolean;
  low: string;
  high: string;
}
/** Each affix at two item levels (10 and 40): the weakest roll, and "up to" the strongest, in the affix's own words. */
export const codexAffixRows = (): CodexAffixRow[] =>
  AFFIXES.map((a) => {
    const line = (L: number) => {
      const [lo, hi] = a.range(L);
      return lo === hi ? a.text(lo) : `${a.text(lo)} (up to ${a.text(hi)})`;
    };
    return { word: a.kind === 'prefix' ? `${a.word} \u2026` : `\u2026 ${a.word}`, kind: a.kind, necro: a.necro, low: line(10), high: line(40) };
  });

/** Codex: the Legion kit (thrall gear) and its Reinforce gold sink. The examples and the cost ladder are computed from the rules, so they cannot drift. */
export const CODEX_LEGION_COUNSEL =
  `Your thralls can wear spare gear. Press Y (necromancers) or use the Legion button in the Reliquary: one Weapon slot (a weapon or off-hand) and one Armour slot (a helm, chest, legs, boots or gloves), kept outside your bag, so the Vault, Salvage and Sell all junk never touch them. A piece's stat points (STR, AGI, INT and VIT, plus flat stat affixes) become thrall bonuses: a weapon gives +${+(KIT_RATES.weaponDamagePerPoint * 100).toFixed(1)}% thrall damage and +${+(KIT_RATES.weaponSpeedPerPoint * 100).toFixed(2)}% attack speed per point, armour gives +${+(KIT_RATES.armorHpPerPoint * 100).toFixed(1)}% thrall health per point, each capped (+${KIT_RATES.weaponDamageCap * 100}% damage, +${KIT_RATES.weaponSpeedCap * 100}% attack speed, +${KIT_RATES.armorHpCap * 100}% health). Gravebound, of the Legion and of the Ossuary Wall affixes count too, at ${KIT_RATES.affixShare * 100}% of their worn strength; other affixes belong to you alone. Kit pieces never change your own stats. Each spare weapon and armour piece in the Legion panel wears a green ▲ or red ▼ against what the legion holds now. The bonus applies to thralls you raise after a change (the ones already standing keep what they were raised with), and archers and bone mages show the kit bow and staff while every kit-wearing thrall takes a light wash of the armour's colour. Reinforce binds the dead tighter for gold: ${LEGION_UPGRADE.maxTier} tiers, each +${LEGION_UPGRADE.perTier * 100}% thrall health and damage and +${LEGION_UPGRADE.speedPerTier * 100}% attack speed, at a price that rises with every tier. Like Damage and Wave Speed, the tiers reset when you Ascend; the kit pieces stay.`;
export interface CodexLegionExample { item: string; slot: string; points: number; gives: string }
export const codexLegionExamples = (): CodexLegionExample[] =>
  ['bow_oak', 'sword_copper', 'staff_iron', 'staff_moon', 'helm_copper', 'plate_copper', 'chest_iron', 'set_ossuary_ascended_chest'].map((id) => {
    const m = ITEMS[id];
    const kit = m.type === 'weapon' || m.type === 'offhand' ? 'weapon' : 'armor';
    const b = pieceBonus(kit, { itemType: m.type, statBonus: m.offlineStats ?? null });
    const parts = [b.damage && `+${+(b.damage * 100).toFixed(1)}% damage`, b.speed && `+${+(b.speed * 100).toFixed(1)}% attack speed`, b.hp && `+${+(b.hp * 100).toFixed(1)}% health`].filter(Boolean);
    return { item: m.name, slot: kit === 'weapon' ? 'Weapon' : 'Armour', points: b.points, gives: parts.join(', ') };
  });
export const codexLegionTiers = () =>
  Array.from({ length: LEGION_UPGRADE.maxTier }, (_, i) => ({
    tier: i + 1,
    cost: LEGION_UPGRADE.cost(i),
    total: Array.from({ length: i + 1 }, (_, k) => LEGION_UPGRADE.cost(k)).reduce((a, b) => a + b, 0),
    bonus: `+${+((i + 1) * LEGION_UPGRADE.perTier * 100).toFixed(1)}% health and damage, +${+((i + 1) * LEGION_UPGRADE.speedPerTier * 100).toFixed(1)}% attack speed`,
  }));

/** Codex: Relic runes. Every number in the lines comes from RUNE_TUNING (content/runes.ts), so the words follow the game. */
export const CODEX_RUNES_COUNSEL =
  `Runes are the build-depth layer: each changes how a rite behaves, not how hard it hits, and the five necromancer rites (Bone Needle, Marrow Spear, Exhume, Miasma Circle, Black Litany) take one each. Open the Grimoire (L), pick a rite and socket a rune from your bag; a rune fits only its own rite, a jade badge on the hotbar slot shows it, and hovering the slot says exactly what changed. Taking a rune out, or setting another in its place, returns it to your bag: nothing is ever lost. Runes stack in the Reliquary, can rest in the Ossuary Vault, sell for gold and can be ground at the Bone Grinder (one at a time, into reagents only). They drop from elites (${+(ELITE_RUNE_CHANCE * 100).toFixed(1)}% a kill), from Grave Surge offerings (${SURGE_RUNE_CHANCE * 100}% of them) and from bosses: the Prelate and every boss's first kill always leave one, repeat kills ${BOSS_REPEAT_RUNE_CHANCE * 100}% of the time. The first grounds shed uncommon runes only; rares start in the Marrow Ossuary and epics in the Bell Sanctum. A Bone Needle rune works with the needle, not with a scythe's arc. Runes are for the necromancer disciplines (Ossuary, Gravecaller, Mourner, Rotweaver).`;
export interface CodexRuneRow { id: RuneId; name: string; rarity: string; rite: string; short: string; lines: string[]; cost: string | null; lore: string; sources: string }
export const codexRuneRows = (): { rite: string; runes: CodexRuneRow[] }[] =>
  RUNE_RITES.map((rite) => ({
    rite: ABILITIES[rite].name,
    runes: runesFor(rite).map((r) => ({ id: r.id, name: r.name, rarity: r.rarity, rite: ABILITIES[rite].name, short: r.short, lines: r.lines, cost: r.cost, lore: r.lore, sources: runeSources(r.id) })),
  }));
