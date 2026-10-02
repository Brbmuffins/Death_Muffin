/**
 * The shared necromancer kit. Data only — behaviour lives in
 * gameplay/AbilitySystem.ts. `power` multiplies the caster's spell power.
 */
export type AbilityId =
  | 'bone_needle'
  | 'marrow_spear'
  | 'exhume'
  | 'miasma'
  | 'black_litany'
  | 'corpse_explosion'
  // Grimoire rites: level-gated alternatives for the five swappable slots (see GRIMOIRE).
  | 'wailing_skull'
  | 'grave_step'
  | 'grave_frost'
  | 'bone_mantle'
  // Spell variety (docs/agent-briefs/spell-variety-first-session.md §4): two primaries and five keys.
  | 'bone_fan'
  | 'rot_lance'
  | 'grave_offering'
  | 'ivory_cleave'
  | 'veil_step'
  | 'rally_dead'
  | 'carrion_seed'
  // Grimoire expansion (2026-09-28): four new shapes, with Binbun VFX layered on.
  | 'soul_siphon'
  | 'bone_prison'
  | 'grave_hands'
  | 'bone_storm'
  // Hollow Knight (Release 0.3, family 'knight'). Rage, not Grave Essence.
  | 'hollow_cut'
  | 'shield_bash'
  | 'grave_slam'
  | 'bulwark'
  | 'corpse_vigil'
  | 'grave_brand'
  | 'oath_unbroken'
  | 'flail_swing' | 'lantern_cone' | 'chain_pull' | 'burn_the_dead' | 'watchmans_ward' | 'cremate' | 'last_light'
  | 'palm_strike' | 'toll' | 'resonant_step' | 'knell' | 'choir_of_one' | 'sound_the_corpse' | 'great_toll'
  | 'hook_throw' | 'harvest' | 'crow_swarm' | 'hook_pull' | 'hex_charm' | 'butcher' | 'murder_of_crows'
  | 'spirit_bolt' | 'veil_form' | 'echo' | 'veil_tear' | 'crossing' | 'lay_to_rest' | 'between_worlds'
  // Discipline signature rites (level 10, key R / 6).
  | 'ossuary_wall'
  | 'command_rend'
  | 'dirge'
  | 'plague_bloom';
export type Targeting = 'enemy' | 'direction' | 'corpse' | 'ground' | 'self';
/** Hotbar position: 1–4 = number keys, 5 = right-click (also key 5), 6 = the discipline's signature (R / 6). */
export type HotbarSlot = 1 | 2 | 3 | 4 | 5 | 6;

export interface AbilityDef {
  id: AbilityId;
  /**
   * 0 = primary (left click), 1–5 = a Grimoire rite (the number is its
   * default slot; the player's loadout decides the real one), 6 = signature.
   */
  slot: 0 | HotbarSlot;
  /** Character level that unlocks the rite (default 1). */
  unlockLevel?: number;
  name: string;
  description: string;
  icon: string;
  targeting: Targeting;
  cooldownMs: number;
  essenceCost: number;
  range: number;
  radius: number;
  power: number;
}

export type NewBloodId = Exclude<AbilityId,
  | 'bone_needle' | 'marrow_spear' | 'exhume' | 'miasma' | 'black_litany' | 'corpse_explosion'
  | 'wailing_skull' | 'grave_step' | 'grave_frost' | 'bone_mantle' | 'bone_fan' | 'rot_lance'
  | 'grave_offering' | 'ivory_cleave' | 'veil_step' | 'rally_dead' | 'carrion_seed'
  | 'soul_siphon' | 'bone_prison' | 'grave_hands' | 'bone_storm'
  | 'hollow_cut' | 'shield_bash' | 'grave_slam' | 'bulwark' | 'corpse_vigil' | 'grave_brand' | 'oath_unbroken'
  | 'ossuary_wall' | 'command_rend' | 'dirge' | 'plague_bloom'>;

function newRite(id: NewBloodId, slot: AbilityDef['slot'], name: string, family: string, icon: string,
  targeting: Targeting, cooldownMs: number, essenceCost: number, range: number, radius: number,
  power: number, description: string, unlockLevel?: number): AbilityDef {
  return { id, slot, name, description, icon: `art/abilities/${family}-${icon}.webp`, targeting,
    cooldownMs, essenceCost, range, radius, power, ...(unlockLevel ? { unlockLevel } : {}) };
}

