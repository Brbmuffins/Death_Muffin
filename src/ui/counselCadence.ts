/**
 * Covenant counsel cadence: pure rules for WHEN a queued tip may appear (ui/Onboarding does the drawing).
 *
 * The owner's brief is "immersive but not overwhelming", so the rules are about restraint:
 *  - one card at a time, always;
 *  - a tip that explains a quiet idea ("calm") waits for a calm moment: no fight, no conversation, no area banner, no open
 *    panel, and a gap since the last card closed;
 *  - a tip that is only useful mid-fight ("danger": a telegraph, an exhume) may show in combat, but never while talking or
 *    standing in a sanctuary, and is dropped if it could not be shown within seconds, because the thing it described has moved on
 *    (the urgent "Hurt?" reminder is the exception: it jumps the queue);
 *  - a tip about something the player just did ("asked": opened the Vault, placed a rite on a key) shows promptly;
 *  - tips on the same subject (gear, bag, brewing, gathering) keep a long gap between them, so one drop that is armor AND
 *    affixed AND loot does not queue three cards saying the same thing.
 * Everything here is a function of plain numbers, so it is unit-tested without a DOM (ui/__tests__/counselCadence.test.ts).
 */

export type TipKind = 'urgent' | 'danger' | 'asked' | 'calm';

export interface Busy {
  /** A fight is on: several enemies close by, or a blow taken in the last few seconds. */
  combat: boolean;
  /** Under attack right now: a blow taken in the last few seconds, or a boss awake. Nothing but fight-time tips shows then. */
  hurt: boolean;
  /** A conversation card is open. */
  talking: boolean;
  /** The area-name banner is on screen. */
  banner: boolean;
  /** The hero is dead (the death screen owns the view). */
  dead: boolean;
  /** A big panel (Reliquary, Grimoire, Codex...) is open. */
  panel: boolean;
  /** The area the hero stands in ('' = unknown, which never blocks a tip). */
  area: string;
  /** The hero stands in a sanctuary (Acre, Chapterhouse, Wing): no fight is on, so fight-time tips about the dead have no use yet. */
  safe: boolean;
}

export const NOT_BUSY: Busy = { combat: false, hurt: false, talking: false, banner: false, dead: false, panel: false, area: '', safe: false };

export interface QueuedTip {
  id: string;
  kind: TipKind;
  /** Higher first among tips of the same kind. */
  priority: number;
  queuedAt: number;
  seq: number;
}

export interface CadenceState {
  now: number;
  /** When the last card closed (ms, same clock as `now`); -Infinity if none has. */
  lastClosedAt: number;
  /** When a card of each subject group was last shown. */
  groupShownAt: Record<string, number>;
  busy: Busy;
}

/** Quiet time after one card closes before the next may open, by the kind of the next one. */
export const GAP_MS: Record<TipKind, number> = { urgent: 0, danger: 12_000, asked: 3000, calm: 20_000 };
/** Tips on one subject keep at least this long between them (calm and danger alike; "asked" tips ignore it). */
export const GROUP_GAP_MS = 150_000;
/** The first-sight cards for individual enemies, and the fight lessons, each come at most this often: a new hall shows several kinds at once, and one card at a time is plenty. */
export const ENEMY_GAP_MS = 40_000;
const GROUP_GAPS: Record<string, number> = { enemy: ENEMY_GAP_MS, lesson: ENEMY_GAP_MS };
/** A queued tip older than this is dropped (and may fire again the next time its trigger happens). */
export const MAX_AGE_MS: Record<TipKind, number> = { urgent: 15_000, danger: 20_000, asked: 120_000, calm: 360_000 };
/** The core fight lessons stay worth showing for a couple of minutes, unlike a telegraph tip about one enemy that has moved on. */
export const LESSON_AGE_MS = 120_000;
/** The queue never holds more calm tips than this; the oldest are dropped first. */
export const MAX_CALM_QUEUED = 4;
/** A calm tip that has waited this long may show in a lull of a fight (nobody hitting the hero), so a player who never stops fighting still gets it. */
export const STARVED_MS = 90_000;
/** How long a calm card must have been up before a fight or a conversation may send it back to the queue. */
export const YIELD_AFTER_MS = 6000;
/** How long a card must have been up before a more urgent one may take its place. */
export const PREEMPT_AFTER_MS = 5000;

