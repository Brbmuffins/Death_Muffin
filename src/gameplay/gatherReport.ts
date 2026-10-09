import type { GatherReply } from '../net/api';
import type { Rarity } from '../net/types';
import { SKILLS, type SkillId } from '../../server/rules/gameplay/gatheringRules';

/**
 * The "while you were away" report. An AFK session collects what every gather reply returned (items, XP, gold, levels) and, when
 * work stops, turns it into something worth reading: what you brought back, what it is worth, what you learned, and any milestone
 * or personal best you crossed. Pure logic (no DOM, no network) so it is easy to test.
 */

export interface ReportItem {
  itemId: string;
  name: string;
  rarity: Rarity;
  qty: number;
  /** Total sell value of this stack. */
  value: number;
}

export interface ReportSkill {
  skill: SkillId;
  name: string;
  xp: number;
  fromLevel: number;
  toLevel: number;
  /** Items gathered with this skill during the session. */
  items: number;
}

export interface GatherReport {
  seconds: number;
  /** Why work stopped (the GatherStop reason, or 'paused'). */
  reason: string;
  items: ReportItem[];
  totalItems: number;
  goldValue: number;
  gold: number;
  skills: ReportSkill[];
  /** The rarest thing brought back. */
  best: ReportItem | null;
  milestones: string[];
  records: string[];
}

export interface ItemInfo {
  name: string;
  rarity: Rarity;
  sell: number;
}

const RARITY_RANK: Record<Rarity, number> = { common: 0, uncommon: 1, rare: 2, epic: 3, legendary: 4 };

/** Lifetime finds worth a line of their own. */
export const MILESTONES = [100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000];

/** Milestones passed while going from `before` to `after` lifetime finds. */
export function crossedMilestones(before: number, after: number): number[] {
  return MILESTONES.filter((m) => before < m && after >= m);
}

/** Longest session worth a report; anything shorter (a click or two) is not an "away". */
export const MIN_REPORT_SECONDS = 20;

export type Bests = Partial<Record<SkillId, { items: number; xpPerHour: number }>>;

const bestsKey = (characterId: number) => `dm_gather_best_v1:${characterId}`;

export function loadBests(storage: Pick<Storage, 'getItem'> | null, characterId: number): Bests {
  try {
    return JSON.parse(storage?.getItem(bestsKey(characterId)) ?? '{}') as Bests;
  } catch {
    return {};
  }
}

export function saveBests(storage: Pick<Storage, 'setItem'> | null, characterId: number, bests: Bests) {
  try {
    storage?.setItem(bestsKey(characterId), JSON.stringify(bests));
  } catch {
    /* private mode or full: the record simply won't persist */
  }
}

export class GatherSession {
  private items = new Map<string, number>();
  private xp = new Map<SkillId, number>();
  private counts = new Map<SkillId, number>();
  private startLevels = new Map<SkillId, number>();
  private startLife = new Map<SkillId, number>();
  private gold = 0;

  constructor(
    readonly startedAt: number,
    private info: (itemId: string) => ItemInfo,
    private levelOf: (skill: SkillId) => number,
    /** Lifetime finds for a skill (the Chronicle's gathered.<skill>). */
    private lifeOf: (skill: SkillId) => number,
  ) {
    // Snapshot now: Skills.adopt() runs before each reply reaches record(), so "the level at the first reply" is already the new level.
    for (const skill of Object.keys(SKILLS) as SkillId[]) {
      this.startLevels.set(skill, levelOf(skill));
      this.startLife.set(skill, lifeOf(skill));
    }
  }

  /** Fold one /api/gather reply in. The first reply for a skill fixes its starting level. */
  record(reply: GatherReply) {
    const skill = reply.skill as SkillId;
    if (!SKILLS[skill]) return;
    let qty = 0;
    for (const g of reply.items) {
      this.items.set(g.itemId, (this.items.get(g.itemId) ?? 0) + g.qty);
      qty += g.qty;
    }
    this.xp.set(skill, (this.xp.get(skill) ?? 0) + reply.xp);
    this.counts.set(skill, (this.counts.get(skill) ?? 0) + qty);
    this.gold += reply.gold;
  }

  get hasYield() {
    return this.items.size > 0 || this.gold > 0;
  }

  /** Build the report, or null when the session was too short or brought nothing back. */
  finish(nowMs: number, reason: string, bests: Bests = {}): { report: GatherReport; bests: Bests } | null {
    const seconds = Math.max(0, Math.round((nowMs - this.startedAt) / 1000));
    if (seconds < MIN_REPORT_SECONDS || !this.hasYield) return null;

    const items: ReportItem[] = [...this.items].map(([itemId, qty]) => {
      const m = this.info(itemId);
      return { itemId, name: m.name, rarity: m.rarity, qty, value: m.sell * qty };
    });
    items.sort((a, b) => RARITY_RANK[b.rarity] - RARITY_RANK[a.rarity] || b.value - a.value || a.name.localeCompare(b.name));
    const best = items.length && RARITY_RANK[items[0].rarity] > 0 ? items[0] : null;

    const skills: ReportSkill[] = [...this.xp].map(([skill, xp]) => ({
      skill,
      name: SKILLS[skill].name,
      xp,
      fromLevel: this.startLevels.get(skill) ?? this.levelOf(skill),
      toLevel: this.levelOf(skill),
      items: this.counts.get(skill) ?? 0,
    }));

    const milestones: string[] = [];
    const records: string[] = [];
    const nextBests: Bests = { ...bests };
    for (const s of skills) {
      const before = this.startLife.get(s.skill) ?? 0;
      for (const m of crossedMilestones(before, before + s.items)) milestones.push(`${m.toLocaleString()} ${s.name} finds`);
      if (s.toLevel > s.fromLevel) milestones.push(`${s.name} level ${s.toLevel}`);
      const xpPerHour = Math.round((s.xp / seconds) * 3600);
      const prev = bests[s.skill];
      // A record only means something once there is a previous session to beat.
      if (prev && s.items > prev.items) records.push(`Most ${s.name} finds in one session (was ${prev.items.toLocaleString()})`);
      nextBests[s.skill] = { items: Math.max(prev?.items ?? 0, s.items), xpPerHour: Math.max(prev?.xpPerHour ?? 0, xpPerHour) };
    }

    return {
      report: {
        seconds,
        reason,
        items,
        totalItems: items.reduce((n, i) => n + i.qty, 0),
        goldValue: items.reduce((n, i) => n + i.value, 0),
        gold: this.gold,
        skills,
        best,
        milestones,
        records,
      },
      bests: nextBests,
    };
  }
}

export function durationText(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return h ? `${h}h ${m}m` : m ? `${m}m ${s}s` : `${s}s`;
}
