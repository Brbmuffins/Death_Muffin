import { isAlwaysOpen, type AreaId } from '../content/areas';
import { devAccess } from './devAccess';
import type { Chronicle } from './chronicle';
import { ashesForRun, boonBlocked, boonCost, boonEffects, isUnlocked, unlockCost, vowEffects, vowHeat, vowKey, legacyVows, VOWS, type BoonId, type BoonEffects, type BoonRanks, type RunRecord, type VowEffects, type VowId, type VowRanks } from '../content/ascension';
import { DAMAGE_UPGRADE, LEGION_UPGRADE, WAVE_UPGRADE } from '../content/upgrades';
import { ApiError, necroApi, reportKills, saveProgress, type NecroReply } from '../net/api';
import { KillReporter, type KillInput } from '../net/killReporter';
import type { BossKill, FloorClear } from './killRules';
import { applySave, normalise, type NecroState, type SaveInput } from './necroRules';
import type { Character } from '../net/types';
import { xpToNext } from './characterStats';
import { BOSSES, type BossId } from '../content/bosses';

/**
 * Necromancer progression (upgrade tiers, soul shards, area kills / unlocks,
 * Ascension). Two modes:
 *  - **local**: stored per character in the browser (older servers without the
 *    /api/necro-progress routes, or the server unreachable at load).
 *  - **server**: the server owns it (server/VPS_HANDOFF.md). The browser copy
 *    becomes a cache; changes apply optimistically and are reconciled with the
 *    server's answer. On first connect the browser save is imported once.
 * Level, XP and gold always go to the server via save-progress.
 */
export interface LocalProgress {
  v: 1;
  damageTier: number;
  waveTierOwned: number;
  waveTierActive: number;
  /** Legion reinforcement tiers bought this run (thrall kit gold sink). */
  legionTier?: number;
  shards: number;
  areaKills: Partial<Record<AreaId, number>>;
  unlocked: AreaId[];
  /** Lifetime counters (Ascension never resets these). */
  bossKills: number;
  totalKills: number;
  /** Ascension: rank reached, unspent Ashes, bought Covenant Boons, and this run's record. */
  ascension: number;
  ashes: number;
  boons: BoonRanks;
  /** Vows sworn for the run in progress, and the vows / boons opened with soul shards. A save without `vows` is a pre-Vows save (rank N = N steps of Elder Dead). */
  vows?: VowRanks;
  unlocks?: string[];
  run: RunRecord;
  /** Server mode: paid Prelate summons not yet reported as kills. */
  summonsPending?: number;
  /** This cache mirrors a server record (never import it again). */
  serverBacked?: boolean;
}

/** LocalProgress ⇄ the shared NecroState (server/rules shape). */
export function toNecro(l: LocalProgress): NecroState {
  return normalise({
    damageTier: l.damageTier,
    waveTierOwned: l.waveTierOwned,
    waveTierActive: l.waveTierActive,
    legionTier: l.legionTier ?? 0,
    soulShards: l.shards,
    areaKills: l.areaKills,
    unlockedAreas: l.unlocked,
    bossKills: l.bossKills,
    totalKills: l.totalKills,
    ascension: l.ascension,
    ashes: l.ashes,
    boons: l.boons,
    vows: l.vows ?? legacyVows(l.ascension),
    unlocks: l.unlocks ?? [],
    run: l.run,
    summonsPending: l.summonsPending ?? 0,
    migrated: !!l.serverBacked,
  });
}

function copyInto(l: LocalProgress, s: NecroState) {
  l.damageTier = s.damageTier;
  l.waveTierOwned = s.waveTierOwned;
  l.waveTierActive = s.waveTierActive;
  l.legionTier = s.legionTier;
  l.shards = s.soulShards;
  l.areaKills = { ...s.areaKills };
  l.unlocked = [...s.unlockedAreas];
  l.bossKills = s.bossKills;
  l.totalKills = s.totalKills;
  l.ascension = s.ascension;
  l.ashes = s.ashes;
  l.boons = { ...s.boons };
  l.vows = { ...s.vows };
  l.unlocks = [...s.unlocks];
  l.run = { ...s.run };
  l.summonsPending = s.summonsPending;
  l.serverBacked = true;
}

