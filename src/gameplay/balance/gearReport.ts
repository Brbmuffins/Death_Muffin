/**
 * Gear pass report: `npm run balance:gear` (vite-node). One tab-separated row per area x band x discipline x kit, averaged over
 * seeds, for the analysis in BALANCE.md ("Gear pass"). Columns: area band disc kit kills gold xp hurt deaths first_med ttk
 * minhp peak lvl. Pair it with the same row at kit `none` to read the lift; seeds are shared, so the pairing is exact.
 *
 * Env: GEAR_AREAS, GEAR_BANDS, GEAR_DISCIPLINES (client indices 1-4), GEAR_KITS, GEAR_SEEDS (default 8), GEAR_MINUTES (3),
 *      GEAR_NO_RITES=1 (the pre-gear-pass bot: no corpse heal / Litany barrier),
 *      GEAR_STAT_SCALE=0.6 (what-if: scale the worn items' base stat points),
 *      GEAR_STRIP=sets,weapon,affixes (keep base stats, switch those effects off), GEAR_LEVERS, GEAR_SET,
 *      GEAR_WEAPON=main:off (override the kit's weapon pair, e.g. staff:none), GEAR_TIER=bone..moon (override its weapon tier).
 */
import { runBalance, type BalanceResult, type BalanceRun } from './harness';
import { AREAS, type AreaId } from '../../content/areas';
import { BANDS } from './bands';
import { KIT_NAMES, type KitName, type KitRequest } from './kits';
import type { NecroKind, NecroTier } from '../../content/necroWeapons';

const list = (v: string | undefined, d: string[]) => (v ? v.split(',').map((s) => s.trim()) : d);
const areas = list(process.env.GEAR_AREAS, ['graves', 'warren', 'ossuary', 'coliseum', 'nave', 'sanctum', 'cloister', 'pyre', 'fen']) as AreaId[];
const bands = list(process.env.GEAR_BANDS, ['intended', 'geared', 'push', 'max']);
const discs = list(process.env.GEAR_DISCIPLINES, ['1', '2', '3', '4']).map(Number);
const kits = list(process.env.GEAR_KITS, ['none']) as KitName[];
const SEEDS = Number(process.env.GEAR_SEEDS ?? 8);
const MINUTES = Number(process.env.GEAR_MINUTES ?? 3);
const names: Record<number, string> = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver' };
for (const k of kits) if (!KIT_NAMES.includes(k)) throw new Error(`unknown kit ${k}`);

/** GEAR_WEAPON=staff:none  GEAR_TIER=gold  GEAR_LEVERS=s_ward,p_thrall_dmg  GEAR_SET=ossuary_ascended */
const [mainW, offW] = (process.env.GEAR_WEAPON ?? '').split(':');
const OVERRIDE: KitRequest['override'] = {
  ...(mainW ? { main: mainW as NecroKind, off: !offW || offW === 'none' ? null : (offW as NecroKind) } : {}),
  ...(process.env.GEAR_TIER ? { tier: process.env.GEAR_TIER as NecroTier } : {}),
  ...(process.env.GEAR_LEVERS ? { levers: process.env.GEAR_LEVERS.split(',') } : {}),
  ...(process.env.GEAR_SET ? { sets: process.env.GEAR_SET } : {}),
  ...(process.env.GEAR_STAT_SCALE ? { statScale: Number(process.env.GEAR_STAT_SCALE) } : {}),
  ...(process.env.GEAR_STRIP ? { strip: process.env.GEAR_STRIP.split(',') as ('sets' | 'weapon' | 'affixes')[] } : {}),
};
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
console.log(['area', 'band', 'disc', 'kit', 'kills', 'gold', 'xp', 'hurt', 'deaths', 'first_med', 'ttk', 'minhp', 'peak', 'lvl'].join('\t'));
for (const area of areas) {
  for (const band of bands) {
    for (const classIndex of discs) {
      for (const kit of kits) {
        const rs: BalanceResult[] = [];
        for (let i = 0; i < SEEDS; i++) rs.push(runBalance({ ...(BANDS[band](AREAS[area].level) as BalanceRun), area, classIndex, minutes: MINUTES, seed: 42 + i, kit, kitOverride: OVERRIDE, noRiteEffects: !!process.env.GEAR_NO_RITES }));
        const firsts = rs.map((r) => (r.firstDeathSec >= 0 ? r.firstDeathSec : MINUTES * 60)).sort((a, b) => a - b);
        const f = (n: number, d = 1) => n.toFixed(d);
        console.log([area, band, names[classIndex], kit, f(mean(rs.map((r) => r.killsPerMin))), f(mean(rs.map((r) => r.goldPerMin)), 0), f(mean(rs.map((r) => r.xpPerMin)), 0),
          f(mean(rs.map((r) => r.dmgPctPerMin)), 0), f(mean(rs.map((r) => r.deaths)), 2), f(firsts[Math.floor(firsts.length / 2)], 0), f(mean(rs.map((r) => r.avgTtkSec))),
          f(Math.min(...rs.map((r) => r.minHpPct)), 0), f(mean(rs.map((r) => r.peakEnemies)), 0), f(mean(rs.map((r) => r.run.level)), 0)].join('\t'));
      }
    }
  }
}
