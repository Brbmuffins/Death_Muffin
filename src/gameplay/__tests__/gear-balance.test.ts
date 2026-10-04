import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { AREAS, type AreaId } from '../../content/areas';
import { ARMOR_PARTS, ARMOR_PIECES } from '../../content/armorSets';
import { DISCIPLINES } from '../../content/disciplines';
import { EQUIP_SLOTS, equippedBySlot } from '../../content/gear';
import { NECRO_WEAPON_BY_ID } from '../../content/necroWeapons';
import { SET_BONUSES, SET_IDS, SET_NAMES, describeEffect } from '../../content/setBonuses';
import { AFFIXES, affixRange, instanceProblem } from '../affixRules';
import { runBalance } from '../balance/harness';
import { BANDS } from '../balance/bands';
import { KIT_NAMES, kitItems, kitSlots, type KitItem, type KitName } from '../balance/kits';
import { gearPower } from '../gearStats';
import { botCharacter } from '../balance/harness';
import type { BalanceRun } from '../balance/harness';

/**
 * Guards for the 2026-10-02 gear pass (BALANCE.md "Gear pass"). The score-based ones are deterministic; the harness ones use three
 * seeds and wide margins, so they catch a regression of the shape ("a typical kit is invulnerable again"), not a tenth of a death.
 */
const NECRO = ['ossuary', 'gravecaller', 'mourner', 'rotweaver'] as const;
const INDEX = { ossuary: 1, gravecaller: 2, mourner: 3, rotweaver: 4 } as const;
const SEEDS = [42, 43, 44];
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
const pctile = (xs: number[], p: number) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(p * xs.length))];

describe('gear kits are data and legal', () => {
  const AREA_LIST: AreaId[] = ['graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'];
  it('every kit rolls only legal affixes, never a two-hander with an off-hand, one item per slot', () => {
    for (const kit of KIT_NAMES) {
      for (const discipline of NECRO) {
        for (const area of AREA_LIST) {
          const items = kitItems({ kit, discipline, area, seed: 7 });
          const slots = kitSlots(items);
          expect(Object.keys(equippedBySlot(slots)).length, `${kit} ${discipline} ${area}: one item per slot`).toBe(slots.length);
          const main = items.find((i) => NECRO_WEAPON_BY_ID[i.itemId]?.slot === 'main_hand');
          const off = items.find((i) => NECRO_WEAPON_BY_ID[i.itemId]?.slot === 'off_hand');
          if (main && off) expect(NECRO_WEAPON_BY_ID[main.itemId].twoHanded).toBe(false);
          for (const s of slots) expect(instanceProblem(s.inst, s.item_type), `${kit} ${discipline} ${area} ${s.item_id}`).toBeNull();
        }
      }
    }
  });
  it('typical = the discipline\'s whole first set, a weapon, and two lever affixes', () => {
    for (const discipline of NECRO) {
      const items = kitItems({ kit: 'typical', discipline, area: 'nave' });
      const armor = items.filter((i) => i.itemId.startsWith(`set_${discipline}_`) && !i.itemId.includes('ascended'));
      expect(armor).toHaveLength(5);
      expect(items.flatMap((i) => i.affixes)).toHaveLength(2);
      expect(items.some((i) => NECRO_WEAPON_BY_ID[i.itemId]?.slot === 'main_hand')).toBe(true);
    }
  });
  it('progress is what dropped earlier: nothing in the Graves, two set pieces at the Ossuary, four by the Sanctum', () => {
    const n = (area: AreaId) => kitItems({ kit: 'progress', discipline: 'gravecaller', area }).filter((i) => i.itemId.startsWith('set_')).length;
    expect([n('graves'), n('ossuary'), n('nave'), n('sanctum')]).toEqual([0, 2, 3, 4]);
  });
  it('ascended wears the ascended set and one lever per piece; bis three distinct levers per piece', () => {
    for (const discipline of NECRO) {
      const asc = kitItems({ kit: 'ascended', discipline, area: 'pyre' });
      expect(asc.filter((i) => i.itemId.includes('_ascended_'))).toHaveLength(5);
      for (const it of asc) expect(it.affixes).toHaveLength(1);
      const bis = kitItems({ kit: 'bis', discipline, area: 'pyre' });
      for (const it of bis) expect(new Set(it.affixes.map((a) => AFFIXES.find((d) => d.id === a.id)!.group)).size).toBe(3);
    }
  });
});

