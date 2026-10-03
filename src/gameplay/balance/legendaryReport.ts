/**
 * Legendary set power check: `npx vite-node src/gameplay/balance/legendaryReport.ts` (docs/LEGENDARY-SETS.md).
 * Runs each necromancer with and without its full (2+4+5 piece) legendary bonus, forced on through the harness `effect`
 * option, and prints the ratio of kills/min (clear speed) and of damage taken, plus deaths. The set's armour stats are NOT
 * included (a kit would add them); this isolates the mechanics + the set's own multipliers.
 *
 * Also measures the 2-piece and 4-piece legendary tiers and the same discipline's first and ascended full sets (ordering check),
 * and prints a per-discipline summary. BALANCE_VERBOSE=1 prints every row.
 *
 * Env: BALANCE_MINUTES (3), BALANCE_SEEDS (4), BALANCE_AREAS (nave,sanctum), BALANCE_BANDS (intended,push,max), BALANCE_KIT (none).
 */
import { runBalance, type BalanceResult, type BalanceRun } from './harness';
import { AREAS, type AreaId } from '../../content/areas';
import { BANDS } from './bands';
import type { SetEffect } from '../../content/setBonuses';
import { FULL_SETS, fullSet } from './legendaryFull';
import type { KitName } from './kits';

const MINUTES = Number(process.env.BALANCE_MINUTES ?? 3);
const SEEDS = Math.max(1, Number(process.env.BALANCE_SEEDS ?? 4));
const list = (v: string | undefined, d: string[]) => (v ? v.split(',').map((s) => s.trim()) : d);
const areas = list(process.env.BALANCE_AREAS, ['nave', 'sanctum']) as AreaId[];
const bands = list(process.env.BALANCE_BANDS, ['intended', 'push', 'max']);
const KIT = (process.env.BALANCE_KIT ?? 'none') as KitName;

function avg(run: BalanceRun): BalanceResult {
  const rs = Array.from({ length: SEEDS }, (_, i) => runBalance({ ...run, seed: 42 + i }));
  const out = { ...rs[0] } as unknown as Record<string, number>;
  for (const k of Object.keys(out)) if (k !== 'run' && k !== 'casts') out[k] = rs.reduce((s, r) => s + (r as unknown as Record<string, number>)[k], 0) / SEEDS;
  return out as unknown as BalanceResult;
}

const f = (n: number, d = 1) => n.toFixed(d);
const VERBOSE = !!process.env.BALANCE_VERBOSE;
const TIERS: [string, (set: (typeof FULL_SETS)[number]) => SetEffect][] = [
  ['first', (s) => fullSet(s.plain)],
  ['asc', (s) => fullSet(s.asc)],
  ['leg2', (s) => fullSet(s.id, 2)],
  ['leg4', (s) => fullSet(s.id, 4)],
  ['leg5', (s) => fullSet(s.id, 5)],
];
console.log(`legendary sets, ${SEEDS} seeds x ${MINUTES} sim-min, kit ${KIT}; ratio = with set / without`);
if (VERBOSE) console.log(['area', 'band', 'disc', 'tier', 'kills/m', '->', 'x', 'hurt%/m', '->', 'x', 'deaths', '->', 'thr'].map((h) => h.padEnd(10)).join(''));
type Acc = { k: number; h: number; n: number };
const acc: Record<string, Record<string, Acc>> = {};
for (const area of areas) {
  const lvl = AREAS[area].level;
  for (const band of bands) {
    for (const [idx, set] of Object.entries(FULL_SETS)) {
      const name = set.name.split(' / ')[0];
      const base = { ...(BANDS[band](lvl) as BalanceRun), area, classIndex: Number(idx), minutes: MINUTES, kit: KIT, soulHarvest: set.soul };
      // Requiem only means something with Soul Harvest modelled, so that discipline runs both sides with it on.
      const a = avg(base);
      for (const [tier, eff] of TIERS) {
        const b = avg({ ...base, effect: eff(set) });
        const kx = b.killsPerMin / a.killsPerMin;
        const hx = b.dmgPctPerMin / Math.max(0.01, a.dmgPctPerMin);
        const cell = ((acc[name] ??= {})[tier] ??= { k: 0, h: 0, n: 0 });
        cell.k += kx; cell.h += hx; cell.n++;
        if (VERBOSE) console.log([area, band, name, tier, f(a.killsPerMin), f(b.killsPerMin), `${f(kx, 2)}x`, f(a.dmgPctPerMin, 0), f(b.dmgPctPerMin, 0), `${f(hx, 2)}x`, f(a.deaths), f(b.deaths), f(b.avgThralls)].map((c) => String(c).padEnd(10)).join(''));
      }
    }
  }
}
// Summary: mean clear-speed ratio / mean damage-taken ratio per discipline and tier; power = clear speed / damage taken.
console.log('\nper discipline: clear-speed x / damage-taken x / power (clear / damage), mean over area x band rows');
console.log(['disc', ...TIERS.map(([t]) => t)].map((h) => h.padEnd(24)).join(''));
const powers: Record<string, number> = {};
for (const [name, tiers] of Object.entries(acc)) {
  const cells = TIERS.map(([t]) => {
    const c = tiers[t];
    const k = c.k / c.n, h = c.h / c.n;
    if (t === 'leg5') powers[name] = k / h;
    return `${f(k, 2)} / ${f(h, 2)} / ${f(k / h, 2)}`.padEnd(24);
  });
  console.log(name.padEnd(24) + cells.join(''));
}
const pv = Object.values(powers);
console.log(`legendary full-set power spread: min ${f(Math.min(...pv), 2)} max ${f(Math.max(...pv), 2)} (max/min ${f(Math.max(...pv) / Math.min(...pv), 2)})`);
const mean = (t: string, key: 'k' | 'h') => Object.values(acc).reduce((s, tiers) => s + tiers[t][key] / tiers[t].n, 0) / Object.keys(acc).length;
console.log(`mean legendary full set: clear-speed ${f(mean('leg5', 'k'), 2)}x, damage-taken ${f(mean('leg5', 'h'), 2)}x`);
