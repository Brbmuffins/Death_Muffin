/**
 * The Kill Chain (docs/GRIND-LOOP.md §3 #8): your own kills, thralls' included, chain while each lands within
 * `windowMs` of the last. Higher tiers add a small XP and gold bonus and escalate the feedback. Client-only and
 * cosmetic in the trust model: it multiplies a reward the client already rolls.
 */
export interface ChainTier {
  at: number;
  name: string;
  /** Fractional XP and gold bonus while at this tier (0.1 = +10%). */
  bonus: number;
}

export const CHAIN = {
  windowMs: 4000,
  /** A broken chain is only announced when it reached this many. */
  reportAt: 10,
  tiers: [
    { at: 5, name: 'Stirring', bonus: 0.05 },
    { at: 12, name: 'Rampage', bonus: 0.1 },
    { at: 25, name: 'Slaughter', bonus: 0.15 },
    { at: 45, name: 'Massacre', bonus: 0.2 },
    { at: 80, name: 'Requiem', bonus: 0.25 },
  ] as readonly ChainTier[],
};

export class KillChain {
  count = 0;
  /** Best chain this session (the caller persists whatever it wants to keep). */
  best = 0;
  private until = 0;

  /** The tier a chain of `n` has reached (null below the first). */
  static tierFor(n: number): ChainTier | null {
    let t: ChainTier | null = null;
    for (const tier of CHAIN.tiers) if (n >= tier.at) t = tier;
    return t;
  }

  get tier() {
    return KillChain.tierFor(this.count);
  }

  /** XP and gold multiplier for the *next* reward: earned by the chain as it stood before this kill. */
  get mult() {
    return 1 + (this.tier?.bonus ?? 0);
  }

  get active() {
    return this.count > 0;
  }

  /** Fraction of the window left (1 just after a kill, 0 as it breaks). */
  frac(now: number) {
    return this.count === 0 ? 0 : Math.max(0, Math.min(1, (this.until - now) / CHAIN.windowMs));
  }

  /** Register a kill. Returns the tier reached if this kill crossed into a new one. */
  hit(now: number): ChainTier | null {
    if (this.count > 0 && now > this.until) this.count = 0;
    const before = this.tier;
    this.count++;
    this.until = now + CHAIN.windowMs;
    this.best = Math.max(this.best, this.count);
    const after = this.tier;
    return after && after !== before ? after : null;
  }

  /** Call every frame. Returns the length of a chain that just broke (0 when nothing did). */
  tick(now: number): number {
    if (this.count > 0 && now > this.until) {
      const broke = this.count;
      this.count = 0;
      return broke;
    }
    return 0;
  }

  /** Death (or anything else that ends a run of kills) drops the chain without a report. */
  reset() {
    this.count = 0;
  }
}
