import { NODE_REACH, type NodePlacement } from '../content/layout';
import { NODES, type GatherSkill } from './gatheringRules';

/**
 * Pure decisions for the gathering loop (roadmap §7), kept apart from the
 * scene so they can be unit-tested like autoCombat.ts.
 */

export interface LiveNode extends NodePlacement {
  /** Successes left before it depletes (0 = depleted, waiting to respawn). */
  remaining: number;
}

export interface Blocker {
  blocked(x: number, z: number, r: number): boolean;
}

/**
 * Where to stand to work a node: the free point on its reach ring nearest to
 * `from`. Returns null if the whole ring is blocked.
 */
export function standSpot(nav: Blocker, node: { type: string; x: number; z: number }, fromX: number, fromZ: number, r = 0.45) {
  const reach = NODE_REACH[NODES[node.type].kind];
  let best: { x: number; z: number } | null = null;
  let bestD = Infinity;
  for (let k = 0; k < 16; k++) {
    const a = (k / 16) * Math.PI * 2;
    const x = node.x + Math.cos(a) * reach;
    const z = node.z + Math.sin(a) * reach;
    if (nav.blocked(x, z, r)) continue;
    const d = Math.hypot(x - fromX, z - fromZ);
    if (d < bestD) {
      bestD = d;
      best = { x, z };
    }
  }
  return best;
}

/** Why the loop can't (or won't) work a node, as a player-readable line; null = go. */
export function gatherBlocker(type: string, level: number): string | null {
  const def = NODES[type];
  if (!def) return 'Nothing to gather here.';
  if (level < def.level) return `Requires ${skillName(def.skill)} level ${def.level}`;
  return null;
}

const NAMES: Record<GatherSkill, string> = { woodcutting: 'Woodcutting', mining: 'Mining', fishing: 'Fishing', gravedigging: 'Gravedigging' };
const skillName = (s: GatherSkill) => NAMES[s];

export interface AutoGatherInput {
  /** The node just depleted (or finished). */
  from: { type: string; x: number; z: number; area: string };
  nodes: Iterable<LiveNode>;
  /** Current level in the node's skill. */
  level: number;
  /** Hero position. */
  x: number;
  z: number;
}

/**
 * Auto: the nearest live node of the same type in the same area. If none is
 * live, the nearest same-skill node the player can use with the same item
 * tier is NOT chosen: Auto waits at the depleted node instead (never wanders
 * off to a different kind, never leaves the area, never above the level).
 */
export function nextAutoNode(input: AutoGatherInput): LiveNode | null {
  const def = NODES[input.from.type];
  if (!def || input.level < def.level) return null;
  let best: LiveNode | null = null;
  let bestD = Infinity;
  for (const n of input.nodes) {
    if (n.type !== input.from.type || n.area !== input.from.area || n.remaining <= 0) continue;
    if (n.x === input.from.x && n.z === input.from.z) continue;
    const d = Math.hypot(n.x - input.x, n.z - input.z);
    if (d < bestD) {
      bestD = d;
      best = n;
    }
  }
  return best;
}

/** Stop conditions shared with auto combat: movement input, a panel, a full bag, damage. */
export type GatherStop = 'moved' | 'panel' | 'bagFull' | 'hurt' | 'dead' | 'left';

export const STOP_TEXT: Record<GatherStop, string | null> = {
  moved: null,
  panel: null,
  bagFull: 'Your bag is full. Visit the Reliquary or drop something to keep gathering.',
  hurt: 'Something struck you. Gathering stopped.',
  dead: null,
  left: null,
};
