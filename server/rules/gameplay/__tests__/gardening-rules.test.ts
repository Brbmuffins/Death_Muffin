import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { COMPOST_SPEED, GARDEN_ITEMS, PLOTS, SEEDS, seedDef } from '../../content/gardening';
import { ITEMS } from '../../content/items';
import { LEVEL_CAP, NODES } from '../gatheringRules';
import { growMs, plantBlocker, plotDef, remainingText, rollHarvest, stateOf, type PlotRow } from '../gardeningRules';

const row = (o: Partial<PlotRow> = {}): PlotRow => ({ plot: 'h0', seedId: 'seed_mourning_moss', plantedAt: 0, readyAt: 1000, composted: false, ...o });

describe('garden content', () => {
  it('registers every garden item in the client catalogue, and every seed/crop is a known item', () => {
    for (const id of Object.keys(GARDEN_ITEMS)) expect(ITEMS[id], id).toBeTruthy();
    for (const s of SEEDS) {
      expect(ITEMS[s.id], s.id).toBeTruthy();
      expect(ITEMS[s.harvest], s.harvest).toBeTruthy();
    }
  });

  it('every seed can actually be found somewhere (a gathering extra), except the free-standing Mourning Moss which graves already drop', () => {
    const dropped = new Set(Object.values(NODES).flatMap((n) => n.extras.map((e) => e.item)));
    for (const s of SEEDS) expect(dropped.has(s.id), `${s.id} has no source`).toBe(true);
  });

  it('has unique plot ids, and a plot for every kind of seed there is', () => {
    expect(new Set(PLOTS.map((p) => p.id)).size).toBe(PLOTS.length);
    for (const kind of new Set(SEEDS.map((s) => s.kind))) expect(PLOTS.some((p) => p.kind === kind), `a ${kind} plot`).toBe(true);
    for (const p of PLOTS) expect(plotDef(p.id)).toBe(p);
    expect(plotDef('no_such_plot')).toBeUndefined();
  });
});

describe('growth and planting', () => {
  it('reads plot state from the server clock', () => {
    expect(stateOf(null, 500)).toBe('empty');
    expect(stateOf(row({ seedId: null }), 500)).toBe('empty');
    expect(stateOf(row(), 999)).toBe('growing');
    expect(stateOf(row(), 1000)).toBe('ready');
  });

  it('bone meal grows a plot faster, by the compost speed', () => {
    for (const s of SEEDS) {
      expect(growMs(s, false), s.id).toBe(Math.round(s.growMin * 60_000));
      expect(growMs(s, true), s.id).toBe(Math.round(s.growMin * 60_000 * COMPOST_SPEED));
    }
    expect(COMPOST_SPEED).toBeGreaterThan(0);
    expect(COMPOST_SPEED).toBeLessThan(1);
  });

  it('blocks the wrong plot, too low a level, and an occupied plot', () => {
    const herb = PLOTS.find((p) => p.kind === 'herb')!;
    const tree = PLOTS.find((p) => p.kind === 'tree')!;
    const herbSeed = SEEDS.find((s) => s.kind === 'herb')!;
    const sapling = SEEDS.find((s) => s.kind === 'tree')!;
    expect(plantBlocker(herb, herbSeed.id, LEVEL_CAP, null, 0)).toBeNull();
    expect(plantBlocker(tree, herbSeed.id, LEVEL_CAP, null, 0)).toMatch(/Mourning Bed/);
    expect(plantBlocker(herb, sapling.id, LEVEL_CAP, null, 0)).toMatch(/Coffin Patch/);
    const demanding = SEEDS.filter((s) => s.kind === 'herb' && s.level > 1).sort((a, b) => a.level - b.level)[0];
    expect(plantBlocker(herb, demanding.id, demanding.level - 1, null, 0)).toMatch(new RegExp(String(demanding.level)));
    expect(plantBlocker(herb, demanding.id, demanding.level, null, 0)).toBeNull();
    expect(plantBlocker(herb, herbSeed.id, LEVEL_CAP, row(), 10)).toMatch(/already/);
    expect(plantBlocker(herb, herbSeed.id, LEVEL_CAP, row(), 5000)).toMatch(/already/); // ready but not harvested is still occupied
    expect(plantBlocker(undefined, herbSeed.id, LEVEL_CAP, null, 0)).toMatch(/no such plot/);
    expect(plantBlocker(herb, 'not_a_seed', LEVEL_CAP, null, 0)).toMatch(/cannot be planted/);
  });
});

describe('harvest', () => {
  it('rolls within the yield range, and returns a seed only on a lucky roll', () => {
    // a seed of its own: a 40% chance to give the seed back, 3 to 6 per harvest
    const s = { ...SEEDS.find((x) => x.kind === 'herb')!, yields: [3, 6] as [number, number], seedBack: 0.4 };
    const low = rollHarvest(s, () => 0);
    expect(low).toMatchObject({ itemId: s.harvest, qty: 3, seedBack: s.id, xp: s.harvestXp });
    const high = rollHarvest(s, () => 0.999);
    expect(high.qty).toBe(6);
    expect(high.seedBack).toBeNull();
    for (const real of SEEDS) {
      const [lo, hi] = real.yields;
      expect(rollHarvest(real, () => 0).qty, real.id).toBe(lo);
      expect(rollHarvest(real, () => 0.999).qty, real.id).toBe(hi);
    }
  });

  it('formats countdowns', () => {
    expect(remainingText(45_000)).toBe('45s');
    expect(remainingText(35 * 60_000)).toBe('35m');
    expect(remainingText(80 * 60_000)).toBe('1h 20m');
  });
});

describe('server migration', () => {
  it('007-gardening.sql is generated from the content (run node tools/build-gardening-sql.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-gardening-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });
});