/** Release 0.3 class rites. The sim owns corpse spends, displacement and lasting statuses. */
export const NEW_BLOOD_ABILITIES: Record<NewBloodId, AbilityDef> = {
  flail_swing: newRite('flail_swing', 0, 'Flail Swing', 'warden', 'flail-swing', 'direction', 600, 0, 3, 3, 1, 'Sweep the flail through a wide arc in front of you.'),
  lantern_cone: newRite('lantern_cone', 1, 'Lantern Cone', 'warden', 'lantern-cone', 'direction', 4000, 20, 7, 7, 1.3, 'Burn a cone of enemies, strip Shrouded and stun wraiths.'),
  chain_pull: newRite('chain_pull', 2, 'Chain Pull', 'warden', 'chain-pull', 'enemy', 6000, 10, 10, 0, 0.6, 'Pull an enemy to your feet. Bosses cannot be pulled.'),
  burn_the_dead: newRite('burn_the_dead', 3, 'Burn the Dead', 'warden', 'burn-the-dead', 'ground', 9000, 0, 10, 4, 0.5, 'Burn up to three corpses into fire pools for five seconds. Gain 20 Oil for each.', 3),
  watchmans_ward: newRite('watchmans_ward', 4, "Watchman's Ward", 'warden', 'watchmans-ward', 'ground', 18000, 25, 10, 5, 0, 'Plant a lantern for eight seconds. Allies inside take less damage and enemies slow.', 5),
  cremate: newRite('cremate', 5, 'Cremate', 'warden', 'cremate', 'corpse', 5000, 0, 12, 1.2, 0.7, 'Spend one corpse to kindle a three-second fire pillar.'),
  last_light: newRite('last_light', 6, 'Last Light', 'warden', 'last-light', 'self', 50000, 0, 0, 12, 1.2, 'Stun nearby enemies, strip Shrouded and heal nearby allies by 10%.', 10),
  palm_strike: newRite('palm_strike', 0, 'Palm Strike', 'monk', 'palm-strike', 'enemy', 400, 0, 1.8, 0, 1, 'A quick palm strike. Hits on the bell beat deal extra damage and Resonance.'),
  toll: newRite('toll', 1, 'Toll', 'monk', 'toll', 'self', 4500, 0, 0, 4, 1.2, 'Ring around you and interrupt casters. Spend 25 Resonance to stun.'),
  resonant_step: newRite('resonant_step', 2, 'Resonant Step', 'monk', 'resonant-step', 'direction', 6000, 0, 5, 0.8, 1, 'Dash through enemies, striking every body along the path.'),
  knell: newRite('knell', 3, 'Knell', 'monk', 'knell', 'enemy', 9000, 15, 9, 0, 0.6, 'Mark a target. The next three tolls hurt it harder.', 3),
  choir_of_one: newRite('choir_of_one', 4, 'Choir of One', 'monk', 'choir-of-one', 'self', 20000, 30, 0, 2.5, 0.5, 'For six seconds every beat emits a small toll ring.', 5),
  sound_the_corpse: newRite('sound_the_corpse', 5, 'Sound the Corpse', 'monk', 'sound-the-corpse', 'corpse', 7000, 0, 10, 1.2, 0.8, 'Sound a corpse as a resonant bell. Tolls near it strike harder.'),
  great_toll: newRite('great_toll', 6, 'Great Toll', 'monk', 'great-toll', 'self', 50000, 0, 0, 9, 2, 'Spend all Resonance on a great toll that damages and silences foes.', 10),
  hook_throw: newRite('hook_throw', 0, 'Hook Throw', 'witch', 'hook-throw', 'enemy', 550, 0, 8, 0, 1, 'Hurl a hook that bleeds its target.'),
  harvest: newRite('harvest', 1, 'Harvest', 'witch', 'harvest', 'corpse', 6000, 0, 10, 1.2, 0, 'Consume a corpse for 30 Offal and summon three crows for six seconds.'),
  crow_swarm: newRite('crow_swarm', 2, 'Crow Swarm', 'witch', 'crow-swarm', 'ground', 8000, 30, 10, 3, 0.4, 'Send crows into a three-metre circle for five seconds.'),
  hook_pull: newRite('hook_pull', 3, 'Hook Pull', 'witch', 'hook-pull', 'enemy', 7000, 10, 8, 0, 0.6, 'Drag an enemy to you. Bosses cannot be pulled.', 3),
  hex_charm: newRite('hex_charm', 4, 'Hex Charm', 'witch', 'hex-charm', 'enemy', 12000, 20, 9, 0, 0.3, 'Curse a target to deal 25% less damage. On death it jumps to two neighbours.', 5),
  butcher: newRite('butcher', 5, 'Butcher', 'witch', 'butcher', 'corpse', 7000, 0, 10, 1.2, 0, 'Carve a corpse into three charms. Allies who collect them heal 5%.'),
  murder_of_crows: newRite('murder_of_crows', 6, 'Murder of Crows', 'witch', 'murder-of-crows', 'ground', 50000, 35, 12, 4, 0.7, 'An eight-second swarm follows your aim and rends nearby enemies.', 10),
  spirit_bolt: newRite('spirit_bolt', 0, 'Spirit Bolt', 'veil', 'spirit-bolt', 'enemy', 450, 0, 11, 0, 1, 'Loose a spectral bolt from your palm.'),
  veil_form: newRite('veil_form', 1, 'Veil Form', 'veil', 'veil-form', 'self', 500, 0, 0, 0, 0, 'Toggle Veil form. Avoid enemy blows, move faster and deal less damage while Veil drains.'),
  echo: newRite('echo', 2, 'Echo', 'veil', 'echo', 'corpse', 7000, 25, 12, 1.2, 0, 'Raise an echo corpse as a spectral ally for ten seconds.'),
  veil_tear: newRite('veil_tear', 3, 'Veil Tear', 'veil', 'veil-tear', 'ground', 10000, 20, 10, 3, 0.4, 'Open a two-second rift that draws enemies inward.', 3),
  crossing: newRite('crossing', 4, 'Crossing', 'veil', 'crossing', 'corpse', 10000, 15, 12, 1.2, 0, 'Blink to an echo corpse.', 5),
  lay_to_rest: newRite('lay_to_rest', 5, 'Lay to Rest', 'veil', 'lay-to-rest', 'corpse', 6000, 0, 10, 1.2, 0, 'Consume a corpse, heal 6% and leave two echo corpses.'),
  between_worlds: newRite('between_worlds', 6, 'Between Worlds', 'veil', 'between-worlds', 'self', 60000, 0, 0, 0, 0, 'For five seconds gain Veil protection with full Life-form damage.', 10),
};