/** Tips about a place show only while the hero is there (they wait in the queue until they return, or go stale). */
export const HERE: Record<string, string[]> = {
  welcome: ['acre'], acre: ['acre'], laborers_working: ['acre'], wing: ['alchemist_wing'],
  cloister: ['cloister'], pyre: ['pyre'], fen: ['fen'], warren: ['warren'], coliseum: ['coliseum'],
  boss_gravedigger: ['graves'], boss_abbess: ['ossuary'], boss_congregation: ['nave'], boss_saint: ['cloister'], boss_regent: ['pyre'], boss_mire: ['fen'],
  boons: ['chapterhouse'],
  // The stair is in the Warren; the floors' own cards are shown by what the player just did.
  depths: ['warren'],
};

const KIND_RANK: Record<TipKind, number> = { urgent: 0, danger: 1, asked: 2, calm: 3 };

// ---------------------------------------------------------------------------
// Classification. Anything not listed is a calm, ungrouped tip of priority 50.
// ---------------------------------------------------------------------------

const URGENT = ['hurt'];

/** Useful in the middle of a fight: shown even while enemies are on you. */
const DANGER = [
  'move', 'exhume', 'litany', 'burst', 'souls', 'deacon', 'elite', 'surge', 'sanctify',
  'procession', 'censer', 'wraith', 'swarm', 'golem', 'gargoyle', 'moth', 'bats', 'seraph', 'ghoul', 'acolyte', 'templar',
  'plague_doctor', 'flagellant', 'cinder_husk', 'pyre_priest', 'cinderhound', 'slag_brute',
  'bog_hag', 'mire_leech', 'fen_wisp', 'drowned_sexton',
];

/** The player just did the thing the tip is about (opened a panel, placed a rite, hit the wall). */
const ASKED = [
  'rite_skull', 'rite_step', 'rite_frost', 'rite_mantle', 'rite_siphon', 'rite_prison', 'rite_hands', 'rite_storm',
  'rite_fan', 'rite_lance', 'rite_offering', 'rite_cleave', 'rite_veil', 'rite_rally', 'rite_seed',
  'gearEquip', 'statSheet', 'setBonus', 'legendary', 'necroWeapon', 'toolBelt', 'vault', 'salvage', 'bag_full', 'essence',
  'minimap', 'auto_combat', 'change_class', 'station', 'gather', 'wing',
  'depths_floor', 'depths_affix', 'depths_chest', 'depths_solo',
];

/** Fight-time tips that teach the kit itself (not one enemy's telegraph): they wait their turn instead of going stale. */
const LESSONS = ['move', 'exhume', 'litany', 'burst', 'souls'];

/** Subjects that must not pile up. */
const GROUPS: Record<string, string[]> = {
  lesson: LESSONS,
  enemy: ['deacon', 'elite', 'surge', 'sanctify', 'procession', 'censer', 'wraith', 'swarm', 'golem', 'gargoyle', 'moth', 'bats', 'seraph', 'ghoul', 'acolyte', 'templar',
    'plague_doctor', 'flagellant', 'cinder_husk', 'pyre_priest', 'cinderhound', 'slag_brute', 'bog_hag', 'mire_leech', 'fen_wisp', 'drowned_sexton'],
  gear: ['relic', 'armor', 'legendary', 'affix', 'tool', 'legion', 'rune'],
  bag: ['bag_filling'],
  brew: ['reagent', 'brew', 'meal'],
  acre: ['acre', 'rich_node', 'skill_up', 'laborers_working'],
  road: ['gate', 'wave', 'codex'],
};

/** Calm tips in the order a new player is likelier to need them (default 50). */
const PRIORITY: Record<string, number> = {
  welcome: 100, acre: 80, thrall: 70, relic: 66, wave: 60, gate: 58, people: 45, omen: 30, chain: 35, codex: 30,
  // Fight-time lessons come before the first-sight telegraphs of individual enemies.
  move: 90, exhume: 85, litany: 70, burst: 65, souls: 60,
};

export function kindOf(id: string): TipKind {
  if (URGENT.includes(id)) return 'urgent';
  if (DANGER.includes(id)) return 'danger';
  if (ASKED.includes(id)) return 'asked';
  return 'calm';
}

export function groupOf(id: string): string | null {
  for (const [g, ids] of Object.entries(GROUPS)) if (ids.includes(id)) return g;
  return null;
}

export const priorityOf = (id: string) => PRIORITY[id] ?? 50;

