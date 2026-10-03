/**
 * Catacomb Depths balance report: `npm run balance:depths` (vite-node).
 * The necromancer bot fights a held floor of each depth (the same depth re-rolled when its stair opens), beside the same hero in the
 * Cinder Pyre / Mourning Fen, which are level-scaled the same way, so "how much harder is depth d than the hunting ground at my level"
 * reads off one table. The bot never walks to the stair, so floors cost it nothing between clears; `floors/m` is its clear pace while
 * fighting, and a real descent adds a few seconds of walking per floor.
 *
 * Env: DEPTH_LEVELS=20,40,60 (hero level) DEPTH_DEPTHS=1,10,20 DEPTH_BANDS=intended,geared DEPTH_DISCIPLINES=1,2,3,4
 *      BALANCE_MINUTES (3) BALANCE_SEEDS (2) BALANCE_DIFFICULTY (medium) DEPTH_REFERENCE=pyre,fen (ground rows; '' for none).
 */
import { runBalance, type BalanceResult, type BalanceRun } from './harness';
import { depthEnemyLevel } from '../../content/depths';
import type { AreaId } from '../../content/areas';
import type { Difficulty } from '../../content/difficulty';
import { BANDS } from './bands';
import type { KitName } from './kits';

const list = (v: string | undefined, d: string[]) => (v !== undefined ? v.split(',').map((s) => s.trim()).filter(Boolean) : d);
const MINUTES = Number(process.env.BALANCE_MINUTES ?? 3);
const SEEDS = Math.max(1, Number(process.env.BALANCE_SEEDS ?? 2));
const DIFFICULTY = (process.env.BALANCE_DIFFICULTY ?? 'medium') as Difficulty;
const levels = list(process.env.DEPTH_LEVELS, ['20', '40', '60']).map(Number);
const depths = list(process.env.DEPTH_DEPTHS, ['1', '10', '20']).map(Number);
const bands = list(process.env.DEPTH_BANDS, ['intended', 'geared']);
const disciplines = list(process.env.DEPTH_DISCIPLINES, ['1', '2', '3', '4']).map(Number);
const reference = list(process.env.DEPTH_REFERENCE, ['pyre', 'fen']) as AreaId[];
const names: Record<number, string> = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver', 5: 'Grave Warden', 6: 'Bell Monk', 7: 'Carrion Witch', 8: 'Hollow Knight', 9: 'Veilwalker' };
const AUTO_KIT: Record<string, KitName> = { intended: 'progress', geared: 'typical', push: 'typical', max: 'ascended' };

function averaged(run: BalanceRun): BalanceResult {
  const results = Array.from({ length: SEEDS }, (_, i) => runBalance({ ...run, difficulty: DIFFICULTY, seed: 42 + i }));
  const avg = { ...results[0] } as unknown as Record<string, number>;
  for (const key of Object.keys(avg)) if (key !== 'run' && key !== 'casts') avg[key] = results.reduce((s, r) => s + (r as unknown as Record<string, number>)[key], 0) / SEEDS;
  avg.minHpPct = Math.min(...results.map((r) => r.minHpPct));
  const first = results.map((r) => r.firstDeathSec).filter((x) => x >= 0);
  avg.firstDeathSec = first.length ? Math.min(...first) : -1;
  return avg as unknown as BalanceResult;
}

const cols: [string, number][] = [['ground', 10], ['lvl', 4], ['dead', 5], ['band', 9], ['disc', 14], ['kills/m', 8], ['floors/m', 9], ['xp/m', 8], ['gold/m', 8], ['hurt%/m', 8], ['minHp', 6], ['deaths', 7], ['1st†s', 6], ['ttk s', 6], ['peak', 5]];
const pad = (s: string | number, n: number) => String(s).padEnd(n);
const rows: string[] = [cols.map(([h, n]) => pad(h, n)).join('')];
for (const lvl of levels) {
  for (const band of bands) {
    for (const classIndex of disciplines) {
      const base = { ...(BANDS[band](lvl) as BalanceRun), classIndex, minutes: MINUTES, kit: AUTO_KIT[band] };
      const put = (ground: string, dead: number, res: BalanceResult) => {
        const cells = [ground, base.level, dead, band, names[classIndex], res.killsPerMin.toFixed(1), res.floorsPerMin ? res.floorsPerMin.toFixed(1) : '-', res.xpPerMin.toFixed(0), res.goldPerMin.toFixed(0), res.dmgPctPerMin.toFixed(0), res.minHpPct.toFixed(0), res.deaths.toFixed(1), res.firstDeathSec < 0 ? '-' : res.firstDeathSec.toFixed(0), res.avgTtkSec.toFixed(1), res.peakEnemies.toFixed(0)];
        rows.push(cells.map((c, i) => pad(c, cols[i][1])).join(''));
      };
      for (const ground of reference) put(ground, Math.max(base.level ?? lvl, ground === 'fen' ? 45 : 30), averaged({ ...base, area: ground } as BalanceRun));
      for (const depth of depths) put(`depth ${depth}`, depthEnemyLevel(depth, base.level ?? lvl), averaged({ ...base, area: 'depths', depth } as BalanceRun));
    }
  }
}
console.log(`\nCatacomb Depths balance: ${MINUTES} simulated minutes per row, ${SEEDS} seed(s), difficulty ${DIFFICULTY}`);
console.log('dead = enemy level · hurt%/m = damage taken per minute as % of max HP · 1st†s = seconds to first death · floors/m = floors cleared per minute fighting\n');
console.log(rows.join('\n'));
