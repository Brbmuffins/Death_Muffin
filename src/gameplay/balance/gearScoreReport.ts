/**
 * Does the Reliquary's up/down arrow (gearStats.gearPower) rank gear the way the harness does? `npm run balance:score` (vite-node).
 *
 * For each necromancer it takes the `typical` kit, applies a list of single swaps (a different chest, a different weapon, an
 * affix added / swapped, a set piece removed or added) and prints, per swap, the change in the power score and the change in
 * what the bot achieves (kills/min, damage taken, time to kill) over several seeds in a stress band where the bot is not capped by the
 * wave supply. It ends with the Spearman rank correlation of score against each harness metric.
 *
 * Env: SCORE_AREA (nave), SCORE_BAND (push), SCORE_SEEDS (8), SCORE_DISCIPLINES (1,2,3,4).
 */
import { runBalance, botCharacter, type BalanceRun, type BalanceResult } from './harness';
import { AREAS, type AreaId } from '../../content/areas';
import { disciplineFor } from '../../content/disciplines';
import { gearPower } from '../gearStats';
import { BANDS } from './bands';
import { kitItems, kitSlots, type KitItem } from './kits';
import { ARMOR_PARTS } from '../../content/armorSets';
import { EQUIP_SLOTS, equippedBySlot } from '../../content/gear';

const area = (process.env.SCORE_AREA ?? 'nave') as AreaId;
const band = process.env.SCORE_BAND ?? 'push';
const SEEDS = Number(process.env.SCORE_SEEDS ?? 8);
const discs = (process.env.SCORE_DISCIPLINES ?? '1,2,3,4').split(',').map(Number);
const names: Record<number, string> = { 1: 'ossuary', 2: 'gravecaller', 3: 'mourner', 4: 'rotweaver' };

const isWeapon = (i: KitItem) => /^(staff|scythe|wand|sickle)_/.test(i.itemId);
const isOff = (i: KitItem) => /^(skull_focus|grimoire|mourning_bell)_/.test(i.itemId);
const part = (i: KitItem) => ARMOR_PARTS.find((p) => i.itemId.endsWith(`_${p}`));
const withAff = (items: KitItem[], pick: (i: KitItem) => boolean, affixes: { id: string; q: number }[]) => items.map((i) => (pick(i) ? { ...i, affixes } : i));
const swapSet = (items: KitItem[], set: string, parts: string[]) => items.map((i) => (part(i) && parts.includes(part(i)!) ? { ...i, itemId: `set_${set}_${part(i)}` } : i));

interface Variant { name: string; make: (base: KitItem[], disc: string) => KitItem[] }
const VARIANTS: Variant[] = [
  { name: 'typical kit', make: (b) => b },
  { name: 'no kit at all', make: () => [] },
  { name: 'drop weapon', make: (b) => b.filter((i) => !isWeapon(i) && !isOff(i)) },
  { name: 'drop chest', make: (b) => b.filter((i) => part(i) !== 'chest') },
  { name: 'drop feet', make: (b) => b.filter((i) => part(i) !== 'feet') },
  { name: 'break set (swap head+hands to warden)', make: (b) => swapSet(b, 'warden', ['head', 'hands']) },
  { name: 'break set (swap chest to monk)', make: (b) => swapSet(b, 'monk', ['chest']) },
  { name: 'ascended chest + legs (mixed sets)', make: (b, d) => b.map((i) => (part(i) === 'chest' || part(i) === 'legs' ? { ...i, itemId: `set_${d}_ascended_${part(i)}` } : i)) },
  { name: 'full ascended set, first weapon', make: (b, d) => b.map((i) => (part(i) ? { ...i, itemId: `set_${d}_ascended_${part(i)}` } : i)) },
  { name: 'weapon: staff', make: (b) => b.filter((i) => !isWeapon(i) && !isOff(i)).concat([{ itemId: 'staff_gold', ilvl: 12, affixes: [] }]) },
  { name: 'weapon: scythe', make: (b) => b.filter((i) => !isWeapon(i) && !isOff(i)).concat([{ itemId: 'scythe_gold', ilvl: 12, affixes: [] }]) },
  { name: 'weapon: wand + grimoire', make: (b) => b.filter((i) => !isWeapon(i) && !isOff(i)).concat([{ itemId: 'wand_gold', ilvl: 12, affixes: [] }, { itemId: 'grimoire_gold', ilvl: 12, affixes: [] }]) },
  { name: 'weapon: sickle + skull focus', make: (b) => b.filter((i) => !isWeapon(i) && !isOff(i)).concat([{ itemId: 'sickle_gold', ilvl: 12, affixes: [] }, { itemId: 'skull_focus_gold', ilvl: 12, affixes: [] }]) },
  { name: 'weapon: wand + mourning bell', make: (b) => b.filter((i) => !isWeapon(i) && !isOff(i)).concat([{ itemId: 'wand_gold', ilvl: 12, affixes: [] }, { itemId: 'mourning_bell_gold', ilvl: 12, affixes: [] }]) },
  ...['p_thrall_dmg', 's_thrall_hp', 'p_essence_regen', 's_miasma', 'p_withered', 's_ward', 'p_int', 's_vit'].map((id): Variant => ({
    name: `+${id} q1 on chest`, make: (b) => withAff(b, (i) => part(i) === 'chest', [{ id, q: 1 }]),
  })),
  ...['p_thrall_dmg', 's_thrall_hp', 's_ward'].map((id): Variant => ({
    name: `+${id} q1 on chest and weapon`, make: (b) => withAff(b, (i) => part(i) === 'chest' || (isWeapon(i)), [{ id, q: 1 }]),
  })),
];