export const ABILITIES: Record<AbilityId, AbilityDef> = {
  ...NEW_BLOOD_ABILITIES,
  bone_needle: {
    id: 'bone_needle',
    slot: 0,
    name: 'Bone Needle',
    description: 'Fling a sliver of marrow. Each hit returns 6 Grave Essence.',
    icon: 'art/abilities/necro-needle.webp',
    targeting: 'enemy',
    cooldownMs: 380,
    essenceCost: 0,
    range: 11,
    radius: 0.35,
    power: 1.0,
  },
  marrow_spear: {
    id: 'marrow_spear',
    slot: 1,
    name: 'Marrow Spear',
    description: 'A line of bone erupts toward the cursor, piercing everything and applying Fracture (+15% damage taken, 3 stacks).',
    icon: 'art/abilities/necro-spear.webp',
    targeting: 'direction',
    cooldownMs: 2200,
    essenceCost: 18,
    range: 12,
    radius: 0.9,
    power: 2.1,
  },
  exhume: {
    id: 'exhume',
    slot: 2,
    name: 'Exhume',
    description: 'Consume the corpse nearest the cursor and raise it as your thrall. At the cap, your oldest thrall crumbles.',
    icon: 'art/abilities/necro-exhume.webp',
    targeting: 'corpse',
    cooldownMs: 500,
    essenceCost: 12,
    range: 13,
    radius: 3.2,
    power: 0,
  },
  miasma: {
    id: 'miasma',
    slot: 3,
    name: 'Miasma Circle',
    description: 'Seed rot at the cursor for 6s. Enemies inside are slowed 40% and gain a Withered stack each second.',
    icon: 'art/abilities/necro-miasma.webp',
    targeting: 'ground',
    cooldownMs: 7000,
    essenceCost: 25,
    range: 14,
    radius: 3.8,
    power: 0.22,
  },
  black_litany: {
    id: 'black_litany',
    slot: 4,
    name: 'Black Litany',
    description: 'Consume every corpse and sacrifice every thrall within 7m in one ritual burst. Power grows with what you give.',
    icon: 'art/abilities/necro-litany.webp',
    targeting: 'self',
    cooldownMs: 14000,
    essenceCost: 40,
    range: 0,
    radius: 7,
    power: 1.5,
  },
  corpse_explosion: {
    id: 'corpse_explosion',
    slot: 5,
    name: 'Corpse Explosion',
    description:
      'Right-click a corpse to burst it in a 3m blast of marrow and bone. Resonant corpses blast wider, toxic corpses leave a rot pool, elite corpses hit twice as hard.',
    icon: 'art/abilities/necro-corpse-explosion.webp',
    targeting: 'corpse',
    cooldownMs: 600,
    essenceCost: 15,
    range: 13,
    /** Blast radius; the sim owns it (clients never send a radius). */
    radius: 3,
    power: 1.8,
  },
  // --- Grimoire rites: level-gated; any four of GRIMOIRE sit on keys 1–4. Each borrows the
  // feel of a shipped rite: the skull flies like Bone Needle, Grave Step picks corpses like
  // Corpse Explosion, Grave Frost resolves its cone like Marrow Spear, and Bone Mantle
  // consumes corpses on the host like Black Litany.
  wailing_skull: {
    id: 'wailing_skull',
    slot: 1,
    unlockLevel: 3,
    name: 'Wailing Skull',
    description: 'Loose a shrieking skull at the enemy nearest the cursor. It leaps to 2 more, each leap 20% weaker, and a leap that kills earns another (up to 5).',
    icon: 'art/abilities/necro-wailing-skull.webp',
    targeting: 'enemy',
    cooldownMs: 3000,
    essenceCost: 16,
    range: 13,
    radius: 4,
    power: 2.4,
  },
  grave_step: {
    id: 'grave_step',
    slot: 2,
    unlockLevel: 5,
    name: 'Grave Step',
    description: 'Dissolve into blood mist and re-form on the corpse nearest the cursor, up to 12m away. Enemies around it take a marrow burst and bleed. The corpse stays for your next rite.',
    icon: 'art/abilities/necro-grave-step.webp',
    targeting: 'corpse',
    cooldownMs: 5000,
    essenceCost: 10,
    range: 12,
    radius: 2.6,
    power: 1.3,
  },
  grave_frost: {
    id: 'grave_frost',
    slot: 3,
    unlockLevel: 7,
    name: 'Grave Frost',
    description: "Exhale the barrow's chill in a 7m cone toward the cursor. Every enemy it touches is Chilled (−30% move, −25% attack speed); enemies already Chilled shatter for +50% damage.",
    icon: 'art/abilities/necro-grave-frost.webp',
    targeting: 'direction',
    cooldownMs: 4500,
    essenceCost: 20,
    range: 7,
    radius: 7,
    power: 1.4,
  },
  bone_mantle: {
    id: 'bone_mantle',
    slot: 4,
    unlockLevel: 12,
    name: 'Bone Mantle',
    description: 'Draw up to 5 corpses within 6m into a whirling mantle: a barrier of 10% max health +7% per corpse holds for 6s, while bone shards shred enemies beside you.',
    icon: 'art/abilities/necro-bone-mantle.webp',
    targeting: 'self',
    cooldownMs: 15000,
    essenceCost: 25,
    range: 0,
    radius: 6,
    power: 0.3,
  },
  // --- Spell variety: primaries (left click, no cost) and five more Grimoire rites. ---
  bone_fan: {
    id: 'bone_fan',
    slot: 0,
    unlockLevel: 2,
    name: 'Bone Fan',
    description: 'Fling three slivers in a fan. Each homes on a different enemy near the one you clicked (the Prelate takes only one). +3 essence per sliver that lands.',
    icon: 'art/abilities/necro-bone-fan.webp',
    targeting: 'enemy',
    cooldownMs: 520,
    essenceCost: 0,
    range: 8,
    radius: 0.35,
    power: 0.55,
  },
  rot_lance: {
    id: 'rot_lance',
    slot: 0,
    unlockLevel: 6,
    name: 'Rot Lance',
    description: 'A lance of rot pierces the first two enemies in a line toward your target, adding a stack of Withered to each. +4 essence on the first hit.',
    icon: 'art/abilities/necro-rot-lance.webp',
    targeting: 'enemy',
    cooldownMs: 700,
    essenceCost: 0,
    range: 14,
    radius: 0.5,
    power: 0.8,
  },
  grave_offering: {
    id: 'grave_offering',
    slot: 2,
    unlockLevel: 2,
    name: 'Grave Offering',
    description: 'Burn the corpse nearest the cursor into your own reserves: +16 Grave Essence (more from resonant and elite bodies) and 4% of your health.',
    icon: 'art/abilities/necro-grave-offering.webp',
    targeting: 'corpse',
    cooldownMs: 2000,
    essenceCost: 0,
    range: 13,
    radius: 2.5,
    power: 0,
  },
  ivory_cleave: {
    id: 'ivory_cleave',
    slot: 1,
    unlockLevel: 4,
    name: 'Ivory Cleave',
    description: 'Sweep a crescent of bone through everything in a wide arc in front of you (3.6m), Fracturing what it cuts.',
    icon: 'art/abilities/necro-ivory-cleave.webp',
    targeting: 'direction',
    cooldownMs: 1600,
    essenceCost: 14,
    range: 3.6,
    radius: 3.6,
    power: 1.7,
  },
  veil_step: {
    id: 'veil_step',
    slot: 2,
    unlockLevel: 4,
    name: 'Veil Step',
    description: 'Slip through the veil toward the cursor, up to 5.5m. No corpse needed; it never passes a sealed door or leaves the hall you stand in.',
    icon: 'art/abilities/necro-veil-step.webp',
    targeting: 'ground',
    cooldownMs: 7000,
    essenceCost: 0,
    range: 5.5,
    radius: 0,
    power: 0,
  },
  rally_dead: {
    id: 'rally_dead',
    slot: 4,
    unlockLevel: 6,
    name: 'Rally the Dead',
    description: 'Rally every thrall you command for 6s: +40% damage, +30% attack speed, 20% health restored, and they turn on the enemy nearest the cursor.',
    icon: 'art/abilities/necro-rally-the-dead.webp',
    targeting: 'self',
    cooldownMs: 12000,
    essenceCost: 20,
    range: 14,
    radius: 8,
    power: 0,
  },
  carrion_seed: {
    id: 'carrion_seed',
    slot: 3,
    unlockLevel: 8,
    name: 'Carrion Seed',
    description: 'Plant a seed of rot in a corpse. When an enemy comes close it bursts, hurting everything within 3m and leaving 2 stacks of Withered. One seed at a time.',
    icon: 'art/abilities/necro-carrion-seed.webp',
    targeting: 'corpse',
    cooldownMs: 6000,
    essenceCost: 18,
    range: 13,
    radius: 3,
    power: 1.6,
  },
  // --- Grimoire expansion: a drain, a cage, a field and a storm (icons: gemini-jobs/spells-v6.json). ---
  soul_siphon: {
    id: 'soul_siphon',
    slot: 2,
    unlockLevel: 6,
    name: 'Soul Siphon',
    description: 'Latch a soul-tether onto an enemy for 3s. It follows them while you move, drains damage every half second, and heals you for 35% of it plus 2 essence a tick. Breaks if they get too far away.',
    icon: 'art/abilities/necro-soul-siphon.webp',
    targeting: 'enemy',
    cooldownMs: 7000,
    essenceCost: 14,
    range: 9,
    radius: 0,
    power: 0.55,
  },
  bone_prison: {
    id: 'bone_prison',
    slot: 3,
    unlockLevel: 9,
    name: 'Bone Prison',
    description: 'A ring of bone spikes bursts out of the ground at the cursor, caging everything inside for 1.8s (rooted: they can still swing) and Fracturing it.',
    icon: 'art/abilities/necro-bone-prison.webp',
    targeting: 'ground',
    cooldownMs: 9000,
    essenceCost: 24,
    range: 11,
    radius: 2.4,
    power: 1.1,
  },
  grave_hands: {
    id: 'grave_hands',
    slot: 3,
    unlockLevel: 11,
    name: 'Grave Hands',
    description: 'The buried dead claw up through a 3.5m field for 3s, slowing and raking everything in it. Every corpse in the field adds more hands (+15% damage each, up to +60%).',
    icon: 'art/abilities/necro-grave-hands.webp',
    targeting: 'ground',
    cooldownMs: 11000,
    essenceCost: 26,
    range: 10,
    radius: 3.5,
    power: 0.4,
  },
  bone_storm: {
    id: 'bone_storm',
    slot: 4,
    unlockLevel: 14,
    name: 'Bone Storm',
    description: 'Whip a tornado of bone fragments up at the cursor. It creeps toward the nearest enemy for 4s, shredding everything within 2m; each corpse it starts on adds 0.6s (up to +3s).',
    icon: 'art/abilities/necro-bone-storm.webp',
    targeting: 'ground',
    cooldownMs: 12000,
    essenceCost: 32,
    range: 10,
    radius: 2,
    power: 0.5,
  },
  // --- Signature rites: one per discipline, unlocked at SIGNATURE_LEVEL (icons: gemini-jobs/icons-v4.json).
  // ── Hollow Knight ──────────────────────────────────────────────────────────
  // Starting numbers from docs/agent-briefs/new-classes.md §3. Where the brief
  // left a value open (bash/slam power, most cooldowns) the number here is a
  // first pass to be tuned with the balance harness, not a design decision.
  hollow_cut: {
    id: 'hollow_cut',
    slot: 0,
    name: 'Hollow Cut',
    description: 'A short sword arc in front of you. Every enemy it cuts returns 4 Rage.',
    icon: 'art/abilities/knight-hollow-cut.webp',
    targeting: 'direction',
    cooldownMs: 550,
    essenceCost: 0,
    range: 2.4,
    radius: 2.4,
    power: 1.1,
  },
  shield_bash: {
    id: 'shield_bash',
    slot: 1,
    name: 'Shield Bash',
    description: 'Dash 3m behind your shield. The first enemy you strike is stunned for 0.8s (0.2s against a boss).',
    icon: 'art/abilities/knight-shield-bash.webp',
    targeting: 'direction',
    cooldownMs: 6000,
    essenceCost: 0,
    range: 3,
    radius: 1,
    power: 0.9,
  },
  grave_slam: {
    id: 'grave_slam',
    slot: 2,
    name: 'Grave Slam',
    description: 'Leap up to 8m to the cursor and slam down, striking everything within 3m.',
    icon: 'art/abilities/knight-grave-slam.webp',
    targeting: 'ground',
    cooldownMs: 9000,
    essenceCost: 30,
    range: 8,
    radius: 3,
    power: 2.2,
  },
  bulwark: {
    id: 'bulwark',
    slot: 3,
    unlockLevel: 3,
    name: 'Bulwark',
    description: 'Raise the shield for 2s: 60% less damage from the front. A blow in the first 0.25s is a perfect block — half of it is reflected and you gain 15 Rage.',
    icon: 'art/abilities/knight-bulwark.webp',
    targeting: 'self',
    cooldownMs: 12000,
    essenceCost: 0,
    range: 0,
    radius: 0,
    power: 0,
  },
  corpse_vigil: {
    id: 'corpse_vigil',
    slot: 4,
    unlockLevel: 5,
    name: 'Corpse Vigil',
    description: 'Stand over a corpse and keep vigil: it is consumed and you regain 3% of your health each second for 4s.',
    icon: 'art/abilities/knight-corpse-vigil.webp',
    targeting: 'corpse',
    cooldownMs: 15000,
    essenceCost: 0,
    range: 1.6,
    radius: 1.2,
    power: 0,
  },
  grave_brand: {
    id: 'grave_brand',
    slot: 5,
    name: 'Grave Brand',
    description: 'Brand a corpse. The next enemy to come within 1.5m of it is rooted for 1.5s and the corpse is spent.',
    icon: 'art/abilities/knight-grave-brand.webp',
    targeting: 'corpse',
    cooldownMs: 8000,
    essenceCost: 0,
    range: 6,
    radius: 1.2,
    power: 0,
  },
  oath_unbroken: {
    id: 'oath_unbroken',
    slot: 6,
    unlockLevel: 10,
    name: 'Oath Unbroken',
    description: 'For 6s you cannot fall below 1 health, you deal 30% more damage, and your Rage refills.',
    icon: 'art/abilities/knight-oath-unbroken.webp',
    targeting: 'self',
    cooldownMs: 60000,
    essenceCost: 0,
    range: 0,
    radius: 0,
    power: 0,
  },
  ossuary_wall: {
    id: 'ossuary_wall',
    slot: 6,
    unlockLevel: 10,
    name: 'Ossuary Wall',
    description: 'Raise a 7m wall of fused bone across the cursor line for 6s. The dead cannot pass it and Penitent cones break on it.',
    icon: 'art/abilities/necro-ossuary-wall.webp',
    targeting: 'direction',
    cooldownMs: 16000,
    essenceCost: 30,
    range: 10,
    radius: 3.5,
    power: 0,
  },
  command_rend: {
    id: 'command_rend',
    slot: 6,
    unlockLevel: 10,
    name: 'Command: Rend',
    description: 'Your whole legion leaps to the cursor and cleaves everything around it. Costs each thrall 15% of its health instead of essence.',
    icon: 'art/abilities/necro-command-rend.webp',
    targeting: 'ground',
    cooldownMs: 9000,
    essenceCost: 0,
    range: 13,
    radius: 2.2,
    power: 0,
  },
  dirge: {
    id: 'dirge',
    slot: 6,
    unlockLevel: 10,
    name: 'Dirge',
    description: 'Toll a 4s funeral bell-song around you: you and your thralls mend each second, and enemy casters inside are Silenced.',
    icon: 'art/abilities/necro-dirge.webp',
    targeting: 'self',
    cooldownMs: 18000,
    essenceCost: 35,
    range: 0,
    radius: 6,
    power: 0.6,
  },
  plague_bloom: {
    id: 'plague_bloom',
    slot: 6,
    unlockLevel: 10,
    name: 'Plague Bloom',
    description: 'Plant a rot flower at the cursor. It pulses Withered and every 2s seeds a new bloom on the nearest corpse, chaining through the corpse field.',
    icon: 'art/abilities/necro-plague-bloom.webp',
    targeting: 'ground',
    cooldownMs: 12000,
    essenceCost: 28,
    range: 14,
    radius: 2.4,
    power: 0.3,
  },
};

