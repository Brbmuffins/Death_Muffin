/**
 * Server-side boss simulation (host only). The Void Warden has three phases:
 * Phase 1 (>50% HP): slow advance + ground slams.
 * Phase 2 (25–50%): adds void bolt barrages.
 * Phase 3 (<25%): enrages — full speed + both attacks faster.
 */

export interface BossState {
  hp: number;
  maxHp: number;
  phase: 1 | 2 | 3;
  x: number;
  z: number;
  alive: boolean;
}

export interface BossEvent {
  type: 'slam' | 'bolt' | 'enrage';
  x: number;
  z: number;
  targetX?: number;
  targetZ?: number;
}

const BOSS_ROOM_RADIUS = 12;
const SLAM_INTERVAL: Record<number, number> = { 1: 4000, 2: 3000, 3: 2000 };
const BOLT_INTERVAL: Record<number, number> = { 1: Infinity, 2: 2500, 3: 1500 };
const MOVE_SPEED: Record<number, number> = { 1: 1.5, 2: 2.5, 3: 3.5 };
const CONTACT_RANGE = 3.0;

export class BossSimulation {
  private hp = 800;
  readonly maxHp = 800;
  private phase: 1 | 2 | 3 = 1;
  private x = 0;
  private z = 0;
  private alive = true;
  private lastSlam = 0;
  private lastBolt = 0;
  private enrageEmitted = false;
  private playerPositions = new Map<string, { x: number; z: number }>();

  setPlayerPos(id: string, pos: { x: number; z: number }) {
    this.playerPositions.set(id, pos);
  }

  removePlayer(id: string) {
    this.playerPositions.delete(id);
  }

  applyHit(dmg: number): void {
    if (!this.alive) return;
    this.hp = Math.max(0, this.hp - dmg);
    if (this.hp === 0) { this.alive = false; return; }
    const ratio = this.hp / this.maxHp;
    if (ratio <= 0.25 && this.phase < 3) this.phase = 3;
    else if (ratio <= 0.5 && this.phase < 2) this.phase = 2;
  }

  tick(now: number, dt: number): BossEvent[] {
    if (!this.alive) return [];
    const events: BossEvent[] = [];

    const nearest = this.nearestPlayer();
    if (nearest) {
      const dx = nearest.x - this.x;
      const dz = nearest.z - this.z;
      const dist = Math.sqrt(dx * dx + dz * dz);
      if (dist > CONTACT_RANGE) {
        const speed = MOVE_SPEED[this.phase];
        this.x += (dx / dist) * speed * dt;
        this.z += (dz / dist) * speed * dt;
        const r = Math.sqrt(this.x * this.x + this.z * this.z);
        if (r > BOSS_ROOM_RADIUS) {
          this.x = (this.x / r) * BOSS_ROOM_RADIUS;
          this.z = (this.z / r) * BOSS_ROOM_RADIUS;
        }
      }
    }

    if (now - this.lastSlam >= SLAM_INTERVAL[this.phase]) {
      this.lastSlam = now;
      events.push({ type: 'slam', x: this.x, z: this.z });
    }

    if (this.phase >= 2 && nearest && now - this.lastBolt >= BOLT_INTERVAL[this.phase]) {
      this.lastBolt = now;
      events.push({ type: 'bolt', x: this.x, z: this.z, targetX: nearest.x, targetZ: nearest.z });
    }

    if (this.phase === 3 && !this.enrageEmitted) {
      this.enrageEmitted = true;
      events.push({ type: 'enrage', x: this.x, z: this.z });
    }

    return events;
  }

  getState(): BossState {
    return { hp: this.hp, maxHp: this.maxHp, phase: this.phase, x: this.x, z: this.z, alive: this.alive };
  }

  private nearestPlayer(): { x: number; z: number } | null {
    let best: { x: number; z: number } | null = null;
    let bestDist = Infinity;
    for (const pos of this.playerPositions.values()) {
      const d = (pos.x - this.x) ** 2 + (pos.z - this.z) ** 2;
      if (d < bestDist) { bestDist = d; best = pos; }
    }
    return best;
  }
}
