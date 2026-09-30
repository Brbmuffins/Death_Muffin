import { BULWARK, KNIGHT_RAGE, SOUL_HARVEST } from '../content/abilities';
import { CHILL } from '../content/statuses';
import type { AreaId } from '../content/areas';
import type { ClassFamily } from '../content/disciplines';
import type { DerivedStats } from './characterStats';
import type { Nav } from './nav';
import { resourceRulesFor, type ResourceKind, type ResourceRules } from './resources';
import { brewValue, emptyBrews, type ActiveBrews, type BrewKind } from '../content/brews';

const OUT_OF_COMBAT_MS = 5000;

/**
 * The local player's body and resources. Movement is client-simulated and
 * reported to the host; health changes arrive as `hurt` events.
 */
export class Player {
  x = 0;
  z = 0;
  facing = Math.PI;
  moving = false;
  hp = 100;
  /**
   * The family resource (Grave Essence, Rage, Oil, …). `essence` below is kept
   * as an alias so the necromancer call sites — and their tests — are untouched.
   */
  resource: { kind: ResourceKind; value: number; max: number };
  /** Veilwalker form. The short Between Worlds window shares its protection. */
  veilForm = false;
  betweenUntil = 0;
  lastResourceGainAt = 0;
  private clockNow = 0;
  private readonly rules: ResourceRules;
  barrier = 0;
  /** Bone Mantle holds the barrier until this time (scene ms); it decays as usual after. */
  barrierHoldUntil = 0;
  /** Hollow Knight — Bulwark: the shield is up until this time, perfect until the earlier one. */
  bulwarkUntil = 0;
  bulwarkPerfectUntil = 0;
  /** Hollow Knight — Oath Unbroken: cannot drop below 1 health until this time. */
  unbreakableUntil = 0;
  /** How Bulwark answered the last blow, for the caller's reflect + Rage. */
  lastBlock: 'none' | 'front' | 'perfect' = 'none';
  alive = true;
  area: AreaId | null = 'chapterhouse';
  lastHurtAt = -1e9;
  rootedUntil = 0;
  /** Flood Hymn's Chill slows movement until this scene time (ms). */
  chilledUntil = 0;
  /** Shared recovery between spells; independent of each spell's cooldown. */
  castUntil = 0;
  /** DEV QA only (window.__cwDebug.god). */
  god = false;
  /** Soul Harvest meter (client-side): kills credited to you or your thralls. */
  souls = 0;
  /** Souls needed to charge the meter (Soul Hunger boons lower it). */
  soulsMax = SOUL_HARVEST.souls;
  /** Queued waypoints for click-to-move (door-aware). */
  private path: { x: number; z: number }[] = [];
  readonly cooldowns = new Map<string, number>();

  constructor(
    public stats: DerivedStats,
    private nav: Nav,
    family: ClassFamily = 'necromancer',
  ) {
    this.rules = resourceRulesFor(family);
    const max = this.rules.max(stats);
    this.resource = { kind: this.rules.kind, value: this.rules.initial(max), max };
    this.hp = stats.maxHp;
  }

  /** Alias for `resource.value` — the necromancer's Grave Essence. */
  get essence() {
    return this.resource.value;
  }

  set essence(value: number) {
    this.resource.value = value;
  }

  /** Add to (or drain) the family resource, clamped to 0..max. */
  addResource(amount: number) {
    if (amount > 0 && this.resource.kind === 'resonance') this.lastResourceGainAt = this.clockNow;
    this.resource.value = Math.max(0, Math.min(this.resource.max, this.resource.value + amount));
  }

  setStats(stats: DerivedStats) {
    const hpFrac = this.hp / this.stats.maxHp;
    this.stats = stats;
    this.hp = Math.min(stats.maxHp, Math.max(1, Math.round(stats.maxHp * hpFrac)));
    this.resource.max = this.rules.max(stats);
    this.resource.value = Math.min(this.resource.max, this.resource.value);
  }

  teleport(x: number, z: number) {
    [this.x, this.z] = this.nav.resolve(x, z, 0.45);
    this.path = [];
    this.area = this.nav.areaAt(this.x, this.z);
  }

