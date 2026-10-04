import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Helix, 2026-10-04: a laborer's loot is listed under the laborers, not in a Ledger window that replaces the laborer window.
const src = (p: string) => readFileSync(join(__dirname, '..', '..', p), 'utf8');

describe('laborer loot stays in the laborer window', () => {
  it('collecting no longer swaps the window for the Ledger', () => {
    const world = src('scenes/WorldScene.ts');
    const fn = world.slice(world.indexOf('private onLaborCollected'), world.indexOf('private noteLabor'));
    expect(fn).toContain('this.laborPanel.addLoot(slot,');
    expect(fn).not.toContain('closePanels()');
    expect(fn).not.toContain('gatherReportPanel');
  });
  it('the laborer panel lists the loot and can clear it', () => {
    const panel = src('ui/LaborPanel.ts');
    expect(panel).toContain('addLoot(slot: number, report: GatherReport)');
    expect(panel).toContain('data-clear-loot');
    expect(panel).toContain('this.onCollected(result, slot)');
  });
});