export function makeEntry(id: string, now: number, seq: number, bump = false): QueuedTip {
  return { id, kind: kindOf(id), priority: priorityOf(id) + (bump ? 100 : 0), queuedAt: now, seq };
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

/** May this queued tip be drawn right now (assuming no card is up)? */
export function canShow(t: QueuedTip, s: CadenceState): boolean {
  const b = s.busy;
  if (t.kind === 'urgent') return !b.dead;
  if (b.dead || b.talking) return false;
  if (t.kind === 'danger' && (b.safe || b.panel)) return false;
  const here = HERE[t.id];
  if (here && b.area && !here.includes(b.area)) return false;
  if (s.now - s.lastClosedAt < GAP_MS[t.kind]) return false;
  if (t.kind === 'calm') {
    if (b.banner || b.panel || b.hurt) return false;
    if (b.combat && s.now - t.queuedAt < STARVED_MS) return false;
  }
  if (t.kind !== 'asked') {
    const g = groupOf(t.id);
    if (g && s.now - (s.groupShownAt[g] ?? -Infinity) < (GROUP_GAPS[g] ?? GROUP_GAP_MS)) return false;
  }
  return true;
}

/** The best tip that may be shown now: by kind (urgent, danger, asked, calm), then priority, then arrival order. */
export function pickNext(queue: QueuedTip[], s: CadenceState): QueuedTip | null {
  let best: QueuedTip | null = null;
  for (const t of queue) {
    if (!canShow(t, s)) continue;
    if (!best || KIND_RANK[t.kind] < KIND_RANK[best.kind]
      || (t.kind === best.kind && (t.priority > best.priority || (t.priority === best.priority && t.seq < best.seq)))) best = t;
  }
  return best;
}

/** Drop what has gone stale, and cap the calm backlog (oldest first). */
export function maxAge(t: QueuedTip): number {
  return t.kind === 'danger' && LESSONS.includes(t.id) ? LESSON_AGE_MS : MAX_AGE_MS[t.kind];
}

export function prune(queue: QueuedTip[], now: number): QueuedTip[] {
  const live = queue.filter((t) => now - t.queuedAt <= maxAge(t));
  const calm = live.filter((t) => t.kind === 'calm');
  if (calm.length <= MAX_CALM_QUEUED) return live;
  const drop = new Set(calm.sort((a, b) => a.priority - b.priority || b.queuedAt - a.queuedAt).slice(0, calm.length - MAX_CALM_QUEUED));
  return live.filter((t) => !drop.has(t));
}

export interface ShownCard {
  id: string;
  kind: TipKind;
  shownAt: number;
}

/** Should a waiting tip take the place of the card on screen? Hurt? may take any other card, a fight lesson only a calm one; never a card just started. */
export function shouldPreempt(card: ShownCard, waiting: QueuedTip | null, s: CadenceState): boolean {
  if (!waiting || !canShow({ ...waiting }, { ...s, lastClosedAt: -Infinity })) return false;
  if (s.now - card.shownAt < PREEMPT_AFTER_MS) return false;
  // Only urgent news takes a card the player asked for; a fight-time lesson replaces a calm card only.
  if (waiting.kind === 'urgent') return card.kind !== 'urgent';
  return waiting.kind === 'danger' && card.kind === 'calm';
}

/** A calm card that has been up a while steps aside for a fight or a conversation, and any card but Hurt? steps aside for the death screen (it comes back afterwards). */
export function shouldYield(card: ShownCard, s: CadenceState): boolean {
  if (card.kind === 'urgent') return false;
  // The death screen owns the view: whatever was up comes back after the hero rises again.
  if (s.busy.dead) return s.now - card.shownAt >= 1000;
  // A card about a place leaves when the hero does (it returns when they do).
  const here = HERE[card.id];
  if (here && s.busy.area && !here.includes(s.busy.area)) return s.now - card.shownAt >= 2000;
  // A card the player asked for belongs with the panel they opened and stays; the others make way for a panel, a conversation or (calm ones) a fight.
  if (card.kind === 'asked' || s.now - card.shownAt < YIELD_AFTER_MS) return false;
  if (s.busy.panel || s.busy.talking) return true;
  return card.kind === 'calm' && s.busy.combat;
}

/** How long a card stays up: calm and asked cards at least 25 s; fight-time cards a shorter read. */
export function showMs(kind: TipKind, words: number): number {
  return kind === 'danger' || kind === 'urgent' ? Math.max(14_000, 4000 + words * 450) : Math.min(40_000, Math.max(25_000, 5000 + words * 400));
}