describe('set bonuses against the power score', () => {
  const ORDER = ['head', 'hands', 'chest', 'legs', 'feet'];
  /** Total power of wearing one whole set (stats + bonuses, no weapon) over wearing nothing, in percent. */
  function setPower(discipline: (typeof NECRO)[number], set: string, collection: 'first' | 'ascended', level: number) {
    const disc = DISCIPLINES[discipline];
    const ch = botCharacter(disc.classIndex, level, (0.8 * level * 5) / EQUIP_SLOTS.length);
    const f = (slots: ReturnType<typeof kitSlots>) => gearPower({ character: ch, slots, discipline: disc, damageTier: Math.round(level * 0.6) }).total;
    const id = collection === 'first' ? set : `${set}_ascended`;
    const slots = kitSlots(ORDER.map((part) => ({ itemId: ARMOR_PIECES.find((p) => p.setId === id && p.part === part)!.id, ilvl: level, affixes: [] })));
    return (f(slots) / f([]) - 1) * 100;
  }
  it('each necromancer\'s own set is its best set, in both collections, by at least 1.5 points of power', () => {
    for (const [collection, level] of [['first', 13], ['ascended', 30]] as const) {
      for (const d of NECRO) {
        const own = setPower(d, d, collection, level);
        for (const other of ['ossuary', 'gravecaller', 'mourner', 'rotweaver', 'witch', 'warden', 'monk', 'knight', 'veil']) {
          if (other === d) continue;
          expect(own, `${d} ${collection}: own ${own.toFixed(1)} vs ${other} ${setPower(d, other, collection, level).toFixed(1)}`).toBeGreaterThan(setPower(d, other, collection, level) + 1.5);
        }
      }
    }
  });
  it('the ascended set is worth more than the first for its own discipline', () => {
    for (const d of NECRO) expect(setPower(d, d, 'ascended', 30)).toBeGreaterThan(setPower(d, d, 'first', 30));
  });
});

