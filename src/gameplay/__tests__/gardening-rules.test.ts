import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { GARDEN_ITEMS, PLOTS, SEEDS, seedDef } from '../../content/gardening';
import { ITEMS } from '../../content/items';
import { NODES } from '../gatheringRules';
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

  it('has two plot kinds and unique plot ids', () => {
    expect(new Set(PLOTS.map((p) => p.id)).size).toBe(PLOTS.length);
    expect(PLOTS.filter((p) => p.kind === 'herb')).toHaveLength(4);
    expect(PLOTS.filter((p) => p.kind === 'tree')).toHaveLength(2);
  });
});

describe('growth and planting', () => {
  it('reads plot state from the server clock', () => {
    expect(stateOf(null, 500)).toBe('empty');
    expect(stateOf(row({ seedId: null }), 500)).toBe('empty');
    expect(stateOf(row(), 999)).toBe('growing');
    expect(stateOf(row(), 1000)).toBe('ready');
  });

  it('bone meal grows a plot a quarter faster', () => {
    const s = seedDef('seed_mourning_moss')!;
    expect(growMs(s, false)).toBe(20 * 60_000);
    expect(growMs(s, true)).toBe(15 * 60_000);
  });

  it('blocks the wrong plot, too low a level, and an occupied plot', () => {
    const herb = plotDef('h0');
    const tree = plotDef('t0');
    expect(plantBlocker(herb, 'seed_mourning_moss', 1, null, 0)).toBeNull();
    expect(plantBlocker(tree, 'seed_mourning_moss', 1, null, 0)).toMatch(/Mourning Bed/);
    expect(plantBlocker(herb, 'sapling_oak', 50, null, 0)).toMatch(/Coffin Patch/);
    expect(plantBlocker(herb, 'seed_nightshade', 14, null, 0)).toMatch(/15/);
    expect(plantBlocker(herb, 'seed_mourning_moss', 1, row(), 10)).toMatch(/already/);
    expect(plantBlocker(herb, 'seed_mourning_moss', 1, row(), 5000)).toMatch(/already/); // ready but not harvested is still occupied
    expect(plantBlocker(undefined, 'seed_mourning_moss', 1, null, 0)).toMatch(/no such plot/);
  });
});

describe('harvest', () => {
  it('rolls within the yield range, and returns a seed only on a lucky roll', () => {
    const s = seedDef('seed_mourning_moss')!;
    const low = rollHarvest(s, () => 0);
    expect(low).toMatchObject({ itemId: 'herb_mourning_moss', qty: s.yields[0], seedBack: 'seed_mourning_moss', xp: s.harvestXp });
    const high = rollHarvest(s, () => 0.999);
    expect(high.qty).toBe(s.yields[1]);
    expect(high.seedBack).toBeNull();
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
