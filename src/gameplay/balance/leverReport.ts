/**
 * What is one number worth? `npm run balance:lever` (vite-node). Wears a base kit and folds ONE extra effect on top (a thrall
 * multiplier, a ward, a stat...), then prints the change in what the bot achieves, paired by seed, so the set bonus / affix
 * tables and `gearStats` SET_VALUE can be set from measurements rather than taste (BALANCE.md "Gear pass").
 *
 * Env: LEVER_AREA (nave), LEVER_BAND (max), LEVER_KIT (typical), LEVER_SEEDS (16), LEVER_DISCIPLINES (1,2,3,4), LEVER_SCALE (1).
 * LEVER_SCALE multiplies every step so a small effect rises above the noise; read the table per unit.
 */
import { runBalance, type BalanceRun, type BalanceResult } from './harness';
import { AREAS, type AreaId } from '../../../server/rules/content/areas';
import { BANDS } from './bands';
import type { KitName } from './kits';
import type { SetEffect } from '../../content/setBonuses';

const area = (process.env.LEVER_AREA ?? 'nave') as AreaId;
const band = process.env.LEVER_BAND ?? 'max';
const kit = (process.env.LEVER_KIT ?? 'typical') as KitName;
const SEEDS = Number(process.env.LEVER_SEEDS ?? 16);
const discs = (process.env.LEVER_DISCIPLINES ?? '1,2,3,4').split(',').map(Number);
const K = Number(process.env.LEVER_SCALE ?? 1);
const names: Record<number, string> = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver' };

/** Each step is "+10%" / "+1" / "+1% per..." times K. */
const m = (key: string, pct: number): SetEffect => ({ mult: { [key]: 1 + (pct * K) / 100 } });
const a = (key: string, v: number): SetEffect => ({ add: { [key]: v * K } });
const LEVERS: [string, SetEffect][] = [
  ['thrall damage +10%', m('thrallDamageMult', 10)],
  ['thrall health +10%', m('thrallHpMult', 10)],
  ['thrall attack speed +10%', m('thrallAttackSpeedMult', 10)],
  ['thrall cap +1', a('thrallCap', 1)],
  ['max health +10%', m('maxHpMult', 10)],
  ['essence regen +10%', m('essenceRegenMult', 10)],
  ['Miasma radius +10%', m('miasmaRadiusMult', 10)],
  ['Withered stacks +1', a('witheredMaxStacks', 1)],
  ['ward +1% per thrall', a('wardPerThrall', 0.01)],
  ['Litany barrier +1% per corpse', a('litanyBarrier', 0.01)],
  ['corpse heal +1%', a('corpseHeal', 0.01)],
  ['+5 INT', { stats: { stat_int: 5 * K } }],
  ['+5 VIT', { stats: { stat_vit: 5 * K } }],
  ['+5 STR', { stats: { stat_str: 5 * K } }],
  ['+5 AGI', { stats: { stat_agi: 5 * K } }],
];

const run = (classIndex: number, effect?: SetEffect) => {
  const rs: BalanceResult[] = [];
  for (let s = 0; s < SEEDS; s++) rs.push(runBalance({ ...(BANDS[band](AREAS[area].level) as BalanceRun), area, classIndex, minutes: 3, seed: 42 + s, kit, effect }));
  const mean = (f: (r: BalanceResult) => number) => rs.reduce((x, r) => x + f(r), 0) / rs.length;
  return { kills: mean((r) => r.killsPerMin), hurt: mean((r) => r.dmgPctPerMin), ttk: mean((r) => r.avgTtkSec), deaths: mean((r) => r.deaths), xp: mean((r) => r.xpPerMin) };
};
console.log(`lever value: ${area} ${band}, base kit ${kit}, ${SEEDS} seeds, scale x${K} (percent change; each step is x${K} of the row's unit)`);
for (const ci of discs) {
  const base = run(ci);
  console.log(`\n${names[ci]}  base: kills ${base.kills.toFixed(1)}/min  hurt ${base.hurt.toFixed(0)}%/min  ttk ${base.ttk.toFixed(2)}s  deaths ${base.deaths.toFixed(2)}`);
  console.log(`${'effect'.padEnd(32)}kills%   hurt%    ttk%  deaths`);
  for (const [name, e] of LEVERS) {
    const r = run(ci, e);
    const pc = (x: number, y: number) => (((x / y) - 1) * 100).toFixed(1).padStart(6);
    console.log(`${name.padEnd(32)}${pc(r.kills, base.kills)} ${pc(r.hurt, base.hurt)} ${pc(r.ttk, base.ttk)} ${r.deaths.toFixed(2).padStart(7)}`);
  }
}