const emptyPending = (): Required<Pick<SaveInput, 'areaKills' | 'shards' | 'prelateKills' | 'peakWaveTier'>> => ({
  areaKills: {},
  shards: 0,
  prelateKills: 0,
  peakWaveTier: 0,
});

const blank = (): LocalProgress => ({
  v: 1,
  damageTier: 0,
  waveTierOwned: 0,
  waveTierActive: 0,
  legionTier: 0,
  shards: 0,
  areaKills: {},
  unlocked: ['chapterhouse', 'graves'],
  bossKills: 0,
  totalKills: 0,
  ascension: 0,
  ashes: 0,
  boons: {},
  vows: {},
  unlocks: [],
  run: { prelateKills: 0, peakWaveTier: 0, kills: 0 },
});

const key = (characterId: number) => `${import.meta.env.VITE_OFFLINE_BUILD === '1' ? 'dm_offline_' : ''}dm_progress_v1_${characterId}`;

export function loadLocalProgress(characterId: number): LocalProgress {
  try {
    const raw = localStorage.getItem(key(characterId));
    if (raw) {
      const saved = JSON.parse(raw) as Partial<LocalProgress>;
      const p = { ...blank(), ...saved };
      // Saves from before Ascension: everything so far counts as the current run.
      if (!saved.vows) p.vows = legacyVows(p.ascension);
      if (!saved.run) p.run = { prelateKills: p.bossKills, peakWaveTier: p.waveTierOwned, kills: p.totalKills };
      return p;
    }
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
  private remoteInFlight = 0;
  /** Necro-progress requests run one at a time, so their replies are adopted in the order the server applied them. */
  private necroChain: Promise<unknown> = Promise.resolve();
  private listeners = new Set<() => void>();
  /** Lifetime stats (set by the scene): kills, gold and Ascension runs feed it from here. */
  chronicle: Chronicle | null = null;
  /** 'server' once the necro-progress routes answered; 'local' otherwise. */
  mode: 'local' | 'server' = 'local';
  /** Server authority step 2: what was killed, sent with the saves (net/killReporter.ts). */
  readonly reporter = new KillReporter();
  /** Deltas gathered since the last necro save (server mode). */
  private pending = emptyPending();
  private pendingWaveActive = false;
  private errorListeners = new Set<(msg: string) => void>();
  private syncListeners = new Set<() => void>();

  constructor(readonly character: Character) {
    this.local = loadLocalProgress(character.id);
  }

  /** Player-readable server errors (show verbatim). */
  onError(fn: (msg: string) => void) {
    this.errorListeners.add(fn);
    return () => this.errorListeners.delete(fn);
  }

  /** Fired when server state replaced the local copy (seals, tiers or rank may have moved). */
  onSynced(fn: () => void) {
    this.syncListeners.add(fn);
    return () => this.syncListeners.delete(fn);
  }

  /**
   * Try the server. 404 (route missing) or unreachable → stay in local mode.
   * First contact imports the browser save once; after that the server wins.
   */
  async connect(): Promise<'local' | 'server'> {
    let reply: NecroReply;
    try {
      reply = await necroApi.get(this.character.id);
    } catch (err) {
      if (!(err instanceof ApiError) || err.status !== 404) console.warn('[progress] server progression unavailable, using browser storage', err);
      return (this.mode = 'local');
    }
    try {
      if (!reply.progress.migrated) {
        reply = await necroApi.importLocal(this.character.id, this.local);
        // Everything gathered so far was inside the imported record.
        this.pending = emptyPending();
        this.pendingWaveActive = false;
      }
    } catch (err) {
      console.warn('[progress] browser save import refused; adopting the server record', err);
    }
    this.mode = 'server';
    this.adopt(reply.progress);
    return this.mode;
  }

  /** Replace local with the server's state plus anything gathered since the request left. */
  private adopt(server: NecroState) {
    const merged = applySave(normalise(server), {
      ...this.pending,
      ...(this.pendingWaveActive ? { waveTierActive: this.local.waveTierActive } : {}),
    });
    if (merged.ok) copyInto(this.local, merged.state);
    this.saveLocal();
    this.syncListeners.forEach((fn) => fn());
  }

  /**
   * Run a necro-progress request after every earlier one has been answered. Overlapping requests used to be adopted in
   * whatever order the replies arrived: an older reply (computed before a newer save) landed last and rolled kills,
   * a just-opened seal or a boon back for a moment.
   */
  private serial<T>(task: () => Promise<T>): Promise<T> {
    const run = this.necroChain.then(task);
    this.necroChain = run.then(() => undefined, () => undefined);
    return run;
  }

  /** Fire a server mutation; on success adopt its state, on failure report and resync. */
  private remote(call: () => Promise<NecroReply>) {
    if (this.mode !== 'server') return;
    this.remoteInFlight++;
    void this.serial(() =>
      call()
        .then((r) => this.adopt(r.progress))
        .catch((err) => {
          this.errorListeners.forEach((fn) => fn(err instanceof Error ? err.message : 'Progress could not be saved'));
          return necroApi
            .get(this.character.id)
            .then((r) => this.adopt(r.progress))
            .catch(() => undefined);
        }),
    ).finally(() => { this.remoteInFlight--; });
  }

  private get hasPending() {
    const p = this.pending;
    return this.pendingWaveActive || p.shards > 0 || p.prelateKills > 0 || Object.values(p.areaKills).some((n) => (n ?? 0) > 0);
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
    if (amount > 0) this.chronicle?.add('gold.earned', Math.round(amount));
    this.character.gold = (this.character.gold ?? 0) + Math.round(amount);
    this.markServerDirty(false);
  }

  canAfford(cost: number) {
    return (this.character.gold ?? 0) >= cost;
  }

  // --- Upgrades (local) ---

  damageCost() {
    if (this.local.damageTier >= DAMAGE_UPGRADE.maxTier) return null;
    return Math.round(DAMAGE_UPGRADE.cost(this.local.damageTier) * this.boons.damageCostMult);
  }

  waveCost() {
    if (this.local.waveTierOwned >= WAVE_UPGRADE.maxTier) return null;
    return Math.round(WAVE_UPGRADE.cost(this.local.waveTierOwned) * this.boons.waveCostMult);
  }

  /** Gold for the next Legion reinforcement tier, or null at the top. */
  legionCost() {
    const tier = this.local.legionTier ?? 0;
    return tier >= LEGION_UPGRADE.maxTier ? null : LEGION_UPGRADE.cost(tier);
  }

  // --- Ascension (local) ---

  get boons(): BoonEffects {
    return boonEffects(this.local.boons);
  }

  /** The vows sworn for this run. */
  get vows(): VowRanks {
    return this.local.vows ?? (this.local.vows = legacyVows(this.local.ascension));
  }

  /** What the sworn vows change. */
  get vowFx(): VowEffects {
    return vowEffects(this.vows);
  }

  /** The rank this run plays at: the heat of the vows sworn. */
  get heat(): number {
    return vowHeat(this.vows);
  }

  /** Ashes the Altar would pay for this run right now (0 = not yet ready). */
  ashesOnAscend() {
    return ashesForRun(this.local.run, this.heat);
  }

  canAscend() {
    return this.ashesOnAscend() > 0;
  }

  /**
   * Burn the run: tiers and the run tally reset; Ashes rise and the best rank with them if this run was hotter. Seals, kill
   * counts and soul shards stay, and so do the sworn vows. Level, XP, gold and items are untouched.
   */
  ascend(): number {
    const earned = this.ashesOnAscend();
    if (!earned) return 0;
    const l = this.local;
    const fx = this.boons;
    const heat = this.heat;
    l.ascension = Math.max(l.ascension, heat);
    l.ashes += earned;
    l.damageTier = fx.startDamageTier;
    l.waveTierOwned = 0;
    l.waveTierActive = 0;
    l.legionTier = 0;
    l.shards = Math.max(l.shards, fx.startShards);
    l.run = { prelateKills: 0, peakWaveTier: 0, kills: 0 };
    void this.chronicle?.ascend(heat);
    l.summonsPending = 0;
    this.pending = emptyPending();
    this.saveLocal();
    if (this.mode === 'server') this.remote(() => necroApi.ascend(this.character.id));
    else this.markServerDirty(true);
    return earned;
  }

  /** Why these vows can't be sworn (null = they can). Mirrors the server rule. */
  vowsProblem(next: VowRanks): string | null {
    for (const id of Object.keys(next) as VowId[]) {
      const n = next[id] ?? 0;
      if (!VOWS[id] || n < 0 || n > VOWS[id].maxRank) return 'Unknown vow.';
      if (n && !isUnlocked(this.local.unlocks, vowKey(id))) return `${VOWS[id].name} is not unlocked yet.`;
    }
    return null;
  }

  /** Would swearing `next` restart this run's tally (it has kills or a Prelate kill, and the vows differ)? */
  vowsRestartRun(next: VowRanks): boolean {
    const r = this.local.run;
    const differs = (Object.keys(VOWS) as VowId[]).some((id) => (next[id] ?? 0) !== (this.vows[id] ?? 0));
    return differs && (r.kills > 0 || r.prelateKills > 0 || r.peakWaveTier > 0);
  }

  /** Swear the whole set of vows for the next run. Returns false if refused. */
  swearVows(next: VowRanks): boolean {
    if (this.vowsProblem(next)) return false;
    const clean: VowRanks = {};
    for (const id of Object.keys(next) as VowId[]) if (next[id]) clean[id] = next[id];
    const restart = this.vowsRestartRun(clean);
    this.local.vows = clean;
    if (restart) {
      this.local.run = { prelateKills: 0, peakWaveTier: 0, kills: 0 };
    }
    this.saveLocal();
    if (this.mode === 'server') {
      // Kills gathered since the last save must reach the server before it decides whether the run restarts.
      this.remote(async () => {
        await this.sendNecro();
        return necroApi.vows(this.character.id, clean);
      });
    } else this.markServerDirty(true);
    this.emit();
    return true;
  }

  /** Why a vow or boon can't be unlocked with shards (null = it can). */
  unlockProblem(key: string): string | null {
    const cost = unlockCost(key);
    if (!cost) return 'Nothing to unlock.';
    if (this.local.unlocks?.includes(key)) return 'Already unlocked.';
    return this.local.shards < cost ? `Needs ${cost} soul shards` : null;
  }

  /** Spend soul shards at the Altar to open a vow or a boon. */
  unlockAtAltar(key: string): boolean {
    if (this.unlockProblem(key)) return false;
    this.local.shards -= unlockCost(key)!;
    (this.local.unlocks ??= []).push(key);
    this.saveLocal();
    if (this.mode === 'server') {
      this.remote(async () => {
        await this.sendNecro();
        return necroApi.unlock(this.character.id, key);
      });
    } else this.markServerDirty(true);
    this.emit();
    return true;
  }

  /** Why a boon can't be bought (null = it can). */
  boonProblem(id: BoonId): string | null {
    const blocked = boonBlocked(id, this.local.boons, this.local.ascension, this.local.unlocks ?? []);
    if (blocked) return blocked;
    const cost = boonCost(id, this.local.boons)!;
    return this.local.ashes < cost ? `Needs ${cost} Ashes` : null;
  }

  buyBoon(id: BoonId): boolean {
    if (this.boonProblem(id)) return false;
    const cost = boonCost(id, this.local.boons)!;
    this.local.ashes -= cost;
    this.local.boons[id] = (this.local.boons[id] ?? 0) + 1;
    // Starting boons also take effect for the run in progress.
    if (id === 'first_rites') this.local.damageTier = Math.max(this.local.damageTier, this.boons.startDamageTier);
    this.saveLocal();
    this.remote(() => necroApi.boon(this.character.id, id));
    return true;
  }

  /** Kills needed in `area` to open the next seal (Swift Seals lowers it). */
  unlockKills(base: number) {
    return Math.max(1, Math.round(base * this.boons.unlockKillsMult));
  }

  recordPrelateKill() {
    this.local.bossKills++;
    this.local.run.prelateKills++;
    this.local.summonsPending = Math.max(0, (this.local.summonsPending ?? 0) - 1);
    this.pending.prelateKills++;
    this.saveLocal();
    if (this.mode === 'server') this.markServerDirty(true);
  }

  buyDamage(): boolean {
    const cost = this.damageCost();
    if (cost === null || !this.canAfford(cost)) return false;
    this.character.gold -= cost;
    this.chronicle?.add('gold.spent', cost);
    this.local.damageTier++;
    this.saveLocal();
    this.serverPurchase('damage', cost);
    return true;
  }

  /**
   * Server mode: gold stays client-authoritative (save-progress carries it), so
   * first bring the server's gold up to what we had *before* this purchase,
   * then let the server price and record the tier. The optimistic local
   * deduction already happened; the next regular save carries the new gold.
   */
  private serverPurchase(upgrade: 'damage' | 'wave' | 'legion', cost: number) {
    if (this.mode !== 'server') return this.markServerDirty(true);
    const goldBefore = (this.character.gold ?? 0) + cost;
    this.remote(async () => {
      const sent = { ...this.payload(), gold: Math.max(0, Math.round(goldBefore)) };
      await saveProgress(sent);
      this.ackReports(sent);
      const r = await necroApi.purchase(this.character.id, upgrade);
      this.markServerDirty(false);
      return r;
    });
  }

  buyWave(): boolean {
    const cost = this.waveCost();
    if (cost === null || !this.canAfford(cost)) return false;
    this.character.gold -= cost;
    this.chronicle?.add('gold.spent', cost);
    this.local.waveTierOwned++;
    this.local.waveTierActive = this.local.waveTierOwned;
    this.saveLocal();
    this.serverPurchase('wave', cost);
    return true;
  }

  /**
   * A gold spend the server prices and takes (Workbench reforge, Empowered summons). Gold is client-saved, so first bring the server's
   * copy up to ours (as a Damage tier does), then make the call, then adopt the gold in its reply, keeping anything picked up meanwhile.
   * Runs in the same queue as the other server mutations, one at a time. Throws the server's readable error unchanged.
   */
  spendOnServer<T extends { gold: number; cost?: number }>(call: () => Promise<T>): Promise<T> {
    return this.serial(async () => {
      await saveProgress(this.payload());
      const before = this.character.gold ?? 0;
      const reply = await call();
      const gained = (this.character.gold ?? 0) - before;
      this.character.gold = Math.max(0, Math.round(reply.gold + gained));
      if (reply.cost) this.chronicle?.add('gold.spent', reply.cost);
      if (gained !== 0) this.markServerDirty(false);
      this.emit();
      return reply;
    });
  }

  /** Reinforce the Legion one tier for gold (the thrall kit's gold sink). */
  buyLegion(): boolean {
    const cost = this.legionCost();
    if (cost === null || !this.canAfford(cost)) return false;
    this.character.gold -= cost;
    this.chronicle?.add('gold.spent', cost);
    this.local.legionTier = (this.local.legionTier ?? 0) + 1;
    this.saveLocal();
    this.serverPurchase('legion', cost);
    return true;
  }

  setActiveWaveTier(tier: number) {
    this.local.waveTierActive = Math.max(0, Math.min(this.local.waveTierOwned, tier));
    this.pendingWaveActive = true;
    this.saveLocal();
    if (this.mode === 'server') this.markServerDirty(false);
  }

  // --- Kills / unlocks / shards (local) ---

  /** Report a paid kill to the server (what died, where, how old, and the multipliers the reward used). Call it BEFORE the XP is added: a level-up saves at once. */
  reportKill(k: KillInput) {
    this.reporter.kill(k);
    if (this.reporter.crowded) void this.flushReports();
  }

  reportBoss(b: Omit<BossKill, 'n'>) {
    this.reporter.boss(b);
  }

  /** A Depths floor was cleared: the stair proves the next depth, so this goes out at once (the Chronicle's deepest-floor flush follows within seconds). */
  reportFloor(f: FloorClear) {
    this.reporter.floor(f);
    void this.flushReports();
  }

  /** Post whatever the reporter holds on its own. Never rejects: a failure keeps the batches for the next save. */
  async flushReports(keepalive = false): Promise<void> {
    const reports = this.reporter.batches();
    if (!reports.length) return;
    try {
      await reportKills(this.character.id, reports, keepalive);
      this.reporter.ack(reports[reports.length - 1].seq);
    } catch (err) {
      // An older server has no route (or the account cannot report): stop holding batches. Anything else is retried with the next save.
      if (err instanceof ApiError && (err.status === 404 || err.status === 400)) this.reporter.discard();
    }
  }

  recordKill(area: AreaId, waveTier = this.local.waveTierActive) {
    // Dev access walks into sealed halls and its kills are banked like anyone's (the server accepts staff kills past every seal).
    // Without dev access a sealed hall cannot be entered, so there is nothing to bank.
    if (!devAccess.active && !this.reallyUnlocked(area)) return;
    this.local.areaKills[area] = (this.local.areaKills[area] ?? 0) + 1;
    this.local.totalKills++;
    this.local.run.kills++;
    this.local.run.peakWaveTier = Math.max(this.local.run.peakWaveTier, waveTier);
    this.chronicle?.add('kills');
    this.chronicle?.add(`kills.${area}`);
    this.chronicle?.max('peak.wave', waveTier);
    this.pending.areaKills[area] = (this.pending.areaKills[area] ?? 0) + 1;
    this.pending.peakWaveTier = Math.max(this.pending.peakWaveTier, waveTier);
    if (this.mode === 'server') this.markServerDirty(false);
    this.saveLocalSoon();
  }

  kills(area: AreaId) {
    return this.local.areaKills[area] ?? 0;
  }

  isUnlocked(area: AreaId) {
    return devAccess.active || this.reallyUnlocked(area);
  }

  /** The saved truth, ignoring the dev overlay (kills only count where the character has really opened the seal). */
  reallyUnlocked(area: AreaId) {
    return isAlwaysOpen(area) || this.local.unlocked.includes(area);
  }

  unlock(area: AreaId) {
    // Check the saved truth: with dev access on, isUnlocked is always true and an earned seal would never be saved.
    if (this.reallyUnlocked(area)) return false;
    this.local.unlocked.push(area);
    this.saveLocal();
    return true;
  }

  addShards(n: number) {
    this.local.shards += n;
    this.pending.shards += n;
    this.saveLocal();
    if (this.mode === 'server') this.markServerDirty(false);
  }

  /** Pay soul shards at the Sundered Bell (the only shard spend today). */
  spendShards(n: number): boolean {
    if (this.local.shards < n) return false;
    this.local.shards -= n;
    this.local.summonsPending = (this.local.summonsPending ?? 0) + 1;
    this.saveLocal();
    if (this.mode === 'server') {
      // Shards picked up since the last save must reach the server before it charges them.
      this.remote(async () => {
        await this.sendNecro();
        return necroApi.summonPrelate(this.character.id);
      });
    }
    return true;
  }

  /** Area bosses: the boss's own cost, charged by the server's summon-boss rule (no Prelate summon is owed). */
  spendBossShards(boss: BossId): boolean {
    const n = BOSSES[boss].shards;
    if (this.local.shards < n) return false;
    this.local.shards -= n;
    this.saveLocal();
    if (this.mode === 'server') {
      this.remote(async () => {
        await this.sendNecro();
        return necroApi.summonBoss(this.character.id, boss);
      });
    }
    return true;
  }

  /** Give shards back when a summon never happened (another boss was already awake on the host). */
  refundBossShards(boss: BossId) {
    this.addShards(BOSSES[boss].shards);
  }

  /** Send gathered deltas now (server mode), after any request already out. A keepalive flush (tab closing) goes at once. */
  private flushNecro(keepalive = false): Promise<void> {
    return keepalive ? this.sendNecro(true) : this.serial(() => this.sendNecro());
  }

  /** The save itself, outside the queue (for callers already inside it). Failures put the unsent deltas back for the next try. */
  private async sendNecro(keepalive = false) {
    if (this.mode !== 'server' || !this.hasPending) return;
    // The kills this save claims must already be on the server's ledger (a keepalive flush is preceded by the progress save that carries them).
    if (!keepalive && this.reporter.hasPending) await this.flushReports();
    const sent = this.pending;
    const wave = this.pendingWaveActive;
    this.pending = emptyPending();
    this.pendingWaveActive = false;
    try {
      const r = await necroApi.save(this.character.id, { ...sent, ...(wave ? { waveTierActive: this.local.waveTierActive } : {}) }, keepalive);
      this.adopt(r.progress);
    } catch (err) {
      // Put the unsent deltas back in front of anything gathered meanwhile.
      for (const [a, n] of Object.entries(sent.areaKills)) this.pending.areaKills[a as AreaId] = (this.pending.areaKills[a as AreaId] ?? 0) + (n ?? 0);
      this.pending.shards += sent.shards;
      this.pending.prelateKills += sent.prelateKills;
      this.pending.peakWaveTier = Math.max(this.pending.peakWaveTier, sent.peakWaveTier);
      this.pendingWaveActive ||= wave;
      throw err;
    }
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
    if (urgent) {
      // An urgent save asked for while one is already in flight is not lost: flush() runs again the moment that one lands (it used to wait out the 45 s timer).
      if (this.inFlight) this.urgentAgain = true;
      else void this.flush();
    } else if (!this.timer) this.timer = window.setTimeout(() => this.flush(), 45000);
  }
  private urgentAgain = false;

  private payload() {
    const c = this.character;
    const killReports = this.reporter.batches();
    return {
      ...(killReports.length ? { killReports } : {}),
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

  /** The server has the kill batches a save carried: forget them (a failed save keeps them, and the retry repeats them with the same numbers). */
  private ackReports(sent: { killReports?: { seq: number }[] }) {
    const reports = sent.killReports;
    if (reports && reports.length) this.reporter.ack(reports[reports.length - 1].seq);
  }

  async flush(keepalive = false): Promise<void> {
    window.clearTimeout(this.timer);
    this.timer = 0;
    if (!this.dirtyServer) return;
    if (this.inFlight) {
      // The tab is closing and a save is already out (it may be cut off): push the newest gains now rather than skip them.
      if (!keepalive) return;
      this.dirtyServer = false;
      try {
        const sent = this.payload();
        await saveProgress(sent, true);
        this.ackReports(sent);
        await this.flushNecro(true);
      } catch {
        this.dirtyServer = true;
      }
      return;
    }
    this.inFlight = true;
    this.dirtyServer = false;
    this.saveState = 'saving';
    this.emit();
    try {
      const sent = this.payload();
      await saveProgress(sent, keepalive);
      this.ackReports(sent);
      await this.flushNecro(keepalive);
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
      const again = this.urgentAgain;
      this.urgentAgain = false;
      if (again && this.dirtyServer && this.saveState === 'dirty') void this.flush();
      else if (this.dirtyServer && this.saveState === 'dirty' && !this.timer) {
        this.timer = window.setTimeout(() => this.flush(), 45000);
      }
    }
  }

  /** Drain pending saves before changing scenes; leave the old class on failure. */
  async saveBeforeClassChange() {
    const deadline = performance.now() + 15000;
    while (this.inFlight || this.remoteInFlight) {
      if (performance.now() > deadline) throw new Error('Your progress is still saving. Please try again.');
      await new Promise<void>((resolve) => window.setTimeout(resolve, 50));
    }
    this.saveLocal();
    await this.flush();
    if (this.dirtyServer || this.saveState === 'retrying') throw new Error('Could not save your progress. Please try again before changing class.');
    await this.flushNecro();
  }

  dispose() {
    window.clearTimeout(this.timer);
    window.clearTimeout(this.localTimer);
    this.saveLocal();
    void this.flush(true);
    this.listeners.clear();
  }
}
