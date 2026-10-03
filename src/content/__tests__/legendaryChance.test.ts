import { describe, expect, it } from 'vitest';
import { LEGENDARY_DROP, legendaryBossChance } from '../legendarySets';

describe('legendary boss chance (owner, 3 Oct 2026)', () => {
  it('15% from the Abbess onward, 3% at the Gravedigger King, none elsewhere', () => {
    expect(LEGENDARY_DROP.bossChance).toBe(0.15);
    for (const a of ['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'] as const) expect(legendaryBossChance(a)).toBe(0.15);
    expect(legendaryBossChance('graves')).toBe(0.03);
    expect(legendaryBossChance('chapterhouse' as any)).toBe(0);
  });
});
