import { AREAS, type AreaId } from './areas';
import { BOSSES, BOSS_IDS, type BossId } from './bosses';
import type { NpcId } from './npcs';
import { formatSealProgress, lowerThe, bossBeaten, bossesWaiting, isOpen, pendingSeals, suggestionFor, BAG_FULL_FRACTION, GRAVE_DUST_FOR_TONIC, type GuidanceState, type NewsItem, type Suggestion } from '../gameplay/guidance';

/**
 * What the people of the Covenant say. Plain text only (the panel escapes it), two to three short lines per answer.
 * Every answer is a small function of the real state (gameplay/guidance.ts), so the numbers they quote are the numbers you have.
 * They advise and never command: no line ever says a thing must be done.
 */
export const LABEL = {
  advice: { prior: 'Where should I go next?', sexton: 'What needs doing?', apothecary: 'What should I brew?' } satisfies Record<NpcId, string>,
  about: 'Tell me about…',
  back: 'Back',
  bye: 'Goodbye',
};

export interface TopicDef {
  id: string;
  label: string;
  lines: (s: GuidanceState) => string[];
}

type Greeting = { when: (s: GuidanceState, news: NewsItem[], met: boolean) => boolean; lines: (s: GuidanceState, news: NewsItem[]) => string[] };

const has = (news: NewsItem[], prefix: string) => news.find((n) => n.key.startsWith(prefix));
const n = (v: number) => v.toLocaleString();
const plural = (k: number, one: string, many: string) => (k === 1 ? one : many);
const levelDesc = (a: AreaId) => `level ${AREAS[a].level}${AREAS[a].scaling ? '+' : ''}`;

/** One practical sentence per boss (README "Fight clue"). */
export const BOSS_HINT: Record<BossId, string> = {
  gravedigger: 'Leave the marked burial ground before it roots you, and watch for pits later in the fight.',
  abbess: 'Break the skull niches that heal her, and spend your corpses before she draws them in.',
  congregation: 'Use the pews to block the Flood Hymn, and step out of the grasping rings.',
  prelate: 'Keep out of the Toll ring, the frontal Slam and the marked Bell Rain circles.',
  saint: 'Move her off the rot pools where she heals, and kill the Plague Doctors that feed her.',
  regent: 'When Conflagration starts, run to a grey ash circle and stay on it.',
  mire: 'Fight from the dry hummocks, and spend your corpses before her third phase.',
};

// ---------------------------------------------------------------------------
// The Prior
// ---------------------------------------------------------------------------

const PRIOR_GREETINGS: Greeting[] = [
  {
    when: (_s, _n, met) => !met,
    lines: () => [
      'Welcome to the Chapterhouse, child of the Covenant. I am the Prior; the seals and the dead of this diocese are my charge.',
      'No one commands you here. Ask me where to go and I will say it plainly; you may ignore every word.',
    ],
  },
  {
    when: (_s, news) => !!has(news, 'ascend:ready'),
    lines: (s) => [
      'The Bell-Sworn Prelate lies silent, and the Altar of Ascension stands ready.',
      `It will take this run and give back ${n(s.ashesOnAscend)} Ashes, if you choose. No one is hurrying you.`,
    ],
  },
  {
    when: (_s, news) => news.some((x) => x.key.startsWith('boss:') && !x.key.startsWith('boss:prelate')),
    lines: (_s, news) => {
      const id = news.find((x) => x.key.startsWith('boss:') && !x.key.startsWith('boss:prelate'))!.key.split(':')[1] as BossId;
      return [`${BOSSES[id].name} is buried. Even the cloisters have heard.`, 'Take your rest in the Chapterhouse, or walk on while the dead are still frightened.'];
    },
  },
  {
    when: (_s, news) => !!has(news, 'seal:'),
    lines: (_s, news) => {
      const a = has(news, 'seal:')!.key.split(':')[1] as AreaId;
      return [`A seal has broken: ${lowerThe(AREAS[a].name)} lies open to you, and its dead are ${levelDesc(a)}.`, 'Go when you feel ready. The road will wait.'];
    },
  },
  {
    when: (s, news) => !!has(news, 'rank:') && s.ascension > 0,
    lines: (s) => [`You have risen to rank ${s.ascension}. The seals have closed behind you, but you remember the way.`, 'The dead are older now. Ask, and I will tell you what lies open.'],
  },
  {
    when: (s) => s.totalKills < 10 && s.ascension === 0,
    lines: () => ['The Hollow Graves lie north, through the door at the top of this hall. Begin there.'],
  },
  {
    when: () => true,
    lines: (s) => {
      const open = ['Walk carefully. The dead remember.', 'The Covenant keeps what it can. What it cannot keep, you bury.', 'You look well. The diocese is not, but that is hardly your fault.'];
      return [open[s.level % open.length]];
    },
  },
];