/** Level at which each discipline's signature rite unlocks. */
export const SIGNATURE_LEVEL = 10;

/** Level a rite unlocks at (1 = from the start). */
export function unlockLevel(id: AbilityId) {
  return ABILITIES[id].unlockLevel ?? 1;
}

/** Each discipline's signature rite (DisciplineId → ability). */
export const SIGNATURE_BY_DISCIPLINE = {
  ossuary: 'ossuary_wall',
  gravecaller: 'command_rend',
  mourner: 'dirge',
  rotweaver: 'plague_bloom',
} as const satisfies Record<string, AbilityId>;

export type SignatureKind = 'wall' | 'rend' | 'dirge' | 'bloom';
/** Host-shaped rites carried by the `signature` intent: the four signatures plus Bone Mantle. */
export type RiteKind = SignatureKind | 'mantle' | 'offering' | 'rally' | 'seed' | 'bash' | 'vigil' | 'brand';
export const SIGNATURE_KIND: Partial<Record<AbilityId, SignatureKind>> = {
  ossuary_wall: 'wall',
  command_rend: 'rend',
  dirge: 'dirge',
  plague_bloom: 'bloom',
};

/** Host-side tuning for the signature rites (the intent carries only aim + spell power). */
export const SIGNATURE = {
  wall: { length: 7, thickness: 0.8, durationS: 6, maxCastRange: 11 },
  rend: { cleaveRadius: 2.2, damageMult: 2.5, hpCost: 0.15, maxCastRange: 14 },
  dirge: { radius: 6, durationS: 4, thrallHealFrac: 0.08, silenceS: 1.2 },
  bloom: { radius: 2.4, durationS: 8, spreadEveryS: 2, spreadReach: 6, maxGenerations: 3, childDurationS: 6, witheredCap: 8, maxCastRange: 15 },
};

