import type { BossKill, FloorClear, KillGroup, KillReport } from '../gameplay/killRules';

/**
 * Server authority, step 2 (docs/SERVER-AUTHORITY.md): the browser reports what it killed so the server can work out what the kills were
 * worth. Kills are counted here as they happen and sealed into numbered batches; a batch rides along with the next progress save (one
 * request, so the server has the credit before it judges the XP and gold), or is posted on its own when nothing else is going out.
 *
 * A batch keeps its sequence number until the server confirms it, so a retry after a lost reply is recognised as a repeat and never counted
 * twice, and a batch that was never delivered is still there. Nothing here changes what the game pays: the sim still rolls every kill.
 */

export type KillInput = Omit<KillGroup, 'n'>;

const MAX_UNACKED = 4;

const groupKey = (k: KillInput) => `${k.area}|${k.def}|${k.level}|${k.elite ? 1 : 0}|${k.tier}|${k.diff}|${k.rank}|${k.xpMult}|${k.goldMult}|${k.shardMult}`;
const bossKey = (b: Omit<BossKill, 'n'>) => `${b.boss}|${b.tier}|${b.diff}|${b.first ? 1 : 0}|${b.summon ?? 0}`;
const round2 = (n: number) => Math.round(n * 100) / 100;

export class KillReporter {
  private groups = new Map<string, KillGroup>();
  private bosses = new Map<string, BossKill>();
  private floors: FloorClear[] = [];
  /** Sealed batches the server has not confirmed yet, oldest first. */
  private sealed: KillReport[] = [];
  private lastSeq = 0;

  constructor(private now: () => number = Date.now) {}

  /** A kill the hero is paid for. Multipliers are rounded to two places so a chain ticking up does not make a group per kill. */
  kill(input: KillInput) {
    const k: KillInput = { ...input, xpMult: round2(input.xpMult), goldMult: round2(input.goldMult), shardMult: round2(input.shardMult) };
    const key = groupKey(k);
    const have = this.groups.get(key);
    if (have) have.n++;
    else this.groups.set(key, { ...k, n: 1 });
  }

  boss(input: Omit<BossKill, 'n'>) {
    const key = bossKey(input);
    const have = this.bosses.get(key);
    if (have) have.n++;
    else this.bosses.set(key, { ...input, n: 1 });
  }

  floor(f: FloorClear) {
    this.floors.push({ ...f, mult: round2(f.mult) });
  }

  /** Anything not yet sealed or confirmed. */
  get hasPending() {
    return this.groups.size > 0 || this.bosses.size > 0 || this.floors.length > 0 || this.sealed.length > 0;
  }

  /** True when the open batch is big enough that it should go now (the server caps a report's groups). */
  get crowded() {
    return this.groups.size >= 120;
  }

  /** Seal the open batch (if it holds anything) and return every unconfirmed batch, oldest first. */
  batches(): KillReport[] {
    if (this.groups.size || this.bosses.size || this.floors.length) {
      const seq = Math.max(this.lastSeq + 1, this.now());
      this.lastSeq = seq;
      this.sealed.push({ seq, groups: [...this.groups.values()], bosses: [...this.bosses.values()], floors: this.floors });
      this.groups = new Map();
      this.bosses = new Map();
      this.floors = [];
      // A server that never confirms must not make the browser hold an unbounded pile: the oldest batches are dropped first.
      while (this.sealed.length > MAX_UNACKED) this.sealed.shift();
    }
    return this.sealed.slice();
  }

  /** The server has seen every batch up to and including `seq`. */
  ack(seq: number) {
    this.sealed = this.sealed.filter((b) => b.seq > seq);
  }

  /** The server cannot take reports at all (an older server without the route): stop holding them. */
  discard() {
    this.groups = new Map();
    this.bosses = new Map();
    this.floors = [];
    this.sealed = [];
  }
}
