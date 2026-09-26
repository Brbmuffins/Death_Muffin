/**
 * Balance report: `npm run balance` (runs through vite-node).
 * Prints farming rate, pacing and danger for each area at four level bands,
 * for each discipline. Targets live in BALANCE.md.
 *
 * Env: BALANCE_MINUTES (default 3), BALANCE_AREAS=graves,nave, BALANCE_BANDS=intended,max,
 *      BALANCE_DISCIPLINES=1,3, BALANCE_SEEDS=2 (averages seeds 42, 43, …).
 */
import { runBalance, type BalanceResult, type BalanceRun } from './harness';
import { AREAS, AREA_ORDER, type AreaId } from '../../content/areas';
import type { Difficulty } from '../../content/difficulty';
import { ascensionLevels } from '../../content/ascension';

const MINUTES = Number(process.env.BALANCE_MINUTES ?? 3);
const DIFFICULTY = (process.env.BALANCE_DIFFICULTY ?? 'medium') as Difficulty;
/** World Ascension rank; bands then anchor on the aged area level. */
const ASC = Math.max(0, Number(process.env.BALANCE_ASCENSION ?? 0));
const SEEDS = Math.max(1, Number(process.env.BALANCE_SEEDS ?? 1));
const list = (v: string | undefined) => (v ? v.split(',').map((s) => s.trim()) : null);
const areas = (list(process.env.BALANCE_AREAS) ?? ['graves', 'ossuary', 'nave', 'sanctum']) as AreaId[];
const disciplines = (list(process.env.BALANCE_DISCIPLINES) ?? ['1', '2', '3', '4']).map(Number);
const names: Record<number, string> = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver' };

/** Level bands relative to the area's level: how a player plausibly arrives and pushes. */
const BANDS: Record<string, (lvl: number) => Partial<BalanceRun>> = {
  /** Just arrived: at the area's level, a few damage tiers, waves at base speed. */
  intended: (lvl) => ({ level: lvl, damageTier: Math.round(lvl * 0.6), waveTier: 0, gearStats: Math.round(lvl * 0.8) }),
  /** Settled in: a few levels up, more damage, moderate Wave Speed. */
  geared: (lvl) => ({ level: lvl + 3, damageTier: Math.round(lvl * 0.9), waveTier: 3, gearStats: Math.round(lvl) }),
  /** Greedy: arrived-level power with Wave Speed pushed hard. */
  push: (lvl) => ({ level: lvl, damageTier: Math.round(lvl * 0.6), waveTier: 6, gearStats: Math.round(lvl * 0.8) }),
  /** Reckless: arrived-level power at max Wave Speed. Should kill a careless player. */
  max: (lvl) => ({ level: lvl, damageTier: Math.round(lvl * 0.6), waveTier: 8, gearStats: Math.round(lvl * 0.8) }),
};
const bandNames = list(process.env.BALANCE_BANDS) ?? Object.keys(BANDS);

/** Kills this area requires to open the next one (for pacing). */
function unlockKills(area: AreaId): number | null {
  for (const id of AREA_ORDER) if (AREAS[id].unlock?.area === area) return AREAS[id].unlock!.kills;
  return null;
}

function averaged(run: BalanceRun): BalanceResult {
  const results = Array.from({ length: SEEDS }, (_, i) => runBalance({ ...run, difficulty: DIFFICULTY, seed: 42 + i, ascension: ASC }));
  if (SEEDS === 1) return results[0];
  const avg = { ...results[0] } as unknown as Record<string, number>;
  for (const key of Object.keys(avg)) {
    if (key === 'run') continue;
    avg[key] = results.reduce((s, r) => s + (r as unknown as Record<string, number>)[key], 0) / SEEDS;
  }
  avg.minHpPct = Math.min(...results.map((r) => r.minHpPct));
  // Earliest first death across seeds (-1 only if every seed survived).
  const deaths = results.map((r) => r.firstDeathSec).filter((s) => s >= 0);
  avg.firstDeathSec = deaths.length ? Math.min(...deaths) : -1;
  return avg as unknown as BalanceResult;
}

const cols: [string, number][] = [
  ['area', 8], ['band', 9], ['disc', 12], ['lvl', 4], ['dmgT', 5], ['waveT', 6], ['kills/m', 8], ['gold/m', 7], ['xp/m', 6],
  ['hurt%/m', 8], ['minHp', 6], ['avgHp', 6], ['deaths', 7], ['1st†s', 6], ['ttk s', 6], ['peak', 5], ['lvl+', 5], ['surge', 6], ['unlock m', 8],
];
const pad = (s: string | number, n: number) => String(s).padEnd(n);
const rows: string[] = [cols.map(([h, n]) => pad(h, n)).join('')];
for (const area of areas) {
  const lvl = AREAS[area].level + ascensionLevels(ASC);
  const needed = unlockKills(area);
  for (const band of bandNames) {
    for (const classIndex of disciplines) {
      const res = averaged({ ...(BANDS[band](lvl) as BalanceRun), area, classIndex, minutes: MINUTES });
      const r = res.run;
      const cells = [
        area, band, names[classIndex], r.level, r.damageTier, r.waveTier,
        res.killsPerMin.toFixed(1), res.goldPerMin.toFixed(0), res.xpPerMin.toFixed(0),
        res.dmgPctPerMin.toFixed(0), res.minHpPct.toFixed(0), res.avgHpPct.toFixed(0), res.deaths.toFixed(SEEDS > 1 ? 1 : 0),
        res.firstDeathSec < 0 ? '-' : res.firstDeathSec.toFixed(0),
        res.avgTtkSec.toFixed(1), res.peakEnemies.toFixed(0), res.levelsGained.toFixed(SEEDS > 1 ? 1 : 0),
        `${res.surgesCleared.toFixed(0)}/${(res.surgesCleared + res.surgesFailed).toFixed(0)}`,
        needed && res.killsPerMin ? (needed / res.killsPerMin).toFixed(1) : '-',
      ];
      rows.push(cells.map((c, i) => pad(c, cols[i][1])).join(''));
    }
  }
}
console.log(`\nCrossworlds balance report: ${MINUTES} simulated minutes per row, ${SEEDS} seed(s), difficulty ${DIFFICULTY}, ascension ${ASC}`);
console.log('hurt%/m = damage taken per minute as % of max HP · 1st†s = seconds to first death · unlock m = minutes of kills to open the next area\n');
console.log(rows.join('\n'));
