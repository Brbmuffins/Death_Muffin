#!/usr/bin/env node
// The seeded scenario comparison between today's game and the rebuilt client (native/README.md "Proof of same game").
//
//   node tools/rebuild/compare-scenarios.mjs [--seeds=1-5] [--seconds=180] [--level=10] [--difficulty=easy] [--discipline=2] [--area=graves] [--out=<dir>] [--from=<dir>] [--strict]
//
// Runs `godot/tests/parity/scenario.gd` (today's game) and `client/tools/parity_scenario.gd` (the rebuilt client) for each seed, ONE Godot process at a time under `nice -n 10`,
// alternating the sides seed by seed so the shared machine's load drifts over both alike. Each run writes a JSON of the same keys; the sides are averaged over the seeds and
// printed as a table: metric, today, client, difference, tolerance, noise, verdict. The tolerances are native/README.md "Proof of same game"; change them there and here together.
// A miss is never fixed by tuning game numbers: it is investigated (a scenario mismatch is fixed in the two tool scripts; a real difference goes to native/README.md "Differences").
//   --discipline=<index>  the hero's discipline (1 Ossuary, 2 Gravecaller, 3 Mourner, 4 Rotweaver, 11 the Reaper); --area=<id>  the hunting ground (default the Hollow Graves, `graves`)
//   --from=<dir>   tabulate the JSON files of an earlier run (today-<seed>.json, client-<seed>.json) instead of running Godot
//   --out=<dir>    where the JSON files go (default: a new folder under the system temp dir)
//   --resume       keep the runs already in --out (a stopped comparison goes on where it was)
//   --strict       exit 1 when a metric misses (default: exit 0 whenever the runs completed)
//   --sides=today|client|both   run only one side (a table needs both; the run line is printed for each)
//   GODOT=<path>   the Godot binary (default /home/ubuntu/tools/godot/godot)
import { spawnSync, execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const arg = (name, dflt) => {
  const a = process.argv.slice(2).find((x) => x.startsWith(`--${name}=`));
  return a === undefined ? dflt : a.slice(name.length + 3);
};
const flag = (name) => process.argv.slice(2).includes(`--${name}`);

const GODOT = process.env.GODOT || '/home/ubuntu/tools/godot/godot';
const seconds = Number(arg('seconds', '180'));
const level = Number(arg('level', '10'));
const difficulty = arg('difficulty', 'easy');
const discipline = Number(arg('discipline', '2'));
const area = arg('area', 'graves');
const DISCIPLINES = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver', 11: 'Reaper' };
const AREAS = { graves: 'the Hollow Graves', warren: 'the Catacomb Warren', ossuary: 'the Marrow Ossuary', nave: 'the Drowned Nave', coliseum: 'the Bone Coliseum', sanctum: 'the Bell Sanctum',
  cloister: 'the Plague Cloister', pyre: 'the Cinder Pyre', fen: 'the Mourning Fen' };
const heroName = (d) => DISCIPLINES[d] || `discipline ${d}`;
const areaName = (a) => AREAS[a] || a;
const sides = arg('sides', 'both');
const resume = flag('resume');
const from = arg('from', '');
const outDir = arg('out', '');
const seeds = parseSeeds(arg('seeds', '1-5'));
const RUN_TIMEOUT_MS = 40 * 60 * 1000;

function parseSeeds(text) {
  const out = [];
  for (const part of text.split(',')) {
    const m = /^(\d+)-(\d+)$/.exec(part.trim());
    if (m) for (let i = Number(m[1]); i <= Number(m[2]); i++) out.push(i);
    else if (/^\d+$/.test(part.trim())) out.push(Number(part.trim()));
    else throw new Error(`bad --seeds: ${text}`);
  }
  return out;
}

// ---- the runs ----------------------------------------------------------------------------------------------------------------------------------

const SIDES = {
  today: { project: 'godot', script: 'res://tests/parity/scenario.gd' },
  client: { project: 'client', script: 'res://tools/parity_scenario.gd' },
};

// What a run that ended without a result says about itself. Godot's crash handler tells the main loop (SceneTree), which hands it to /root.propagate_notification, and that call
// is refused off the main thread: so "The caller thread can't call the function `propagate_notification()`" on /root is what ANY crash on a thread other than the main one prints
// just before "handle_crash: Program crashed with signal N". It is not a node touched from a thread; the signal and the C++ frames below it (client/README.md "Threads") are the crash.
function crashNote(text) {
  const sig = /handle_crash: Program crashed with signal (\d+)/.exec(text);
  if (!sig) return '';
  const offMain = /caller thread can't call the function `propagate_notification\(\)`/.test(text);
  return `    Godot's crash handler ran (signal ${sig[1]}) ${offMain ? "on a thread other than the main one: the propagate_notification line above it is the handler's own message, not the cause" : 'on the main thread'}; the C++ frames are in the log`;
}

function runSide(side, seed, dir) {
  const s = SIDES[side];
  const out = path.join(dir, `${side}-${seed}.json`);
  if (resume && existsSync(out)) {
    console.log(`  ${side.padEnd(6)} seed ${seed}: kept from the earlier run`);
    return { out, wall: 0 };
  }
  const args = ['-n', '10', GODOT, '--headless', '--fixed-fps', '60', '--path', s.project, '--script', s.script, '--',
    `--seed=${seed}`, `--seconds=${seconds}`, `--level=${level}`, `--difficulty=${difficulty}`, `--discipline=${discipline}`, `--area=${area}`, `--out=${out}`];
  // The engine now and then aborts a headless process before the scenario ends (a crash of Godot, not a result): the whole output is kept
  // beside the results (<side>-<seed>-crash<n>.log) and the run is made again, once; a second crash stops the comparison.
  for (let attempt = 1; ; attempt++) {
    const t0 = Date.now();
    const r = spawnSync('nice', args, { cwd: root, encoding: 'utf8', timeout: RUN_TIMEOUT_MS, maxBuffer: 1 << 28 });
    const wall = (Date.now() - t0) / 1000;
    const text = `${r.stdout || ''}\n${r.stderr || ''}`;
    if (existsSync(out)) {
      const line = text.split('\n').find((l) => l.startsWith('PARITY '));
      console.log(`  ${side.padEnd(6)} seed ${seed}: ${wall.toFixed(0)} s  ${line ? line.replace(/^PARITY \w+ seed=\d+ /, '') : ''}`);
      return { out, wall };
    }
    const log = path.join(dir, `${side}-${seed}-crash${attempt}.log`);
    writeFileSync(log, text);
    const tail = text.split('\n').filter((l) => /ERROR|SCRIPT|Parse|error/i.test(l) && !/leaked|still in use|Pages in use|RID allocations/.test(l)).slice(0, 12).join('\n');
    console.log(`  ${side.padEnd(6)} seed ${seed}: no result (exit ${r.status}, signal ${r.signal}); output in ${log}`);
    const note = crashNote(text);
    if (note) console.log(note);
    if (attempt >= 2) throw new Error(`${side} seed ${seed}: no result twice (exit ${r.status}, signal ${r.signal})\n${tail}`);
  }
}

function runAll(dir) {
  mkdirSync(dir, { recursive: true });
  const t0 = Date.now();
  for (const seed of seeds) {
    for (const side of ['today', 'client']) {
      if (sides === 'both' || sides === side) runSide(side, seed, dir);
    }
  }
  return (Date.now() - t0) / 1000;
}

// ---- the numbers -------------------------------------------------------------------------------------------------------------------------------

const mean = (xs) => xs.reduce((a, b) => a + b, 0) / Math.max(1, xs.length);
const sd = (xs) => {
  if (xs.length < 2) return 0;
  const m = mean(xs);
  return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1));
};
const se = (xs) => sd(xs) / Math.sqrt(Math.max(1, xs.length));

