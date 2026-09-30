import { describe, expect, it } from 'vitest';
import type { GatherReply } from '../../net/api';
import { GatherSession, crossedMilestones, durationText, MIN_REPORT_SECONDS, type Bests, type ItemInfo } from '../gatherReport';

const ITEMS: Record<string, ItemInfo> = {
  log_oak: { name: 'Oak Log', rarity: 'common', sell: 1 },
  log_yew: { name: 'Yew Log', rarity: 'uncommon', sell: 10 },
  gem_bone_opal: { name: 'Bone Opal', rarity: 'rare', sell: 45 },
};

const reply = (skill: string, items: [string, number][], xp = 10, gold = 0): GatherReply => ({
  node: 'n', skill, accepted: 1, successes: 1, xp, gold, items: items.map(([itemId, qty]) => ({ itemId, qty })), rejected: [], leveledUp: false, skills: [],
});

function session(levels: Partial<Record<string, number>> = {}, life: Partial<Record<string, number>> = {}) {
  const lv = { woodcutting: 10, mining: 5, ...levels } as Record<string, number>;
  const s = new GatherSession(0, (id) => ITEMS[id], (k) => lv[k] ?? 1, (k) => life[k] ?? 0);
  return { s, lv };
}

describe('crossedMilestones', () => {
  it('lists the round numbers passed, not ones already behind you', () => {
    expect(crossedMilestones(90, 120)).toEqual([100]);
    expect(crossedMilestones(0, 1200)).toEqual([100, 250, 500, 1000]);
    expect(crossedMilestones(100, 240)).toEqual([]);
  });
});

describe('GatherSession', () => {
  it('ignores sessions that are too short or brought nothing back', () => {
    const { s } = session();
    expect(s.finish(60_000, 'paused')).toBeNull();
    s.record(reply('woodcutting', [['log_oak', 3]]));
    expect(s.finish((MIN_REPORT_SECONDS - 1) * 1000, 'paused')).toBeNull();
  });

  it('totals items and value, and sorts the rarest find first', () => {
    const { s } = session();
    s.record(reply('woodcutting', [['log_oak', 40]], 100));
    s.record(reply('woodcutting', [['log_yew', 5]], 60));
    s.record(reply('mining', [['gem_bone_opal', 1]], 30, 12));
    const out = s.finish(600_000, 'bagFull')!;
    expect(out.report.totalItems).toBe(46);
    expect(out.report.goldValue).toBe(40 + 50 + 45);
    expect(out.report.gold).toBe(12);
    expect(out.report.items[0].itemId).toBe('gem_bone_opal');
    expect(out.report.best?.name).toBe('Bone Opal');
    expect(out.report.seconds).toBe(600);
    expect(out.report.skills.map((k) => [k.skill, k.xp, k.items])).toEqual([['woodcutting', 160, 45], ['mining', 30, 1]]);
  });

  it('reports the level the session started at, even though replies arrive after the level-up', () => {
    const { s, lv } = session({ woodcutting: 10 });
    lv.woodcutting = 12; // Skills.adopt() has already run when the reply is recorded
    s.record(reply('woodcutting', [['log_oak', 10]], 400));
    const out = s.finish(300_000, 'paused')!;
    expect(out.report.skills[0]).toMatchObject({ fromLevel: 10, toLevel: 12 });
    expect(out.report.milestones).toContain('Woodcutting level 12');
  });

  it('flags lifetime milestones and only calls a personal best when there is an older one to beat', () => {
    const { s } = session({}, { woodcutting: 950 });
    s.record(reply('woodcutting', [['log_oak', 80]], 200));
    const first = s.finish(1_800_000, 'paused', {})!;
    expect(first.report.milestones).toContain('1,000 Woodcutting finds');
    expect(first.report.records).toEqual([]);
    expect(first.bests.woodcutting?.items).toBe(80);

    const { s: s2 } = session();
    s2.record(reply('woodcutting', [['log_oak', 120]], 200));
    const bests: Bests = first.bests;
    const second = s2.finish(1_800_000, 'paused', bests)!;
    expect(second.report.records[0]).toContain('Most Woodcutting finds');
    expect(second.bests.woodcutting?.items).toBe(120);
  });
});

describe('durationText', () => {
  it('reads naturally', () => {
    expect(durationText(45)).toBe('45s');
    expect(durationText(125)).toBe('2m 5s');
    expect(durationText(7500)).toBe('2h 5m');
  });
});
