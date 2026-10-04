import { describe, expect, it } from 'vitest';
import { KILL_REWARD_RANGE, bossRewardEligible } from '../killCredit';

describe('kill credit (normal kills and bosses share it)', () => {
  it('pays a living hero within range only', () => {
    expect(bossRewardEligible(true, 10)).toBe(true);
    expect(bossRewardEligible(true, KILL_REWARD_RANGE + 1)).toBe(false);
    expect(bossRewardEligible(false, 5)).toBe(false);
  });
});
