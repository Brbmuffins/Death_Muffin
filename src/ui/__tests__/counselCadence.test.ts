import { describe, expect, it } from 'vitest';
import { TIPS } from '../Onboarding';
import {
  ENEMY_GAP_MS, GAP_MS, GROUP_GAP_MS, LESSON_AGE_MS, MAX_AGE_MS, MAX_CALM_QUEUED, NOT_BUSY, PREEMPT_AFTER_MS, STARVED_MS, YIELD_AFTER_MS,
  canShow, groupOf, kindOf, makeEntry, pickNext, priorityOf, prune, shouldPreempt, shouldYield, showMs,
  type CadenceState, type QueuedTip,
} from '../counselCadence';

const st = (over: Partial<Omit<CadenceState, 'busy'>> & { busy?: Partial<CadenceState['busy']> } = {}): CadenceState => ({
  now: 100_000, lastClosedAt: -Infinity, groupShownAt: {}, ...over, busy: { ...NOT_BUSY, ...(over.busy ?? {}) },
});
const q = (id: string, at = 100_000, seq = 1, bump = false): QueuedTip => makeEntry(id, at, seq, bump);

describe('counsel cadence: classification', () => {
  it('every tip id has a kind, and the classified ids all exist', () => {
    for (const id of Object.keys(TIPS)) expect(['urgent', 'danger', 'asked', 'calm']).toContain(kindOf(id));
    for (const id of ['hurt', 'exhume', 'wraith', 'gearEquip', 'grimoire', 'vault', 'welcome', 'acre', 'people', 'omen']) expect(TIPS, id).toHaveProperty(id);
  });

  it('hurt is urgent, telegraphs are danger, a panel the player opened is asked, background lore is calm', () => {
    expect(kindOf('hurt')).toBe('urgent');
    expect(kindOf('wraith')).toBe('danger');
    expect(kindOf('exhume')).toBe('danger');
    expect(kindOf('vault')).toBe('asked');
    expect(kindOf('rite_skull')).toBe('asked');
    expect(kindOf('welcome')).toBe('calm');
    expect(kindOf('omen')).toBe('calm');
    expect(kindOf('cloister')).toBe('calm');
  });

  it('gear tips share a subject so one drop cannot queue three cards', () => {
    expect(groupOf('relic')).toBe('gear');
    expect(groupOf('armor')).toBe('gear');
    expect(groupOf('affix')).toBe('gear');
    expect(groupOf('wraith')).toBe('enemy');
    expect(groupOf('exhume')).toBe('lesson');
    expect(groupOf('hurt')).toBeNull();
  });
});

