import { SOUL_HARVEST } from '../content/abilities';
import type { AreaId } from '../content/areas';
import type { DerivedStats } from './characterStats';
import type { Nav } from './nav';

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
  essence = 50;
  barrier = 0;
  alive = true;
  area: AreaId | null = 'chapterhouse';
  lastHurtAt = -1e9;
  rootedUntil = 0;
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
  ) {
    this.hp = stats.maxHp;
    this.essence = stats.maxEssence * 0.6;
  }

  setStats(stats: DerivedStats) {
    const hpFrac = this.hp / this.stats.maxHp;
    this.stats = stats;
    this.hp = Math.min(stats.maxHp, Math.max(1, Math.round(stats.maxHp * hpFrac)));
    this.essence = Math.min(stats.maxEssence, this.essence);
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
  update(dt: number, now: number, keyDir: { x: number; z: number } | null): boolean {
    this.moving = false;
    if (!this.alive) return false;
    // Regeneration: brisk out of combat, a trickle in it.
    const ooc = now - this.lastHurtAt > OUT_OF_COMBAT_MS;
    this.hp = Math.min(this.stats.maxHp, this.hp + this.stats.maxHp * (ooc ? 0.045 : 0.004) * dt);
    this.essence = Math.min(this.stats.maxEssence, this.essence + this.stats.essenceRegen * dt);
    this.barrier = Math.max(0, this.barrier - this.stats.maxHp * 0.04 * dt);
    if (now < this.rootedUntil) return false;

    const speed = this.stats.moveSpeed;
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

  /** Apply incoming damage through barrier + Bone Ward. Returns damage taken. */
  takeDamage(raw: number, wardPct: number, now: number): number {
    if (!this.alive || this.god) return 0;
    let dmg = raw * (1 - Math.min(0.6, wardPct));
    const absorbed = Math.min(this.barrier, dmg);
    this.barrier -= absorbed;
    dmg -= absorbed;
    this.hp -= dmg;
    this.lastHurtAt = now;
    if (this.hp <= 0) {
      this.hp = 0;
      this.alive = false;
      this.path = [];
    }
    return dmg;
  }

  heal(amount: number) {
    if (!this.alive) return;
    this.hp = Math.min(this.stats.maxHp, this.hp + amount);
  }

  revive() {
    this.alive = true;
    this.hp = this.stats.maxHp;
    this.essence = this.stats.maxEssence * 0.5;
    this.barrier = 0;
  }
}