  moveTo(x: number, z: number) {
    const destination = this.destination;
    if (destination && Math.hypot(destination.x - x, destination.z - z) < 0.35) return;
    this.path = this.nav.route(this.x, this.z, x, z);
  }

  /** Follow precomputed waypoints (Nav.findPath — used when walking up to a gathering node). */
  moveAlong(path: { x: number; z: number }[]) {
    this.path = path.map((p) => ({ x: p.x, z: p.z }));
  }

  stop() {
    this.path = [];
  }

  get hasPath() {
    return this.path.length > 0;
  }

  get destination() {
    return this.path[this.path.length - 1] ?? null;
  }

  onCooldown(id: string, now: number) {
    return (this.cooldowns.get(id) ?? 0) > now;
  }

  cooldownLeft(id: string, now: number) {
    return Math.max(0, (this.cooldowns.get(id) ?? 0) - now);
  }

  /** Full meter: the next Marrow Spear / Miasma / Black Litany is free and 50% larger. */
  get soulsCharged() {
    return this.souls >= this.soulsMax;
  }

  /** Add harvested souls; returns true on the kill that fills the meter. */
  addSouls(n = 1): boolean {
    if (this.soulsCharged) return false;
    this.souls = Math.min(this.soulsMax, this.souls + n);
    return this.soulsCharged;
  }

  /** Spend a charged meter. */
  spendSouls() {
    this.souls = 0;
  }

  /** Walk the path, or step along a WASD direction. Returns true if moved. */
  /** Scene-set movement multiplier (the Drowned Congregation's rising water, a Swiftness Flask). */
  moveMult = 1;
  /** The active elixir and tonic (content/brews.ts). Local-only; never sent to the realtime host. */
  brews: ActiveBrews = emptyBrews();
  /** Summed value of one brew effect kind at `now` (0 when none is active). */
  brewValue(kind: BrewKind, now: number) {
    return brewValue(this.brews, kind, now);
  }

  update(dt: number, now: number, keyDir: { x: number; z: number } | null): boolean {
    this.clockNow = now;
    this.moving = false;
    if (!this.alive) return false;
    // Regeneration: brisk out of combat, a trickle in it.
    const ooc = now - this.lastHurtAt > OUT_OF_COMBAT_MS;
    this.hp = Math.min(this.stats.maxHp, this.hp + this.stats.maxHp * (ooc ? 0.045 : 0.004) * dt);
    const essenceBoost = this.brews.tonic ? brewValue(this.brews, 'essence', now) : 0;
    // Family resource drift. For the necromancer this is `stats.essenceRegen`
    // every frame, exactly as before; Rage instead decays out of combat.
    this.addResource(
      (this.resource.kind === 'veil' && this.veilForm ? -12 : this.rules.passive({
        // Tonic of essence: the regen rate grows while it lasts (only allocates while the brew is active).
        stats: essenceBoost ? { ...this.stats, essenceRegen: this.stats.essenceRegen * (1 + essenceBoost) } : this.stats,
        value: this.resource.value,
        max: this.resource.max,
        sinceHurtMs: now - this.lastHurtAt,
        sinceResourceGainMs: now - this.lastResourceGainAt,
      })) * dt,
    );
    if (this.resource.kind === 'veil' && this.resource.value <= 0) this.veilForm = false;
    if (now >= this.barrierHoldUntil) this.barrier = Math.max(0, this.barrier - this.stats.maxHp * 0.04 * dt);
    if (now < this.rootedUntil) return false;

    const speed = this.stats.moveSpeed * (this.veilForm || now < this.betweenUntil ? 1.2 : 1) * this.moveMult * (now < this.chilledUntil ? CHILL.moveMult : 1);
    let dx = 0;
    let dz = 0;
    if (keyDir && (keyDir.x || keyDir.z)) {
      this.path = [];
      const len = Math.hypot(keyDir.x, keyDir.z);
      dx = (keyDir.x / len) * speed * dt;
      dz = (keyDir.z / len) * speed * dt;
    } else if (this.path.length) {
      while (this.path.length && Math.hypot(this.path[0].x - this.x, this.path[0].z - this.z) < 0.2) this.path.shift();
      if (!this.path.length) return false;
      const wp = this.path[0];
      const ddx = wp.x - this.x;
      const ddz = wp.z - this.z;
      const d = Math.hypot(ddx, ddz);
      const step = Math.min(d, speed * dt);
      dx = (ddx / d) * step;
      dz = (ddz / d) * step;
    }
    if (!dx && !dz) return false;
    const [nx, nz] = this.nav.resolve(this.x + dx, this.z + dz, 0.45);
    const moved = Math.hypot(nx - this.x, nz - this.z);
    // Stuck against geometry while path-following: give up this waypoint.
    if (moved < speed * dt * 0.1 && this.path.length) this.path.shift();
    if (moved > 1e-4) {
      this.facing = Math.atan2(nx - this.x, nz - this.z);
      this.moving = true;
    }
    this.x = nx;
    this.z = nz;
    this.area = this.nav.areaAt(this.x, this.z) ?? this.area;
    return this.moving;
  }