describe('counsel cadence: when a tip may show', () => {
  it('calm tips wait out a fight, a conversation, a banner, an open panel and the death screen', () => {
    for (const busy of [{ combat: true }, { hurt: true }, { talking: true }, { banner: true }, { panel: true }, { dead: true }]) {
      expect(canShow(q('thrall'), st({ busy })), JSON.stringify(busy)).toBe(false);
    }
    expect(canShow(q('thrall'), st())).toBe(true);
  });

  it('a calm tip starved by a long fight shows in a lull, but never while the hero is being hit', () => {
    const queuedAt = 100_000;
    const waited = (ms: number) => st({ now: queuedAt + ms, busy: { combat: true } });
    expect(canShow(q('thrall', queuedAt), waited(STARVED_MS - 1))).toBe(false);
    expect(canShow(q('thrall', queuedAt), waited(STARVED_MS))).toBe(true);
    expect(canShow(q('thrall', queuedAt), st({ now: queuedAt + STARVED_MS, busy: { combat: true, hurt: true } }))).toBe(false);
  });

  it('danger tips may show in a fight but not while talking or dead', () => {
    expect(canShow(q('wraith'), st({ busy: { combat: true } }))).toBe(true);
    expect(canShow(q('wraith'), st({ busy: { talking: true } }))).toBe(false);
    expect(canShow(q('wraith'), st({ busy: { dead: true } }))).toBe(false);
  });

  it('danger tips also wait while a panel is open', () => {
    expect(canShow(q('wraith'), st({ busy: { panel: true } }))).toBe(false);
    expect(canShow(q('hurt'), st({ busy: { panel: true } }))).toBe(true);
    expect(canShow(q('vault'), st({ busy: { panel: true } }))).toBe(true);
  });

  it('danger tips about the dead wait until the hero leaves a sanctuary', () => {
    expect(canShow(q('wraith'), st({ busy: { safe: true } }))).toBe(false);
    expect(canShow(q('wraith'), st({ busy: { safe: false } }))).toBe(true);
    expect(canShow(q('hurt'), st({ busy: { safe: true } }))).toBe(true);
  });

  it('place tips wait for their place', () => {
    expect(canShow(q('acre'), st({ busy: { area: 'chapterhouse' } }))).toBe(false);
    expect(canShow(q('acre'), st({ busy: { area: 'acre' } }))).toBe(true);
    expect(canShow(q('acre'), st({ busy: { area: '' } }))).toBe(true);
    expect(canShow(q('wing'), st({ busy: { area: 'acre' } }))).toBe(false);
    expect(canShow(q('welcome'), st({ busy: { area: 'graves' } }))).toBe(false);
    expect(canShow(q('welcome'), st({ busy: { area: 'acre' } }))).toBe(true);
    expect(canShow(q('thrall'), st({ busy: { area: 'acre' } }))).toBe(true);
  });

  it('urgent hurt shows even mid-fight and straight after a card, but not on the death screen', () => {
    expect(canShow(q('hurt'), st({ lastClosedAt: 99_900, busy: { combat: true } }))).toBe(true);
    expect(canShow(q('hurt'), st({ busy: { dead: true } }))).toBe(false);
  });

  it('keeps a gap after the last card, longer for calm counsel', () => {
    const now = 100_000;
    expect(canShow(q('thrall'), st({ now, lastClosedAt: now - (GAP_MS.calm - 1) }))).toBe(false);
    expect(canShow(q('thrall'), st({ now, lastClosedAt: now - GAP_MS.calm }))).toBe(true);
    expect(canShow(q('wraith'), st({ now, lastClosedAt: now - 1000 }))).toBe(false);
    expect(canShow(q('wraith'), st({ now, lastClosedAt: now - GAP_MS.danger }))).toBe(true);
  });

  it('shows the first-sight card of one enemy kind at a time, 40 s apart, even in a new hall', () => {
    const now = 500_000;
    const s = st({ now, groupShownAt: { enemy: now - (ENEMY_GAP_MS - 1) } });
    expect(canShow(q('golem', now), s)).toBe(false);
    expect(canShow(q('wraith', now), s)).toBe(false);
    expect(canShow(q('exhume', now), s)).toBe(true);
    expect(canShow(q('hurt', now), s)).toBe(true);
    expect(canShow(q('golem', now), st({ now, groupShownAt: { enemy: now - ENEMY_GAP_MS } }))).toBe(true);
  });

  it('teaches one fight lesson at a time: fight, then raising the dead, then the rest, 40 s apart', () => {
    const now = 500_000;
    const s = st({ now, groupShownAt: { lesson: now - 10_000 } });
    expect(canShow(q('exhume', now), s)).toBe(false);
    expect(canShow(q('litany', now), s)).toBe(false);
    expect(canShow(q('wraith', now), s)).toBe(true); // an enemy card is another subject
    expect(canShow(q('hurt', now), s)).toBe(true);
    expect(canShow(q('exhume', now), st({ now, groupShownAt: { lesson: now - ENEMY_GAP_MS } }))).toBe(true);
  });

  it('keeps tips of one subject far apart, except one the player asked for', () => {
    const now = 500_000;
    const s = st({ now, groupShownAt: { gear: now - (GROUP_GAP_MS - 1) } });
    expect(canShow(q('armor', now), s)).toBe(false);
    expect(canShow(q('affix', now), s)).toBe(false);
    expect(canShow(q('thrall', now), s)).toBe(true);
    expect(canShow(q('gearEquip', now), s)).toBe(true);
    expect(canShow(q('armor', now), st({ now, groupShownAt: { gear: now - GROUP_GAP_MS } }))).toBe(true);
  });
});