/** Hotbar order; index + 1 is the HotbarSlot. Slot 5 is the right-click action. */
export const HOTBAR: AbilityId[] = ['marrow_spear', 'exhume', 'miasma', 'black_litany', 'corpse_explosion'];

/**
 * The Grimoire (L): class rites available for the five swappable slots.
 * The default right-click rite is added by gameplay/loadout.ts.
 */
export const GRIMOIRE: AbilityId[] = [
  'marrow_spear',
  'exhume',
  'miasma',
  'black_litany',
  'wailing_skull',
  'grave_step',
  'grave_frost',
  'bone_mantle',
  'grave_offering',
  'ivory_cleave',
  'veil_step',
  'rally_dead',
  'carrion_seed',
  'soul_siphon',
  'bone_prison',
  'grave_hands',
  'bone_storm',
];
export const DEFAULT_LOADOUT: AbilityId[] = ['marrow_spear', 'exhume', 'miasma', 'black_litany'];

/** Left-click primaries (0 essence). The Grimoire's LMB socket picks one; Bone Needle is the default. */
export const PRIMARIES: AbilityId[] = ['bone_needle', 'bone_fan', 'rot_lance'];
export const DEFAULT_PRIMARY: AbilityId = 'bone_needle';

/** Grimoire role chips: what a rite is for (a filter in the Grimoire, a line in the Codex). */
export type RiteRole = 'damage' | 'corpse' | 'control' | 'survival' | 'legion';
export const ROLE_LABEL: Record<RiteRole, string> = { damage: 'Damage', corpse: 'Corpse', control: 'Control', survival: 'Survival', legion: 'Legion' };
export const RITE_ROLES: Partial<Record<AbilityId, RiteRole[]>> = {
  bone_needle: ['damage'],
  marrow_spear: ['damage'],
  exhume: ['corpse', 'legion'],
  miasma: ['control', 'damage'],
  black_litany: ['corpse', 'damage'],
  wailing_skull: ['damage'],
  grave_step: ['survival', 'corpse'],
  grave_frost: ['control'],
  bone_mantle: ['survival', 'corpse'],
  bone_fan: ['damage'],
  rot_lance: ['damage', 'control'],
  grave_offering: ['corpse', 'survival'],
  ivory_cleave: ['damage'],
  veil_step: ['survival'],
  rally_dead: ['legion'],
  carrion_seed: ['control', 'corpse'],
  soul_siphon: ['survival', 'damage'],
  bone_prison: ['control'],
  grave_hands: ['control', 'corpse'],
  bone_storm: ['damage', 'corpse'],
  hollow_cut: ['damage'],
  shield_bash: ['control', 'damage'],
  grave_slam: ['damage', 'control'],
  bulwark: ['survival'],
  corpse_vigil: ['survival', 'corpse'],
  grave_brand: ['control', 'corpse'],
  oath_unbroken: ['survival', 'damage'],
  flail_swing: ['damage'], lantern_cone: ['damage', 'control'], chain_pull: ['control'], burn_the_dead: ['corpse', 'damage'],
  watchmans_ward: ['survival'], cremate: ['corpse', 'damage'], last_light: ['survival', 'control'],
  palm_strike: ['damage'], toll: ['damage', 'control'], resonant_step: ['damage'], knell: ['control'],
  choir_of_one: ['damage'], sound_the_corpse: ['corpse', 'damage'], great_toll: ['damage', 'control'],
  hook_throw: ['damage'], harvest: ['corpse', 'legion'], crow_swarm: ['damage'], hook_pull: ['control'],
  hex_charm: ['control'], butcher: ['corpse', 'survival'], murder_of_crows: ['damage'],
  spirit_bolt: ['damage'], veil_form: ['survival'], echo: ['corpse', 'legion'], veil_tear: ['control'],
  crossing: ['survival', 'corpse'], lay_to_rest: ['corpse', 'survival'], between_worlds: ['survival'],
};
export const rolesOf = (id: AbilityId): RiteRole[] => RITE_ROLES[id] ?? [];
/** Key caps for hotbar slots 1–6 (slot 5 is the right-click action, 6 the signature). */
export const SLOT_KEYS = ['1', '2', '3', '4', 'RMB', 'R'] as const;

