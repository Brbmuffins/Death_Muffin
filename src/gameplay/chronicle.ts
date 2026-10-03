import { addChronicle, ascendChronicle, getChronicle, type ChronicleData } from '../net/api';

/**
 * The Chronicle: lifetime stats Ascension never resets, plus a record of every finished run. Counters accumulate here and
 * flush to the server in small batches (a failed flush keeps them for the next try), so play never waits on the network.
 * Keys are dotted groups the server whitelists (kills.graves, boss.saint, gold.earned, gathered.mining, peak.level …).
 */
const FLUSH_MS = 30_000;

export const EMPTY_CHRONICLE: ChronicleData = { life: {}, run: {}, runNo: 1, runStartedAt: null, runs: [] };

export class Chronicle {
  private data: ChronicleData = { ...EMPTY_CHRONICLE, life: {}, run: {}, runs: [] };
  private sums: Record<string, number> = {};
  private maxes: Record<string, number> = {};
  /** The batch a flush has sent and the server has not yet confirmed: still part of what view() shows. */
  private sending: { sums: Record<string, number>; maxes: Record<string, number> } | null = null;
  private fraction = { playSeconds: 0, afkSeconds: 0 };
  private timer: ReturnType<typeof setInterval> | undefined;
  private inFlight = false;
  private loaded = false;
  private disposed = false;

  constructor(private characterId: number) {
    this.timer = setInterval(() => void this.flush(), FLUSH_MS);
  }

  /** Fetch the saved record (safe to call again to refresh the runs table). */
  async load(): Promise<void> {
    try {
      this.data = await getChronicle(this.characterId);
      this.loaded = true;
    } catch (err) {
      console.warn('[chronicle] load failed', err);
    }
  }

  add(key: string, n = 1) {
    if (!(n > 0)) return;
    this.sums[key] = (this.sums[key] ?? 0) + n;
  }

  max(key: string, value: number) {
    if (value > (this.maxes[key] ?? 0)) this.maxes[key] = value;
  }

  /** Play time (and AFK time) in whole seconds; fractions carry over. */
  time(dt: number, afk: boolean) {
    this.fraction.playSeconds += dt;
    if (afk) this.fraction.afkSeconds += dt;
    for (const k of ['playSeconds', 'afkSeconds'] as const) {
      const whole = Math.floor(this.fraction[k]);
      if (whole > 0) {
        this.fraction[k] -= whole;
        this.add(k, whole);
      }
    }
  }

  /** What the panel shows: the saved record plus anything not yet flushed. */
  view(): ChronicleData {
    const fold = (base: Record<string, number>) => {
      const out = { ...base };
      for (const part of [this.sending, this]) {
        if (!part) continue;
        for (const [k, v] of Object.entries(part.sums)) out[k] = (out[k] ?? 0) + v;
        for (const [k, v] of Object.entries(part.maxes)) out[k] = Math.max(out[k] ?? 0, v);
      }
      return out;
    };
    return { ...this.data, life: fold(this.data.life), run: fold(this.data.run) };
  }

  get isLoaded() {
    return this.loaded;
  }

  async flush(): Promise<void> {
    if (this.inFlight || this.disposed && !this.hasPending()) return;
    if (!this.hasPending()) return;
    const sums = this.sums;
    const maxes = this.maxes;
    this.sums = {};
    this.maxes = {};
    this.inFlight = true;
    this.sending = { sums, maxes };
    try {
      await addChronicle(this.characterId, sums, maxes);
      // The saved record now includes them; keep the local copy in step so view() doesn't double count.
      for (const [k, v] of Object.entries(sums)) {
        this.data.life[k] = (this.data.life[k] ?? 0) + v;
        this.data.run[k] = (this.data.run[k] ?? 0) + v;
      }
      for (const [k, v] of Object.entries(maxes)) {
        this.data.life[k] = Math.max(this.data.life[k] ?? 0, v);
        this.data.run[k] = Math.max(this.data.run[k] ?? 0, v);
      }
    } catch (err) {
      console.warn('[chronicle] flush failed, will retry', err);
      for (const [k, v] of Object.entries(sums)) this.sums[k] = (this.sums[k] ?? 0) + v;
      for (const [k, v] of Object.entries(maxes)) this.maxes[k] = Math.max(this.maxes[k] ?? 0, v);
    } finally {
      this.sending = null;
      this.inFlight = false;
    }
  }

  private hasPending() {
    return Object.keys(this.sums).length > 0 || Object.keys(this.maxes).length > 0;
  }

  /** The Altar burned the run: bank what this run did, archive it, and start the next. */
  async ascend(rank: number): Promise<void> {
    while (this.inFlight) await new Promise<void>((r) => setTimeout(r, 50));
    await this.flush();
    try {
      await ascendChronicle(this.characterId, rank);
      await this.load();
    } catch (err) {
      console.warn('[chronicle] ascend failed', err);
    }
  }

  dispose() {
    this.disposed = true;
    clearInterval(this.timer);
    void this.flush();
  }
}
