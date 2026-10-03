import { gateAuto, onSettingsChange, settings, updateSettings } from '../app/settings';
import { browserStorage, type StorageLike } from '../gameplay/codexJournal';
import {
  NOT_BUSY, canShow, groupOf, makeEntry, pickNext, prune, shouldPreempt, shouldYield, showMs,
  type Busy, type CadenceState, type QueuedTip, type ShownCard, type TipKind,
} from './counselCadence';

/**
 * First-time contextual tips, shown once per character. A small reliquary card
 * movable by its header: it never takes focus or pauses play, dismisses on click or
 * after at least 25s (fight-time cards 14s; longer cards stay longer), and queues so two tips never stack.
 * WHEN a queued tip may appear is decided by ui/counselCadence.ts (calm tips wait for a calm moment, tips about one
 * subject keep their distance, stale ones are dropped). "Don't show tips" (here or in Settings) turns the whole
 * sequence off via app/settings `tips`; Settings -> Show tips again replays them.
 */
export type TipId =
  | 'minimap'
  | 'auto_combat'
  | 'change_class'
  | 'knight_rage'
  | 'warden_oil'
  | 'monk_beat'
  | 'witch_offal'
  | 'veil_forms'
  | 'welcome'
  | 'move'
  | 'exhume'
  | 'wave'
  | 'deacon'
  | 'gate'
  // Just-in-time counsel for the rest of the kit and the loop.
  | 'essence'
  | 'thrall'
  | 'litany'
  | 'burst'
  | 'hurt'
  | 'elite'
  | 'surge'
  | 'relic'
  | 'armor'
  | 'setBonus'
  | 'legendary'
  | 'affix'
  | 'necroWeapon'
  | 'gearEquip'
  | 'atlas'
  | 'statSheet'
  | 'codex'
  | 'signature'
  | 'prelate'
  | 'ascend'
  | 'souls'
  | 'sanctify'
  | 'boons'
  // The Grimoire and its level-gated rites (shown the first time each is placed on a key).
  | 'grimoire'
  | 'rite_skull'
  | 'rite_step'
  | 'rite_frost'
  | 'rite_mantle'
  | 'rite_siphon'
  | 'rite_prison'
  | 'rite_hands'
  | 'rite_storm'
  // Spell variety (shown the first time each is placed on a key or the LMB socket).
  | 'rite_fan'
  | 'rite_lance'
  | 'rite_offering'
  | 'rite_cleave'
  | 'rite_veil'
  | 'rite_rally'
  | 'rite_seed'
  // Enemy variety: processions and the four newer kinds of dead (first sight).
  | 'procession'
  | 'censer'
  | 'wraith'
  | 'swarm'
  | 'golem'
  | 'gargoyle'
  | 'moth'
  | 'bats'
  | 'seraph'
  | 'ghoul'
  | 'meal'
  | 'brew'
  | 'belt'
  | 'reagent'
  | 'plague_doctor'
  | 'flagellant'
  | 'cloister'
  | 'pyre'
  | 'chain'
  | 'omen'
  | 'warren'
  | 'wing'
  | 'coliseum'
  | 'cinder_husk'
  | 'pyre_priest'
  | 'cinderhound'
  | 'slag_brute'
  | 'fen'
  | 'bog_hag'
  | 'mire_leech'
  | 'fen_wisp'
  | 'drowned_sexton'
  | 'boss_mire'
  | 'boss_gravedigger'
  | 'boss_abbess'
  | 'boss_congregation'
  | 'boss_saint'
  | 'boss_regent'
  | 'tool'
  | 'toolBelt'
  | 'legion'
  | 'rune'
  | 'runeSocketed'
  // The Catacomb Depths.
  | 'depths'
  | 'depths_floor'
  | 'depths_affix'
  | 'depths_chest'
  | 'depths_solo'
  | 'acolyte'
  | 'templar'
  // Professions (docs/PROFESSIONS-ROADMAP.md §11).
  | 'acre'
  | 'laborers_working'
  | 'gather'
  | 'bag_full'
  | 'skill_up'
  | 'rich_node'
  | 'station'
  // Inventory relief: a filling bag, the shared Vault and the Bone Grinder.
  | 'bag_filling'
  | 'vault'
  | 'salvage'
  // People of the Covenant (first sight of an NPC).
  | 'people';

interface Tip {
  title: string;
  /**
   * Trusted static HTML (kbd hints only). `{key:<abilityId>}` becomes the key that
   * rite sits on in the player's Grimoire loadout (see Onboarding.keyFor).
   */
  body: string;
}

/**
 * Tip text is written for the keyboard. Markup resolved by renderText:
 *   {p:X}               " (<kbd>X</kbd>)"
 *   {key:<abilityId>}   the key that rite sits on in the player's Grimoire loadout
 * (A stray `[[desktop||touch]]` pair, from the mobile branch, resolves to its desktop half.)
 */
export function renderText(text: string, keyFor?: (ability: string) => string | null): string {
  return gateAuto(text)
    .replace(/\[\[([\s\S]*?)\|\|([\s\S]*?)\]\]/g, (_m, d: string) => d)
    .replace(/\{p:(\w)\}/g, (_m, k: string) => ` (<kbd>${k}</kbd>)`)
    .replace(/\{key:(\w+)\}/g, (_m, ability: string) => {
      const k = keyFor?.(ability);
      return k ? `<kbd>${k}</kbd>` : 'a key from your Grimoire (<kbd>L</kbd>)';
    });
}