function priorAdvice(sg: Suggestion | null, s: GuidanceState): string[] {
  if (!sg) return ['Nothing presses. Hunt where you like, and come back when you want counsel.'];
  const d = sg.data;
  switch (sg.kind) {
    case 'first-steps':
      return ['North, through the door at the top of this hall, lie the Hollow Graves. Strike the robbers and hounds there.', 'Gather what falls. Your bag is the Reliquary on the west wall (I).'];
    case 'seal': {
      const lvl = Number(d.level);
      const note = s.level + 2 < lvl ? `You are level ${s.level}; a few more levels will make that road kinder.` : `You are level ${s.level}. You are strong enough for it.`;
      return [`The road onward is sealed. Slay ${n(Number(d.need) - Number(d.kills))} more of the dead in ${d.from}, and ${d.to} will open. ${d.seal}.`, note];
    }
    case 'boss-ready':
      return [`${d.boss} stirs at ${d.at}, in ${d.area}. You hold the ${d.shards} soul shards it asks.`, BOSS_HINT[BOSS_IDS.find((id) => BOSSES[id].name === d.boss)!]];
    case 'boss-short':
      return [`${d.boss} will answer ${d.at} in ${d.area} once you bring ${d.shards} soul shards. You hold ${d.have}; elites carry them.`, BOSS_HINT[BOSS_IDS.find((id) => BOSSES[id].name === d.boss)!]];
    case 'ascend':
      return [`The Altar of Ascension is ready. It trades this run (seals, upgrades, shards) for ${n(Number(d.ashes))} Ashes and a higher rank, and keeps your level, gold and gear.`, 'It is a choice, never a duty.'];
    case 'hunt':
      return d.clear
        ? [`Every seal I know of is broken and every king buried. Hunt in ${d.area}, where the dead are level ${d.level}+ and the spoils richest.`, 'Or ascend, or hunt for a set of armor. The diocese is yours.']
        : [`Hunt in ${d.area}: its dead are level ${d.level}+. When you wish for a harder master, ask me again.`];
    default:
      return [sg.text];
  }
}

const sideHalls = (s: GuidanceState): string[] => {
  const out: string[] = [];
  for (const a of ['warren', 'coliseum'] as AreaId[]) {
    if (isOpen(s, a)) continue;
    const u = AREAS[a].unlock!;
    out.push(`${AREAS[a].name} (${n(Math.max(1, Math.round(u.kills * s.unlockMult)))} dead in ${lowerThe(AREAS[u.area].name)})`);
  }
  return out;
};