/** Bone Fan: three slivers, each on a distinct enemy in a narrow cone around the clicked one. */
export const BONE_FAN = { slivers: 3, spreadDeg: 12, coneHalfDeg: 15, essencePerHit: 3, essenceCap: 6, speed: 24 };
/** Rot Lance: pierces the first two in a 0.5m lane; one Withered stack each (host-capped). */
export const ROT_LANCE = { pierce: 2, halfWidth: 0.25, essence: 4, withered: 1, speed: 32 };
/** Grave Offering: a corpse burned for essence + health (host consumes it). */
export const GRAVE_OFFERING = { essence: 16, resonantBonus: 8, eliteMult: 2, healFrac: 0.04, pickRadius: 0.9 };
/** Ivory Cleave: a 120° crescent in front of the caster. */
export const IVORY_CLEAVE = { halfAngleDeg: 60, reach: 3.6, fracture: 1 };
/** Veil Step: a short dash that walks the segment in small steps and stops at the last valid point. */
export const VEIL_STEP = { stepM: 0.25, durationS: 0.16 };
/** Rally the Dead (host): thrall buff. Gravecallers rally for 2s longer. */
export const RALLY = { durationS: 6, gravecallerBonusS: 2, damageMult: 1.4, attackSpeedMult: 1.3, healFrac: 0.2 };
/** Carrion Seed (host): arm delay, life, trigger reach, burst radius and Withered. */
export const CARRION_SEED = { armS: 0.6, lifeS: 20, triggerR: 2.2, burstR: 3, withered: 2, witheredCap: 6, pickRadius: 0.9 };