export const TIPS: Record<TipId, Tip> = {
  warden_oil: {
    title: 'Keep the lantern lit',
    body: '<b>Oil</b> refills slowly. Burn nearby corpses with <kbd>3</kbd> or <kbd>Right-click</kbd> to reclaim 20 oil per body and leave fire behind. Your lantern cone strips Shrouded and stuns wraiths; plant a ward to protect allies.',
  },
  monk_beat: {
    title: 'Hear the beat',
    body: '<b>Resonance</b> rises with hits and fades after a quiet moment. The resource orb pulses every 1.2 seconds: strike within the pulse for extra damage and Resonance. Toll spends 25 Resonance to stun; Sound the Corpse makes nearby Tolls stronger.',
  },
  witch_offal: {
    title: 'Feed the crows',
    body: '<b>Offal</b> comes from corpses. Harvest one with <kbd>1</kbd> to gain 30 Offal and summon pecking crows. Butcher a body with <kbd>Right-click</kbd> to leave three healing charms for allies.',
  },
  veil_forms: {
    title: 'Walk the Veil',
    body: '<kbd>1</kbd> changes form. Veil form drains your meter and protects you from enemy attacks while you move faster; your spirit attacks deal less damage. Life form refills Veil. Lay a body to rest for healing and echo corpses, then raise or cross to an echo.',
  },
  minimap: {
    title: 'Choose your path',
    body: 'Click a walkable spot on the minimap to travel there. The amber marker shows your fixed destination. Click another spot to change it; sealed halls stay closed. Hover a spell icon for its cost, targeting, effects and a useful combat tip.',
  },
  auto_combat: {
    title: 'Settle into the fight',
    body: 'On Easy, auto combat engages enemies in the current area, uses equipped rites and may cast your signature when useful. It drinks healing flasks and mends you while under attack. The Hollow Knight also guards automatically. Click or use movement keys to take control. Toggle it with <kbd>G</kbd> or the Auto button.',
  },
  knight_rage: {
    title: 'Rage, not essence',
    body: 'You are the <b>Hollow Knight</b>: no thralls, no Grave Essence. <b>Rage</b> builds when you are hit, when <kbd>LMB</kbd> Hollow Cut catches a body, and fastest of all from a perfect block — hold <kbd>3</kbd> Bulwark <b>facing</b> the blow. Spend it on <kbd>2</kbd> Grave Slam. <kbd>4</kbd> Corpse Vigil is your only heal, so keep a body spare.',
  },
  change_class: {
    title: 'A new discipline',
    body: 'Choose a class here whenever you want. Your level, gold, items and permanent progress stay with the same character. Changing discipline returns you safely to the Chapterhouse with its new model and passives.',
  },
  welcome: {
    title: 'Take your time',
    body: 'This gathering sanctuary has <b>no enemies</b>. <kbd>Click</kbd> a tree, ore seam, pool or grave to work it (<kbd>P</kbd> shows your Skills), or walk on whenever you like. Move with <kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd> or by clicking the ground. The <b>Next</b> line under the minimap offers one optional suggestion at a time. <kbd>Esc</kbd> opens Settings.',
  },
  move: {
    title: 'Walk among the dead',
    body: 'Aim with the mouse and <kbd>Click</kbd> an enemy for your basic attack; <kbd>Shift</kbd>+<kbd>Click</kbd> attacks without moving. Press <kbd>1</kbd>–<kbd>4</kbd> for rites and <kbd>Right-click</kbd> (or <kbd>5</kbd>) for your fifth. Watch the ground for warning rings and step out of them.',
  },
  exhume: {
    title: 'A corpse lies near',
    body: 'Press {key:exhume} to Exhume the corpse nearest your cursor and raise it as your thrall. Unclaimed bodies rot away.',
  },
  wave: {
    title: 'Wave Speed',
    body: 'You can afford to <b>Quicken</b> the waves (lower right). Faster waves bring more dead and richer rewards. The three diamonds are milestones (tiers 3, 6 and 8) that add wave affixes; hover them. Use <kbd>−</kbd> to dial the active tier back down whenever the pressure is too much.',
  },
  deacon: {
    title: 'Kill the Crypt Deacon first',
    body: 'Deacons steal unclaimed corpses and raise them as Risen against you. Watch for the green beam, and put it down before it reaches the dead.',
  },
  gate: {
    title: 'A sealed door',
    body: 'This gate stays sealed until you have slain enough of the dead on this side. The count sits under the map, top right.',
  },
  essence: {
    title: 'Grave Essence',
    body: 'Rites cost essence (the blue orb). Bone Needle is free, and every needle hit refunds some, so keep a target under attack between rites.',
  },
  thrall: {
    title: 'Your first thrall',
    body: 'It follows you and fights what you fight. Raise more with {key:exhume} up to your cap (the skull count, lower right); past the cap your oldest crumbles. A corpse remembers what it was: Penitents rise as archers, Deacons as bone mages, Carrion Sacs as plague bearers.',
  },
  litany: {
    title: 'Black Litany',
    body: 'Press {key:black_litany} to give everything within 7m (corpses and thralls) to one burst. The more you give, the harder it hits. Pull the pack onto a pile of bodies first.',
  },
  burst: {
    title: 'Corpse Explosion',
    body: '<kbd>Right-click</kbd> a corpse to burst it under a pack. Best when the dead are already on you, or your legion is full.',
  },
  hurt: {
    title: 'Hurt?',
    body: 'Press <kbd>Q</kbd> (the <b>Heal</b> slot at the left edge) to drink a healing flask. <kbd>T</kbd> returns you to the Chapterhouse. Falling costs nothing but the walk back, and <kbd>−</kbd> on the Wave Speed dial eases the pressure.',
  },
  elite: {
    title: 'An elite',
    body: 'Elites glow and carry an affix; read its tag in the target frame (top) before you engage. They drop soul shards, and five shards summon the Prelate.',
  },
  surge: {
    title: 'Grave Surge',
    body: 'A crypt has cracked open. Kill most of what climbs out before it seals (about 20s) and it yields a guaranteed relic and bonus gold.',
  },
  relic: {
    title: 'A relic',
    body: 'Loot goes to your Reliquary{p:I}. Equip gear there; the Workbench{p:C} turns ore and bars into more.',
  },
  armor: {
    title: 'Set armor',
    body: 'Armor comes in five-piece sets, one look per discipline, and <b>any class can wear any set</b>. Open your Reliquary{p:I} and double-click a piece to wear it; it shows on your hero. Wear <b>2, 4 or 5 pieces of the same set</b> to unlock set bonuses; hover a piece to see them. Later areas drop the rarer, stronger sets.',
  },
  setBonus: {
    title: 'A set bonus is awake',
    body: 'Two pieces of the same armor set are worn, so its first <b>set bonus</b> is active. Hover any piece: <b>green lines</b> are on, grey lines need more pieces (4 and 5 are the big ones). A bag item marked <b>completes</b> in its arrow line will switch a bonus on. The Character sheet (<kbd>J</kbd>) shows what each set still needs and where it drops.',
  },
  legendary: {
    title: 'A legendary set',
    body: 'Legendary pieces are rare and <b>change how you play</b>. Each set is built for one discipline, and its pieces drop from <b>area bosses</b> (and very rarely from elites in the Cloister, Pyre and Fen); your own discipline’s set is the most likely. Wear <b>2, 4 or 5 pieces of the same set</b>: two is a nudge, four changes a mechanic, five defines the build. Hover a piece for exactly what each tier does. Wearing four or more gives your hero a faint glow in the set’s colour. The Codex lists all four sets and where they drop.',
  },
  affix: {
    title: 'A rolled relic',
    body: 'Gear now drops with an <b>item level</b> and up to <b>three affixes</b>, rolled by the server so nobody can edit them. More affixes means a richer colour; a higher item level means bigger numbers. <b>Violet † lines</b> feed your legion, essence and rites. Hover a piece: the arrow says if it beats what you wear. Salvage and selling pay more for good rolls.',
  },
  gearEquip: {
    title: 'Gear you can read',
    body: 'Hover or select a piece in the Reliquary{p:I} and every stat says what it does for <b>you</b>: <b>VIT</b> is health, <b>INT</b> is spell power and essence. A bag item wears a small <b>green ▲</b> when it beats what you wear for your discipline, and a <b>red ▼</b> when it is worse; hover it for why. Press <kbd>J</kbd> to see which stats to look for.',
  },
  atlas: {
    title: 'The Gear Atlas',
    body: 'What is worth wearing, and where does it drop? The <b>Gear Atlas</b> [[(<kbd>.</kbd> key)||(in the Menu)]] lists every piece with its drop chances, how to craft it and a <b>green ▲</b> or <b>red ▼</b> against what you wear. <b>Best for me</b> shows your top upgrades.',
  },
  statSheet: {
    title: 'Your Character sheet',
    body: 'At the top: <b>what you are looking for</b>, the stats and weapons that suit your discipline and the slots most worth fixing. Below: every number your hero fights with. Click a line to see where it comes from. The <b>Set bonuses</b> block lists what your armor sets give and which piece completes the next one.',
  },
  necroWeapon: {
    title: 'A weapon that changes your left click',
    body: 'Necromancer weapons change your <b>Bone Needle</b> (left click): a <b>Scythe</b> becomes a close reaping arc that pays a soul per kill, a <b>Wand</b> casts faster but softer, a <b>Ritual Sickle</b> leaves targets Withered, and a <b>Staff</b> reaches farther and pierces. Off-hands add a passive. Hover any piece in the Reliquary{p:I} for its line; the Codex{p:K} lists them all.',
  },
  codex: {
    title: 'The Codex',
    body: 'Press <kbd>K</kbd> for everything you have met: every rite, every kind of dead, and how to beat it.',
  },
  signature: {
    title: 'Your signature rite awakens',
    body: 'Level 10: [[press <kbd>R</kbd> for your class\'s own rite. Hover the new slot||tap the new slot on your hotbar for your class\'s own rite. Press and hold it]] to read what it does.{auto} On Easy, Auto may also use it when the fight calls for it.{/auto}',
  },
  ascend: {
    title: 'The Altar of Ascension stirs',
    body: 'The Prelate has fallen. At the Altar in the Chapterhouse you may <b>Ascend</b>: your tiers, shards and opened seals reset, but you keep your level, gold and relics, earn Ashes for permanent boons, and the dead grow older and richer.',
  },
  souls: {
    title: 'Soul Harvest',
    body: 'The skull above your hotbar is full. Your next Marrow Spear, Miasma Circle or Black Litany is <b>free and 50% larger</b>; the empowered slots glow jade.',
  },
  sanctify: {
    title: 'Sanctified',
    body: 'That pale gold halo is a Deacon\'s blessing: the enemy takes 30% less damage while it lasts. Kill the Deacon, or turn your rites on something else until it fades.',
  },
  boons: {
    title: 'Ashes to spend',
    body: 'Your Ashes buy permanent <b>Covenant Boons</b> at the Altar of Ascension: more health, cheaper upgrades, a head start on every run, even another thrall at higher ranks.',
  },
  prelate: {
    title: 'Five soul shards',
    body: 'Enough to wake the Bell-Sworn Prelate. Offer them at the Sundered Bell in the Bell Sanctum, and learn to step out of its bronze rings.',
  },
  grimoire: {
    title: 'The Grimoire',
    body: 'New rites have come to you. [[Click||Tap]] the <b>swap arrows</b> below a hotbar spell[[ (or press <kbd>L</kbd>)||, or open the Grimoire from the Menu,]] to choose which unlocked rites sit on [[slots <kbd>1</kbd>–<kbd>5</kbd>; slot 5 also uses right-click||slots 1–5]]. Your signature stays on [[<kbd>R</kbd>||the sixth slot]]. Each rite keeps its cooldown.',
  },
  rite_skull: {
    title: 'Wailing Skull',
    body: 'The skull hunts the enemy nearest your cursor, then leaps on to two more, each bite a little weaker. Finish a wounded foe with it and it earns an extra leap. Good for elites and stragglers.',
  },
  rite_step: {
    title: 'Grave Step',
    body: 'Aim at a corpse up to 12m away to re-form on it in blood mist, bleeding everything beside it. The body stays, so follow with Corpse Explosion or Exhume. It never carries you through a sealed door.',
  },
  rite_frost: {
    title: 'Grave Frost',
    body: 'A cone of grave cold: everything it touches is <b>Chilled</b>, slower to move and to strike. Breathe on the same pack again and the Chilled enemies <b>shatter</b> for +50% damage.',
  },
  procession: {
    title: 'A procession',
    body: 'Not every wave is a mix. Now and then the dead arrive as a <b>procession</b>, a themed band named on the banner (hounds and rats, a choir, a censer and its bells). Read the name, then pick your rites for it.',
  },
  censer: {
    title: 'Censer Bearer',
    body: 'Its bronze incense <b>Incenses</b> the dead around it: faster feet, faster blows (bronze motes on them). Kill the censer first and the pack slows back down.',
  },
  wraith: {
    title: 'Choir Wraith',
    body: 'Pale song-lines mark a ring where you stand; when the hymn breaks, the ring screams. One step out is enough. Wraiths leave no corpse.',
  },
  swarm: {
    title: 'Skull-rats',
    body: 'They pour out in packs and leave no corpses. Needles are wasted on them: a Miasma, a Grave Frost cone or a Corpse Explosion ends a whole pack at once.',
  },
  golem: {
    title: 'Bone Golem',
    body: 'A slow giant with a wide bronze-brown slam ring: step out, then punish it. It falls apart into <b>three corpses</b>, a whole legion or a Litany in one kill.',
  },
  gargoyle: {
    title: 'Belfry Gargoyle',
    body: 'When a <b>bronze circle</b> fills in under you, a gargoyle is about to dive onto it. Walk out, then turn on it: it sits <b>grounded in the rubble</b> for a moment after it lands. A stun knocks it out of the air.',
  },
  moth: {
    title: 'Shroud Moth',
    body: 'An <b>ochre ring</b> means grave dust is coming down. Step out before it bursts, and stay out of the cloud it leaves for a few seconds. Moths are fragile: one or two good hits.',
  },
  bats: {
    title: 'Tithe Bats',
    body: 'They bite and flit away, again and again, and leave no corpses. Don\'t chase them. Hold your ground and sweep the flock with Miasma, a Grave Frost cone or Bone Mantle.',
  },
  seraph: {
    title: 'Weeping Seraph',
    body: 'It blesses <b>every ally near it</b> at once (priest-gold motes: they take less damage). Kill the seraph first, or silence it with a Dirge.',
  },
  boss_gravedigger: {
    title: "The King's Grave",
    body: 'Offer <b>2 soul shards</b> here to wake the Gravedigger King. When a <b>grave outline</b> opens under you, step off it or be Buried (rooted, casting allowed). In his last phase, stay out of the open pits.',
  },
  boss_abbess: {
    title: "The Abbess's Reliquary",
    body: 'Offer <b>3 soul shards</b> to wake the Bone Abbess. Break her four <b>skull niches</b> first: they heal her and each one broken tears at her. Stand between the chorus spokes, and <b>spend the corpses</b> before her Communion eats them.',
  },
  boss_congregation: {
    title: 'The Drowned Font',
    body: 'Offer <b>4 soul shards</b> to wake the Drowned Congregation. When the tide crests march out, put a <b>pew</b> between you and her: it is the only cover from the Flood Hymn. The rising water slows you off her dais.',
  },
  boss_saint: {
    title: "The Saint's Litter",
    body: 'Offer <b>5 soul shards</b> to wake the Plague Saint. She grows as strong as you. Her Rot Rain leaves <b>rot pools</b>, and she <b>heals while she stands in one</b>: pull her out onto clean ground before you unload. Later her <b>Plague Doctors</b> feed her through a green link: kill them first.',
  },
  boss_regent: {
    title: 'The Ember Altar',
    body: 'Offer <b>6 soul shards</b> to wake the Cinder Regent. He grows as strong as you. When <b>Conflagration</b> begins the whole arena will burn: run to a <b>grey ash circle</b> and stay on it. Kill the Pyre Priests early, before their coals cover the ash.',
  },
  plague_doctor: {
    title: 'Plague Doctor',
    body: 'A <b>green ring</b> means a plague flask is coming. Step out, then stay off the rot pool it leaves behind.',
  },
  flagellant: {
    title: 'Flagellant',
    body: 'Wounded below half, a Flagellant <b>frenzies</b> (blood motes): much faster feet and blows. Take it from half to dead in one burst.',
  },
  cloister: {
    title: 'The Plague Cloister',
    body: 'The blight <b>grows with you</b>: the dead here always match the highest-level player inside (never below 20), so every kill is worth your level. The Plague Saint waits at the Saint’s Litter.',
  },
  omen: {
    title: 'The Week’s Omen',
    body: 'One omen hangs over the diocese each week (the icon on the left, hover it for the rules), the same for everyone: <b>Blood Moon</b> (more elites), <b>Drowned Week</b> (bigger waves) or <b>The Tolling</b> (Bell-Tolled elites, double shards). It changes on Monday, UTC.',
  },
  chain: {
    title: 'Kill Chain',
    body: 'Kills that land within <b>4 seconds</b> of each other build a chain. Every tier (5, 12, 25, 45, 80) adds a bonus to XP and gold, and the count turns warmer. Keep killing to keep it; dying ends it.',
  },
  pyre: {
    title: 'The Cinder Pyre',
    body: 'Fire, ash and embers. The dead here are <b>level-scaled</b> like the Cloister’s (never below 30) and every one of them leaves <b>burning ground</b>: orange rings are coals about to land, glowing cracks are ground to leave.',
  },
  warren: {
    title: 'The Catacomb Warren',
    body: 'Nine chambers split by <b>tall half-walls</b>. Walls stop cones and blows, so break line of sight to a caster by stepping behind one, and fight in the gaps where the swarm has to funnel.',
  },
  wing: {
    title: "The Alchemist's Wing",
    body: 'A safe workshop for brewing. <kbd>Click</kbd> the <b>Great Cauldron</b> (or the Alembic) to brew flasks, tonics and elixirs, and the <b>Reagent Shelf</b> to see every herb, reagent and ichor you have found. Today\'s <b>brew of the day</b> gives one extra the first time you make it. Drink with <kbd>Z</kbd> (elixir) and <kbd>X</kbd> (tonic).',
  },
  coliseum: {
    title: 'The Bone Coliseum',
    body: 'A pit with <b>four gates</b> and fast surges: twice the elites, richer drops. Fight from the pillar islands, and clear each surge before the next arrives.',
  },
  cinder_husk: {
    title: 'Cinder Husk',
    body: 'When a Husk falls it <b>bursts into embers</b> and leaves burning ground where it died. Finish it at range, or step back the moment it drops.',
  },
  pyre_priest: {
    title: 'Pyre Priest',
    body: 'An <b>orange ring</b> means a coal is coming. Step out, then stay off the burning ground it leaves behind.',
  },
  cinderhound: {
    title: 'Cinderhound',
    body: 'Burning hounds that hunt in <b>packs of two or three</b> and flank fast. Fight with your back to a wall or a Bone Ward; their corpses rise as hounds of your own.',
  },
  fen: {
    title: 'The Mourning Fen',
    body: 'A drowned marsh, level-scaled like the Pyre (never below 45). <b>Bog water slows you</b>; the pale-rimmed <b>hummocks are dry and safe</b>, so fight from them. The <b>Bog Hag</b>’s magenta ring <b>hexes your thralls</b> (30% softer for six seconds): kill her first or move your legion out of it.',
  },
  bog_hag: {
    title: 'Bog Hag',
    body: 'A <b>magenta ring</b> on your thralls is her hex: anything inside deals 30% less damage for six seconds. Kill her first, or pull the legion out before the ring fills.',
  },
  mire_leech: {
    title: 'Mire Leech',
    body: 'They come in <b>swarms of four to six</b> and leave no corpse. Sweep them with Miasma or another area rite instead of chasing them one by one.',
  },
  fen_wisp: {
    title: 'Fen Wisp',
    body: 'A <b>teal ring</b> under your feet is a cold pulse that slows you. Step out, and do not chase it: it backs away toward the open water, where you wade slowly.',
  },
  drowned_sexton: {
    title: 'Drowned Sexton',
    body: 'A <b>rust-brown line</b> is his grave-hook: it drags you toward him, then the slam follows. Step off the line, or cross it on a hummock and be ready to leave the slam ring.',
  },
  boss_mire: {
    title: 'The Mire Altar',
    body: 'Offer <b>7 soul shards</b> to wake the Mire Mother. She <b>sinks and resurfaces</b> under a hummock (a ring marks it: leave, then hit her while she is winded); phase 2 <b>floods the marsh</b>; in phase 3 she <b>raises every corpse in the Fen</b>, so spend yours first.',
  },
  slag_brute: {
    title: 'Slag Brute',
    body: 'A slow slam that cracks a wide ring and <b>leaves it burning</b>. Leave the ring when it winds up, and do not fight standing in the old one.',
  },
  meal: {
    title: 'Well fed',
    body: 'A cooked meal <b>heals over time</b> and stacks with a flask. Cook fish at the Cooking Fire in the Acre; the rarer the fish, the bigger the meal. One meal at a time.',
  },
  belt: {
    title: 'Your belt',
    body: 'Three slots wait at the left edge: <b>Heal</b>, <b>Elixir</b> and <b>Tonic</b>. Press <kbd>Q</kbd>, <kbd>Z</kbd> or <kbd>X</kbd> to drink what is in it. They stay empty until you brew: <b>Moss Tonic</b> (level 1) makes healing potions, and the Alchemist\'s Wing in the Chapterhouse\'s east door brews elixirs and tonics. Hover an empty slot to read how to fill it.',
  },
  brew: {
    title: 'Elixirs and tonics',
    body: 'You can hold <b>one elixir</b> (combat: damage, wards) and <b>one tonic</b> (utility: speed) at once. A new elixir <b>replaces</b> the old one; the same brew again extends it. Right-click a brew in the Reliquary to <b>put it on your belt</b>, then press <kbd>Z</kbd> for your elixir and <kbd>X</kbd> for your tonic. The belt at the left edge shows both slots and their timers.',
  },
  reagent: {
    title: 'Reagents',
    body: 'Grave Dust, ectoplasm, bile, ash and boss ichor are <b>Alchemy reagents</b>. Take them to the <b>Alchemist\'s Wing</b> (the Chapterhouse\'s east door): four Grave Dust brew a tonic at level 1, no garden needed. Better reagents make better elixirs as your Alchemy rises; every brew is an Elixir or a Tonic you drink with <kbd>Z</kbd> or <kbd>X</kbd>.',
  },
  tool: {
    title: 'Gathering tools',
    body: 'Carry a tool and it speeds that skill up: <b>+5% success per metal tier</b> (the best one you carry counts). Forge hatchets, pickaxes, rods and spades at the Bone Kiln (Tools tab) or the Workbench. Put them on the <b>tool belt</b> under the paper doll in the Reliquary{p:I} and they stop taking bag space.',
  },
  toolBelt: {
    title: 'The tool belt',
    body: 'Four belt slots hold one tool each: hatchet, pickaxe, rod and spade. A belted tool counts for gathering exactly like one in your bag (the best of both wins) and takes <b>no bag space</b>. Select a tool and press <b>Put on belt</b>, or double-click it; double-click it on the belt to take it off, which needs a free bag slot. Skills{p:P} shows which tool each skill is using.',
  },
  legion: {
    title: 'Spare gear for your legion',
    body: 'That weapon or armor can arm your thralls instead of being salvaged. Open the <b>Legion</b> (<kbd>Y</kbd>, or the button in the Reliquary): one <b>Weapon</b> and one <b>Armour</b> slot, kept outside your bag. Its stats become thrall damage, health and attack speed, and each spare piece shows <b>▲</b> or <b>▼</b> against what the legion wears. Spend gold there to <b>Reinforce</b> the bindings. Thralls you raise from then on carry it.',
  },
  rune: {
    title: 'A Relic rune',
    body: 'Runes change <b>how</b> a rite behaves, not how hard it hits: one turns five corpses into a single giant, another delays Black Litany and doubles it. Open the <b>Grimoire</b>{p:L}, choose a rite and socket the rune under the bar. One rune per rite, and it fits only its own. Take it out whenever you like; it is never lost. Runes stack in the Reliquary, can rest in the Vault and can be ground at the Bone Grinder. The Codex{p:K} lists them all.',
  },
  runeSocketed: {
    title: 'The rune is set',
    body: 'The rite now wears the rune: a <b>jade badge</b> sits on its slot, and hovering the slot shows exactly what changed and what it costs. Swap runes in the Grimoire{p:L} to try another style; your cooldowns are not reset.',
  },
  depths: {
    title: 'A stair in the dark',
    body: 'The Warren\'s west chamber hides a <b>stair down to the Catacomb Depths</b>: floor after floor of small chambers, each a level older than the last. <kbd>Click</kbd> the glowing stair to go down. Slay a floor\'s quota and the stair beyond it opens; leaving or falling ends the run, and whatever you looted is yours. Your legion comes with you. Solo for now.',
  },
  depths_floor: {
    title: 'Slay, then descend',
    body: 'The count at the top (and under the minimap) is this floor\'s quota. When it is met the <b>stair down</b> glows, the minimap points to it and the dead stop coming: <kbd>Click</kbd> it to go deeper. The way back up is behind you; it ends the run, so it asks twice. The dead come through the doorways to find you, so fight in the gaps and use the walls: they stop cones and blows.',
  },
  depths_affix: {
    title: 'Elites with company',
    body: 'From depth 5 an elite carries <b>more than one affix</b>, one more every fifth floor, and all of them work at once. The target frame names them all. Burst a Shrouded one inside your Miasma, step out of Bell-Tolled rings, spend corpses before a Hungering one eats them, and keep your distance from a Vengeful one\'s Risen.',
  },
  depths_chest: {
    title: 'The fifth floor\'s chest',
    body: 'Every fifth floor holds a <b>chest</b> in a side chamber, marked on the minimap. It gives gear with at least one affix, finds from the depth\'s own ground, gold and experience, and now and then a Relic rune. The deeper the chest, the more it holds.',
  },
  depths_solo: {
    title: 'Solo, for now',
    body: 'The Depths are a descent for one. Leave your party, or wait until your friends have gone, and the stair will open. Co-op floors need the realtime relay to carry the layout; they are on the list.',
  },
  ghoul: {
    title: 'Barrow Ghoul',
    body: 'Barrow Ghouls tunnel toward you. When the ground <b>cracks in a ring</b>, step out of it, then kill the ghoul before it digs back down.',
  },
  acolyte: {
    title: 'Lich Acolyte',
    body: 'A Lich Acolyte turns your <b>fallen thralls</b> against you. Kill it first, or keep your legion out of its crimson ring. Sacrificing a thrall (Litany) is safe.',
  },
  templar: {
    title: 'Bell-Sworn Templar',
    body: 'Blows from the <b>front</b> glance off its bronze shield. Come at it from the side, let your thralls turn it, or <b>Fracture</b> it (Marrow Spear, Ivory Cleave) to break the guard.',
  },
  acre: {
    title: "The Sexton's Acre",
    body: 'No waves ever come here. <kbd>Click</kbd> a tree, an ore seam, a fishing spot on the pond or a burial plot, and your necromancer keeps working it until it is spent. Coffin-Oaks just north of the entrance, the nearby Copper Seam and Pauper’s Grave, and Still Pools on the pond are usable at <b>level 1</b>. The stronger nodes lie further from the door. Press <kbd>P</kbd> to see your skills.',
  },
  laborers_working: {
    title: 'Your laborers at work',
    body: 'The dead you sent to work (<kbd>H</kbd>) stand at their posts in the Acre: chopping, mining, digging or fishing. A gold check over one means it has finished work for you to collect. <kbd>Hover</kbd> a laborer to see its post and time, or <kbd>click</kbd> it to open the Laborers.',
  },
  gather: {
    title: 'Working a node',
    body: 'Each swing, cast or dig is one work cycle; the ring under you fills as it goes. Every success gives skill XP and a find. For hands-off work in the Acre, open <kbd>P</kbd>, choose a node and <b>Start AFK</b>. Keep the game open: your hero changes nodes and waits for respawns until your bag fills. Skills can stay open; moving, casting or other panels pause work. <b>Pause AFK</b> stops it whenever you like.',
  },
  bag_full: {
    title: 'Your bag is full',
    body: 'Nothing more fits: gathering stops and loot stays on the ground until you free a slot. Sell junk in the Reliquary{p:I}, move materials to the Vault (<kbd>V</kbd>), or grind spare gear at the Bone Grinder in the Acre.',
  },
  skill_up: {
    title: 'A skill rises',
    body: 'Each level improves your odds on every node of that skill and opens a stronger one. The Skills panel{p:P} shows what the next level unlocks and your total level.',
  },
  rich_node: {
    title: 'A rich node',
    body: 'Gold-lit nodes in the hunting grounds hold more before they are spent and come back twice as fast. Taking a hit stops gathering, so clear the dead around it first.',
  },
  bag_filling: {
    title: 'Your Reliquary is filling',
    body: 'Make room before it fills: the <b>Vault</b> (<kbd>V</kbd>, in the Chapterhouse or the Acre) keeps materials and gear for every character on this account, and the <b>Bone Grinder</b> in the Acre turns spare gear into ingots, planks and reagents. In the Reliquary{p:I}, <b>Sell all junk</b> clears common and uncommon gear, and the padlock keeps an item out of every bulk button.',
  },
  vault: {
    title: 'The Ossuary Vault',
    body: 'One stash of 120 slots, shared by all your characters. <kbd>Click</kbd> an item to move its whole stack across; <b>Deposit materials</b>, <b>Deposit all</b> and <b>Sort</b> do it in bulk, and locked items always stay in your bag. It opens with <kbd>V</kbd> in the Chapterhouse or the Acre, and a move that will not fit changes nothing.',
  },
  salvage: {
    title: 'Salvaging',
    body: 'The Bone Grinder breaks unwanted gear into <b>ingots</b> (or <b>planks</b> from staffs, wands and grimoires) by rarity, plus <b>Grave Dust</b> and other reagents, and trains Salvaging. If the yield will not fit your bag, nothing is ground. Worn and locked gear is never touched.',
  },
  people: {
    title: 'People of the Covenant',
    body: 'Some of the Covenant still stand in these halls: the <b>Prior</b> in the Chapterhouse, the <b>Sexton</b> in the Acre, the <b>Apothecary</b> at her counter in the Alchemist’s Wing (the Chapterhouse’s east door). Click one, or stand close and press <kbd>E</kbd>. A gold <b>!</b> means they have something new to say. They only advise. The <b>Next</b> line under the minimap shows one suggestion; Settings can hide it.',
  },
  station: {
    title: 'A working station',
    body: 'Stations turn what you gather into something useful. The Sawpit’s warm gold light marks where to click for wood recipes. Recipes need the matching skill level and their ingredients in your bag; crafting grants skill XP too. The server checks every recipe, and its reason is shown if one fails.',
  },
  rite_fan: {
    title: 'Bone Fan',
    body: 'Your left click now throws three slivers, each at a different enemy near the one you click. It clears packs fast but is weaker on one target (the Prelate only ever takes one sliver). Swap back to Bone Needle on the Grimoire\'s <b>LMB</b> socket for bosses.',
  },
  rite_lance: {
    title: 'Rot Lance',
    body: 'Your left click now pierces the first two enemies in line and leaves Withered ticking on each. Line the dead up; the rot keeps working while you move on.',
  },
  rite_offering: {
    title: 'Grave Offering',
    body: 'Press {key:grave_offering} on a corpse to burn it into Grave Essence and a little health. Spend the bodies you won\'t raise: when your legion is full, or when essence runs dry.',
  },
  rite_cleave: {
    title: 'Ivory Cleave',
    body: 'Press {key:ivory_cleave} to sweep a bone crescent through everything in a wide arc in front of you, Fracturing it. Cleave the pack that reaches you, then Spear the line.',
  },
  rite_veil: {
    title: 'Veil Step',
    body: 'Press {key:veil_step} to slip a few metres toward the cursor, no corpse needed. It stops at walls and sealed doors. Use it to leave a cone or a bell ring; auto combat never does.',
  },
  rite_rally: {
    title: 'Rally the Dead',
    body: 'With thralls at your side, press {key:rally_dead} with the cursor on the enemy you want dead: your legion heals, hits harder and faster, and turns on it. The jade sigils show who is rallied.',
  },
  rite_seed: {
    title: 'Carrion Seed',
    body: 'Press {key:carrion_seed} on a corpse in the pack\'s path. The bud arms in a moment, then bursts in rot when an enemy comes close. One seed at a time; if another rite uses that corpse, the seed goes with it.',
  },
  rite_siphon: {
    title: 'Soul Siphon',
    body: 'Latch the jade tether onto something sturdy and <b>keep moving</b>: it follows the target for 3 seconds, draining it into your health and essence. It snaps if they get too far away.',
  },
  rite_prison: {
    title: 'Bone Prison',
    body: 'Drop the cage on a pack as it closes. Everything inside is <b>rooted</b> for a moment and Fractured: the perfect setup for a Marrow Spear or a Corpse Explosion. Rooted enemies still swing at whatever stands beside them.',
  },
  rite_hands: {
    title: 'Grave Hands',
    body: 'Cast it where the dead lie thickest: every corpse in the field adds more hands and more damage, and <b>none are used up</b>. Everything inside is slowed while the hands claw.',
  },
  rite_storm: {
    title: 'Bone Storm',
    body: 'Start the storm on a pile of corpses to make it last longer (they are not used up), then let it <b>drift through the pack on its own</b> while you keep casting.',
  },
  rite_mantle: {
    title: 'Bone Mantle',
    body: 'Cast it standing among the dead: each corpse within 6m thickens a barrier that holds for 6 seconds, while whirling shards cut whatever reaches you. With no corpses you still get a thin mantle.',
  },
};

