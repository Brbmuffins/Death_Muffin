import type { BossState, Corpse, Intent, SimEvent, Zone } from '../gameplay/sim/types';
import type { EnemyId } from '../content/enemies';
import type { ThrallKind } from '../content/disciplines';
import type { Difficulty } from '../content/difficulty';

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

/**
 * Compact enemy row: [id, def, x, z, facing, hp, maxHp, stateIdx, flags, stateT, speed, scale, area, affix]
 * `affix` = AFFIX_ORDER index + 1 (0 = none). Appended last so older rows (13 fields) still parse.
 */
export type EnemyRow = [number, EnemyId, number, number, number, number, number, number, number, number, number, number, string, number?];
/** [id, owner, kind, x, z, facing, hp, maxHp, stateIdx, stateT, empowered, speed] */
export type ThrallRow = [number, string, ThrallKind, number, number, number, number, number, number, number, number, number];

export interface WorldSnapshot {
  t: number;
  waveTier: number;
  /** Host's session difficulty (absent from older hosts → medium). */
  difficulty?: Difficulty;
  /** Host's Ascension rank (absent from older hosts → 0). */
  ascension?: number;
  enemies: EnemyRow[];
  thralls: ThrallRow[];
  /** Full corpse + zone lists ride along every Nth snapshot for resync. */
  corpses?: Corpse[];
  zones?: Zone[];
  boss: BossState;
  /** Depleted gathering nodes: [nodeId, seconds until back] (absent from older hosts). */
  depleted?: [string, number][];
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