const load = (dir, side) => seeds.map((seed) => JSON.parse(readFileSync(path.join(dir, `${side}-${seed}.json`), 'utf8')));

// kind 'rel': a percentage of today's value; kind 'pp': percentage points of a fraction. tol null = information only.
const METRICS = [
  { id: 'kills', name: 'kills', kind: 'rel', tol: 15, get: (r) => r.metrics.kills, fmt: (v) => v.toFixed(1) },
  { id: 'hero_damage', name: 'hero damage dealt', kind: 'rel', tol: 15, get: (r) => r.metrics.hero_damage, fmt: (v) => v.toFixed(0) },
  { id: 'thrall_damage', name: 'thrall damage dealt', kind: 'rel', tol: 20, get: (r) => r.metrics.thrall_damage, fmt: (v) => v.toFixed(0) },
  { id: 'ttk_median', name: 'median time to kill (s)', kind: 'rel', tol: 20, get: (r) => r.metrics.ttk.median, fmt: (v) => v.toFixed(2) },
  { id: 'uptime', name: 'thrall uptime (live / cap, %)', kind: 'pp', tol: 10, get: (r) => 100 * r.metrics.thrall_mean_places / Math.max(1, r.metrics.thrall_cap), fmt: (v) => v.toFixed(1) },
  { id: 'at_cap', name: 'time at the thrall cap (%)', kind: 'pp', tol: 10, get: (r) => 100 * r.metrics.thrall_at_cap_frac, fmt: (v) => v.toFixed(1) },
  // The hero alone is hit about twice a run (3.6 each, the thralls stand in front of him): that measures nothing, so the metric is what the enemies do to the hero and his thralls.
  { id: 'taken_all', name: 'damage taken by the hero and his thralls', kind: 'rel', tol: 25, get: (r) => r.metrics.damage_taken + r.metrics.thrall_damage_taken, fmt: (v) => v.toFixed(0) },
  // information: no tolerance, here to explain a miss
  { id: 'spawned', name: 'enemies spawned', kind: 'rel', tol: null, get: (r) => r.metrics.spawned, fmt: (v) => v.toFixed(1) },
  { id: 'ttk_p25', name: 'time to kill p25 (s)', kind: 'rel', tol: null, get: (r) => r.metrics.ttk.p25, fmt: (v) => v.toFixed(2) },
  { id: 'ttk_p75', name: 'time to kill p75 (s)', kind: 'rel', tol: null, get: (r) => r.metrics.ttk.p75, fmt: (v) => v.toFixed(2) },
  { id: 'live', name: 'mean live thralls', kind: 'rel', tol: null, get: (r) => r.metrics.thrall_mean_live, fmt: (v) => v.toFixed(2) },
  { id: 'raised', name: 'thralls raised', kind: 'rel', tol: null, get: (r) => r.metrics.thralls_raised, fmt: (v) => v.toFixed(1) },
  { id: 'lost', name: 'thralls lost', kind: 'rel', tol: null, get: (r) => r.metrics.thralls_lost, fmt: (v) => v.toFixed(1) },
  { id: 'taken', name: 'damage taken by the hero alone', kind: 'rel', tol: null, get: (r) => r.metrics.damage_taken, fmt: (v) => v.toFixed(1) },
  { id: 'legion_taken', name: 'damage taken by the thralls alone', kind: 'rel', tol: null, get: (r) => r.metrics.thrall_damage_taken, fmt: (v) => v.toFixed(0) },
  { id: 'casts', name: 'rite casts', kind: 'rel', tol: null, get: (r) => r.metrics.casts_total, fmt: (v) => v.toFixed(1) },
  { id: 'unsticks', name: 'times the hero was set back at the door', kind: 'rel', tol: null, get: (r) => r.metrics.unsticks, fmt: (v) => v.toFixed(1) },
  // the hero's own `hurt` signal on both sides (today's `struck` and the client's `hero_hit` count different things: the client's include the clouds and pools, today's do not)
  { id: 'blows', name: 'blows that hurt the hero', kind: 'rel', tol: null, get: (r) => r.metrics.blows_taken, fmt: (v) => v.toFixed(1) },
];