const PRIOR_TOPICS: TopicDef[] = [
  {
    id: 'seals',
    label: 'The seals',
    lines: (s) => {
      const seals = pendingSeals(s).filter((x) => !x.side);
      const first = 'Slay enough of the dead in a hall and the seal to the next breaks by itself. There is nothing to carry or to buy.';
      const now = seals[0]
        ? `Now: ${formatSealProgress(seals[0].area, seals[0].kills, seals[0].need)}, in ${lowerThe(AREAS[seals[0].from].name)}.`
        : 'Every seal on the main road is broken.';
      const side = sideHalls(s);
      return [first, now, ...(side.length ? [`Two side halls open sooner: ${side.join(' and ')}.`] : [])];
    },
  },
  {
    id: 'bosses',
    label: 'The kings of the dead',
    lines: (s) => {
      const next = bossesWaiting(s)[0];
      const base = 'Each hunting ground has an altar that wakes its king for soul shards. Elites carry the shards; only one king can wake at a time.';
      if (!next) return [base, 'Every king in the halls you have opened is buried. Their first defeat paid two extra shards and a rare relic.'];
      const b = BOSSES[next];
      return [base, `Next: ${b.name} at ${b.summonLabel.replace(/^The /, 'the ')}, ${b.shards} shards (you hold ${s.shards}). ${BOSS_HINT[next]}`];
    },
  },
  {
    id: 'ascension',
    label: 'The Altar of Ascension',
    lines: (s) => {
      if (s.canAscend) return [`It is ready. Ascending resets seals, upgrades and shards; it keeps your level, gold, gear and skills, and pays ${n(s.ashesOnAscend)} Ashes.`, 'Ashes buy Covenant Boons at the Altar. Each rank makes the dead three levels older, and the spoils richer.'];
      if (!bossBeaten(s, 'prelate'))
        return ['Defeat the Bell-Sworn Prelate at the Sundered Bell, in the Bell Sanctum (5 soul shards), and the Altar will open to you.', s.ascension > 0 ? `You hold rank ${s.ascension} already.` : 'It is far ahead of you yet, and entirely optional.'];
      return [`You hold rank ${s.ascension}. Another Prelate kill this run will make the Altar ready again.`, 'Ashes buy Covenant Boons; each rank makes the dead three levels older.'];
    },
  },
];

// ---------------------------------------------------------------------------
// The Sexton
// ---------------------------------------------------------------------------

const SEXTON_GREETINGS: Greeting[] = [
  {
    when: (_s, _n, met) => !met,
    lines: () => ['Mind the graves, they are tended. I am the Sexton; this Acre is mine and, I suppose, yours now.', 'Nothing here bites. Trees, seams, pools and graves: pick whichever takes your fancy.'],
  },
  { when: (_s, news) => !!has(news, 'labor:ready'), lines: () => ['Your laborers have been busy. There is work waiting on them: press H and collect it.'] },
  {
    when: (_s, news) => !!has(news, 'bag:full'),
    lines: (s) => [`That bag of yours is groaning (${s.bagUsed} of ${s.bagSize}). The Grinder turns spare gear into ingots, and the Vault keeps the rest.`],
  },
  { when: (s, news) => !!has(news, 'contracts:open') && !!s.contracts, lines: (s) => [`The board has ${s.contracts!.open} ${plural(s.contracts!.open, 'order', 'orders')} still unfilled today. Press O to see them.`] },
  {
    when: () => true,
    lines: (s) => {
      const open = ['Wood, ore, fish, bones. The Acre gives what you are patient enough to take.', 'Quiet today. The dead here do not complain, which is why I like them.', 'Take your time. The nodes come back, they always come back.'];
      return [open[s.level % open.length]];
    },
  },
];

function sextonAdvice(sg: Suggestion | null): string[] {
  if (!sg) return ['Nothing presses. Work a node, fill an order, or let your laborers carry on, whichever suits you.'];
  const d = sg.data;
  switch (sg.kind) {
    case 'bag-full':
      return [`Your bag is ${d.used} of ${d.size}. Spare gear can go to the Bone Grinder by the kiln (it trains Salvaging), and anything you wish to keep can go in the Vault (V).`, 'Padlock the pieces you want to keep first, and the bulk buttons will leave them be.'];
    case 'labor-ready':
      return [`${d.ready} of your laborers ${Number(d.ready) === 1 ? 'has' : 'have'} a good haul waiting. Press H to collect it and set them back to work.`];
    case 'contracts':
      return [`The board has ${d.open} of ${d.total} orders unfilled today (O). Deliver from your bag for gold and sometimes an item; all three pay a bonus.`];
    case 'labor-idle':
      return ['A laborer stands idle. Press H and give them a post: they gather slowly, for up to eight hours, while you hunt or sleep.'];
    case 'gather-intro':
      return ['Click a Coffin-Oak, a Seam, a Still Pool or a Pauper’s Grave to start a skill at level 1. Press P to watch your skills grow.', 'You can also set one to work while you do other things: P, choose a tier, Start AFK.'];
    default:
      return [sg.text];
  }
}

