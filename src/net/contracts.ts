import type { BossState, Corpse, Intent, SimEvent, Zone } from '../gameplay/sim/types';
import type { EnemyId } from '../../server/rules/content/enemies';
import type { ThrallKind } from '../../server/rules/content/disciplines';
import type { Difficulty } from '../../server/rules/content/difficulty';

/**
 * Realtime wire contracts (Socket.io). The server (server/realtime/server.js)
 * validates shapes and enforces: world rooms are instanced (≤10 players each),
 * only the elected host may publish snapshots/events, and intents are routed
 * to the host only.
 */

export interface RemotePlayer {
  id: string;
  characterId: number;
  name: string;
  classIndex: number;
  /** Character level at join (older servers omit it). */
  level?: number;
  x: number;
  z: number;
  facing: number;
  moving: boolean;
  hpFrac: number;
  /** Visible equipment by slot (item ids); older servers omit it. */
  gear?: Record<string, string>;
}

export interface JoinRequest {
  /** Party invite code: joins (or creates) that party's world. Omit for a private solo world. */
  instance?: string;
  characterId: number;
  classIndex: number;
  level?: number;
  x: number;
  z: number;
  facing: number;
  gear?: Record<string, string>;
}

export interface JoinResult {
  self: RemotePlayer;
  players: RemotePlayer[];
  hostId: string;
  instance: string;
  /** True when the world is your private solo world (older servers omit it and matchmake: treat absent as unknown). */
  solo?: boolean;
  snapshot: WorldSnapshot | null;
}

export interface PlayerMove {
  x: number;
  z: number;
  facing: number;
  moving: boolean;
  hpFrac: number;
  /** Character level, so partners' frames follow level-ups mid-session (older clients/servers omit it). */
  level?: number;
}

/**
 * Compact enemy row: [id, def, x, z, facing, hp, maxHp, stateIdx, flags, stateT, speed, scale, area, affix]
 * `affix` = AFFIX_ORDER index + 1 (0 = none). Appended last so older rows (13 fields) still parse.
 */
export type EnemyRow = [number, EnemyId, number, number, number, number, number, number, number, number, number, number, string, number?, number?];
/** [id, owner, kind, x, z, facing, hp, maxHp, stateIdx, stateT, empowered, speed, damage?, attackInterval?] (the last two let a new host keep the legion's real strength). */
export type ThrallRow = [number, string, ThrallKind, number, number, number, number, number, number, number, number, number, number?, number?];

export interface WorldSnapshot {
  t: number;
  waveTier: number;
  /** Host's session difficulty (absent from older hosts → medium). */
  difficulty?: Difficulty;
  /** Host's Ascension rank (absent from older hosts → 0). */
  ascension?: number;
  /** Host's sworn Vows (absent when none, and from older hosts: `ascension` then means that many steps of Elder Dead). */
  vows?: Partial<Record<string, number>>;
  enemies: EnemyRow[];
  thralls: ThrallRow[];
  /** Full corpse + zone lists ride along every Nth snapshot for resync. */
  corpses?: Corpse[];
  zones?: Zone[];
  /** Creeping Rot rune: [zone id, x, z] of every drifting circle, in every snapshot (the full zone list is too rare to follow them). */
  zpos?: [number, number, number][];
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
