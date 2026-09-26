import type { AreaId } from '../content/areas';
import { DAMAGE_UPGRADE, WAVE_UPGRADE } from '../content/upgrades';
import { saveProgress } from '../net/api';
import type { Character } from '../net/types';
import { xpToNext } from './characterStats';

/**
 * Progress the live server has no column for yet (upgrade tiers, soul shards,
 * area kill counts / unlocks). Stored per character in the browser — the
 * user-approved interim; see server/proposals/necromancer-progress.md for the
 * server spec that replaces it. Level, XP and gold still go to the server.
 */
export interface LocalProgress {
  v: 1;
  damageTier: number;
  waveTierOwned: number;
  waveTierActive: number;
  shards: number;
  areaKills: Partial<Record<AreaId, number>>;
  unlocked: AreaId[];
  bossKills: number;
  totalKills: number;
}

const blank = (): LocalProgress => ({
  v: 1,
  damageTier: 0,
  waveTierOwned: 0,
  waveTierActive: 0,
  shards: 0,
  areaKills: {},
  unlocked: ['chapterhouse', 'graves'],
  bossKills: 0,
  totalKills: 0,
});

const key = (characterId: number) => `cw_progress_v1_${characterId}`;

export function loadLocalProgress(characterId: number): LocalProgress {
  try {
    const raw = localStorage.getItem(key(characterId));
    if (raw) return { ...blank(), ...JSON.parse(raw) };
  } catch {
    /* storage unavailable */
  }
  return blank();
}

export type SaveState = 'saved' | 'dirty' | 'saving' | 'retrying';

/**
 * Owns the character's progression and its persistence. Server saves happen on
 * level-up, periodically while dirty, on area change and on tab hide — never per
 * kill (server design intent). Failures retry with backoff and surface in the
 * HUD instead of being silently dropped.
 */
export class Progression {
  readonly local: LocalProgress;
  private dirtyServer = false;
  private saveState: SaveState = 'saved';
  private retryDelay = 4000;
  private timer = 0;
  private inFlight = false;
  private listeners = new Set<() => void>();

  constructor(readonly character: Character) {
    this.local = loadLocalProgress(character.id);
  }

  onChange(fn: () => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit() {
    this.listeners.forEach((fn) => fn());
  }

  get state() {
    return this.saveState;
  }

  // --- XP / level / gold (server-backed) ---

  /** Returns the number of levels gained. */
  addXp(amount: number): number {
    const c = this.character;
    c.experience = (c.experience ?? 0) + Math.round(amount);
    let gained = 0;
    while (c.experience >= xpToNext(c.level)) {
      c.experience -= xpToNext(c.level);
      c.level += 1;
      gained++;
    }
    this.markServerDirty(gained > 0);
    return gained;
  }

  addGold(amount: number) {
    this.character.gold = (this.character.gold ?? 0) + Math.round(amount);
    this.markServerDirty(false);
  }

  canAfford(cost: number) {
    return (this.character.gold ?? 0) >= cost;
  }

  // --- Upgrades (local) ---

  damageCost() {
    return this.local.damageTier >= DAMAGE_UPGRADE.maxTier ? null : DAMAGE_UPGRADE.cost(this.local.damageTier);
  }

  waveCost() {
    return this.local.waveTierOwned >= WAVE_UPGRADE.maxTier ? null : WAVE_UPGRADE.cost(this.local.waveTierOwned);
  }

  buyDamage(): boolean {
    const cost = this.damageCost();
    if (cost === null || !this.canAfford(cost)) return false;
    this.character.gold -= cost;
    this.local.damageTier++;
    this.saveLocal();
    this.markServerDirty(true);
    return true;
  }

  buyWave(): boolean {
    const cost = this.waveCost();
    if (cost === null || !this.canAfford(cost)) return false;
    this.character.gold -= cost;
    this.local.waveTierOwned++;
    this.local.waveTierActive = this.local.waveTierOwned;
    this.saveLocal();
    this.markServerDirty(true);
    return true;
  }

  setActiveWaveTier(tier: number) {
    this.local.waveTierActive = Math.max(0, Math.min(this.local.waveTierOwned, tier));
    this.saveLocal();
    this.emit();
  }

  // --- Kills / unlocks / shards (local) ---

  recordKill(area: AreaId) {
    this.local.areaKills[area] = (this.local.areaKills[area] ?? 0) + 1;
    this.local.totalKills++;
    this.saveLocalSoon();
  }

  kills(area: AreaId) {
    return this.local.areaKills[area] ?? 0;
  }

  isUnlocked(area: AreaId) {
    return this.local.unlocked.includes(area);
  }

  unlock(area: AreaId) {
    if (this.isUnlocked(area)) return false;
    this.local.unlocked.push(area);
    this.saveLocal();
    return true;
  }

  addShards(n: number) {
    this.local.shards += n;
    this.saveLocal();
  }

  spendShards(n: number): boolean {
    if (this.local.shards < n) return false;
    this.local.shards -= n;
    this.saveLocal();
    return true;
  }

  // --- Persistence ---

  private localTimer = 0;
  private saveLocalSoon() {
    if (this.localTimer) return;
    this.localTimer = window.setTimeout(() => {
      this.localTimer = 0;
      this.saveLocal();
    }, 1500);
  }

  saveLocal() {
    try {
      localStorage.setItem(key(this.character.id), JSON.stringify(this.local));
    } catch {
      /* storage unavailable — progress lives for this session only */
    }
    this.emit();
  }

  private markServerDirty(urgent: boolean) {
    this.dirtyServer = true;
    if (this.saveState === 'saved') this.saveState = 'dirty';
    this.emit();
    if (urgent) this.flush();
    else if (!this.timer) this.timer = window.setTimeout(() => this.flush(), 45000);
  }

  private payload() {
    const c = this.character;
    return {
      characterId: c.id,
      level: c.level,
      xp: c.experience ?? 0,
      gold: Math.max(0, Math.round(c.gold ?? 0)),
      stat_str: c.stat_str ?? 5,
      stat_agi: c.stat_agi ?? 5,
      stat_int: c.stat_int ?? 5,
      stat_vit: c.stat_vit ?? 5,
    };
  }

  async flush(keepalive = false): Promise<void> {
    window.clearTimeout(this.timer);
    this.timer = 0;
    if (!this.dirtyServer || this.inFlight) return;
    this.inFlight = true;
    this.dirtyServer = false;
    this.saveState = 'saving';
    this.emit();
    try {
      await saveProgress(this.payload(), keepalive);
      this.retryDelay = 4000;
      this.saveState = this.dirtyServer ? 'dirty' : 'saved';
    } catch (err) {
      console.warn('[progress] save failed, will retry', err);
      this.dirtyServer = true;
      this.saveState = 'retrying';
      this.timer = window.setTimeout(() => this.flush(), this.retryDelay);
      this.retryDelay = Math.min(60000, this.retryDelay * 2);
    } finally {
      this.inFlight = false;
      this.emit();
      if (this.dirtyServer && this.saveState === 'dirty' && !this.timer) {
        this.timer = window.setTimeout(() => this.flush(), 45000);
      }
    }
  }

  dispose() {
    window.clearTimeout(this.timer);
    window.clearTimeout(this.localTimer);
    this.saveLocal();
    void this.flush(true);
    this.listeners.clear();
  }
}
