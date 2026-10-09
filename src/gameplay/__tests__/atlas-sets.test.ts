import { describe, expect, it } from 'vitest';
import { ARMOR_PIECES } from '../../../server/rules/content/armorSets';
import { DISCIPLINES, type DisciplineId } from '../../../server/rules/content/disciplines';
import { ITEMS } from '../../../server/rules/content/items';
import { legendaryItemId, legendarySetFor } from '../../../server/rules/content/legendarySets';
import { atlasSlot, fitBand, fitTable, powerGainPct, referenceContext, setOutlook } from '../atlas';
import { itemVerdict } from '../gearStats';

const NECROS: DisciplineId[] = ['gravecaller', 'ossuary', 'mourner', 'rotweaver'];

describe('atlas: set pieces are valued with their set', () => {
  it('a legendary piece is worth far more as part of its set than the bare piece, and its fit counts the share', () => {
    for (const d of NECROS) {
      const id = legendaryItemId(legendarySetFor(d)!, 'chest');
      const ctx = referenceContext(d);
      const o = setOutlook(ctx, id)!;
      expect(o.total).toBe(5);
      expect(o.bonusPct).toBeGreaterThan(20);
      expect(o.withSetPct).toBeGreaterThan(powerGainPct(ctx, id));
      expect(fitTable(id)[d]).toBeGreaterThan(powerGainPct(ctx, id) + 3);
    }
  });

  it('a legendary with lower bare stats outranks a plain piece of the same slot once its set bonus counts', () => {
    const d: DisciplineId = 'gravecaller';
    const leg = legendaryItemId(legendarySetFor(d)!, 'chest');
    const ctx = referenceContext(d);
    // A plain chest piece with a strong roll (more bare INT than the legendary): it beats the legendary on bare stats.
    const plainId = Object.keys(ITEMS).find((id) => !ARMOR_PIECES.some((p) => p.id === id) && atlasSlot(id)?.item_type === atlasSlot(leg)!.item_type)!;
    const base = atlasSlot(plainId, 1)!;
    const worn = { ...base, equipped: 1 as const, stat_bonus: { ...(base.stat_bonus ?? {}), stat_int: 60, stat_vit: 20 } };
    const bag = atlasSlot(leg, 50)!;
    const withWorn = { ...ctx, slots: [worn] };
    const v = itemVerdict({ ...withWorn, slots: [worn, bag] }, bag)!;
    expect(v.kind).toBe('downgrade'); // bare stats: red arrow
    const o = setOutlook(withWorn, leg)!;
    expect(o.withSetPct).toBeGreaterThan(5); // but the set beats the plain piece
    expect(o.bonusPct).toBeGreaterThan(20);
  });

  it('wearing a second piece reaches the 2-piece tier and says so; the set share is counted in the verdict', () => {
    const d: DisciplineId = 'rotweaver';
    const set = legendarySetFor(d)!;
    const head = { ...atlasSlot(legendaryItemId(set, 'head'), 1)!, equipped: 1 as const };
    const chest = atlasSlot(legendaryItemId(set, 'chest'), 50)!;
    const ctx = { ...referenceContext(d), slots: [head] };
    const o = setOutlook(ctx, chest.item_id)!;
    expect(o.have).toBe(2);
    expect(o.hint).toMatch(/Completes 2\/5/);
    const v = itemVerdict({ ...ctx, slots: [head, chest] }, chest)!;
    expect(v.sets.gained.length).toBeGreaterThan(0);
  });

  it('armour set tiers (non-legendary) are valued too', () => {
    const p = ARMOR_PIECES.find((x) => x.collection === 1 && x.disciplineId === 'gravecaller')!;
    const o = setOutlook(referenceContext('gravecaller'), p.id)!;
    expect(o.bonusPct).toBeGreaterThan(0);
    expect(o.withSetPct).toBeGreaterThan(0);
  });

  it('non-set gear is unchanged', () => {
    const plain = Object.keys(ITEMS).find((id) => atlasSlot(id) && !ARMOR_PIECES.some((p) => p.id === id))!;
    const ctx = referenceContext('gravecaller');
    expect(setOutlook(ctx, plain)).toBeNull();
    expect(fitTable(plain).gravecaller).toBe(Math.round(powerGainPct(ctx, plain) * 10) / 10);
    expect(DISCIPLINES.gravecaller).toBeTruthy();
    void fitBand;
  });
});
