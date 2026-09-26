/**
 * Prelate report: `npm run balance:boss`. One row per band × discipline × dodge,
 * averaged over seeds. Targets live in BALANCE.md.
 *
 * Env: BALANCE_SEEDS=3, BALANCE_BANDS=intended,geared, BALANCE_DISCIPLINES=1,3.
 */
import { AREAS } from '../../content/areas';
import { runBossFight, type BossResult, type BossRun } from './boss';
import type { Difficulty } from '../../content/difficulty';
import { ascensionLevels } from '../../content/ascension';

const DIFFICULTY = (process.env.BALANCE_DIFFICULTY ?? 'medium') as Difficulty;
/** World Ascension rank; bands then anchor on the aged area level. */
const ASC = Math.max(0, Number(process.env.BALANCE_ASCENSION ?? 0));
const SEEDS = Math.max(1, Number(process.env.BALANCE_SEEDS ?? 3));
const list = (v: string | undefined) => (v ? v.split(',').map((s) => s.trim()) : null);
const disciplines = (list(process.env.BALANCE_DISCIPLINES) ?? ['1', '2', '3', '4']).map(Number);
const names: Record<number, string> = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver' };
const L = AREAS.sanctum.level + ascensionLevels(ASC);

/** Same bands as the farming report, anchored on the Sanctum's level. */
const BANDS: Record<string, Omit<BossRun, 'classIndex' | 'dodge'>> = {
  intended: { level: L, damageTier: Math.round(L * 0.6), gearStats: Math.round(L * 0.8) },
  geared: { level: L + 3, damageTier: Math.round(L * 0.9), gearStats: L },
};
const bandNames = list(process.env.BALANCE_BANDS) ?? Object.keys(BANDS);

const cols: [string, number][] = [
  ['band', 9], ['disc', 12], ['dodge', 6], ['wins', 6], ['time s', 7], ['P2 s', 6], ['P3 s', 6], ['boss%', 6],
  ['dps', 6], ['hurt%/m', 8], ['prelate%', 9], ['adds%', 6], ['minHp', 6], ['flasks', 6],
];
const pad = (s: string | number, n: number) => String(s).padEnd(n);
const avg = (rs: BossResult[], f: (r: BossResult) => number) => rs.reduce((s, r) => s + f(r), 0) / rs.length;
const avgPhase = (rs: BossResult[], f: (r: BossResult) => number) => {
  const hit = rs.map(f).filter((x) => x >= 0);
  return hit.length ? (hit.reduce((a, b) => a + b, 0) / hit.length).toFixed(0) : '-';
};
const rows: string[] = [cols.map(([h, n]) => pad(h, n)).join('')];
let maxHp = 0;
for (const band of bandNames) {
  for (const classIndex of disciplines) {
    for (const dodge of [true, false]) {
      const rs = Array.from({ length: SEEDS }, (_, i) => runBossFight({ ...BANDS[band], classIndex, dodge, difficulty: DIFFICULTY, seed: 42 + i, ascension: ASC }));
      maxHp = rs[0].bossMaxHp;
      const wins = rs.filter((r) => r.outcome === 'win');
      const cells = [
        band, names[classIndex], dodge ? 'yes' : 'no', `${wins.length}/${SEEDS}`,
        wins.length ? avg(wins, (r) => r.seconds).toFixed(0) : '-',
        avgPhase(rs, (r) => r.phase2At), avgPhase(rs, (r) => r.phase3At),
        avg(rs, (r) => r.bossHpLeftPct).toFixed(0), avg(rs, (r) => r.dps).toFixed(0),
        avg(rs, (r) => r.dmgPctPerMin).toFixed(0), avg(rs, (r) => r.bySource.prelate ?? 0).toFixed(0),
        avg(rs, (r) => r.bySource.adds ?? 0).toFixed(0), Math.min(...rs.map((r) => r.minHpPct)).toFixed(0),
        avg(rs, (r) => r.flasksUsed).toFixed(1),
      ];
      rows.push(cells.map((c, i) => pad(c, cols[i][1])).join(''));
    }
  }
}
console.log(`\nBell-Sworn Prelate report: ${SEEDS} seed(s) per row, solo, difficulty ${DIFFICULTY}, ascension ${ASC}, boss max HP ${Math.round(maxHp)}`);
console.log('time s = average kill time of winning runs · boss% = HP left (avg) · prelate%/adds% = damage taken as % of max HP over the fight\n');
console.log(rows.join('\n'));
