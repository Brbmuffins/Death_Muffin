/**
 * Session difficulty (Easy / Medium / Hard). Scales how hard enemies and the
 * Prelate hit and how much health they have, and rewards to match so no
 * setting is the "farming" setting. Medium is the tuning in BALANCE.md. In
 * co-op the host's choice runs the world (it rides in every snapshot).
 * Only append to DIFFICULTY_ORDER — snapshots may carry the index later.
 */
export type Difficulty = 'easy' | 'medium' | 'hard';
export const DIFFICULTY_ORDER: Difficulty[] = ['easy', 'medium', 'hard'];

export interface DifficultyDef {
  id: Difficulty;
  name: string;
  blurb: string;
  enemyHpMult: number;
  enemyDamageMult: number;
  /** Gold and XP from kills, surges and the Prelate. */
  rewardMult: number;
  /** Added to every area's elite chance. */
  eliteBonus: number;
}

export const DIFFICULTIES: Record<Difficulty, DifficultyDef> = {
  easy: {
    id: 'easy',
    name: 'Easy',
    blurb: 'The dead hit softer and fall faster. Less gold and experience.',
    enemyHpMult: 0.75,
    enemyDamageMult: 0.3,
    rewardMult: 0.75,
    eliteBonus: 0,
  },
  medium: {
    id: 'medium',
    name: 'Medium',
    blurb: 'The intended balance.',
    enemyHpMult: 1,
    enemyDamageMult: 1,
    rewardMult: 1,
    eliteBonus: 0,
  },
  hard: {
    id: 'hard',
    name: 'Hard',
    blurb: 'Tougher, deadlier dead and more elites. More gold and experience.',
    enemyHpMult: 1.2,
    enemyDamageMult: 1.3,
    rewardMult: 1.3,
    eliteBonus: 0.02,
  },
};

export function isDifficulty(v: unknown): v is Difficulty {
  return typeof v === 'string' && (DIFFICULTY_ORDER as string[]).includes(v);
}
