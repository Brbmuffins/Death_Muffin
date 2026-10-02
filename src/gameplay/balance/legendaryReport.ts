/**
 * Legendary set power check: `npx vite-node src/gameplay/balance/legendaryReport.ts` (docs/LEGENDARY-SETS.md).
 * Runs each necromancer with and without its full (2+4+5 piece) legendary bonus, forced on through the harness `effect`
 * option, and prints the ratio of kills/min (clear speed) and of damage taken, plus deaths. The set's armour stats are NOT
 * included (a kit would add them); this isolates the mechanics + the set's own multipliers.
 *
 * Env: BALANCE_MINUTES (3), BALANCE_SEEDS (4), BALANCE_AREAS (nave,sanctum), BALANCE_BANDS (intended,push,max), BALANCE_KIT (none).
 */
import { runBalance, type BalanceResult, type BalanceRun } from './harness';
import { AREAS, type AreaId } from '../../content/areas';
import { BANDS } from './bands';
import type { SetEffect } from '../../content/setBonuses';
import type { KitName } from './kits';

const MINUTES = Number(process.env.BALANCE_MINUTES ?? 3);
const SEEDS = Math.max(1, Number(process.env.BALANCE_SEEDS ?? 4));
const list = (v: string | undefined, d: string[]) => (v ? v.split(',').map((s) => s.trim()) : d);
const areas = list(process.env.BALANCE_AREAS, ['nave', 'sanctum']) as AreaId[];
const bands = list(process.env.BALANCE_BANDS, ['intended', 'push', 'max']);
const KIT = (process.env.BALANCE_KIT ?? 'none') as KitName;

/** The full-set sum of every tier in docs/LEGENDARY-SETS.md (the numbers the set bonuses carry). */
export const FULL_SETS: Record<number, { name: string; effect: SetEffect; soul: boolean }> = {
  2: { name: 'Gravecaller / Legion of the Unburied', soul: false, effect: { mult: { thrallDamageMult: 1.15 }, add: { thrallDeathBurst: 0.6, thrallCap: 2, championEvery: 5, spearRally: 0.75 } } },
  1: { name: 'Ossuary / Colossus Mantle', soul: false, effect: { mult: { thrallHpMult: 1.25 }, add: { wardReflect: 0.4, colossusGuard: 0.25, litanyShatter: 3 } } },
  3: { name: 'Mourner / Requiem of Wraiths', soul: true, effect: { mult: { essenceRegenMult: 1.3, soulHarvestRateMult: 2 }, add: { corpseWisp: 8, wraithNova: 0.8 } } },
  4: { name: 'Rotweaver / Plague Choir', soul: false, effect: { mult: { miasmaRadiusMult: 1.15 }, add: { miasmaSpreadsWithered: 1, witheredBurstAt: 10 } } },
};

function avg(run: BalanceRun): BalanceResult {
  const rs = Array.from({ length: SEEDS }, (_, i) => runBalance({ ...run, seed: 42 + i }));
  const out = { ...rs[0] } as unknown as Record<string, number>;
  for (const k of Object.keys(out)) if (k !== 'run') out[k] = rs.reduce((s, r) => s + (r as unknown as Record<string, number>)[k], 0) / SEEDS;
  return out as unknown as BalanceResult;
}

const f = (n: number, d = 1) => n.toFixed(d);
console.log(`legendary sets, ${SEEDS} seeds x ${MINUTES} sim-min, kit ${KIT}; ratio = with set / without`);
console.log(['area', 'band', 'disc', 'soul', 'kills/m', '->', 'x', 'hurt%/m', '->', 'x', 'deaths', '->', 'avgHp', '->', 'thr'].map((h) => h.padEnd(9)).join(''));
let sumKills = 0;
let sumHurt = 0;
let n = 0;
for (const area of areas) {
  const lvl = AREAS[area].level;
  for (const band of bands) {
    for (const [idx, set] of Object.entries(FULL_SETS)) {
      const base = { ...(BANDS[band](lvl) as BalanceRun), area, classIndex: Number(idx), minutes: MINUTES, kit: KIT };
      // Requiem only means something with Soul Harvest modelled, so that discipline runs both sides with it on.
      const a = avg({ ...base, soulHarvest: set.soul });
      const b = avg({ ...base, soulHarvest: set.soul, effect: set.effect });
      const kx = b.killsPerMin / a.killsPerMin;
      const hx = b.dmgPctPerMin / Math.max(0.01, a.dmgPctPerMin);
      sumKills += kx;
      sumHurt += hx;
      n++;
      console.log([area, band, set.name.split(' / ')[0], set.soul ? 'on' : '-', f(a.killsPerMin), f(b.killsPerMin), `${f(kx, 2)}x`, f(a.dmgPctPerMin, 0), f(b.dmgPctPerMin, 0), `${f(hx, 2)}x`,
        f(a.deaths), f(b.deaths), f(a.avgHpPct, 0), f(b.avgHpPct, 0), f(b.avgThralls)].map((c) => String(c).padEnd(9)).join(''));
    }
  }
}
console.log(`mean clear-speed ratio ${f(sumKills / n, 2)}x, mean damage-taken ratio ${f(sumHurt / n, 2)}x over ${n} rows`);