const rank = (xs: number[]) => {
  const idx = xs.map((x, i) => [x, i] as const).sort((a, b) => a[0] - b[0]);
  const r = new Array<number>(xs.length);
  for (let k = 0; k < idx.length; ) {
    let j = k;
    while (j + 1 < idx.length && idx[j + 1][0] === idx[k][0]) j++;
    for (let m = k; m <= j; m++) r[idx[m][1]] = (k + j) / 2;
    k = j + 1;
  }
  return r;
};
const pearson = (a: number[], b: number[]) => {
  const ma = a.reduce((s, x) => s + x, 0) / a.length;
  const mb = b.reduce((s, x) => s + x, 0) / b.length;
  let n = 0, da = 0, db = 0;
  for (let i = 0; i < a.length; i++) { n += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) ** 2; db += (b[i] - mb) ** 2; }
  return da && db ? n / Math.sqrt(da * db) : 0;
};
const spearman = (a: number[], b: number[]) => pearson(rank(a), rank(b));

const allScore: number[] = [], allKills: number[] = [], allHurt: number[] = [], allTtk: number[] = [];
console.log(`gear score vs harness: ${area} ${band}, ${SEEDS} seeds (percent change versus the typical kit)`);
for (const classIndex of discs) {
  const id = names[classIndex];
  const disc = disciplineFor(classIndex);
  const bandRun = BANDS[band](AREAS[area].level) as BalanceRun;
  const base = kitItems({ kit: 'typical', discipline: id, area });
  const rows: { name: string; score: number; kills: number; hurt: number; ttk: number; deaths: number }[] = [];
  for (const v of VARIANTS) {
    const items = v.make(base, id);
    const slots = kitSlots(items);
    const covered = Object.keys(equippedBySlot(slots)).length;
    const character = botCharacter(classIndex, bandRun.level!, (bandRun.gearStats ?? 0) * (1 - covered / EQUIP_SLOTS.length));
    const score = gearPower({ character, slots, discipline: disc, damageTier: bandRun.damageTier ?? 0 }).total;
    const rs: BalanceResult[] = [];
    for (let s = 0; s < SEEDS; s++) rs.push(runBalance({ ...bandRun, area, classIndex, minutes: 3, seed: 42 + s, slots }));
    const m = (f: (r: BalanceResult) => number) => rs.reduce((a, r) => a + f(r), 0) / rs.length;
    rows.push({ name: v.name, score, kills: m((r) => r.killsPerMin), hurt: m((r) => r.dmgPctPerMin), ttk: m((r) => r.avgTtkSec), deaths: m((r) => r.deaths) });
  }
  const b = rows[0];
  console.log(`\n${id}\n${'variant'.padEnd(44)} score%  kills%  hurt%   ttk%  deaths`);
  const pc = (x: number, y: number) => ((x / y - 1) * 100);
  const d = rows.slice(1).map((r) => ({ name: r.name, s: pc(r.score, b.score), k: pc(r.kills, b.kills), h: pc(r.hurt, b.hurt), t: pc(r.ttk, b.ttk), deaths: r.deaths }));
  for (const r of d) console.log(`${r.name.padEnd(44)} ${r.s.toFixed(1).padStart(6)} ${r.k.toFixed(1).padStart(7)} ${r.h.toFixed(0).padStart(6)} ${r.t.toFixed(0).padStart(6)} ${r.deaths.toFixed(2).padStart(7)}`);
  console.log(`spearman(score, kills) ${spearman(d.map((r) => r.s), d.map((r) => r.k)).toFixed(2)}  (score, -hurt) ${spearman(d.map((r) => r.s), d.map((r) => -r.h)).toFixed(2)}  (score, -ttk) ${spearman(d.map((r) => r.s), d.map((r) => -r.t)).toFixed(2)}`);
  for (const r of d) { allScore.push(r.s); allKills.push(r.k); allHurt.push(r.h); allTtk.push(r.t); }
}
console.log(`\nALL spearman(score, kills) ${spearman(allScore, allKills).toFixed(2)}  (score, -hurt) ${spearman(allScore, allHurt.map((x) => -x)).toFixed(2)}  (score, -ttk) ${spearman(allScore, allTtk.map((x) => -x)).toFixed(2)}`);
