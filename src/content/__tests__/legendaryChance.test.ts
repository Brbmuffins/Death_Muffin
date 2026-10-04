import { describe, expect, it } from 'vitest';
import { LEGENDARY_DROP, legendaryBossChance } from '../legendarySets';

describe('legendary boss chance (owner, 3 Oct 2026)', () => {
  it('20% at the Abbess rising to 33% in the Fen, 6% at the Gravedigger King, none elsewhere', () => {
    expect(LEGENDARY_DROP.bossChance).toBe(0.2);
    const chances = (['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'] as const).map(legendaryBossChance);
    expect(chances).toEqual([0.2, 0.22, 0.25, 0.28, 0.3, 0.33]);
    expect(legendaryBossChance('graves')).toBe(0.06);
    expect(legendaryBossChance('chapterhouse' as any)).toBe(0);
  });
});
