import { describe, expect, it } from 'vitest';
import { CueQueue, HudReveal, dialReady, isVeteran, veteranReveals, type VeteranFacts } from '../progressiveHud';

const mem = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
};
const none: VeteranFacts = { level: 1, gold: 0, damageTier: 0, waveOwned: 0, shards: 0, knowsAcre: false, swapReady: false, hasGear: false, hasHunted: false };

describe('HudReveal', () => {
  it('reveals once, flags new, and remembers across sessions', () => {
    const s = mem();
    const a = new HudReveal(7, s);
    expect(a.fresh).toBe(true);
    expect(a.has('hud.upgrades')).toBe(false);
    expect(a.reveal('hud.upgrades')).toBe(true);
    expect(a.reveal('hud.upgrades')).toBe(false);
    expect(a.isNew('hud.upgrades')).toBe(true);
    const b = new HudReveal(7, s);
    expect(b.fresh).toBe(false);
    expect(b.has('hud.upgrades')).toBe(true);
    expect(b.isNew('hud.upgrades')).toBe(true);
    expect(b.clear('hud.upgrades')).toBe(true);
    expect(b.clear('hud.upgrades')).toBe(false);
    expect(new HudReveal(7, s).isNew('hud.upgrades')).toBe(false);
  });
  it('silent reveal (veterans) carries no cue, and a used cue never returns', () => {
    const r = new HudReveal(1, mem());
    r.reveal('hud.dial', false);
    expect(r.has('hud.dial')).toBe(true);
    expect(r.isNew('hud.dial')).toBe(false);
    expect(r.flag('tab.acre.garden')).toBe(true);
    r.clear('tab.acre.garden');
    expect(r.flag('tab.acre.garden')).toBe(false);
  });
  it('is per character and survives broken storage', () => {
    const s = mem();
    new HudReveal(1, s).reveal('hud.shards');
    expect(new HudReveal(2, s).has('hud.shards')).toBe(false);
    const broken = { getItem: () => { throw new Error('x'); }, setItem: () => { throw new Error('x'); } };
    const r = new HudReveal(1, broken);
    expect(r.reveal('hud.shards')).toBe(true);
    expect(r.has('hud.shards')).toBe(true);
    expect(new HudReveal(1, null).fresh).toBe(true);
    const junk = mem();
    junk.setItem('dm_hud_reveal_v1_3', '{not json');
    expect(new HudReveal(3, junk).has('hud.shards')).toBe(false);
  });
});

describe('veteranReveals', () => {
  it('a fresh level 1 gets nothing', () => expect(veteranReveals(none)).toEqual([]));
  it('keeps what a veteran already used', () => {
    const v = veteranReveals({ ...none, level: 30, waveOwned: 3, shards: 4, swapReady: true, hasGear: true, knowsAcre: true, hasHunted: true });
    expect(v).toEqual(['hud.upgrades', 'hud.dial', 'hud.shards', 'hud.spells', 'menu.spells', 'menu.atlas', 'menu.skills', 'hud.omen']);
  });
  it('level 2 or any gold shows the plate; the dial needs an owned tier', () => {
    expect(veteranReveals({ ...none, level: 2 })).toEqual(['hud.upgrades']);
    expect(dialReady(0)).toBe(false);
    expect(dialReady(1)).toBe(true);
    expect(isVeteran(2)).toBe(false);
    expect(isVeteran(3)).toBe(true);
  });
});

describe('CueQueue', () => {
  it('shows one at a time, queued in order, and skips duplicates and dropped cues', () => {
    const shown: string[] = [];
    const timers: (() => void)[] = [];
    const q = new CueQueue((t) => shown.push(t), (fn) => void timers.push(fn), 5000);
    q.push('a', 'A');
    q.push('b', 'B');
    q.push('b', 'B again');
    q.push('c', 'C');
    expect(shown).toEqual(['A']);
    q.drop('c');
    timers.shift()!();
    expect(shown).toEqual(['A', 'B']);
    timers.shift()!();
    expect(shown).toEqual(['A', 'B']);
    expect(q.pending).toBe(0);
  });
  it('waits while blocked', () => {
    const shown: string[] = [];
    const timers: (() => void)[] = [];
    let blocked = true;
    const q = new CueQueue((t) => shown.push(t), (fn) => void timers.push(fn), 5000, () => blocked);
    q.push('a', 'A');
    expect(shown).toEqual([]);
    blocked = false;
    timers.shift()!();
    expect(shown).toEqual(['A']);
  });
});
