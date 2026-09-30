/**
 * Pyre vs Fen at equal levels (45 and 65), four disciplines, intended and geared bands, 3 sim-minutes each, SEEDS (default 8) seeds.
 *   npx vite-node src/gameplay/balance/fenCompare.ts
 * The Fen is tuned to ~10-15% more XP/min than the Pyre at a similar danger (BALANCE.md).
 */
import { runBalance } from './harness';
const SEEDS = Number(process.env.SEEDS ?? 8);
const discs: [number, string][] = [[2, 'Gravecaller'], [1, 'Ossuary'], [3, 'Mourner'], [4, 'Rotweaver']];
const bands: Record<string, (l: number) => object> = {
  intended: (l) => ({ level: l, damageTier: Math.round(l * 0.6), waveTier: 0, gearStats: Math.round(l * 0.8) }),
  geared: (l) => ({ level: l + 3, damageTier: Math.round(l * 0.9), waveTier: 3, gearStats: Math.round(l) }),
};
const rows: string[] = [];
for (const lvl of [45, 65]) for (const [ci, cn] of discs) for (const [bn, b] of Object.entries(bands)) {
  const out: Record<string, Record<string, number>> = {};
  for (const area of ['pyre', 'fen'] as const) {
    const acc = { k: 0, g: 0, x: 0, h: 0, d: 0, m: 0 };
    for (let s = 0; s < SEEDS; s++) {
      const r = runBalance({ area, classIndex: ci, minutes: 3, seed: 42 + s, ...(b(lvl) as object) } as never);
      acc.k += r.killsPerMin; acc.g += r.goldPerMin; acc.x += r.xpPerMin; acc.h += r.dmgPctPerMin; acc.d += r.deaths; acc.m += r.minHpPct;
    }
    out[area] = Object.fromEntries(Object.entries(acc).map(([k, v]) => [k, v / SEEDS]));
  }
  const f = (a: string, k: string) => out[a][k].toFixed(k === 'd' ? 1 : 0);
  rows.push(`L${lvl} ${cn.padEnd(11)} ${bn.padEnd(8)} | pyre kills ${f('pyre','k')} xp ${f('pyre','x')} hurt ${f('pyre','h')} deaths ${f('pyre','d')} | fen kills ${f('fen','k')} xp ${f('fen','x')} hurt ${f('fen','h')} deaths ${f('fen','d')} | xp ratio ${(out.fen.x / out.pyre.x).toFixed(2)}`);
  console.log(rows[rows.length - 1]);
}