/** Soul Siphon: tick cadence, share of each tick healed, essence per tick, break distance (× range). */
export const SOUL_SIPHON = { durationS: 3, tickS: 0.5, healFrac: 0.35, essencePerTick: 2, breakMult: 1.4 };
/** Bone Prison: the host owns the root duration (a hit can only ask for it). Bosses take damage only. */
export const BONE_PRISON = { rootS: 1.8, spikes: 16, fracture: 1 };
/** Grave Hands: slow ticks in a field; corpses inside at cast time add hands and damage. */
export const GRAVE_HANDS = { durationS: 3, tickS: 0.5, hands: 9, handsPerCorpse: 3, maxHands: 24, perCorpse: 0.15, maxCorpses: 4 };
/** Bone Storm: a drifting funnel; corpses under it at cast time extend it (they are not consumed). */
export const BONE_STORM = { durationS: 4, perCorpseS: 0.6, maxExtraS: 3, tickS: 0.4, drift: 2.2, seekR: 9, shards: 27 };

/** Wailing Skull: damage falls off per leap; a killing leap earns one more (up to maxHops). */
export const WAILING_SKULL = { hops: 3, maxHops: 5, falloff: 0.8, leapRange: 6.5, speed: 15 };
/** Grave Step: the marrow burst where you re-form (its bleed is HEMORRHAGE.dpsFrac of the hit). */
export const GRAVE_STEP = { burstRadius: 2.6 };
/** Grave Frost: a 70° cone. The host applies Chill for `chillS` whatever the claim says. */
export const GRAVE_FROST = { halfAngleDeg: 35, chillS: 3, shatterMult: 1.5, speed: 40 };
/** Bone Mantle: the host consumes the corpses; the caster's client owns the barrier and shard ticks. */
export const BONE_MANTLE = {
  maxCorpses: 5,
  barrierBase: 0.1,
  barrierPerCorpse: 0.07,
  barrierCap: 0.45,
  durationS: 6,
  orbitRadius: 1.7,
  tickS: 0.5,
};

/** Corpse Explosion tuning (host-side; the intent only carries the caster's damage). */
export const DETONATE = {
  radius: 3,
  resonantRadiusMult: 1.6,
  eliteDamageMult: 2,
  /** Sim-side clamp on the damage a client may claim (mirrors the realtime server). */
  maxDamage: 100000,
  /** Toxic corpses leave a friendly rot pool: radius, duration, dps as a share of the blast. */
  rotRadius: 2.6,
  rotDurationMs: 4000,
  rotDpsShare: 0.12,
  rotWitheredCap: 5,
};

/** Soul Harvest (client-side): kills fill the meter; when full the next big spell is free and 50% larger. */
export const SOUL_HARVEST = {
  souls: 50,
  areaMult: 1.5,
  spells: ['marrow_spear', 'miasma', 'black_litany'] as AbilityId[],
};

/** Litany scaling: added spell-power multiples per consumed corpse / thrall. */
export const LITANY_PER_CORPSE = 0.6;
export const LITANY_PER_RESONANT = 1.2;
export const LITANY_PER_THRALL = 1.4;
export const LITANY_MAX_MULT = 14;

export const FRACTURE = { perStack: 0.15, maxStacks: 3, durationMs: 5000 };
export const WITHERED = { dpsPerStack: 0.18, durationMs: 5000 };
export const MIASMA_SLOW = 0.6;
export const WATCHMANS_WARD_SLOW = 0.75;
export const NEEDLE_ESSENCE = 6;

/**
 * Per-spell colour identity (user direction: spells must not all read as dark
 * purple). Violet is reserved for the signature ultimate; the rest spread
 * across bone, marrow, spirit and rot so a crowded fight stays legible.
 */
/** Hollow Knight (docs/agent-briefs/new-classes.md §3). Rage is built, not regenerated. */
export const KNIGHT_RAGE = { max: 100, perHpPercentLost: 1, perCutHit: 4, perPerfectBlock: 15, decayPerS: 4, decayAfterS: 4 };
export const HOLLOW_CUT = { halfAngleDeg: 55, reach: 2.4, rage: 4 };
export const SHIELD_BASH = { dashM: 3, durationS: 0.14, stunS: 0.8, bossStunS: 0.2 };
export const GRAVE_SLAM = { leapM: 8, durationS: 0.28, slamR: 3 };
export const BULWARK = { holdS: 2, frontHalfDeg: 60, damageCut: 0.6, perfectWindowS: 0.25, reflect: 0.5 };
export const CORPSE_VIGIL = { regenFracPerS: 0.03, durationS: 4 };
export const GRAVE_BRAND = { triggerR: 1.5, rootS: 1.5, lifeS: 30 };
export const OATH_UNBROKEN = { durationS: 6, damageMult: 1.3 };