describe('counsel cadence: which tip is next', () => {
  it('danger before asked before calm, then priority, then arrival order', () => {
    const queue = [q('thrall', 0, 1), q('vault', 0, 2), q('wraith', 0, 3), q('welcome', 0, 4), q('relic', 0, 5)];
    const s = st({ now: 10_000 });
    expect(pickNext(queue, s)?.id).toBe('wraith');
    expect(pickNext(queue.filter((t) => t.id !== 'wraith'), s)?.id).toBe('vault');
    expect(pickNext(queue.filter((t) => !['wraith', 'vault'].includes(t.id)), s)?.id).toBe('welcome');
    expect(pickNext([q('thrall', 0, 9), q('cloister', 0, 8)], s)?.id).toBe('thrall');
    expect(pickNext([q('cloister', 0, 9), q('pyre', 0, 8)], s)?.id).toBe('pyre');
  });

  it('a priority bump (the old "front of the queue" flag) wins within its kind', () => {
    expect(pickNext([q('welcome', 0, 1), q('thrall', 0, 2, true)], st({ now: 10_000 }))?.id).toBe('thrall');
  });

  it('returns nothing when the moment is wrong for everything queued', () => {
    expect(pickNext([q('thrall'), q('welcome')], st({ busy: { combat: true } }))).toBeNull();
  });

  it('introduces the Acre card before background lore on a first minute', () => {
    expect(priorityOf('welcome')).toBeGreaterThan(priorityOf('acre'));
    expect(priorityOf('acre')).toBeGreaterThan(priorityOf('people'));
    expect(priorityOf('people')).toBeGreaterThan(priorityOf('omen'));
  });
});

describe('counsel cadence: stale tips', () => {
  it('drops a danger tip that waited too long and keeps a fresh calm one', () => {
    const now = 1_000_000;
    const out = prune([q('wraith', now - MAX_AGE_MS.danger - 1), q('thrall', now - MAX_AGE_MS.danger - 1)], now);
    expect(out.map((t) => t.id)).toEqual(['thrall']);
  });

  it('keeps the core fight lessons (move, exhume) queued behind a Hurt? card, but not an enemy telegraph', () => {
    const now = 1_000_000;
    const at = now - MAX_AGE_MS.danger - 5000;
    const out = prune([q('exhume', at), q('move', at), q('wraith', at)], now);
    expect(out.map((t) => t.id).sort()).toEqual(['exhume', 'move']);
    expect(prune([q('exhume', now - LESSON_AGE_MS - 1)], now)).toEqual([]);
  });

  it('the first fight teaches in order: how to fight, then raising the dead, then the enemy telegraphs', () => {
    const queue = [q('wraith', 0, 1), q('exhume', 0, 2), q('move', 0, 3), q('censer', 0, 4)];
    const s = st({ now: 10_000 });
    expect(pickNext(queue, s)?.id).toBe('move');
    expect(pickNext(queue.filter((t) => t.id !== 'move'), s)?.id).toBe('exhume');
    expect(pickNext(queue.filter((t) => t.id === 'wraith' || t.id === 'censer'), s)?.id).toBe('wraith');
  });

  it('caps the calm backlog, dropping the least important and oldest', () => {
    const now = 1_000;
    const queue = ['welcome', 'acre', 'thrall', 'cloister', 'pyre', 'fen', 'warren'].map((id, i) => q(id, now, i));
    const out = prune(queue, now);
    expect(out.filter((t) => t.kind === 'calm')).toHaveLength(MAX_CALM_QUEUED);
    expect(out.map((t) => t.id)).toContain('welcome');
    expect(out.map((t) => t.id)).toContain('acre');
  });
});