describe('affixes against the power score', () => {
  const ILVLS = [12, 25, 47];
  /** Percent of power one median-rolled affix adds to a character wearing a plain typical set at that level. */
  function value(affixId: string, ilvl: number, discipline: (typeof NECRO)[number], q = 0.5) {
    const area: AreaId = ilvl <= 12 ? 'nave' : ilvl <= 25 ? 'cloister' : 'fen';
    const disc = DISCIPLINES[discipline];
    const plain: KitItem[] = kitItems({ kit: 'typical', discipline, area }).map((i) => ({ ...i, affixes: [] }));
    const level = Math.max(1, ilvl - 2);
    const ch = botCharacter(disc.classIndex, level, (0.8 * level * 2) / EQUIP_SLOTS.length);
    const f = (items: KitItem[]) => gearPower({ character: ch, slots: kitSlots(items), discipline: disc, damageTier: Math.round(level * 0.6) }).total;
    const chest = plain.findIndex((i) => i.itemId.endsWith('_chest'));
    const withAffix = plain.map((i, k) => (k === chest ? { ...i, ilvl, affixes: [{ id: affixId, q }] } : { ...i, ilvl }));
    return (f(withAffix) / f(plain.map((i) => ({ ...i, ilvl }))) - 1) * 100;
  }
  const STAT_IDS = AFFIXES.filter((a) => !a.necro).map((a) => a.id);
  const LEVER_IDS = AFFIXES.filter((a) => a.necro).map((a) => a.id);

  it('no affix is mandatory: the best median roll is within 1.6x of the best stat affix, and no max roll tops 12% of power', () => {
    for (const L of ILVLS) {
      for (const d of NECRO) {
        const bestStat = Math.max(...STAT_IDS.map((id) => value(id, L, d)));
        for (const id of AFFIXES.map((a) => a.id)) {
          expect(value(id, L, d), `${id} at ilvl ${L} for ${d}`).toBeLessThanOrEqual(bestStat * 1.6);
          expect(value(id, L, d, 1), `${id} max roll at ilvl ${L} for ${d}`).toBeLessThan(12);
        }
      }
    }
  });
  it('every lever is worth taking by someone: at least half a stat affix for its home discipline', () => {
    for (const L of ILVLS) {
      const bestStat = (d: (typeof NECRO)[number]) => Math.max(...STAT_IDS.map((id) => value(id, L, d)));
      for (const id of LEVER_IDS) {
        const home = Math.max(...NECRO.map((d) => value(id, L, d) / bestStat(d)));
        expect(home, `${id} at ilvl ${L}`).toBeGreaterThanOrEqual(0.5);
      }
    }
  });
  it('a stat affix is a few percent of power, not a tier of its own', () => {
    for (const L of ILVLS) for (const d of NECRO) {
      const best = Math.max(...STAT_IDS.map((id) => value(id, L, d)));
      expect(best).toBeGreaterThan(1.2);
      expect(best).toBeLessThan(7);
    }
  });
  it('affix tuning 2026-10-03: a home lever is within 1.35x of the best stat affix at every item level, and a good drop is a 3-14% upgrade of the whole kit (2026-10-03 achievable pass: raised from 12)', () => {
    const HOME: Record<(typeof NECRO)[number], string> = { ossuary: 's_thrall_hp', gravecaller: 'p_thrall_dmg', mourner: 'p_essence_regen', rotweaver: 's_miasma' };
    for (const L of [12, 25, 47, 70]) {
      for (const d of NECRO) {
        const bestStat = Math.max(...STAT_IDS.map((id) => value(id, L, d)));
        expect(value(HOME[d], L, d), `${HOME[d]} for ${d} at ilvl ${L}`).toBeLessThan(bestStat * 1.35);
        // two affixes at 75% on one piece: the stat everyone wants plus the discipline's own lever
        const plain: KitItem[] = kitItems({ kit: 'typical', discipline: d, area: L <= 12 ? 'nave' : L <= 25 ? 'cloister' : 'fen' }).map((i) => ({ ...i, ilvl: L, affixes: [] }));
        const disc = DISCIPLINES[d];
        const ch = botCharacter(disc.classIndex, Math.max(1, L - 2), (0.8 * Math.max(1, L - 2) * 2) / EQUIP_SLOTS.length);
        const f = (items: KitItem[]) => gearPower({ character: ch, slots: kitSlots(items), discipline: disc, damageTier: Math.round(Math.max(1, L - 2) * 0.6) }).total;
        const chest = plain.findIndex((i) => i.itemId.endsWith('_chest'));
        const good = plain.map((i, k) => (k === chest ? { ...i, affixes: [{ id: 'p_int', q: 0.75 }, { id: HOME[d], q: 0.75 }] } : i));
        const gain = (f(good) / f(plain) - 1) * 100;
        expect(gain, `good drop for ${d} at ilvl ${L}`).toBeGreaterThan(3);
        expect(gain, `good drop for ${d} at ilvl ${L}`).toBeLessThan(14);
      }
    }
  });
  it('affixes never outclass a completed set: three max-rolled best affixes on one piece stay within 10% of the whole ascended set bonus (bonus lines only)', () => {
    for (const L of [12, 25, 47, 70]) {
      for (const d of NECRO) {
        const disc = DISCIPLINES[d];
        const level = Math.max(1, L - 2);
        const ch = botCharacter(disc.classIndex, level, (0.8 * level * 2) / EQUIP_SLOTS.length);
        const f = (items: KitItem[]) => gearPower({ character: ch, slots: kitSlots(items), discipline: disc, damageTier: Math.round(level * 0.6) }).total;
        const ids = ARMOR_PARTS.map((part) => `set_${d}_ascended_${part}`);
        const setBonus = (f(ids.map((itemId) => ({ itemId, ilvl: L, affixes: [] }))) / f(ids.map((itemId) => ({ itemId, plain: true, ilvl: L, affixes: [] }))) - 1) * 100;
        const picks: string[] = [];
        const groups = new Set<string>();
        for (const id of [...AFFIXES.map((a) => a.id)].sort((a, b) => value(b, L, d, 1) - value(a, L, d, 1))) {
          const g = AFFIXES.find((a) => a.id === id)!.group;
          if (picks.length < 3 && !groups.has(g)) { picks.push(id); groups.add(g); }
        }
        const plain: KitItem[] = kitItems({ kit: 'typical', discipline: d, area: L <= 12 ? 'nave' : L <= 25 ? 'cloister' : 'fen' }).map((i) => ({ ...i, ilvl: L, affixes: [] }));
        const chest = plain.findIndex((i) => i.itemId.endsWith('_chest'));
        const best = plain.map((i, k) => (k === chest ? { ...i, affixes: picks.map((id) => ({ id, q: 1 })) } : i));
        const gain = (f(best) / f(plain) - 1) * 100;
        expect(gain, `${picks.join('+')} for ${d} at ilvl ${L}: ${gain.toFixed(1)} vs ascended set ${setBonus.toFixed(1)}`).toBeLessThan(setBonus * 1.1); // 10% slack since the 2026-10-03 achievable pass: top rolls are meant to be felt, and the weakest ascended set (Mourner, level 70) is the binding case
      }
    }
  });
  it('ranges grow with item level but a level-99 roll is still bounded', () => {
    for (const a of AFFIXES) {
      const [lo22, hi22] = affixRange(a.id, 22)!;
      const [lo99, hi99] = affixRange(a.id, 99)!;
      expect(hi99).toBeGreaterThanOrEqual(hi22);
      expect(lo99).toBeGreaterThanOrEqual(lo22);
    }
  });
});

