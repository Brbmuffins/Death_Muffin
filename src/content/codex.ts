import {
  ABILITIES,
  BONE_MANTLE,
  DETONATE,
  FRACTURE,
  GRAVE_FROST,
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
} from './abilities';
import { AREAS, BOSS_SUMMON_SHARDS, type AreaId } from './areas';
import type { DisciplineId } from './disciplines';
import { CENSER, ENEMIES, SCREAM, type Behavior, type EnemyId } from './enemies';

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
  'ossuary_wall',
  'command_rend',
  'dirge',
  'plague_bloom',
];

export const CODEX_RITES: Record<AbilityId, RiteEntry> = {
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
};

// ---------------------------------------------------------------------------
// Disciplines
// ---------------------------------------------------------------------------

export interface DisciplineEntry {
  /** One line on how the discipline wants to be played. */
  tip: string;
}

export const CLASS_CHANGE_COUNSEL = 'Change class whenever you like through Settings → Change class. Your level, gold, items and permanent progress stay with the same character; the new discipline begins in the Chapterhouse.';

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
};

// ---------------------------------------------------------------------------
// The Dead (enemies + the Prelate)
// ---------------------------------------------------------------------------

export type DeadId = EnemyId | 'prelate';

export const DEAD_ORDER: DeadId[] = ['robber', 'hound', 'penitent', 'sac', 'deacon', 'risen', 'censer', 'wraith', 'rat', 'golem', 'prelate'];

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
  "Click a tree, ore seam, fishing spot or grave and your necromancer keeps working it until it is spent. Every cycle rolls against your level: higher levels succeed more often, and each success gives skill XP and a find, rolled and stored by the server. The Sexton's Acre, west of the Chapterhouse, has every node and no dead. Gold-lit rich nodes in the hunting grounds hold more and return twice as fast. Your bag must have room, and moving, casting, opening a panel or taking a hit stops you. Auto gathering (Settings) walks you on to the next node of the same kind.";

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
