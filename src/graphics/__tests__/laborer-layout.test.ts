import { describe, expect, it } from 'vitest';
import { AREAS } from '../../../server/rules/content/areas';
import { generateLayout } from '../../content/layout';
import { NODES } from '../../../server/rules/gameplay/gatheringRules';
import { wrapRange } from '../Creature';
import { CHOP_IMPACT, CHOP_RANGE, LABORER_MODELS, LABORER_TOOLS, laborerSpot, laborerTip, postNode, workFor, type Spot, type SpotWorld } from '../laborerLayout';

const layout = generateLayout();
const acre = layout.nodes.filter((n) => n.area === 'acre');
const world: SpotWorld = {
  rect: AREAS.acre.rect,
  nodes: acre,
  ponds: layout.ponds,
  blockers: layout.props.filter((p) => p.area === 'acre').map((p) => ({ x: p.x, z: p.z, r: 0.7 })),
};

describe('wrapRange', () => {
  it('leaves times inside the range alone', () => expect(wrapRange(1.5, 0.7, 3)).toBe(1.5));
  it('jumps a time before the range to its start', () => expect(wrapRange(0.1, 0.7, 3)).toBe(0.7));
  it('wraps a time past the end back in, keeping the overshoot', () => {
    expect(wrapRange(3, 0.7, 3)).toBeCloseTo(0.7);
    expect(wrapRange(3.5, 0.7, 3)).toBeCloseTo(1.2);
    expect(wrapRange(8.0, 0.7, 3)).toBeCloseTo(0.7 + ((8 - 0.7) % 2.3));
  });
  it('ignores an empty range', () => expect(wrapRange(5, 2, 2)).toBe(5));
});

describe('laborer work', () => {
  it('chops for wood and ore with the impact inside the looped stroke', () => {
    for (const skill of ['woodcutting', 'mining']) {
      const w = workFor(skill);
      expect(w.anim).toBe('chop');
      expect(w.range).toEqual(CHOP_RANGE);
      expect(w.impact!).toBeGreaterThan(CHOP_RANGE[0]);
      expect(w.impact!).toBeLessThan(CHOP_RANGE[1]);
    }
    expect(CHOP_IMPACT).toBe(2.1);
  });
  it('digs graves, and stands at the water to fish', () => {
    expect(workFor('gravedigging').anim).toBe('dig');
    expect(workFor('fishing').anim).toBe('idle');
  });
  it('has a tool for each laborer skill and four distinct models', () => {
    for (const s of ['woodcutting', 'mining', 'fishing', 'gravedigging'] as const) expect(LABORER_TOOLS[s]).toBeTruthy();
    expect(new Set(LABORER_MODELS).size).toBe(4);
  });
});

describe('postNode', () => {
  it('finds the exact Acre node type', () => expect(postNode(acre, 'seam_iron')!.type).toBe('seam_iron'));
  it('falls back to the lowest node of the skill when the Acre has none (Fen herbs)', () => {
    expect(postNode(acre, 'bog_myrtle')!.type).toBe('grave_pauper');
  });
  it('returns null for an unknown post', () => expect(postNode(acre, 'nope')).toBeNull());
});

describe('laborerSpot', () => {
  it('stands every Acre node a laborer can take clear of the node, the pond, props and bounds, facing it', () => {
    for (const n of acre) {
      const s = laborerSpot(n, 0, world);
      const d = Math.hypot(n.x - s.x, n.z - s.z);
      expect(d, n.id).toBeGreaterThanOrEqual(1.3);
      expect(d, n.id).toBeLessThan(4);
      expect(world.ponds.some((p) => s.x > p.x0 && s.x < p.x1 && s.z > p.z0 && s.z < p.z1), `${n.id} in pond`).toBe(false);
      expect(world.blockers.some((b) => Math.hypot(b.x - s.x, b.z - s.z) < b.r), `${n.id} in prop`).toBe(false);
      expect(s.x).toBeGreaterThan(world.rect.x0);
      expect(s.x).toBeLessThan(world.rect.x1);
      expect(s.z).toBeGreaterThan(world.rect.z0);
      expect(s.z).toBeLessThan(world.rect.z1);
      // Facing points at the node.
      expect(Math.sin(s.facing) * d).toBeCloseTo(n.x - s.x, 5);
      expect(Math.cos(s.facing) * d).toBeCloseTo(n.z - s.z, 5);
    }
  });
  it('never stands on another node', () => {
    for (const n of acre) {
      const s = laborerSpot(n, 0, world);
      for (const o of acre) if (o !== n) expect(Math.hypot(o.x - s.x, o.z - s.z), `${n.id} vs ${o.id}`).toBeGreaterThan(0.7);
    }
  });
  it('keeps four laborers on one node apart', () => {
    const n = acre.find((x) => NODES[x.type].kind === 'tree')!;
    const taken: Spot[] = [];
    for (let slot = 0; slot < 4; slot++) taken.push(laborerSpot(n, slot, world, taken));
    for (let i = 0; i < 4; i++) for (let j = i + 1; j < 4; j++) expect(Math.hypot(taken[i].x - taken[j].x, taken[i].z - taken[j].z)).toBeGreaterThanOrEqual(1.3);
  });
  it('stands quarry workers south of the wall and diggers north of the burial row', () => {
    const seam = acre.find((n) => n.type === 'seam_iron')!;
    const grave = acre.find((n) => n.type === 'grave_crypt')!;
    expect(laborerSpot(seam, 0, world).z).toBeGreaterThan(seam.z);
    expect(laborerSpot(grave, 0, world).z).toBeLessThan(grave.z);
  });
});

describe('laborerTip', () => {
  it('reads like the owner asked', () => {
    const plain = (s: string) => s.replace(/\u00a0/g, ' ');
    expect(plain(laborerTip('Mining', 3 * 3600_000 + 12 * 60_000 + 5000, true, false))).toBe('Grave Laborer · Mining · 3 h 12 m · ready to collect');
    expect(plain(laborerTip('Fishing', 20_000, false, false))).toBe('Grave Laborer · Fishing · under 1 m · working');
    expect(plain(laborerTip('Woodcutting', 45 * 60_000, true, true))).toBe('Grave Laborer · Woodcutting · 45 m · full, collect them');
  });
});