/** How often a waiting tip re-checks whether the moment is right. */
const PUMP_MS = 1000;
/** Default card position: top-left under the hero frame. The left-edge readouts (Kill Chain, Bone Ward, brews) start below it. */
const DEFAULT_X = 18;
const DEFAULT_Y = 70;
/** Showing a tip also counts these as seen: the Acre card is the same lesson as the opening welcome. */
const ALSO_SEEN: Partial<Record<TipId, TipId[]>> = { welcome: ['acre'] };
const tipsKey = (characterId: number) => `dm_tips_v1_${characterId}`;
const POSITION_KEY = 'dm_counsel_position_v1';
const TIP_IDS = Object.keys(TIPS) as TipId[];

export class Onboarding {
  private seen = new Set<TipId>();
  private queue: QueuedTip[] = [];
  private seq = 0;
  private pending = new Set<TipId>();
  private shown: ShownCard | null = null;
  private shownEntry: QueuedTip | null = null;
  private lastClosedAt: number;
  private groupShownAt: Record<string, number> = {};
  private pumpTimer = 0;
  /** What the scene is busy with right now (a fight, a conversation, a banner, an open panel); calm tips wait it out. */
  busy: () => Busy = () => NOT_BUSY;
  private el: HTMLDivElement | null = null;
  private timers = new Set<number>();
  private hideTimer = 0;
  private offSettings: () => void;
  private key: string;
  private position: { x: number; y: number } | null = null;
  private onResize = () => { if (this.el) this.place(this.el); };
  /** The key a rite sits on (Grimoire loadout), or null when it isn't on the bar. */
  keyFor: ((abilityId: string) => string | null) | null = null;

