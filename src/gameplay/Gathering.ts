import type { GatherReply } from '../net/api';
import { devAccess } from './devAccess';
import type { Profession } from '../net/types';
import { NODE_REACH, type NodePlacement } from '../content/layout';
import {
  ALL_SKILLS,
  GATHER_FLUSH_MS,
  GATHER_MAX_BATCH,
  LEVEL_CAP,
  NODES,
  actionMs,
  addSkillXp,
  successChance,
  xpToNext,
  type NodeDef,
  type SkillId,
} from './gatheringRules';
import { gatherBlocker, nextAutoNode, standSpot, type Blocker, type GatherStop, type LiveNode } from './gatherPlan';

/**
 * The skilling side of a character: levels per skill (server truth from
 * /api/professions and every /api/gather reply) plus the XP the client has
 * shown optimistically but the server hasn't confirmed yet.
 */
export class Skills {
  private levels = new Map<SkillId, { level: number; xp: number }>();
  /** Optimistic XP per skill since the last reply (display only). */
  private pendingXp = new Map<SkillId, number>();
  private listeners = new Set<() => void>();

  constructor(rows: Profession[] = []) {
    this.adopt(rows);
  }

  onChange(fn: () => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit() {
    this.listeners.forEach((fn) => fn());
  }

  /** Server rows win. Skills the server has no row for are level 1. */
  adopt(rows: Profession[], clearPendingFor?: SkillId) {
    for (const r of rows) {
      if (!(ALL_SKILLS as string[]).includes(r.profession_id)) continue;
      this.levels.set(r.profession_id as SkillId, { level: Math.max(1, r.skill_level), xp: Math.max(0, r.skill_xp) });
    }
    if (clearPendingFor) this.pendingXp.delete(clearPendingFor);
    this.emit();
  }

  get(skill: SkillId) {
    return this.levels.get(skill) ?? { level: 1, xp: 0 };
  }

  level(skill: SkillId) {
    return this.get(skill).level;
  }

  /** The level tier gates compare against: the real level, or the cap under dev access (never saved). */
  gateLevel(skill: SkillId) {
    return devAccess.active ? LEVEL_CAP : this.level(skill);
  }

  /** Level/XP including optimistic XP, for bars and floating text. */
  shown(skill: SkillId) {
    const p = addSkillXp(this.get(skill), this.pendingXp.get(skill) ?? 0);
    return { level: p.level, xp: p.xp, next: xpToNext(p.level) };
  }

  addPending(skill: SkillId, xp: number) {
    this.pendingXp.set(skill, (this.pendingXp.get(skill) ?? 0) + xp);
    this.emit();
  }

  total() {
    return ALL_SKILLS.reduce((n, s) => n + this.level(s), 0);
  }

  rows(): Profession[] {
    return ALL_SKILLS.map((s) => ({ profession_id: s, skill_level: this.level(s), skill_xp: this.get(s).xp }));
  }
}

export interface GatherHooks {
  now(): number;
  /** Seeded or Math.random. */
  rand(): number;
  nav: Blocker & { findPath(fx: number, fz: number, tx: number, tz: number): { x: number; z: number }[] };
  player: {
    x: number;
    z: number;
    readonly hasPath: boolean;
    readonly moving: boolean;
    moveAlong(path: { x: number; z: number }[]): void;
    face(x: number, z: number): void;
    stop(): void;
  };
  /** Live node lookup (host sim or guest mirror). */
  nodes(): Iterable<LiveNode>;
  live(id: string): boolean;
  /** Whether one more of `itemId` fits in the bag. */
  bagFits(itemId: string): boolean;
  /** Tell the host sim a work cycle landed (depletion). */
  sendSuccess(nodeId: string): void;
  post(nodeType: string, actions: number, keepalive?: boolean, afk?: boolean): Promise<GatherReply>;
  /** Presentation: gesture, floating text, sound. */
  onCycle(def: NodeDef, success: boolean, node: NodePlacement): void;
  onReply(reply: GatherReply): void;
  onStop(reason: GatherStop | 'unreachable' | 'blocked', message?: string): void;
  onError(message: string): void;
  autoEnabled(): boolean;
}

/** How far past the stand ring the hero may drift before work stops. */
const WORK_SLACK = 1.0;

type Phase = 'walk' | 'work' | 'wait';

/**
 * Click → walk to the node's ring → face → loop the gesture → roll each cycle
 * for feel → batch the cycles to /api/gather → adopt the server's answer.
 * Auto moves to the nearest live node of the same kind when this one depletes.
 */
export class GatherLoop {
  node: NodePlacement | null = null;
  afk = false;
  /** Why work last stopped, and the recent history (QA/diagnostics: nothing may end AFK on a resume). */
  lastStopReason: string | null = null;
  readonly stopLog: { reason: string; at: number }[] = [];
  private lastStop = 'Paused';
  private phase: Phase = 'walk';
  private cycleT = 0;
  private spot: { x: number; z: number } | null = null;
  private queue = new Map<string, number>();
  private lastFlush = 0;
  private inFlight = false;
  private pending: Promise<void> | null = null;
  private retryAt = 0;
  private walkRetries = 0;