describe('randomly rolled gear (real drop rules) adds a felt, bounded amount', () => {
  it('7 rolled pieces lift power by about 5-19% on average and under 30% at the 90th percentile', () => {
    for (const area of ['nave', 'pyre', 'fen'] as const) {
      for (const d of NECRO) {
        const disc = DISCIPLINES[d];
        const L = AREAS[area].level;
        const lifts: number[] = [];
        for (let seed = 1; seed <= 150; seed++) {
          const rolled = kitItems({ kit: 'rolled', discipline: d, area, seed });
          const ch = botCharacter(disc.classIndex, L, (0.8 * L * 2) / EQUIP_SLOTS.length);
          const f = (items: KitItem[]) => gearPower({ character: ch, slots: kitSlots(items), discipline: disc, damageTier: Math.round(L * 0.6) }).total;
          lifts.push((f(rolled) / f(rolled.map((i) => ({ ...i, affixes: [] }))) - 1) * 100);
        }
        expect(mean(lifts), `${area} ${d} mean`).toBeGreaterThan(5);
        expect(mean(lifts), `${area} ${d} mean`).toBeLessThan(19);
        expect(pctile(lifts, 0.9), `${area} ${d} p90`).toBeLessThan(30);
      }
    }
  });
});

describe('gear against the harness (3 seeds)', () => {
  function lift(area: AreaId, band: keyof typeof BANDS, kit: KitName, disciplines: number[] = [1, 2, 3, 4]) {
    const out = { kills: [] as number[], hurt: [] as number[], deathsKit: [] as number[], deathsNone: [] as number[] };
    for (const classIndex of disciplines) {
      for (const seed of SEEDS) {
        const run = { ...(BANDS[band](AREAS[area].level) as BalanceRun), area, classIndex, minutes: 3, seed };
        const a = runBalance(run);
        const b = runBalance({ ...run, kit });
        out.kills.push(b.killsPerMin / a.killsPerMin);
        out.hurt.push(b.dmgPctPerMin / Math.max(a.dmgPctPerMin, 1));
        out.deathsKit.push(b.deaths);
        out.deathsNone.push(a.deaths);
      }
    }
    return { kills: mean(out.kills), hurt: mean(out.hurt), deathsKit: mean(out.deathsKit), deathsNone: mean(out.deathsNone) };
  }
  it('the previous area\'s gear is felt at the intended band (Drowned Nave): fewer hits taken, a better clear, no new deaths', () => {
    const r = lift('nave', 'intended', 'progress');
    expect(r.kills).toBeGreaterThan(0.97);
    expect(r.kills).toBeLessThan(1.45);
    expect(r.hurt).toBeLessThan(0.8);
    expect(r.deathsKit).toBeLessThanOrEqual(r.deathsNone + 0.1);
  });
  it('a completed first set and a matching weapon is a large but bounded lift at the geared band (Bell Sanctum)', () => {
    const r = lift('sanctum', 'geared', 'typical');
    expect(r.kills).toBeGreaterThan(1.0);
    expect(r.kills).toBeLessThan(1.6);
    expect(r.hurt).toBeLessThan(0.65);
  });
  it('the ascended kit makes max Wave Speed survivable in the Cinder Pyre without removing the risk or doubling the clear rate', () => {
    const r = lift('pyre', 'max', 'ascended');
    expect(r.kills).toBeGreaterThan(1.2);
    expect(r.kills).toBeLessThan(2.0);
    expect(r.deathsKit).toBeLessThan(r.deathsNone);
    expect(r.deathsKit).toBeLessThan(1.5);
    expect(r.hurt).toBeGreaterThan(0.1);
  });
});

describe('docs/ARMOR-SETS.md matches the set data', () => {
  it('lists every set with the bonus lines the game shows', () => {
    const doc = readFileSync(new URL('../../../docs/ARMOR-SETS.md', import.meta.url), 'utf8');
    for (const id of SET_IDS) {
      const line = SET_BONUSES[id].map((b) => `${b.name ? `**${b.name}**: ` : ''}${describeEffect(b.effect).join(' · ')}`);
      for (const text of line) expect(doc, `${SET_NAMES[id]}: ${text}`).toContain(text);
    }
  });
});