  constructor(
    private root: HTMLElement,
    characterId: number,
    private storage: StorageLike | null = browserStorage(),
    /** Milliseconds on any monotonic clock (the scene passes its game clock); only differences matter. */
    private clock: () => number = () => performance.now(),
  ) {
    this.key = tipsKey(characterId);
    // A fresh session may open with its first card after about three seconds, not twenty.
    this.lastClosedAt = this.clock() - 17_000;
    try {
      const raw = this.storage?.getItem(this.key);
      const list: unknown = raw ? JSON.parse(raw) : [];
      if (Array.isArray(list)) for (const id of list) if (TIP_IDS.includes(id as TipId)) this.seen.add(id as TipId);
    } catch {
      /* storage unavailable or corrupt — tips simply show again */
    }
    try {
      const saved = JSON.parse(this.storage?.getItem(POSITION_KEY) ?? 'null');
      if (saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) this.position = saved;
    } catch { /* Use the default position when storage is unavailable. */ }
    window.addEventListener('resize', this.onResize);
    this.offSettings = onSettingsChange((s) => {
      if (!s.tips) this.clear();
    });
  }

  /**
   * Ask for a tip: once per character, never twice at the same time. Whether and when it appears is the cadence's call
   * (counselCadence.ts); `opts.kind` overrides the tip's usual kind for one call (the Codex lectern is "asked", the 40-kill
   * nudge is "calm"), and `true`/`bump` puts it ahead of others of its kind.
   */
  show(id: TipId, delayMs = 0, opts: boolean | { kind?: TipKind; bump?: boolean } = {}) {
    if (!settings.tips || this.seen.has(id) || this.pending.has(id) || this.queue.some((t) => t.id === id) || this.shown?.id === id) return;
    if (delayMs > 0) {
      this.pending.add(id);
      this.later(() => {
        this.pending.delete(id);
        this.show(id, 0, opts);
      }, delayMs);
      return;
    }
    const o = typeof opts === 'boolean' ? { bump: opts } : opts;
    const entry = makeEntry(id, this.clock(), ++this.seq, !!o.bump);
    if (o.kind) entry.kind = o.kind;
    this.queue.push(entry);
    this.pump();
  }