  constructor(
    private hooks: GatherHooks,
    readonly skills: Skills,
  ) {}

  get active() {
    return this.node !== null;
  }

  get working() {
    return this.node !== null && this.phase === 'work';
  }

  get status() {
    return this.node ? `${this.phase === 'wait' ? 'Waiting for respawn' : this.phase === 'walk' ? 'Walking to' : 'Working'}: ${NODES[this.node.type].name}` : this.lastStop;
  }

  startAfk(node: NodePlacement) {
    const refusal = this.start(node);
    if (!refusal) this.afk = true;
    return refusal;
  }

  /** 0..1 progress through the current work cycle (progress arc). */
  get progress() {
    if (!this.node || this.phase !== 'work') return 0;
    return Math.min(1, this.cycleT / actionMs(NODES[this.node.type]));
  }

  /** Start working a node (a click, or Auto). Returns a player-readable refusal, or null. */
  start(node: NodePlacement): string | null {
    const def = NODES[node.type];
    const block = gatherBlocker(node.type, this.skills.gateLevel(def?.skill ?? 'woodcutting'));
    if (block) return block;
    if (!this.hooks.bagFits(def.item)) return 'Your bag is full.';
    if (!this.hooks.live(node.id)) return this.startWaiting(node);
    const h = this.hooks;
    const spot = standSpot(h.nav, node, h.player.x, h.player.z);
    if (!spot) return 'You cannot reach that.';
    this.node = node;
    this.spot = spot;
    this.cycleT = 0;
    this.walkRetries = 0;
    if (Math.hypot(spot.x - h.player.x, spot.z - h.player.z) < 0.35) this.beginWork();
    else {
      this.phase = 'walk';
      h.player.moveAlong(h.nav.findPath(h.player.x, h.player.z, spot.x, spot.z));
    }
    return null;
  }

  private startWaiting(node: NodePlacement) {
    this.node = node;
    this.phase = 'wait';
    this.spot = standSpot(this.hooks.nav, node, this.hooks.player.x, this.hooks.player.z);
    if (this.spot) this.hooks.player.moveAlong(this.hooks.nav.findPath(this.hooks.player.x, this.hooks.player.z, this.spot.x, this.spot.z));
    return null;
  }

  private beginWork() {
    const n = this.node!;
    this.phase = 'work';
    this.cycleT = 0;
    this.hooks.player.stop();
    this.hooks.player.face(n.x, n.z);
  }

  stop(reason: GatherStop | 'unreachable' | 'blocked', message?: string) {
    if (!this.node) return;
    this.lastStopReason = reason;
    this.stopLog.push({ reason, at: Date.now() });
    if (this.stopLog.length > 20) this.stopLog.shift();
    this.node = null;
    this.spot = null;
    this.lastStop = reason === 'bagFull' ? 'Bag full — make room, then Start AFK again.' : message ?? 'Paused';
    this.hooks.onStop(reason, message);
    void this.flush();
    this.afk = false;
  }

