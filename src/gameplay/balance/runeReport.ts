/**
 * Relic runes against the harness: `npm run balance:runes` (vite-node). For each rune it runs the four necromancers with only that rune
 * socketed and prints the change in what the bot achieves (kills/min, time to kill, damage taken, deaths, living thralls) against the same
 * seeds with no rune. Runes should add build variety, not raw power: about 0-10% either way.
 *
 * Env: RUNE_TUNE="ring.damageMult=0.85,volley.damageFrac=0.35" overrides RUNE_TUNING numbers for this run only (to try a value before editing content/runes.ts),
 *      RUNE_WEAPON (scythe, with RUNE_KIT=typical), RUNE_AREA (nave), RUNE_BAND (push), RUNE_SEEDS (6), RUNE_MINUTES (3), RUNE_DISCIPLINES (1,2,3,4), RUNE_KIT (typical|none|...), RUNE_ONLY (comma list of rune ids).
 * Weapons: the kit's staff makes the left click a needle; a scythe would ignore the needle runes, so the default kit is the historical bare bot (`none`)
 * plus the `typical` kit as a second table (RUNE_KIT=typical).
 */
import { runBalance, type BalanceResult, type BalanceRun } from './harness';
import { AREAS, type AreaId } from '../../content/areas';
import { RUNES, RUNE_IDS, RUNE_TUNING, type RuneId } from '../../content/runes';
import { BANDS } from './bands';
import type { KitName } from './kits';
import type { NecroKind } from '../../content/necroWeapons';

// RUNE_TUNE: dotted paths into RUNE_TUNING, applied before anything runs (the object is plain data at run time).
for (const pair of (process.env.RUNE_TUNE ?? '').split(',').filter(Boolean)) {
  const [path, value] = pair.split('=');
  const keys = path.split('.');
  let o = RUNE_TUNING as unknown as Record<string, unknown>;
  for (const k of keys.slice(0, -1)) o = o[k] as Record<string, unknown>;
  if (!(keys[keys.length - 1] in o)) throw new Error(`RUNE_TUNE: no such number ${path}`);
  o[keys[keys.length - 1]] = Number(value);
}

const area = (process.env.RUNE_AREA ?? 'nave') as AreaId;
const band = process.env.RUNE_BAND ?? 'push';
const SEEDS = Number(process.env.RUNE_SEEDS ?? 6);
const MINUTES = Number(process.env.RUNE_MINUTES ?? 3);
const kit = (process.env.RUNE_KIT ?? 'none') as KitName;
const discs = (process.env.RUNE_DISCIPLINES ?? '1,2,3,4').split(',').map(Number);
const only = process.env.RUNE_ONLY ? process.env.RUNE_ONLY.split(',') : null;
/** RUNE_WEAPON=scythe: swap the kit's main hand (needs RUNE_KIT other than none), to measure the runes riding a scythe's arc. */
const weapon = process.env.RUNE_WEAPON as NecroKind | undefined;
const names: Record<number, string> = { 1: 'ossuary', 2: 'gravecaller', 3: 'mourner', 4: 'rotweaver' };

const mean = (rs: BalanceResult[], f: (r: BalanceResult) => number) => rs.reduce((a, r) => a + f(r), 0) / rs.length;
const pc = (x: number, y: number) => (y ? (x / y - 1) * 100 : 0);
const sum = (rs: BalanceResult[]) => ({
  kills: mean(rs, (r) => r.killsPerMin), gold: mean(rs, (r) => r.goldPerMin), ttk: mean(rs, (r) => r.avgTtkSec), hurt: mean(rs, (r) => r.dmgPctPerMin),
  deaths: mean(rs, (r) => r.deaths), thralls: mean(rs, (r) => r.avgThralls),
});

const bandRun = BANDS[band](AREAS[area].level) as BalanceRun;
const go = (classIndex: number, rune?: RuneId) =>
  Array.from({ length: SEEDS }, (_, s) => runBalance({ ...bandRun, area, classIndex, minutes: MINUTES, seed: 42 + s, kit, ...(weapon ? { kitOverride: { main: weapon, off: null } } : {}), ...(rune ? { runes: { [RUNES[rune].rite]: rune } } : {}) }));

console.log(`rune balance: ${area} ${band}, kit ${kit}, ${SEEDS} seeds x ${MINUTES} min (percent change versus no rune; ttk and hurt: lower is better)`);
const totals: Record<string, { kills: number; ttk: number; hurt: number }[]> = {};
for (const classIndex of discs) {
  const base = sum(go(classIndex));
  console.log(`\n${names[classIndex]}: no rune = ${base.kills.toFixed(1)} kills/min, ${base.gold.toFixed(0)} gold/min, ttk ${base.ttk.toFixed(2)} s, hurt ${base.hurt.toFixed(0)}%/min, deaths ${base.deaths.toFixed(2)}, thralls ${base.thralls.toFixed(2)}`);
  console.log(`${'rune'.padEnd(26)} kills%  gold%   ttk%  hurt%  deaths  thralls`);
  for (const id of RUNE_IDS) {
    if (only && !only.includes(id)) continue;
    const r = sum(go(classIndex, id));
    (totals[id] ??= []).push({ kills: pc(r.kills, base.kills), ttk: pc(r.ttk, base.ttk), hurt: pc(r.hurt, base.hurt) });
    console.log(`${RUNES[id].name.padEnd(26)} ${pc(r.kills, base.kills).toFixed(1).padStart(6)} ${pc(r.gold, base.gold).toFixed(1).padStart(6)} ${pc(r.ttk, base.ttk).toFixed(1).padStart(6)} ${pc(r.hurt, base.hurt).toFixed(0).padStart(6)} ${(r.deaths - base.deaths).toFixed(2).padStart(7)} ${(r.thralls - base.thralls).toFixed(2).padStart(8)}`);
  }
}
console.log('\nmean over the disciplines run:');
for (const [id, rows] of Object.entries(totals)) {
  const m = (f: (x: (typeof rows)[number]) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
  console.log(`${RUNES[id as RuneId].name.padEnd(26)} kills ${m((r) => r.kills).toFixed(1).padStart(6)}%  ttk ${m((r) => r.ttk).toFixed(1).padStart(6)}%  hurt ${m((r) => r.hurt).toFixed(0).padStart(5)}%`);
}