  private cadence(over: Partial<CadenceState> = {}): CadenceState {
    return { now: this.clock(), lastClosedAt: this.lastClosedAt, groupShownAt: this.groupShownAt, busy: this.busy(), ...over };
  }

  /** Decide, now, whether the card on screen should step aside and whether the next waiting tip may open; re-check in a second. */
  private pump() {
    this.cancel(this.pumpTimer);
    this.pumpTimer = 0;
    if (!settings.tips) return;
    this.queue = prune(this.queue, this.clock());
    if (this.el && this.shown && this.shownEntry) {
      const s = this.cadence();
      const waiting = pickNext(this.queue, this.cadence({ lastClosedAt: -Infinity }));
      if (shouldPreempt(this.shown, waiting, s) && waiting) {
        // The urgent tip takes the place at once (it must not wait out the gap the swap itself starts, or the old card would return).
        this.sendBack();
        this.queue = this.queue.filter((t) => t !== waiting);
        this.present(waiting);
      } else if (shouldYield(this.shown, s)) this.sendBack();
    }
    if (!this.el) {
      const next = pickNext(this.queue, this.cadence());
      if (next) {
        this.queue = this.queue.filter((t) => t !== next);
        this.present(next);
      }
    }
    if (this.queue.length) this.pumpTimer = this.later(() => this.pump(), PUMP_MS);
  }

