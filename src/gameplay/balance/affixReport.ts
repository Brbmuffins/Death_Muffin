/**
 * Affix vs set vs legendary power check, from the deterministic power score (`gearPower`, the Reliquary arrow): `npm run balance:affix`.
 * Fast (no sim). Prints, per item level, what one affix roll, a "good drop" (2-3 affixes) and a rolled kit add, next to what a completed
 * armor set bonus and a legendary set bonus add (bonus lines only: the same pieces worn without the set effect).
 * Env: AFFIX_ILVLS (12,25,47,70).
 */
import { AREAS, type AreaId } from '../../content/areas';
import { DISCIPLINES } from '../../content/disciplines';
import { ARMOR_BY_ID, ARMOR_PARTS } from '../../content/armorSets';
import { EQUIP_SLOTS } from '../../content/gear';
import { AFFIXES, affixRange } from '../affixRules';
import { gearPower } from '../gearStats';
import { botCharacter } from './harness';
import { kitItems, kitSlots, type KitItem } from './kits';
import { legendaryItemId } from '../../content/legendarySets';

const NECRO = ['ossuary', 'gravecaller', 'mourner', 'rotweaver'] as const;
type Necro = (typeof NECRO)[number];
const LEGSET: Record<Necro, string> = { ossuary: 'colossus_mantle', gravecaller: 'legion_unburied', mourner: 'requiem_wraiths', rotweaver: 'plague_choir' };
const HOME_LEVER: Record<Necro, string> = { ossuary: 's_thrall_hp', gravecaller: 'p_thrall_dmg', mourner: 'p_essence_regen', rotweaver: 's_miasma' };
const ILVLS = (process.env.AFFIX_ILVLS ?? '12,25,47,70').split(',').map(Number);
const areaOf = (L: number): AreaId => (L <= 12 ? 'nave' : L <= 25 ? 'cloister' : 'fen');
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
const f = (n: number, k = 1) => n.toFixed(k);

const power = (d: Necro, L: number, items: KitItem[]) => {
  const disc = DISCIPLINES[d];
  const character = botCharacter(disc.classIndex, L, (0.8 * L * 2) / EQUIP_SLOTS.length);
  return gearPower({ character, slots: kitSlots(items), discipline: disc, damageTier: Math.round(L * 0.6) } as never).total;
};
const plainKit = (d: Necro, L: number): KitItem[] => kitItems({ kit: 'typical', discipline: d, area: areaOf(L) }).map((i) => ({ ...i, ilvl: L, affixes: [] }));
const withOnChest = (kit: KitItem[], affixes: { id: string; q: number }[]) => kit.map((i) => (i.itemId.endsWith('_chest') ? { ...i, affixes } : i));

console.log('AFFIX VALUE: % of power one affix adds on the chest of a plain typical kit (min / median / max roll), by discipline, and the median averaged over the four');
for (const L of ILVLS) {
  console.log(`\nilvl ${L}`);
  console.log('affix'.padEnd(18) + 'range'.padEnd(12) + NECRO.map((d) => d.padEnd(18)).join(''));
  for (const a of AFFIXES) {
    const [lo, hi] = affixRange(a.id, L)!;
    const meds: number[] = [];
    const cells = NECRO.map((d) => {
      const plain = plainKit(d, L);
      const base = power(d, L, plain);
      const at = (q: number) => (power(d, L, withOnChest(plain, [{ id: a.id, q }])) / base - 1) * 100;
      meds.push(at(0.5));
      return `${f(at(0))}/${f(at(0.5))}/${f(at(1))}`.padEnd(18);
    });
    console.log(a.id.padEnd(18) + `${lo}-${hi}`.padEnd(12) + cells.join('') + `mean median ${f(mean(meds), 2)}`);
  }
}

console.log('\nSET BONUS VALUE: % of power the bonus lines of a whole set add (same pieces, set effect off), for its own wearer');
for (const L of ILVLS) {
  const row: string[] = [];
  for (const d of NECRO) {
    const mk = (ids: string[], plain: boolean): KitItem[] => ids.map((itemId) => ({ itemId, plain, ilvl: L, affixes: [] }));
    const sets = {
      first: ARMOR_PARTS.map((p) => `set_${d}_${p}`),
      asc: ARMOR_PARTS.map((p) => `set_${d}_ascended_${p}`),
      leg: ARMOR_PARTS.map((p) => legendaryItemId(LEGSET[d], p)),
    };
    const v = (ids: string[]) => (ids.every((i) => ARMOR_BY_ID[i]) ? (power(d, L, mk(ids, false)) / power(d, L, mk(ids, true)) - 1) * 100 : NaN);
    row.push(`${d} first ${f(v(sets.first))} asc ${f(v(sets.asc))} leg ${f(v(sets.leg))}`);
  }
  console.log(`ilvl ${L}: ${row.join(' | ')}`);
}

console.log('\nGOOD DROP: affixes on ONE armor piece (chest), % of whole-kit power. stat+stat: Occult+Stout; lever: Occult + home lever; 3aff adds Stout (q 0.9)');
for (const L of ILVLS) {
  const row: string[] = [];
  for (const d of NECRO) {
    const plain = plainKit(d, L);
    const base = power(d, L, plain);
    const v = (ids: string[], q: number) => (power(d, L, withOnChest(plain, ids.map((id) => ({ id, q })))) / base - 1) * 100;
    row.push(`${d} 2stat ${f(v(['p_int', 's_vit'], 0.75))} stat+lever ${f(v(['p_int', HOME_LEVER[d]], 0.75))} 3aff ${f(v(['p_int', 's_vit', HOME_LEVER[d]], 0.9))}`);
  }
  console.log(`ilvl ${L}: ${row.join(' | ')}`);
}

console.log('\nROLLED KIT (real drop rules, 7 pieces, 150 seeds): mean / p90 % of power the affixes add');
for (const area of ['nave', 'pyre', 'fen'] as AreaId[]) {
  const L = AREAS[area].level;
  const row: string[] = [];
  for (const d of NECRO) {
    const lifts: number[] = [];
    for (let seed = 1; seed <= 150; seed++) {
      const r = kitItems({ kit: 'rolled', discipline: d, area, seed });
      lifts.push((power(d, L, r) / power(d, L, r.map((i) => ({ ...i, affixes: [] }))) - 1) * 100);
    }
    lifts.sort((a, b) => a - b);
    row.push(`${d} ${f(mean(lifts))}/${f(lifts[Math.floor(0.9 * lifts.length)])}`);
  }
  console.log(`${area} (L${L}): ${row.join(' | ')}`);
}
