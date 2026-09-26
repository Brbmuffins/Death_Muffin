import type { BossState, Corpse, Intent, SimEvent, Zone } from '../gameplay/sim/types';
import type { EnemyId } from '../content/enemies';
import type { ThrallKind } from '../content/disciplines';

/**
 * Realtime wire contracts (Socket.io). The server (server/realtime/server.js)
 * validates shapes and enforces: world rooms are instanced (≤4 players each),
 * only the elected host may publish snapshots/events, and intents are routed
 * to the host only.
 */

export interface RemotePlayer {
  id: string;
  characterId: number;
  name: string;
  classIndex: number;
  x: number;
  z: number;
  facing: number;
  moving: boolean;
  hpFrac: number;
}

export interface JoinRequest {
  /** Invite code; omit to be matched into any public world with space. */
  instance?: string;
  characterId: number;
  classIndex: number;
  x: number;
  z: number;
  facing: number;
}

export interface JoinResult {
  self: RemotePlayer;
  players: RemotePlayer[];
  hostId: string;
  instance: string;
  snapshot: WorldSnapshot | null;
}

export interface PlayerMove {
  x: number;
  z: number;
  facing: number;
  moving: boolean;
  hpFrac: number;
}

/** Compact enemy row: [id, def, x, z, facing, hp, maxHp, stateIdx, flags, stateT, speed, scale, area] */
export type EnemyRow = [number, EnemyId, number, number, number, number, number, number, number, number, number, number, string];
/** [id, owner, kind, x, z, facing, hp, maxHp, stateIdx, stateT, empowered, speed] */
export type ThrallRow = [number, string, ThrallKind, number, number, number, number, number, number, number, number, number];

export interface WorldSnapshot {
  t: number;
  waveTier: number;
  enemies: EnemyRow[];
  thralls: ThrallRow[];
  /** Full corpse + zone lists ride along every Nth snapshot for resync. */
  corpses?: Corpse[];
  zones?: Zone[];
  boss: BossState;
}

export interface IntentEnvelope {
  from: string;
  intent: Intent;
}

export type EventBatch = SimEvent[];

export interface ChatMessage {
  id: string;
  name: string;
  text: string;
}
