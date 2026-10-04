import { browserStorage, type StorageLike } from '../gameplay/codexJournal';

/**
 * Progressive HUD (owner, 3 Oct 2026): an element stays hidden until it matters, and the first time it appears (or a panel / tab
 * first becomes relevant) it is flagged "new" until the player uses it. Pure and storage-injected, so it is unit-tested and costs
 * nothing per frame: callers ask `reveal()` on events or at the 20 Hz HUD tick, and the work is a Set lookup.
 *
 * UI-only state, browser-local and per character (a convenience, not progress), through browserStorage() so the offline edition
 * namespaces it. Every storage access is guarded; with no storage the HUD simply reveals again next session.
 */

/** Elements the HUD can hold back, and the panel / tab entries that carry a NEW cue. */
export type RevealId =
  | 'hud.upgrades' // the Damage / Wave Speed plate
  | 'hud.dial' // the active wave-speed dial inside the plate
  | 'hud.shards' // the Soul Shards counter
  | 'hud.omen' // the week's Omen chip (cue only: the chip itself also hides in safe areas)
  | 'hud.spells' // the hotbar "Swap spells" button
  | 'menu.spells'
  | 'menu.atlas'
  | 'menu.skills' // the merged Acre ledger button
  | 'tab.acre.garden'
  | 'tab.acre.labor'
  | 'tab.acre.contracts'
  | 'tab.sheet.pets'
  | 'tab.grimoire.legion';

export const storageKey = (characterId: number) => `dm_hud_reveal_v1_${characterId}`;

interface Saved {
  r: string[]; // revealed
  u: string[]; // flagged and not used yet
  t: string[]; // ever flagged (so a used cue never comes back)
}

export class HudReveal {
  private revealed = new Set<string>();
  private unseen = new Set<string>();
  private told = new Set<string>();
  /** True when nothing was stored for this character: the caller seeds veterans once. */
  readonly fresh: boolean;
  private key: string;

  constructor(characterId: number, private storage: StorageLike | null = browserStorage()) {
    this.key = storageKey(characterId);
    let found = false;
    try {
      const raw = this.storage?.getItem(this.key);
      if (raw) {
        const s = JSON.parse(raw) as Partial<Saved>;
        for (const [list, set] of [[s.r, this.revealed], [s.u, this.unseen], [s.t, this.told]] as const) {
          if (Array.isArray(list)) for (const id of list) if (typeof id === 'string') set.add(id);
        }
        found = true;
      }
    } catch {
      /* start empty */
    }
    this.fresh = !found;
  }

  has(id: RevealId): boolean {
    return this.revealed.has(id);
  }

  isNew(id: RevealId): boolean {
    return this.unseen.has(id);
  }

  /** Reveal for good. True the first time. `announce` also flags it new (veterans reveal silently). */
  reveal(id: RevealId, announce = true): boolean {
    if (this.revealed.has(id)) return false;
    this.revealed.add(id);
    if (announce) this.flagNew(id);
    this.save();
    return true;
  }

  /** Flag an entry new without revealing anything (a merged panel's first appearance). True only the first time ever. */
  flag(id: RevealId): boolean {
    if (this.told.has(id)) return false;
    this.flagNew(id);
    this.save();
    return true;
  }

  private flagNew(id: string) {
    if (this.told.has(id)) return;
    this.told.add(id);
    this.unseen.add(id);
  }

  /** The player opened or used it. True when a cue was actually cleared. */
  clear(id: RevealId): boolean {
    if (!this.unseen.delete(id)) return false;
    this.save();
    return true;
  }

  /** Every id still flagged new (the HUD redraws the pips from this on load). */
  newIds(): string[] {
    return [...this.unseen];
  }

  private save() {
    try {
      this.storage?.setItem(this.key, JSON.stringify({ r: [...this.revealed], u: [...this.unseen], t: [...this.told] } satisfies Saved));
    } catch {
      /* storage full or blocked */
    }
  }
}

/** What the veteran check can see about a character. */
export interface VeteranFacts {
  level: number;
  gold: number;
  damageTier: number;
  waveOwned: number;
  shards: number;
  /** Visited the Sexton's Acre (Codex) or has any skill XP. */
  knowsAcre: boolean;
  /** At least one level-gated rite learned (firstHourRules.swapReady). */
  swapReady: boolean;
  /** Owns any gear piece. */
  hasGear: boolean;
  /** Has left the safe areas at least once (Codex area found beyond the Chapterhouse and Acre). */
  hasHunted: boolean;
}

/**
 * The elements that obviously already matter to a character loading in, so a veteran never loses HUD they were using. Ordered, silent
 * (no NEW cue). A fresh level 1 returns an empty list.
 */
export function veteranReveals(f: VeteranFacts): RevealId[] {
  const out: RevealId[] = [];
  if (f.level >= 2 || f.gold > 0 || f.damageTier > 0 || f.waveOwned > 0) out.push('hud.upgrades');
  if (f.waveOwned > 0) out.push('hud.dial');
  if (f.shards > 0) out.push('hud.shards');
  if (f.swapReady) out.push('hud.spells', 'menu.spells');
  if (f.hasGear) out.push('menu.atlas');
  if (f.knowsAcre || f.level >= 3) out.push('menu.skills');
  if (f.hasHunted) out.push('hud.omen');
  return out;
}

/** An existing player (not a fresh character): they knew the old panel layout, so the merged windows get a one-time NEW cue. */
export const isVeteran = (level: number) => level >= 3;

/** Wave Speed's dial only has something to choose once a tier is owned. */
export const dialReady = (waveOwned: number) => waveOwned > 0;

/**
 * The "new" toast line queue: one toast at a time, each held for `holdMs` before the next. `show` draws the toast, `schedule` is
 * setTimeout (injected so the test can drive time).
 */
export class CueQueue {
  private queue: { key: string; text: string }[] = [];
  private busy = false;

  constructor(
    private show: (text: string, key: string) => void,
    private schedule: (fn: () => void, ms: number) => unknown = (fn, ms) => setTimeout(fn, ms),
    private holdMs = 6500,
    /** Held back while true (a loading veil, a boss fight): the queue waits and tries again. */
    private blocked: () => boolean = () => false,
  ) {}

  push(key: string, text: string) {
    if (this.queue.some((q) => q.key === key)) return;
    this.queue.push({ key, text });
    this.pump();
  }

  /** The player already used it: its line is no longer worth a toast. */
  drop(key: string) {
    this.queue = this.queue.filter((q) => q.key !== key);
  }

  get pending() {
    return this.queue.length;
  }

  private pump() {
    if (this.busy || !this.queue.length) return;
    if (this.blocked()) {
      this.busy = true;
      this.schedule(() => { this.busy = false; this.pump(); }, 2000);
      return;
    }
    const next = this.queue.shift()!;
    this.busy = true;
    this.show(next.text, next.key);
    this.schedule(() => { this.busy = false; this.pump(); }, this.holdMs);
  }
}
