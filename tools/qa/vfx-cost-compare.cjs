/**
 * Before/after table from two vfx-cost.cjs reports.
 *   node tools/qa/vfx-cost-compare.cjs <before.json> <after.json> [--md]
 * Ranked by the before report's fill (layers), then draw calls. Prints plain text, or a Markdown table with --md.
 */
const fs = require('node:fs');
const [, , bPath, aPath, ...flags] = process.argv;
const md = flags.includes('--md');
const B = JSON.parse(fs.readFileSync(bPath, 'utf8'));
const A = JSON.parse(fs.readFileSync(aPath, 'utf8'));
const cols = [['calls', 'draw calls'], ['layers', 'overdraw'], ['parts', 'particles'], ['cpu', 'cpu ms'], ['mats', 'mats'], ['progs', 'progs']];
const keys = Object.keys(B.rows).filter((k) => B.rows[k].calls !== undefined && A.rows[k] && A.rows[k].calls !== undefined).sort((x, y) => B.rows[y].layers - B.rows[x].layers || B.rows[y].calls - B.rows[x].calls);
const cell = (b, a) => (b === a ? `${b}` : `${b} -> ${a}`);
const lines = [];
const head = ['effect', ...cols.map((c) => c[1])];
if (md) lines.push(`| ${head.join(' | ')} |`, `|${head.map(() => '---').join('|')}|`);
else lines.push(head.map((h, i) => (i ? h.padStart(16) : h.padEnd(24))).join(''));
for (const k of keys) {
  const row = [k, ...cols.map(([c]) => cell(B.rows[k][c], A.rows[k][c]))];
  lines.push(md ? `| ${row.join(' | ')} |` : row.map((v, i) => (i ? String(v).padStart(16) : String(v).padEnd(24))).join(''));
}
console.log(lines.join('\n'));
const sum = (R, c) => keys.reduce((n, k) => n + (R.rows[k][c] || 0), 0);
console.log(`\nsum over ${keys.length} effects: calls ${sum(B, 'calls')} -> ${sum(A, 'calls')}, overdraw ${sum(B, 'layers').toFixed(2)} -> ${sum(A, 'layers').toFixed(2)}`);
if (B.fight && A.fight) {
  const f = (o) => `calls mean ${o.calls.mean} (max ${o.calls.max}), overdraw mean ${o.layers.mean} (max ${o.layers.max}), cover ${o.cover}, max stack ${o.maxStack}, stale after ${o.staleAfter}, cpu mean ${o.cpu.mean} p95 ${o.cpu.p95}, bb cpu ${o.bbCpu.mean}, peak particles ${o.peakParticles}, peak transients ${o.peakTransients}, peak binbun ${o.peakBinbun}, programs +${o.programsDelta}, materials +${o.materialsDelta}`;
  console.log(`\nBusy fight (${B.fight.seconds} s)\n  before: ${f(B.fight)}\n  after:  ${f(A.fight)}`);
}