  update(dt: number) {
    const h = this.hooks;
    const now = h.now();
    if (this.queue.size && !this.inFlight && now >= this.retryAt && (now - this.lastFlush >= GATHER_FLUSH_MS || this.queuedTotal() >= GATHER_MAX_BATCH)) void this.flush();
    const n = this.node;
    if (!n) return;
    const def = NODES[n.type];
    if (!h.bagFits(def.item)) return this.stop('bagFull');
    if (this.phase === 'walk' || this.phase === 'wait') {
      if (h.player.hasPath) return;
      const d = this.spot ? Math.hypot(this.spot.x - h.player.x, this.spot.z - h.player.z) : Infinity;
      if (d > 0.6) {
        // AFK work is unattended: a walk that ended short (a path cut by a push or an unlucky hop between nodes) gets a few
        // fresh routes before the hero gives up. Hands-on work still stops at once.
        if (this.afk && this.spot && this.walkRetries < 3) {
          this.walkRetries++;
          h.player.moveAlong(h.nav.findPath(h.player.x, h.player.z, this.spot.x, this.spot.z));
          return;
        }
        return this.stop('unreachable', 'You cannot reach that.');
      }
      this.walkRetries = 0;
      if (this.phase === 'wait') {
        h.player.face(n.x, n.z);
        if (h.live(n.id)) this.beginWork();
        return;
      }
      this.beginWork();
      return;
    }
    // Working. Safety net: the hero must still be standing at the node. Any move (input
    // we missed, a push, a teleport) ends the work instead of "cutting" from across the map.
    if (h.player.hasPath || Math.hypot(n.x - h.player.x, n.z - h.player.z) > NODE_REACH[def.kind] + WORK_SLACK) return this.stop('moved');
    if (!h.live(n.id)) return this.onDepleted(n);
    this.cycleT += dt * 1000;
    if (this.cycleT < actionMs(def)) return;
    this.cycleT -= actionMs(def);
    this.queue.set(n.type, (this.queue.get(n.type) ?? 0) + 1);
    const success = h.rand() < successChance(def, Math.max(def.level, this.skills.level(def.skill)));
    if (success) {
      this.skills.addPending(def.skill, def.xp);
      h.sendSuccess(n.id);
    }
    h.onCycle(def, success, n);
  }

  private onDepleted(n: NodePlacement) {
    const def = NODES[n.type];
    if (this.afk || this.hooks.autoEnabled()) {
      const next = nextAutoNode({ from: n, nodes: this.hooks.nodes(), level: this.skills.gateLevel(def.skill), x: this.hooks.player.x, z: this.hooks.player.z });
      if (next) {
        const refusal = this.start(next);
        if (refusal) this.stop('blocked', refusal);
        return;
      }
      // Nothing else live of this kind: wait here for it to come back.
      this.phase = 'wait';
      return;
    }
    this.stop('blocked', `The ${def.name} is spent.`);
  }

  private queuedTotal() {
    let n = 0;
    for (const v of this.queue.values()) n += v;
    return n;
  }

  /** Send queued cycles (one request per node type). `keepalive` for tab close. */
  flush(keepalive = false): Promise<void> {
    if (this.pending) {
      // Tab closing with a batch already out (it may be cut off): send what queued since instead of skipping it.
      if (!keepalive || !this.queue.size) return this.pending;
      return Promise.all([this.pending, this.flushBatch(true, true)]).then(() => undefined);
    }
    this.pending = this.flushBatch(keepalive).finally(() => { this.pending = null; });
    return this.pending;
  }

  /**
   * Send everything queued, including cycles a long catch-up queued while a request was already in flight.
   * Stops early after an offline/server hiccup (those cycles stay queued for the normal retry).
   */
  async drain(): Promise<void> {
    for (let i = 0; i < 8; i++) {
      await this.flush();
      if (!this.queue.size || this.hooks.now() < this.retryAt) return;
    }
  }

  private async flushBatch(keepalive: boolean, alongside = false): Promise<void> {
    if ((this.inFlight && !alongside) || !this.queue.size) return;
    const owned = !alongside;
    if (owned) this.inFlight = true;
    this.lastFlush = this.hooks.now();
    const batch = [...this.queue];
    const afk = this.afk;
    this.queue.clear();
    try {
      for (const [type, count] of batch) {
        for (let left = count; left > 0; left -= GATHER_MAX_BATCH) {
          const actions = Math.min(GATHER_MAX_BATCH, left);
          try {
            const reply = await this.hooks.post(type, actions, keepalive, afk);
            this.skills.adopt(reply.skills, reply.skill as SkillId);
            this.hooks.onReply(reply);
          } catch (err) {
            const e = err as { message?: string; status?: number };
            if (e.status === 0 || (e.status ?? 0) >= 500) {
              // Offline or server hiccup: keep the cycles and retry later.
              this.queue.set(type, (this.queue.get(type) ?? 0) + left);
              this.retryAt = this.hooks.now() + 10_000;
              break;
            }
            // A refusal (level, budget, unknown node) is final for these cycles; the server's words are player-readable.
            const skill = NODES[type]?.skill;
            if (skill) this.skills.adopt([], skill);
            this.hooks.onError(e.message ?? 'Gathering failed');
            break;
          }
        }
      }
    } finally {
      if (owned) this.inFlight = false;
    }
  }
}
