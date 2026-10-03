import { beforeAll, describe, expect, it, vi } from 'vitest';
import { claimKeys, gridLayout, slices, stageProgress } from '../warmRender';
import { areasWithin, requiredAreas } from '../areaStreaming';
import { AREAS } from '../../content/areas';

describe('warm render helpers', () => {
  it('lays bodies out centred, rows of at most cols', () => {
    const p = gridLayout(5, 3, 2);
    expect(p).toHaveLength(5);
    expect(p[0].x).toBe(-2);
    expect(p[2].x).toBe(2);
    // second row has two bodies, centred
    expect(p[3].x).toBe(-1);
    expect(p[4].x).toBe(1);
    expect(p[0].z).toBe(-1);
    expect(p[3].z).toBe(1);
    expect(gridLayout(0, 4)).toEqual([]);
  });

  it('slices work into batches, never empty, never zero-sized', () => {
    expect(slices([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(slices([1, 2], 0)).toEqual([[1], [2]]);
    expect(slices([], 3)).toEqual([]);
  });

  it('claims each key once', () => {
    const c = new Set<string>();
    expect(claimKeys(c, ['a', 'b', 'a'])).toEqual(['a', 'b']);
    expect(claimKeys(c, ['b', 'c'])).toEqual(['c']);
  });

  it('progress is clamped and empty work is done', () => {
    expect(stageProgress(0, 0)).toBe(1);
    expect(stageProgress(3, 6)).toBe(0.5);
    expect(stageProgress(9, 6)).toBe(1);
  });
});

describe('areasWithin', () => {
  it('grows by door hops from the start', () => {
    expect(areasWithin('acre', 0)).toEqual(['acre']);
    expect(areasWithin('acre', 1).sort()).toEqual(['acre', 'chapterhouse']);
    expect(areasWithin('acre', 2)).toEqual(expect.arrayContaining(['acre', 'chapterhouse', 'graves', 'alchemist_wing']));
    expect(areasWithin('acre', 1)).toEqual(requiredAreas('acre'));
  });
});

describe('stageSpecs roster collection', () => {
  let stageSpecs: typeof import('../EntityViews').stageSpecs;
  beforeAll(async () => {
    // EntityViews pulls in the audio engine, which wants a window to hang listeners on.
    vi.stubGlobal('window', { addEventListener() {}, removeEventListener() {} });
    ({ stageSpecs } = await import('../EntityViews'));
  });
  const keys = (a: Parameters<typeof stageSpecs>[0], l?: Parameters<typeof stageSpecs>[1]) => stageSpecs(a, l).map((s) => s.key);

  it('has unique keys and covers every enemy within two doors of the start', () => {
    const k = keys(areasWithin('acre', 2), 'gravecaller');
    expect(new Set(k).size).toBe(k.length);
    for (const a of areasWithin('acre', 2)) for (const { id } of AREAS[a].enemies) expect(k).toContain(`enemy:${id}`);
  });

  it('includes the thrall kinds, the player legion and the spectral thrall', () => {
    const k = keys(['acre'], 'gravecaller');
    for (const t of ['thrall:thrall_legionnaire', 'thrall:warrior', 'thrall:archer', 'thrall:bonemage', 'thrall:wraith', 'thrall:hound', 'thrall:colossus']) expect(k).toContain(t);
  });

  it('a wider area set only ever adds bodies', () => {
    const small = new Set(keys(['acre']));
    const big = new Set(keys(requiredAreas('acre')));
    for (const k of small) expect(big.has(k)).toBe(true);
  });

  it('the Depths add their rosters', () => {
    expect(keys(['depths']).length).toBeGreaterThan(keys([]).length);
  });
});
