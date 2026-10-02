import { NODES, type GatherSkill } from '../gameplay/gatheringRules';
import { NODE_COLLIDER, type NodePlacement, type Rect } from '../content/layout';
import type { CreatureSlug } from './modelPaths';
import type { CreatureAnim } from './Creature';

/**
 * Pure rules for the visible Grave Laborers (LaborerViews.ts): which Acre node a laborer works, where it stands,
 * and which clip + tool it uses. No three.js here, so it is unit-tested directly.
 */

/** One distinct thrall model per laborer slot, so the four read as individuals. */
export const LABORER_MODELS: CreatureSlug[] = ['skeleton_thrall', 'thrall_legionnaire', 'thrall_sentinel', 'thrall_plague'];

/** Hand tool prop id and length (the same props and sizes the hero holds, Avatars.setGatheringTool). */
export const LABORER_TOOLS: Partial<Record<GatherSkill, { id: string; length: number }>> = {
  woodcutting: { id: 'tool_hatchet', length: 0.95 },
  mining: { id: 'tool_pickaxe', length: 1.2 },
  fishing: { id: 'tool_fishing_rod', length: 1.45 },
  gravedigging: { id: 'tool_spade', length: 1.2 },
};

export interface LaborerWork {
  anim: CreatureAnim;
  /** Clip range to loop [start, end) in seconds, or null for the whole clip. */
  range: [number, number] | null;
  /** The clip second of the working stroke's impact (the beat for puffs), or null when time-based. */
  impact: number | null;
  /** Seconds between beats when there is no impact frame. */
  beatEvery: number;
}

/** Chop and dig clip facts (public/models/thrall_*): `chop` swings once, impact ~2.1 s, still after ~3.0 s. */
export const CHOP_RANGE: [number, number] = [0.7, 3.0];
export const CHOP_IMPACT = 2.1;

/** What a laborer of this skill does: chop strokes, steady digging, or standing at the water. */
export function workFor(skill: string | null): LaborerWork {
  switch (skill) {
    case 'woodcutting':
    case 'mining':
      return { anim: 'chop', range: CHOP_RANGE, impact: CHOP_IMPACT, beatEvery: 0 };
    case 'gravedigging':
    case 'gardening':
      return { anim: 'dig', range: null, impact: null, beatEvery: 2.6 };
    default:
      return { anim: 'idle', range: null, impact: null, beatEvery: 0 };
  }
}

/** The Acre node a post is worked at: that exact node type, else the lowest-tier node of the same skill (the Fen's herbs have no Acre bed). */
export function postNode(nodes: readonly NodePlacement[], nodeType: string, slot = 0): NodePlacement | null {
  const def = NODES[nodeType];
  if (!def) return null;
  const same = nodes.filter((n) => n.type === nodeType);
  if (same.length) return same[slot % same.length];
  const skill = nodes.filter((n) => NODES[n.type]?.skill === def.skill).sort((a, b) => NODES[a.type].level - NODES[b.type].level);
  return skill.length ? skill[0] : null;
}

export interface SpotWorld {
  /** Acre bounds. */
  rect: Rect;
  nodes: readonly NodePlacement[];
  ponds: readonly Rect[];
  /** Solid props (x, z, clearance radius). */
  blockers: readonly { x: number; z: number; r: number }[];
}

export interface Spot {
  x: number;
  z: number;
  /** Heading (radians, atan2(dx, dz)) toward the node. */
  facing: number;
}

const inRect = (r: Rect, x: number, z: number, pad = 0) => x >= r.x0 - pad && x <= r.x1 + pad && z >= r.z0 - pad && z <= r.z1 + pad;

/** Visible radius of the big gravedigging models (NodeViews heights 1.2 and 2 on wide crypt/barrow meshes), wider than their collider. */
const FOOTPRINT: Record<string, number> = { grave_crypt: 1.35, grave_barrow_king: 2.25 };

/** Preferred bearing (radians from +x toward +z) per node: the open side of the wall or shore it sits against. */
function preferredAngle(n: NodePlacement, slot: number): number {
  const kind = NODES[n.type].kind;
  if (kind === 'seam' || kind === 'geode') return Math.PI / 2; // quarry wall is north: stand south of it
  if (kind === 'grave' || kind === 'pool') return -Math.PI / 2; // burial rows hug the south wall; the pond's open shore is north
  return Math.PI * 0.75 + slot * 1.1; // trees: any side, a different one per laborer
}

/**
 * Where a laborer stands to work `node`: just outside the player's own gather ring (NODE_REACH is where the hero
 * stands, so the laborer takes the shoulder of the node, never the click point), on land, inside the Acre,
 * clear of other nodes, props, the pond and the other laborers (`taken`). Tries the preferred side first, then
 * fans out around the node and widens the radius. Always returns a spot (the first candidate if nothing is clear).
 */
export function laborerSpot(node: NodePlacement, slot: number, world: SpotWorld, taken: readonly Spot[] = []): Spot {
  const base = preferredAngle(node, slot);
  const kind = NODES[node.type].kind;
  const r0 = Math.max(1.35, (FOOTPRINT[node.type] ?? NODE_COLLIDER[kind]) + 0.85);
  let first: Spot | null = null;
  for (const radius of [r0, r0 + 0.5, r0 + 1.1, r0 + 1.8]) {
    for (let i = 0; i < 12; i++) {
      const step = i === 0 ? 0 : Math.ceil(i / 2) * (i % 2 ? 1 : -1);
      const a = base + step * (Math.PI / 6);
      const x = node.x + Math.cos(a) * radius;
      const z = node.z + Math.sin(a) * radius;
      const spot: Spot = { x, z, facing: Math.atan2(node.x - x, node.z - z) };
      first ??= spot;
      if (!inRect(world.rect, x, z, -2.2)) continue;
      if (world.ponds.some((p) => inRect(p, x, z, 0.5))) continue;
      if (world.nodes.some((o) => o !== node && Math.hypot(o.x - x, o.z - z) < NODE_COLLIDER[NODES[o.type].kind] + 0.8)) continue;
      if (world.blockers.some((b) => Math.hypot(b.x - x, b.z - z) < b.r)) continue;
      if (taken.some((t) => Math.hypot(t.x - x, t.z - z) < 1.3)) continue;
      return spot;
    }
  }
  return first!;
}

/** "3 h 12 m" / "45 m" / "under 1 m" (with non-breaking spaces). */
export function workedText(ms: number): string {
  const m = Math.floor(Math.max(0, ms) / 60000);
  if (m < 1) return 'under 1\u00a0m';
  const h = Math.floor(m / 60);
  // Non-breaking spaces keep "3 h 12 m" on one line in the hover card.
  return h ? `${h}\u00a0h ${m % 60}\u00a0m` : `${m}\u00a0m`;
}

/** The hover line over a laborer: "Grave Laborer · Mining · 3 h 12 m · ready to collect". */
export function laborerTip(skillName: string, workedMs: number, ready: boolean, full: boolean): string {
  const state = full ? 'full, collect them' : ready ? 'ready to collect' : 'working';
  return `Grave Laborer · ${skillName} · ${workedText(workedMs)} · ${state}`;
}