  /** The card on screen leaves before it was read (a fight began, something urgent came): it returns at the front of the line. */
  private sendBack() {
    const entry = this.shownEntry;
    if (entry) {
      this.seen.delete(entry.id as TipId);
      for (const extra of ALSO_SEEN[entry.id as TipId] ?? []) this.seen.delete(extra);
      this.persist();
      this.queue.unshift({ ...entry, queuedAt: this.clock() });
    }
    this.dismiss();
  }

  private present(entry: QueuedTip) {
    const id = entry.id as TipId;
    if (!settings.tips || this.seen.has(id)) return;
    this.seen.add(id);
    for (const extra of ALSO_SEEN[id] ?? []) this.seen.add(extra);
    this.persist();
    this.shown = { id, kind: entry.kind, shownAt: this.clock() };
    this.shownEntry = entry;
    const group = groupOf(id);
    if (group) this.groupShownAt[group] = this.clock();
    const tip = TIPS[id];
    const body = renderText(tip.body, this.keyFor ?? undefined);
    const el = document.createElement('div');
    el.className = 'cw-plate cw-tip';
    el.dataset.kind = entry.kind;
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    // Give each card at least 25 seconds and longer counsel more reading time.
    const words = body.replace(/<[^>]+>/g, ' ').split(/\s+/).filter(Boolean).length;
    const ms = showMs(entry.kind, words);
    el.style.setProperty('--tip-ms', `${ms}ms`);
    el.innerHTML = `
      <div class="kicker" data-move role="button" tabindex="0" aria-label="Move Covenant counsel card" title="Drag this card, or use arrow keys"><span>⋮⋮ Covenant counsel</span><span class="move-hint">Move this card</span></div>
      <div class="title">${renderText(tip.title)}</div>
      <div class="body">${body}</div>
      <div class="foot"><span>Click to dismiss</span><button type="button" data-skip>Don't show tips</button></div>
      <div class="timer"></div>`;
    el.addEventListener('click', e => { if (!(e.target as HTMLElement).closest('[data-move]')) this.dismiss(); });
    el.querySelector('[data-skip]')!.addEventListener('click', (e) => {
      e.stopPropagation();
      updateSettings({ tips: false });
    });
    this.root.appendChild(el);
    this.el = el;
    this.place(el);
    const handle = el.querySelector<HTMLElement>('[data-move]')!;
    let drag: { pointer: number; x: number; y: number; left: number; top: number } | null = null;
    handle.addEventListener('pointerdown', e => {
      if (e.button !== 0 || drag) return;
      e.preventDefault(); e.stopPropagation();
      handle.focus({ preventScroll: true });
      const bounds = el.getBoundingClientRect();
      drag = { pointer: e.pointerId, x: e.clientX, y: e.clientY, left: bounds.left, top: bounds.top };
      el.style.animation = 'none';
      el.classList.add('dragging');
      handle.setPointerCapture(e.pointerId);
      pauseTimer();
    });
    handle.addEventListener('pointermove', e => {
      if (!drag || drag.pointer !== e.pointerId) return;
      e.preventDefault(); e.stopPropagation();
      this.place(el, drag.left + e.clientX - drag.x, drag.top + e.clientY - drag.y);
    });
    const endDrag = (e: PointerEvent) => {
      if (!drag || drag.pointer !== e.pointerId) return;
      e.stopPropagation();
      drag = null;
      el.classList.remove('dragging');
      if (handle.hasPointerCapture(e.pointerId)) handle.releasePointerCapture(e.pointerId);
      this.savePosition();
      if (!el.matches(':hover')) resumeTimer();
    };
    handle.addEventListener('pointerup', endDrag);
    handle.addEventListener('pointercancel', endDrag);
    handle.addEventListener('keydown', e => {
      const step = e.shiftKey ? 30 : 10;
      const moves: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
      const delta = moves[e.key];
      if (!delta) return;
      e.preventDefault(); e.stopPropagation();
      const bounds = el.getBoundingClientRect();
      this.place(el, bounds.left + delta[0], bounds.top + delta[1]);
      this.savePosition();
    });
    let remaining = ms;
    let startedAt = performance.now();
    const timer = el.querySelector<HTMLElement>('.timer')!;
    let paused = false;
    const pauseTimer = () => {
      if (paused) return;
      paused = true;
      remaining = Math.max(0, remaining - (performance.now() - startedAt));
      this.cancel(this.hideTimer);
      timer.style.animationPlayState = 'paused';
    };
    el.addEventListener('pointerenter', pauseTimer);
    const resumeTimer = () => {
      if (this.el !== el || drag || !paused) return;
      paused = false;
      this.cancel(this.hideTimer);
      startedAt = performance.now();
      timer.style.animationPlayState = 'running';
      this.hideTimer = this.later(() => this.dismiss(), remaining);
    };
    el.addEventListener('pointerleave', resumeTimer);
    this.hideTimer = this.later(() => this.dismiss(), remaining);
  }

