import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { AREAS } from '../../../server/rules/content/areas';
import { BOSS_ICHOR } from '../../../server/rules/content/reagents';
import { ITEMS } from '../../../server/rules/content/items';
import { AREA_PEAK, AUTHORITY, GROUND_RATES, LEVEL_CAP, ceilingsFor, isGroundItem, itemCap, itemRatePerMin, splitXp, totalXp } from '../../../server/rules/gameplay/authorityRules';
import { xpToNext } from '../characterStats';

describe('authority rules: experience arithmetic', () => {
  it('totalXp follows the game curve (advancing from L costs L x 100)', () => {
    let total = 0;
    for (let level = 1; level < 60; level++) {
      expect(totalXp(level, 0)).toBe(total);
      expect(totalXp(level, 17)).toBe(total + 17);
      total += xpToNext(level);
    }
  });

  it('splitXp inverts totalXp and caps at level 999', () => {
    for (const [l, x] of [[1, 0], [1, 99], [2, 0], [40, 3999], [135, 20]] as const) expect(splitXp(totalXp(l, x))).toEqual({ level: l, xp: x });
    expect(splitXp(1e12).level).toBe(LEVEL_CAP);
    expect(LEVEL_CAP).toBe(999);
  });
});

describe('authority rules: ceilings come from the game own numbers', () => {
  it('every combat ground the game has is measured, and no safe ground is', () => {
    for (const area of Object.values(AREAS)) {
      if (area.safe) expect(AREA_PEAK[area.id], `${area.id} is safe`).toBeUndefined();
      else expect(AREA_PEAK[area.id], `${area.id} needs a measured peak (BALANCE.md harness)`).toBeDefined();
    }
  });

  it('deeper grounds, higher ranks and higher level-scaled grounds only ever raise a ceiling', () => {
    const base = ceilingsFor(['graves'], 0, 1);
    expect(ceilingsFor(['graves', 'ossuary'], 0, 1).xpPerMin).toBeGreaterThan(base.xpPerMin);
    expect(ceilingsFor(['graves'], 5, 1).xpPerMin).toBeGreaterThan(base.xpPerMin);
    expect(ceilingsFor(['cloister'], 0, 60).xpPerMin).toBeGreaterThan(ceilingsFor(['cloister'], 0, 20).xpPerMin);
  });

  it('a character with no hunting ground earns no XP and only the non-combat gold rate', () => {
    expect(ceilingsFor(['chapterhouse', 'acre'], 0, 50)).toEqual({ xpPerMin: 0, goldPerMin: AUTHORITY.NONCOMBAT_GOLD_PER_MIN, area: null });
  });

  it('the ceiling at the start is generous over a plain play rate but small next to a cheat', () => {
    const c = ceilingsFor(['chapterhouse', 'graves'], 0, 1);
    expect(c.xpPerMin).toBeGreaterThan(AREA_PEAK.graves!.xp * AUTHORITY.HEADROOM);
    expect(c.xpPerMin * 60).toBeLessThan(totalXp(255, 0));
  });
});

describe('authority rules: what can come off the ground', () => {
  it('every area loot item, mob reagent and boss ichor is a ground item', () => {
    for (const area of Object.values(AREAS)) for (const l of area.loot) expect(isGroundItem(l.item), `${area.id}: ${l.item}`).toBe(true);
    for (const ichor of Object.values(BOSS_ICHOR)) expect(isGroundItem(ichor)).toBe(true);
    expect(isGroundItem('reagent_grave_dust')).toBe(true);
  });

  it('every ground item exists in the catalogue (a typo here would silently disable its guard)', () => {
    for (const id of Object.keys(GROUND_RATES)) expect(ITEMS[id], id).toBeDefined();
  });

  it('crafted and gathered things are server-only: rate 0 and cap 0', () => {
    for (const id of ['plank_oak', 'ingot_copper', 'tool_hatchet_copper']) {
      expect(isGroundItem(id)).toBe(false);
      expect(itemRatePerMin(id)).toBe(0);
      expect(itemCap(id)).toBe(0);
    }
  });

  it('rare drops are capped far below common ones; ichors allow a handful', () => {
    expect(itemCap('ichor_prelate')).toBeLessThan(40);
    expect(itemCap('staff_moon')).toBeLessThan(40);
    expect(itemCap('ore_copper')).toBeGreaterThan(itemCap('ichor_prelate'));
  });
});

describe('authority rules: the server bundle is fresh', () => {
  it('matches src/gameplay/authorityRules.ts', async () => {
    const { bundleRulesFor } = await import('../../../tools/build-server-rules.mjs');
    const lf = (s: string) => s.replace(/\r\n/g, '\n');
    const { out, text } = await bundleRulesFor('authority');
    expect(lf(readFileSync(out, 'utf8')), 'run npm run build:server-rules (authority)').toBe(lf(text));
  });
});
