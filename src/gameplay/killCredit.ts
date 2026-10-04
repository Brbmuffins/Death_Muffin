/**
 * Who is paid for a kill. Normal kills and boss kills share one rule (owner, 3 Oct 2026): a living hero within
 * KILL_REWARD_RANGE metres of the body. Before this, every client that saw a boss's `defeated` event was paid,
 * even one dead or in another area.
 */
export const KILL_REWARD_RANGE = 38;

export const bossRewardEligible = (alive: boolean, distance: number) => alive && distance < KILL_REWARD_RANGE;