export const SPELL_FX = {
  warden: { gold: 0xf2b84b, fire: 0xff7a2a, ash: 0x6b3b24 },
  monk: { gold: 0xe8d9a0, sound: 0xf6f1e3, bronze: 0xc9aa6a },
  witch: { blood: 0x9a1b2a, hex: 0xa6b04a, crow: 0x1a1418 },
  veilwalker: { cyan: 0xbff3ff, mist: 0xdfe9ee, deep: 0x668eaa },
  needle: { core: 0xf3e8d2, trail: 0xe9c98f, impact: 0xfff1d6, dust: 0xd8cfbd },
  spear: { bone: 0xe0d6c2, crack: 0xb4502e, dust: 0x4a3a30, marrow: 0x8a2c3c },
  exhume: { spirit: 0x6fe3c8, deep: 0x1f8f86, beam: 0x9ff5e0 },
  miasma: { rot: 0xa8c23a, deep: 0x4f6b1f, spore: 0x2b3317 },
  litany: { core: 0x9b5cff, hot: 0xe6d6ff, void: 0x160a24 },
  /** Corpse Explosion — marrow: ember + dried crimson, with bone shrapnel. */
  detonate: { ember: 0xff6a2a, hot: 0xffc58a, crimson: 0x8a2c3c, bone: 0xe0d6c2, smoke: 0x2a1614 },
  /** Soul Harvest — spirit: jade/teal. */
  souls: { jade: 0x6fe3c8, deep: 0x1f8f86, pale: 0x9ff5e0 },
  thrall: { spark: 0xe8dfcc, wraith: 0x8fb4ff },
  /** Flying pack: dust = Shroud Moth grave-dust ochre; dive = the gargoyle's bell-bronze mark. */
  enemy: { toll: 0xd9a441, rot: 0x7fa05a, curse: 0x8a3a4a, slam: 0x9a6a3a, toxic: 0x6f8f3a, dust: 0xb89a5a, dustDeep: 0x4a3d24, dive: 0xc8923a, dirt: 0x6a4a30, ember: 0xff7a2a, emberDeep: 0x4a1608, emberCore: 0xffc45a, hex: 0xc2409a },
  /** Elite affix tells (bell = bronze, hunger = olive rot, shroud = grave dusk, vengeance = ember). */
  affix: { bell: 0xd9a441, drool: 0x8a8f2a, shroud: 0x3a3448, vengeful: 0xe0552a },
  /** Grave Surge — enemy bell/crypt bronze. */
  surge: { crack: 0xc8923a, glow: 0xd9a441 },
  boss: { bronze: 0xd9a441, shard: 0xc8a06a, spirit: 0xb9c8ff },
  /** Hollow Knight: cold steel + oath crimson. Never enemy bronze. */
  knight: { steel: 0xb8c0cc, oath: 0x8a1f2c, pale: 0xe6ebf2, dust: 0x4a4740 },
  /** Signature rites: Ossuary Wall = bone ivory/amber, Rend = spirit jade, Dirge = Mourner cold blue, Bloom = rot chartreuse. */
  wall: { bone: 0xe8dcc0, amber: 0xd9a66b, dust: 0x6a5a48 },
  rend: { jade: 0x6fe3c8, pale: 0xc8fff0, bone: 0xe0d6c2 },
  dirge: { frost: 0x9fc4ff, deep: 0x5b7fd6, pale: 0xdde8ff },
  bloom: { petal: 0xc7e04a, rot: 0x6f8f22, spore: 0x2b3317 },
  /** Grimoire rites. Skull = spirit jade; Step = marrow blood mist (crimson, not Corpse Explosion's ember); Frost = Chill's cold blue; Mantle = bone ivory / old gold. */
  skull: { jade: 0x6fe3c8, pale: 0xc8fff0, deep: 0x1f8f86 },
  step: { blood: 0xc23a48, crimson: 0x8a2c3c, mist: 0x3a1218, hot: 0xffc58a },
  frost: { frost: 0x9fc4ff, deep: 0x5b7fd6, pale: 0xdde8ff },
  // Mantle: aged bone greys, not cream/gold (the old warm palette plus additive sprites read as bananas).
  mantle: { bone: 0xcfc8b8, gold: 0xb8ad94, amber: 0x8c7d64, dust: 0x5a5046 },
  /** Spell variety: Rot Lance = rot chartreuse/olive; Veil Step = spirit jade/pale (shape-distinct from Grave Step's crimson). */
  lance: { rot: 0xc7e04a, deep: 0x6f8f22, spore: 0x2b3317 },
  /** Grimoire expansion: Siphon = soul jade (like Harvest); Prison/Storm = aged bone + dust; Hands = grave earth + a spirit seep. */
  siphon: { jade: 0x6fe3c8, pale: 0x9ff5e0, deep: 0x1f8f86 },
  prison: { bone: 0xcfc8b8, dust: 0x5a5046, amber: 0x8c7d64 },
  hands: { earth: 0x3a2e22, bone: 0xcfc8b8, seep: 0x6fe3c8 },
  storm: { bone: 0xcfc8b8, ash: 0x8a8378, dust: 0x5a5046 },
  veil: { jade: 0x6fe3c8, pale: 0xdde8ff, deep: 0x1f8f86 },
} as const;