  /**
   * Put the card on screen. Without explicit coordinates it goes where the player last dragged it, or to the default corner.
   */
  private place(el: HTMLElement, x?: number, y?: number) {
    const bounds = el.getBoundingClientRect();
    const px = x ?? this.position?.x ?? DEFAULT_X;
    // In co-op the party list fills the top-left corner: start under it.
    const party = document.querySelector<HTMLElement>('.hud-party');
    const below = party && party.childElementCount ? party.getBoundingClientRect().bottom + 8 : 0;
    const py = y ?? this.position?.y ?? Math.max(DEFAULT_Y, below);
    const cx = Math.max(8, Math.min(px, window.innerWidth - bounds.width - 8));
    const cy = Math.max(8, Math.min(py, window.innerHeight - bounds.height - 8));
    if (x !== undefined || y !== undefined) this.position = { x: cx, y: cy };
    el.style.left = `${cx}px`;
    el.style.top = `${cy}px`;
  }

  private savePosition() {
    try { this.storage?.setItem(POSITION_KEY, JSON.stringify(this.position)); }
    catch { /* Position still works for this session. */ }
  }

  private dismiss() {
    const el = this.el;
    if (!el) return;
    this.el = null;
    this.cancel(this.hideTimer);
    el.classList.add('out');
    this.later(() => el.remove(), 220);
    this.shown = null;
    this.shownEntry = null;
    this.lastClosedAt = this.clock();
    this.later(() => this.pump(), 300);
  }

  /** Forget which tips this character has seen, so the whole sequence plays again. */
  reset() {
    this.clear();
    this.seen.clear();
    this.groupShownAt = {};
    this.persist();
  }

  /** Hide the current card and drop everything queued (tips turned off). */
  private clear() {
    this.queue = [];
    this.pending.clear();
    this.shown = null;
    this.shownEntry = null;
    this.pumpTimer = 0;
    for (const t of this.timers) window.clearTimeout(t);
    this.timers.clear();
    this.el?.remove();
    this.el = null;
  }

  private persist() {
    try {
      this.storage?.setItem(this.key, JSON.stringify([...this.seen]));
    } catch {
      /* storage unavailable — the tip may show again next session */
    }
  }

  private later(fn: () => void, ms: number) {
    const t = window.setTimeout(() => {
      this.timers.delete(t);
      fn();
    }, ms);
    this.timers.add(t);
    return t;
  }

  private cancel(t: number) {
    window.clearTimeout(t);
    this.timers.delete(t);
  }

  dispose() {
    this.clear();
    this.offSettings();
    window.removeEventListener('resize', this.onResize);
  }
}