const SEXTON_TOPICS: TopicDef[] = [
  {
    id: 'gather',
    label: 'Gathering and laborers',
    lines: (s) => {
      const allOne = ['woodcutting', 'mining', 'fishing', 'gravedigging'].every((k) => (s.skills[k] ?? 1) <= 1);
      const first = allOne
        ? 'Click a Coffin-Oak, a Seam, a Still Pool or a Pauper’s Grave to begin. Press P for your skills, or Start AFK to keep working while you do other things.'
        : 'Higher tiers need higher skill. Press P to see what you unlock next, and Start AFK to keep a node worked while you do other things.';
      const lab = s.labor
        ? s.labor.ready > 0
          ? `Your laborers have work waiting: press H.`
          : s.labor.unlocked > s.labor.assigned
            ? 'A laborer stands idle: press H and give them a post.'
            : 'Your laborers are at their posts. They gather slowly for up to eight hours (H).'
        : 'Grave Laborers (H) gather slowly while you are away, for up to eight hours. You gain another for every 50 total gathering levels.';
      return [first, lab];
    },
  },
  {
    id: 'grinder',
    label: 'The Bone Grinder and the Vault',
    lines: (s) => {
      const bag = s.bagSize > 0 && s.bagUsed / s.bagSize >= BAG_FULL_FRACTION ? `Your bag is ${s.bagUsed} of ${s.bagSize}: it is time.` : s.bagSize > 0 && s.bagUsed / s.bagSize >= 0.6 ? `Your bag is ${s.bagUsed} of ${s.bagSize}; there is no hurry yet.` : '';
      return [
        'The Bone Grinder, beside the kiln, turns spare gear into ingots and planks, and trains Salvaging. Worn and padlocked pieces are never touched.',
        'The Ossuary Vault (V), here or in the Chapterhouse, keeps 120 slots shared by every character on your account.',
        ...(bag ? [bag] : []),
      ];
    },
  },
  {
    id: 'contracts',
    label: 'The daily Contracts',
    lines: (s) => [
      'Three orders a day (O), easy to hard, drawn from what your skills can make. Deliver from your bag for gold, and sometimes an item. Now and then I want gems, fragments or seals; I pay double for those.',
      s.contracts ? (s.contracts.open === 0 ? 'Today’s board is done. A fresh one comes tomorrow; finishing all three pays a bonus and builds a streak.' : `${s.contracts.open} of today’s ${s.contracts.total} are still open.`) : 'Fill all three for a bonus, and a streak that grows each day.',
    ],
  },
];

// ---------------------------------------------------------------------------
// The Apothecary
// ---------------------------------------------------------------------------

const APOTHECARY_GREETINGS: Greeting[] = [
  {
    when: (_s, _n, met) => !met,
    lines: () => ['Hush, mind the vials. This is my Wing now: the Great Cauldron, the Alembic, and the Shelf where every reagent you find gets its place.', 'Four Grave Dust and a little patience make a first tonic. Ask, and I will tell you what to brew.'],
  },
  { when: (_s, news) => !!has(news, 'dust:first'), lines: (s) => [`You are carrying ${s.dust} Grave Dust, enough for a tonic. Bring it to the Great Cauldron, here in the Wing.`] },
  { when: (_s, news) => !!has(news, 'reagent:fen'), lines: () => ['The Fen grows bog myrtle and drowned lotus. The Mire Mother’s ichor and a lotus make a Moonlight Elixir, if you are brave.'] },
  { when: (_s, news) => !!has(news, 'reagent:pyre'), lines: () => ['Cinder Ash from the Pyre, and ash-bloom if you grow it. Both go into stronger elixirs.'] },
  { when: (_s, news) => !!has(news, 'reagent:cloister'), lines: () => ['Plague Bile from the Cloister, and rot-cap if you forage it. Do not taste either.'] },
  {
    when: () => true,
    lines: (s) => {
      const open = ['Careful with that. No, the other one.', 'A good brew is mostly patience, and a little contempt for the dead.', 'Everything in this room is either medicine or poison. Occasionally both.'];
      return [open[s.level % open.length]];
    },
  },
];

function reagentTip(s: GuidanceState): string {
  if (isOpen(s, 'fen')) return 'The Fen gives bog myrtle and drowned lotus; the Mire Mother’s ichor and a lotus make a Moonlight Elixir.';
  if (isOpen(s, 'pyre')) return 'The Pyre gives Cinder Ash, and ash-bloom if you grow it from seed in the Acre.';
  if (isOpen(s, 'cloister')) return 'The Cloister gives Plague Bile, and rot-cap you can forage and plant in the Acre.';
  return 'Spirits drop Wraith Ectoplasm. Each deeper hall adds a reagent of its own; I will tell you as you open them.';
}

