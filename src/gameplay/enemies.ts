/**
 * Enemy simulation — runs on the arena host client only; other clients render
 * the state the host broadcasts. Documented simplifications (per build plan):
 * waypoint patrol instead of NavMesh pathfinding, client-authoritative combat
 * (acceptable for PvE co-op; a known risk if PvP ever matters).
 */

export interface EnemyState {
  id: number;
  x: number;
  z: number;
  hp: number;
  maxHp: number;
  aggroTargetId: string | null; // socket id (or 'self' offline)
  alive: boolean;
}

export interface PlayerPos {
  id: string;
  x: number;
  z: number;
}

export const ENEMY_COUNT = 4;
export const ENEMY_MAX_HP = 30;
export const AGGRO_RANGE = 5;
export const ENEMY_ATTACK_RANGE = 1.4;
export const ENEMY_RESPAWN_MS = 8000;
const PATROL_SPEED = 1.6;
const CHASE_SPEED = 2.8;
const PATROL_RADIUS = 2.5;
// Leash: enemies give up and walk home when dragged too far — prevents the
// whole pack camping the arena entrance and death-looping respawning players.
const LEASH_RADIUS = 7;

interface EnemySim extends EnemyState {
  homeX: number;
  homeZ: number;
  patrolAngle: number;
  diedAt: number;
}

export class EnemySimulation {
  enemies: EnemySim[] = [];

  constructor(arenaRadius: number) {
    // Homes on the far (-z) half only — with the leash, enemies can never
    // reach the entrance/respawn point at +z.
    for (let i = 0; i < ENEMY_COUNT; i++) {
      const angle = Math.PI * (1.15 + (0.7 * (i + 0.5)) / ENEMY_COUNT);
      const r = arenaRadius * 0.55;
      this.enemies.push({
        id: i,
        homeX: Math.cos(angle) * r,
        homeZ: Math.sin(angle) * r - arenaRadius * 0.2,
        x: 0,
        z: 0,
        hp: ENEMY_MAX_HP,
        maxHp: ENEMY_MAX_HP,
        aggroTargetId: null,
        alive: true,
        patrolAngle: Math.random() * Math.PI * 2,
        diedAt: 0,
      });
      const e = this.enemies[i];
      e.x = e.homeX;
      e.z = e.homeZ;
    }
  }

  /** Advance the sim. Returns ids of enemies that died this tick. */
  update(dt: number, players: PlayerPos[], now: number): number[] {
    const deaths: number[] = [];
    for (const e of this.enemies) {
      if (!e.alive) {
        if (now - e.diedAt >= ENEMY_RESPAWN_MS) {
          e.alive = true;
          e.hp = e.maxHp;
          e.x = e.homeX;
          e.z = e.homeZ;
          e.aggroTargetId = null;
        }
        continue;
      }

      if (e.hp <= 0) {
        e.alive = false;
        e.diedAt = now;
        e.aggroTargetId = null;
        deaths.push(e.id);
        continue;
      }

      // Aggro: nearest player within range, drop when far outside it.
      let nearest: PlayerPos | null = null;
      let nearestD = Infinity;
      for (const p of players) {
        const d = Math.hypot(p.x - e.x, p.z - e.z);
        if (d < nearestD) {
          nearestD = d;
          nearest = p;
        }
      }
      const homeDist = Math.hypot(e.x - e.homeX, e.z - e.homeZ);
      if (homeDist > LEASH_RADIUS) e.aggroTargetId = null;
      else if (nearest && nearestD <= AGGRO_RANGE) e.aggroTargetId = nearest.id;
      else if (e.aggroTargetId && nearestD > AGGRO_RANGE * 1.8) e.aggroTargetId = null;

      const target = e.aggroTargetId ? players.find((p) => p.id === e.aggroTargetId) : null;
      if (target) {
        const dx = target.x - e.x;
        const dz = target.z - e.z;
        const d = Math.hypot(dx, dz);
        if (d > ENEMY_ATTACK_RANGE * 0.8) {
          e.x += (dx / d) * CHASE_SPEED * dt;
          e.z += (dz / d) * CHASE_SPEED * dt;
        }
      } else if (homeDist > PATROL_RADIUS + 0.3) {
        // Walk home (heals on the way back so campers can't cheese it).
        e.x += ((e.homeX - e.x) / homeDist) * CHASE_SPEED * dt;
        e.z += ((e.homeZ - e.z) / homeDist) * CHASE_SPEED * dt;
        e.hp = Math.min(e.maxHp, e.hp + e.maxHp * 0.5 * dt);
      } else {
        // Circle around home.
        e.patrolAngle += (PATROL_SPEED / PATROL_RADIUS) * dt;
        e.x = e.homeX + Math.cos(e.patrolAngle) * PATROL_RADIUS;
        e.z = e.homeZ + Math.sin(e.patrolAngle) * PATROL_RADIUS;
      }
    }
    return deaths;
  }

  applyHit(enemyId: number, damage: number) {
    const e = this.enemies.find((en) => en.id === enemyId);
    if (e && e.alive) e.hp -= damage;
  }

  snapshot(): EnemyState[] {
    return this.enemies.map(({ id, x, z, hp, maxHp, aggroTargetId, alive }) => ({
      id,
      x,
      z,
      hp,
      maxHp,
      aggroTargetId,
      alive,
    }));
  }
}