function compare(today, client) {
  return METRICS.map((m) => {
    const a = today.map(m.get);
    const b = client.map(m.get);
    const ta = mean(a);
    const tb = mean(b);
    const diff = m.kind === 'pp' ? tb - ta : (ta === 0 ? (tb === 0 ? 0 : Infinity) : (100 * (tb - ta)) / ta);
    // two standard errors of the difference of the means, in the unit of the difference: a miss inside this is a question for more seeds
    const noise = 2 * Math.hypot(se(a), se(b)) * (m.kind === 'pp' ? 1 : (ta === 0 ? 0 : 100 / Math.abs(ta)));
    let verdict = 'info';
    if (m.tol !== null) {
      verdict = Math.abs(diff) <= m.tol ? 'PASS' : (Math.abs(diff) <= m.tol + noise ? 'MISS (within noise)' : 'MISS');
    }
    return { ...m, a, b, ta, tb, diff, noise, verdict };
  });
}

function table(rows) {
  const head = ['metric', 'today', 'client', 'difference', 'tolerance', 'noise (2 s.e.)', 'verdict'];
  const lines = rows.map((r) => {
    const unit = r.kind === 'pp' ? ' pp' : ' %';
    const diff = Number.isFinite(r.diff) ? `${r.diff >= 0 ? '+' : ''}${r.diff.toFixed(1)}${unit}` : 'n/a';
    return [r.name, r.fmt(r.ta), r.fmt(r.tb), diff, r.tol === null ? '' : `+-${r.tol}${unit}`, r.tol === null ? '' : `+-${r.noise.toFixed(1)}${unit}`, r.verdict];
  });
  const widths = head.map((h, i) => Math.max(h.length, ...lines.map((l) => l[i].length)));
  const fmt = (cells) => cells.map((c, i) => (i === 0 || i === cells.length - 1 ? c.padEnd(widths[i]) : c.padStart(widths[i]))).join('  ');
  return [fmt(head), widths.map((w) => '-'.repeat(w)).join('  '), ...lines.map(fmt)].join('\n');
}