function apothecaryAdvice(sg: Suggestion | null, s: GuidanceState): string[] {
  if (!sg) return [`Brew what you can. ${reagentTip(s)}`];
  const d = sg.data;
  switch (sg.kind) {
    case 'brew-dust':
      return [`You carry ${d.dust} Grave Dust. At the Great Cauldron here, four of them brew a Grave-Dust Tonic: more essence regeneration for a minute.`, 'The first brew anyone can make from what the dead drop.'];
    case 'brew-first':
      return ['Grave Dust drops now and then from the dead of the Hollow Graves and the Catacomb Warren. Four make your first tonic.', `You hold ${d.dust}. Keep killing; it will come.`];
    default:
      return [sg.text];
  }
}

const APOTHECARY_TOPICS: TopicDef[] = [
  {
    id: 'brewing',
    label: 'Brewing',
    lines: (s) => [
      'The Great Cauldron or the Alembic here in the Wing. Each recipe wants reagents and a level in Alchemy, which brewing itself trains.',
      s.dust >= GRAVE_DUST_FOR_TONIC ? `You have the dust for a first tonic (${s.dust}).` : `Four Grave Dust make your first tonic. You hold ${s.dust}.`,
    ],
  },
  {
    id: 'reagents',
    label: 'Where reagents fall',
    lines: (s) => [
      'Grave Dust: the Hollow Graves and the Catacomb Warren. Wraith Ectoplasm: spirits. Plague Bile: the Cloister. Cinder Ash: the Pyre.',
      'Every area boss leaves an ichor. Herbs such as rot-cap and ash-bloom grow in the Acre from foraged seeds (U).',
      reagentTip(s),
    ],
  },
  {
    id: 'belt',
    label: 'Elixirs and tonics',
    lines: () => [
      'You have two brew slots: an Elixir for combat (Z) and a Tonic for everything else (X). A new elixir replaces the old one.',
      'Right-click a brew in the Reliquary (I) to put it on your belt. Drinking the same brew again extends it, up to twice its length.',
    ],
  },
];

// ---------------------------------------------------------------------------
// Selectors
// ---------------------------------------------------------------------------

const GREETINGS: Record<NpcId, Greeting[]> = { prior: PRIOR_GREETINGS, sexton: SEXTON_GREETINGS, apothecary: APOTHECARY_GREETINGS };
export const TOPICS: Record<NpcId, TopicDef[]> = { prior: PRIOR_TOPICS, sexton: SEXTON_TOPICS, apothecary: APOTHECARY_TOPICS };

/** The opening words. `news` is what `Guidance.unheard` returned before this talk was recorded. */
export function greetingLines(npc: NpcId, s: GuidanceState, news: NewsItem[], met: boolean): string[] {
  const g = GREETINGS[npc].find((x) => x.when(s, news, met))!;
  return g.lines(s, news);
}

/** The answer to the first button ("where next?"), from the best suggestion on that person's subject. */
export function adviceLines(npc: NpcId, s: GuidanceState): string[] {
  const sg = suggestionFor(npc, s);
  return npc === 'prior' ? priorAdvice(sg, s) : npc === 'sexton' ? sextonAdvice(sg) : apothecaryAdvice(sg, s);
}

export function topicLines(npc: NpcId, id: string, s: GuidanceState): string[] {
  return TOPICS[npc].find((t) => t.id === id)?.lines(s) ?? [];
}

const FAREWELLS: Record<NpcId, string[]> = {
  prior: ['Go with the Covenant’s quiet.', 'The door is always open.', 'Walk well.'],
  sexton: ['Mind the graves.', 'Come back with dirt on your boots.', 'Right. Back to it.'],
  apothecary: ['Do not drink anything you did not brew.', 'Come back alive, I have questions.', 'Mind the vials on the way out.'],
};
export const farewell = (npc: NpcId, s: GuidanceState) => FAREWELLS[npc][s.totalKills % FAREWELLS[npc].length];