  face(x: number, z: number) {
    this.facing = Math.atan2(x - this.x, z - this.z);
  }

  /**
   * Apply incoming damage through barrier + Bone Ward, then the Hollow Knight's
   * guards. Returns damage taken; `lastBlock` reports how Bulwark answered it so
   * the caller can reflect and pay Rage.
   *
   * `from` is where the blow came from — Bulwark only covers the front, so
   * without it a guarded hit is treated as coming from behind (no mitigation).
   */
  takeDamage(raw: number, wardPct: number, now: number, from?: { x: number; z: number }, source?: string): number {
    this.lastBlock = 'none';
    if (!this.alive || this.god) return 0;
    if (this.resource.kind === 'veil' && source !== 'toxic' && source !== 'burn' && (this.veilForm || now < this.betweenUntil)) return 0;
    let dmg = raw * (1 - Math.min(0.6, wardPct));
    if (now < this.bulwarkUntil && this.blowIsFrontal(from)) {
      this.lastBlock = now < this.bulwarkPerfectUntil ? 'perfect' : 'front';
      dmg *= 1 - BULWARK.damageCut;
    }
    const absorbed = Math.min(this.barrier, dmg);
    this.barrier -= absorbed;
    dmg -= absorbed;
    this.hp -= dmg;
    this.lastHurtAt = now;
    // Rage is built by punishment: +1 per 1% of max health lost.
    if (this.resource.kind === 'rage' && dmg > 0) {
      this.addResource((dmg / this.stats.maxHp) * 100 * KNIGHT_RAGE.perHpPercentLost);
    }
    if (this.lastBlock === 'perfect') this.addResource(KNIGHT_RAGE.perPerfectBlock);
    if (this.hp <= 0) {
      // Oath Unbroken: the oath holds at a sliver rather than breaking.
      if (now < this.unbreakableUntil) {
        this.hp = 1;
      } else {
        this.hp = 0;
        this.alive = false;
        this.path = [];
      }
    }
    return dmg;
  }

  /** Inside Bulwark's frontal cover (the front 120°)? */
  private blowIsFrontal(from?: { x: number; z: number }) {
    if (!from) return false;
    const dx = from.x - this.x;
    const dz = from.z - this.z;
    const len = Math.hypot(dx, dz);
    if (len < 1e-6) return true;
    const dot = (Math.sin(this.facing) * dx + Math.cos(this.facing) * dz) / len;
    return dot >= Math.cos((BULWARK.frontHalfDeg * Math.PI) / 180);
  }

  heal(amount: number) {
    if (!this.alive) return;
    this.hp = Math.min(this.stats.maxHp, this.hp + amount);
  }

  revive() {
    this.alive = true;
    this.chilledUntil = 0;
    this.hp = this.stats.maxHp;
    this.resource.value = this.rules.onRevive(this.resource.max);
    this.barrier = 0;
  }
}
