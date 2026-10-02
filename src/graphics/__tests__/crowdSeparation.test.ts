import { describe, expect, it } from 'vitest';
import { countOverlaps, separateBodies, type CrowdBody } from '../crowdSeparation';

const apply = (bodies: CrowdBody[], out: Float32Array): CrowdBody[] => bodies.map((b, i) => ({ ...b, x: b.x + out[i * 2], z: b.z + out[i * 2 + 1] }));

describe('separateBodies', () => {
  it('leaves bodies that do not touch alone', () => {
    const out = new Float32Array(4);
    separateBodies([{ x: 0, z: 0, r: 0.5, w: 1 }, { x: 3, z: 0, r: 0.5, w: 1 }], out);
    expect([...out]).toEqual([0, 0, 0, 0]);
  });

  it('pushes an overlapping pair apart along their line, equally when both yield', () => {
    const bodies = [{ x: 0, z: 0, r: 0.5, w: 1 }, { x: 0.4, z: 0, r: 0.5, w: 1 }];
    const out = new Float32Array(4);
    separateBodies(bodies, out, { maxOffset: 5 });
    expect(out[0]).toBeLessThan(0);
    expect(out[2]).toBeGreaterThan(0);
    expect(out[0]).toBeCloseTo(-out[2], 5);
    expect(out[1]).toBeCloseTo(0, 6);
    expect(countOverlaps(apply(bodies, out))).toBe(0);
  });

  it('never moves an immovable body (the hero) and slides the other one clear', () => {
    const bodies = [{ x: 0, z: 0, r: 0.45, w: 0 }, { x: 0.3, z: 0.1, r: 0.5, w: 1 }];
    const out = new Float32Array(4);
    separateBodies(bodies, out, { maxOffset: 5 });
    expect(out[0]).toBe(0);
    expect(out[1]).toBe(0);
    expect(Math.hypot(0.3 + out[2], 0.1 + out[3])).toBeGreaterThan(0.85);
  });

  it('caps the slide so the drawn body never strays far from the sim', () => {
    const bodies = [{ x: 0, z: 0, r: 2, w: 0 }, { x: 0.1, z: 0, r: 2, w: 1 }];
    const out = new Float32Array(4);
    separateBodies(bodies, out, { maxOffset: 0.5 });
    expect(Math.hypot(out[2], out[3])).toBeCloseTo(0.5, 5);
  });

  it('unravels a clump of bodies stacked on one spot', () => {
    const bodies: CrowdBody[] = Array.from({ length: 8 }, () => ({ x: 5, z: 5, r: 0.5, w: 1 }));
    const out = new Float32Array(16);
    separateBodies(bodies, out, { maxOffset: 3, iterations: 4 });
    const placed = apply(bodies, out);
    expect(countOverlaps(bodies)).toBe(28);
    expect(countOverlaps(placed)).toBeLessThan(10);
    for (const v of out) expect(Number.isFinite(v)).toBe(true);
  });

  it('reduces overlaps in a ring of enemies around the hero', () => {
    const bodies: CrowdBody[] = [{ x: 0, z: 0, r: 0.45, w: 0 }];
    for (let i = 0; i < 14; i++) {
      const a = (i / 14) * Math.PI * 2;
      bodies.push({ x: Math.cos(a) * 1.2, z: Math.sin(a) * 1.2, r: 0.5, w: 1 });
    }
    const out = new Float32Array(bodies.length * 2);
    separateBodies(bodies, out);
    expect(countOverlaps(apply(bodies, out))).toBeLessThan(countOverlaps(bodies));
  });
});