function perSeed(rows) {
  const keys = ['kills', 'hero_damage', 'thrall_damage', 'ttk_median', 'uptime', 'taken_all'];
  const sel = rows.filter((r) => keys.includes(r.id));
  const head = ['seed', ...sel.map((r) => r.id)];
  const lines = seeds.map((seed, i) => [String(seed), ...sel.map((r) => `${r.fmt(r.a[i])} / ${r.fmt(r.b[i])}`)]);
  const sdLine = ['sd', ...sel.map((r) => `${r.fmt(sd(r.a))} / ${r.fmt(sd(r.b))}`)];
  const widths = head.map((h, i) => Math.max(h.length, ...lines.map((l) => l[i].length), sdLine[i].length));
  const fmt = (cells) => cells.map((c, i) => c.padStart(widths[i])).join('  ');
  return ['per seed, today / client', fmt(head), widths.map((w) => '-'.repeat(w)).join('  '), ...lines.map(fmt), fmt(sdLine)].join('\n');
}

function kindsAndCasts(today, client) {
  const avg = (rs, f) => {
    const o = {};
    for (const r of rs) for (const [k, v] of Object.entries(f(r))) o[k] = (o[k] || 0) + v;
    for (const k of Object.keys(o)) o[k] /= rs.length;
    return o;
  };
  // a kind's median time to kill: the seeds' medians weighted by how many of that kind died in each
  const ttkOf = (rs) => {
    const o = {};
    for (const r of rs) {
      for (const [k, v] of Object.entries(r.metrics.ttk_by_kind)) {
        o[k] = o[k] || [0, 0];
        o[k][0] += v.median * v.n;
        o[k][1] += v.n;
      }
    }
    return Object.fromEntries(Object.entries(o).map(([k, [w, n]]) => [k, w / n]));
  };
  const sp = [avg(today, (r) => r.metrics.spawned_by_kind), avg(client, (r) => r.metrics.spawned_by_kind)];
  const kl = [avg(today, (r) => r.metrics.kills_by_kind), avg(client, (r) => r.metrics.kills_by_kind)];
  const tt = [ttkOf(today), ttkOf(client)];
  const kinds = [...new Set([...Object.keys(sp[0]), ...Object.keys(sp[1])])].sort();
  const cell = (v, d = 1) => (v === undefined ? '-' : v.toFixed(d)).padStart(7);
  const kindLines = kinds.map((k) => `  ${k.padEnd(10)} ${cell(sp[0][k])} ${cell(sp[1][k])}   ${cell(kl[0][k])} ${cell(kl[1][k])}   ${cell(100 * (kl[0][k] || 0) / (sp[0][k] || 1), 0)} ${cell(100 * (kl[1][k] || 0) / (sp[1][k] || 1), 0)}   ${cell(tt[0][k], 2)} ${cell(tt[1][k], 2)}`);
  const kindBlock = ['by kind (per run)       spawned           killed        killed %      median time to kill (s)', `  ${' '.repeat(10)} ${'today'.padStart(7)} ${'client'.padStart(7)}   ${'today'.padStart(7)} ${'client'.padStart(7)}   ${'today'.padStart(7)} ${'client'.padStart(7)}   ${'today'.padStart(7)} ${'client'.padStart(7)}`, ...kindLines].join('\n');
  const ca = avg(today, (r) => r.metrics.casts);
  const cb = avg(client, (r) => r.metrics.casts);
  const rites = [...new Set([...Object.keys(ca), ...Object.keys(cb)])].sort();
  const castBlock = ['casts per rite (per run)   today  client', ...rites.map((n) => `  ${n.padEnd(14)} ${cell(ca[n])} ${cell(cb[n])}`)].join('\n');
  // what hurt the thralls (per run: blows and damage by the enemy that dealt them) and how they were lost
  const hb = (rs) => {
    const o = {};
    for (const r of rs) for (const [k, [n, d]] of Object.entries(r.metrics.thrall_hurt_by_def)) { o[k] = o[k] || [0, 0]; o[k][0] += n / rs.length; o[k][1] += d / rs.length; }
    return o;
  };
  const ha = hb(today);
  const hc = hb(client);
  const hurt = [...new Set([...Object.keys(ha), ...Object.keys(hc)])].sort();
  const pair = (v) => (v ? `${v[0].toFixed(1)} / ${v[1].toFixed(0)}` : '-').padStart(11);
  const hurtBlock = ['hurting the thralls (blows / damage per run)   today      client   ("other": no enemy behind it)', ...hurt.map((k) => `  ${k.padEnd(10)} ${pair(ha[k])} ${pair(hc[k])}`)].join('\n');
  const lost = (rs, grp) => avg(rs, (r) => r.metrics.thralls_lost_by[grp]);
  const lostLines = ['reason', 'kind', 'killer'].map((grp) => {
    const a = lost(today, grp);
    const b = lost(client, grp);
    const names = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
    return `  by ${grp}: ${names.map((n) => `${n} ${(a[n] || 0).toFixed(1)}/${(b[n] || 0).toFixed(1)}`).join(', ')}`;
  });
  const lostBlock = ['thralls lost per run, today / client', ...lostLines].join('\n');
  return `${kindBlock}\n\n${castBlock}\n\n${hurtBlock}\n\n${lostBlock}`;
}

