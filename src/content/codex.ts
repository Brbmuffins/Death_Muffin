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
import { AREAS, BOSS_SUMMON_SHARDS, type AreaId } from './areas';
import type { DisciplineId } from './disciplines';
import { BURROW, CENSER, DUST, ENEMIES, SCREAM, TEMPLAR_SHIELD, UNBIND, WARD, type Behavior, type EnemyId } from './enemies';

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
    tip: `Your essence engine. Every hit returns ${NEEDLE_ESSENCE} Grave Essence, so keep a target under attack between rites and the other four pay for themselves. Auto combat (G) handles nearby targets and basic rites while standing still; click to move, or hold 1–4 to repeat a rite at the cursor. Signature rites stay manual. Shift+Click to stand your ground and cast without walking in.`,
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

export type DeadId = EnemyId | 'prelate';

export const DEAD_ORDER: DeadId[] = ['robber', 'hound', 'penitent', 'sac', 'deacon', 'risen', 'censer', 'wraith', 'rat', 'golem', 'bat', 'moth', 'gargoyle', 'seraph', 'ghoul', 'acolyte', 'templar', 'prelate'];

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
  "Click a tree, ore seam, fishing spot or grave and your necromancer keeps working it until it is spent. Every cycle rolls against your level: higher levels succeed more often, and each success gives skill XP and a find, rolled and stored by the server. The Sexton's Acre, west of the Chapterhouse, has every node and no dead. The warm gold pool marks the Sawpit: click it for wood recipes. Gold-lit rich nodes in the hunting grounds hold more and return twice as fast. Your bag must have room, and moving, casting, opening a panel or taking a hit stops you. Auto gathering (Settings) walks you on to the next node of the same kind. For RuneScape-style AFK work, open Skills (P) in the Acre, choose a node and Start AFK. Begin with level-1 Coffin-Oaks, Copper Seams, Still Pools or Pauper’s Graves near the Acre entrance. Keep the game open, including in a background tab: work continues through node changes and respawns until the bag fills. Skills may stay open; movement, casting, other panels or Pause AFK stop work. Closing or reloading the game ends the session. No offline rewards accrue.";

export const CODEX_TRAVEL_COUNSEL = 'Click a walkable spot on the minimap to choose a fixed destination. Travel follows the same paths as ground clicks; locked halls remain closed. The amber marker shows where you are going. Hover or focus a spell icon for detailed rite counsel.';

export const CODEX_AREAS: Record<AreaId, AreaEntry> = {
  chapterhouse: {
    dangers: 'None. The dead cannot follow you here. The Reliquary, the Ossuary Workbench, the Rite Niches, the Altar of Ascension and a waystone wait for you.',
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
};

/** Unlock condition, derived from the area table so thresholds stay in sync. */
export function areaUnlockText(id: AreaId): string {
  const a = AREAS[id];
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