describe('counsel cadence: the card on screen', () => {
  const card = (kind: 'calm' | 'asked' | 'danger', shownAt: number) => ({ id: 'x', kind, shownAt });

  it('a card about a place leaves with the hero', () => {
    const now = 300_000;
    expect(shouldYield({ id: 'welcome', kind: 'calm', shownAt: now - 5000 }, st({ now, busy: { area: 'chapterhouse' } }))).toBe(true);
    expect(shouldYield({ id: 'welcome', kind: 'calm', shownAt: now - 500 }, st({ now, busy: { area: 'chapterhouse' } }))).toBe(false);
    expect(shouldYield({ id: 'welcome', kind: 'calm', shownAt: now - 5000 }, st({ now, busy: { area: 'acre' } }))).toBe(false);
    expect(shouldYield({ id: 'wing', kind: 'asked', shownAt: now - 5000 }, st({ now, busy: { area: 'chapterhouse' } }))).toBe(true);
  });

  it('a calm card steps aside for a fight, but not in its first seconds', () => {
    const now = 200_000;
    expect(shouldYield(card('calm', now - YIELD_AFTER_MS + 1), st({ now, busy: { combat: true } }))).toBe(false);
    expect(shouldYield(card('calm', now - YIELD_AFTER_MS), st({ now, busy: { combat: true } }))).toBe(true);
    expect(shouldYield(card('calm', now - 20_000), st({ now, busy: { talking: true } }))).toBe(true);
    expect(shouldYield(card('calm', now - 20_000), st({ now }))).toBe(false);
    expect(shouldYield(card('asked', now - 20_000), st({ now, busy: { combat: true } }))).toBe(false);
    expect(shouldYield(card('asked', now - 20_000), st({ now, busy: { panel: true } }))).toBe(false);
    expect(shouldYield(card('danger', now - 20_000), st({ now, busy: { panel: true } }))).toBe(true);
    expect(shouldYield(card('danger', now - 20_000), st({ now, busy: { combat: true } }))).toBe(false);
    expect(shouldYield(card('calm', now - 20_000), st({ now, busy: { panel: true } }))).toBe(true);
    expect(shouldYield(card('asked', now - 20_000), st({ now, busy: { dead: true } }))).toBe(true);
    expect(shouldYield(card('danger', now - 20_000), st({ now, busy: { dead: true } }))).toBe(true);
    expect(shouldYield({ id: 'hurt', kind: 'urgent', shownAt: now - 20_000 }, st({ now, busy: { dead: true } }))).toBe(false);
  });

  it('only a more urgent tip replaces a card, and only after it has had a few seconds', () => {
    const now = 200_000;
    const hurt = q('hurt', now);
    expect(shouldPreempt(card('calm', now - PREEMPT_AFTER_MS), hurt, st({ now, busy: { combat: true } }))).toBe(true);
    expect(shouldPreempt(card('calm', now - 1000), hurt, st({ now }))).toBe(false);
    expect(shouldPreempt(card('calm', now - 9000), q('wraith', now), st({ now, busy: { combat: true } }))).toBe(true);
    expect(shouldPreempt(card('asked', now - 9000), q('wraith', now), st({ now, busy: { combat: true } }))).toBe(false);
    expect(shouldPreempt(card('asked', now - 9000), q('hurt', now), st({ now, busy: { combat: true } }))).toBe(true);
    expect(shouldPreempt(card('danger', now - 9000), q('wraith', now), st({ now }))).toBe(false);
    expect(shouldPreempt(card('calm', now - 9000), q('vault', now), st({ now }))).toBe(false);
    expect(shouldPreempt(card('calm', now - 9000), null, st({ now }))).toBe(false);
  });

  it('fight-time cards are a shorter read than calm ones', () => {
    expect(showMs('danger', 20)).toBeLessThan(showMs('calm', 20));
    expect(showMs('calm', 5)).toBe(25_000);
    expect(showMs('calm', 200)).toBe(40_000);
    expect(showMs('danger', 5)).toBe(14_000);
  });
});