// ---- main --------------------------------------------------------------------------------------------------------------------------------------

function gitRev() {
  try {
    const rev = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    const dirty = execFileSync('git', ['status', '--porcelain', '--', 'godot', 'client', 'native'], { cwd: root, encoding: 'utf8' }).trim() !== '';
    return rev + (dirty ? '+changes' : '');
  } catch {
    return 'unknown';
  }
}

let dir = from;
let runSeconds = 0;
if (!from) {
  dir = outDir || mkdtempSync(path.join(os.tmpdir(), 'dm-parity-'));
  console.log(`Seeded scenario comparison: ${areaName(area)}, ${heroName(discipline)} level ${level}, ${difficulty}, ${seconds} s of game time, seeds ${seeds.join(' ')}, results in ${dir}`);
  runSeconds = runAll(dir);
  console.log(`  ${seeds.length * (sides === 'both' ? 2 : 1)} runs in ${(runSeconds / 60).toFixed(1)} min`);
}
if (sides !== 'both' && !from) process.exit(0);

const today = load(dir, 'today');
const client = load(dir, 'client');
const rows = compare(today, client);
const sc = { area: today[0].area || 'graves', discipline: today[0].discipline ?? 2 };   // what the runs say they played (a --from folder may be another scenario than the flags)
console.log(`\nSeeded scenario comparison at ${gitRev()}: ${areaName(sc.area)}, ${heroName(sc.discipline)} level ${today[0].level}, ${today[0].difficulty || 'easy'}, ${today[0].seconds} s of game time, seeds ${seeds.join(' ')} (means over the seeds)\n`);
console.log(table(rows));
console.log('noise: two standard errors of the difference between the means over the seeds, in the unit of the difference. A miss inside it needs more seeds, not a fix.');
console.log(`\n${perSeed(rows)}\n\n${kindsAndCasts(today, client)}`);
const res = { rev: gitRev(), area: sc.area, discipline: sc.discipline, seeds, seconds: today[0].seconds, level: today[0].level, difficulty: today[0].difficulty || 'easy', run_minutes: runSeconds / 60,
  rows: rows.map((r) => ({ id: r.id, name: r.name, today: r.ta, client: r.tb, diff: r.diff, tolerance: r.tol, noise: r.noise, verdict: r.verdict })) };
writeFileSync(path.join(dir, 'compare.json'), JSON.stringify(res, null, 2));
const misses = rows.filter((r) => r.verdict.startsWith('MISS'));
console.log(`\n${misses.length === 0 ? 'Every metric is within its tolerance.' : `${misses.length} metric(s) miss: ${misses.map((r) => r.name).join(', ')}.`}  (${path.join(dir, 'compare.json')})`);
process.exit(flag('strict') && misses.length > 0 ? 1 : 0);
