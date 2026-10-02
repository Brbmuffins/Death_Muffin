#!/usr/bin/env node
// Run the offline-preview browser smokes against ONE fresh Vite server, one at a time.
//
//   node tools/qa/run-all.mjs [--port 5348] [--tree <dir>] [--only a,b] [--skip a,b] [--timeout 420]
//                             [--out <dir>] [--retries 1] [--list] [--no-retry]
//
// - Starts a new Vite on 127.0.0.1:<port> from <tree> (default: the repo this file is in), warms it up, and
//   stops it by PID at the end (also on Ctrl-C / errors). Never uses pkill.
// - Each script runs in its own process group with a timeout; on timeout the whole group (script + Chromium)
//   is killed by PID. Every script gets DM_QA_URL, DM_OFFLINE_URL, a private DM_QA_ARTIFACT_DIR and the Playwright/
//   Chromium paths (override with DM_PLAYWRIGHT_MODULE / DM_CHROMIUM_PATH).
// - A failure is retried once: pass-on-retry is "flaky", fail-twice is "broken".
// - Writes <out>/summary.json, <out>/summary.md and one log per run in <out>/logs/.
// Names: a script is its file name without ".cjs" (e.g. "acre-smoke"); necro-audit runs once per discipline as
// "necro-audit:Ossuary" (DM_QA_DISC) so each fits in a budget. `--only necro-audit` expands to all four.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : def; };
const flag = (name) => args.includes('--' + name);

const TREE = path.resolve(opt('tree', path.resolve(HERE, '../..')));
const PORT = Number(opt('port', 5348));
const DEFAULT_TIMEOUT = Number(opt('timeout', 420)) * 1000;
const RETRIES = flag('no-retry') ? 0 : Number(opt('retries', 1));
const STAMP = new Date().toISOString().replace(/[:.]/g, '-');
const OUT = path.resolve(opt('out', path.join(os.tmpdir(), `dm-qa-${STAMP}`)));
const QA_DIR = path.join(TREE, 'tools/qa');

// Not run by default: they need something other than the offline preview, are samples, or are not pass/fail.
const NOT_OFFLINE = new Set([
  'live-domain-smoke', 'live-release-smoke', 'new-blood-live-smoke', // public site
  'coop-ten-smoke', // isolated realtime server (see README)
  'offline-edition-smoke', // built PWA preview on its own port
]);
const DISCS = ['Gravecaller', 'Ossuary', 'Mourner', 'Rotweaver'];
// Per-script budgets in seconds where the default is not enough (measured on a loaded box).
const TIMEOUTS = { 'necro-audit': 600, 'anim-pass-smoke': 600, 'spell-feel-smoke': 600, 'first-hour-smoke': 600, 'guidance-smoke': 480 };

function discover() {
  const list = fs.readdirSync(QA_DIR).filter((f) => f.endsWith('-smoke.cjs')).map((f) => f.replace(/\.cjs$/, '')).filter((n) => !NOT_OFFLINE.has(n)).sort();
  for (const d of DISCS) list.push(`necro-audit:${d}`);
  return list;
}
function expand(names) {
  return names.flatMap((n) => (n === 'necro-audit' ? DISCS.map((d) => `necro-audit:${d}`) : [n]));
}
const csv = (v) => (v ? v.split(',').map((s) => s.trim()).filter(Boolean) : []);
let names = discover();
if (opt('only')) names = expand(csv(opt('only')));
const skip = new Set(expand(csv(opt('skip'))));
names = names.filter((n) => !skip.has(n));
if (flag('list')) { console.log(names.join('\n')); process.exit(0); }

const env0 = {
  ...process.env,
  DM_PLAYWRIGHT_MODULE: process.env.DM_PLAYWRIGHT_MODULE || '/home/ubuntu/.npm/_npx/e41f203b7505f1fb/node_modules/playwright',
  DM_CHROMIUM_PATH: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
  DM_QA_URL: `http://127.0.0.1:${PORT}/?offline`,
  DM_OFFLINE_URL: `http://127.0.0.1:${PORT}/?offline`,
};

fs.mkdirSync(path.join(OUT, 'logs'), { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const get = (p) => new Promise((resolve) => {
  const req = http.get({ host: '127.0.0.1', port: PORT, path: p, timeout: 20000 }, (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
  req.on('error', () => resolve(0));
  req.on('timeout', () => { req.destroy(); resolve(0); });
});

let vite = null;
function killGroup(child, sig = 'SIGTERM') {
  if (!child || !child.pid) return;
  try { process.kill(-child.pid, sig); } catch { try { process.kill(child.pid, sig); } catch { /* gone */ } }
}
async function stopVite() {
  if (!vite) return;
  const v = vite; vite = null;
  killGroup(v);
  for (let i = 0; i < 20 && v.exitCode === null && v.signalCode === null; i++) await sleep(250);
  if (v.exitCode === null && v.signalCode === null) killGroup(v, 'SIGKILL');
  console.log(`vite (pid ${v.pid}) stopped`);
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, async () => { await stopVite(); process.exit(130); });

async function startVite() {
  if ((await get('/')) !== 0) throw new Error(`port ${PORT} is already serving something; pick another --port (a stale server is the usual cause of "GameRuntime not initialised")`);
  const bin = path.join(TREE, 'node_modules/vite/bin/vite.js');
  if (!fs.existsSync(bin)) throw new Error('no vite at ' + bin);
  const log = fs.openSync(path.join(OUT, 'logs', 'vite.log'), 'w');
  vite = spawn(process.execPath, [bin, '--host', '127.0.0.1', '--port', String(PORT), '--strictPort'], { cwd: TREE, detached: true, stdio: ['ignore', log, log], env: { ...process.env } });
  console.log(`vite pid ${vite.pid} on :${PORT} from ${TREE}`);
  for (let i = 0; i < 120; i++) {
    if (vite.exitCode !== null) throw new Error('vite exited early, see ' + path.join(OUT, 'logs/vite.log'));
    if ((await get('/')) === 200) break;
    await sleep(500);
  }
  // Warm-up: pull the entry graph once so dependency optimisation finishes before the first browser opens.
  const html = await new Promise((resolve) => http.get({ host: '127.0.0.1', port: PORT, path: '/' }, (res) => { let s = ''; res.on('data', (c) => (s += c)); res.on('end', () => resolve(s)); }).on('error', () => resolve('')));
  for (const m of html.matchAll(/(?:src|href)="([^"]+\.(?:ts|js))"/g)) await get('/' + m[1].replace(/^\.?\//, ''));
  await get('/src/scenes/WorldScene.ts');
  await sleep(2500);
}

function runScript(name, attempt) {
  const [file, disc] = name.split(':');
  const script = path.join(QA_DIR, file + '.cjs');
  const tag = `${name.replace(':', '_')}${attempt ? `.retry${attempt}` : ''}`;
  const logFile = path.join(OUT, 'logs', tag + '.log');
  const shots = path.join(OUT, 'shots', tag);
  fs.mkdirSync(shots, { recursive: true });
  const timeout = (TIMEOUTS[file] ? TIMEOUTS[file] * 1000 : DEFAULT_TIMEOUT);
  const env = { ...env0, DM_QA_ARTIFACT_DIR: shots, ...(disc ? { DM_QA_DISC: disc } : {}) };
  const scriptArgs = file === 'necro-audit' ? ['all'] : [];
  return new Promise((resolve) => {
    const out = fs.openSync(logFile, 'w');
    const t0 = Date.now();
    const child = spawn(process.execPath, [script, ...scriptArgs], { cwd: TREE, env, detached: true, stdio: ['ignore', out, out] });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; killGroup(child); setTimeout(() => killGroup(child, 'SIGKILL'), 5000); }, timeout);
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      killGroup(child, 'SIGKILL'); // sweep any orphaned Chromium of this run's group
      resolve({ code, signal, timedOut, seconds: Math.round((Date.now() - t0) / 100) / 10, log: logFile });
    });
  });
}
const tail = (file, n = 25) => { try { return fs.readFileSync(file, 'utf8').trimEnd().split('\n').slice(-n).join('\n'); } catch { return ''; } };

async function main() {
  console.log(`out: ${OUT}\n${names.length} runs: ${names.join(', ')}`);
  await startVite();
  const results = [];
  try {
    for (const name of names) {
      const attempts = [];
      let status = 'broken';
      for (let a = 0; a <= RETRIES; a++) {
        const r = await runScript(name, a);
        const ok = r.code === 0 && !r.timedOut;
        attempts.push({ attempt: a + 1, ok, exitCode: r.code, timedOut: r.timedOut, seconds: r.seconds, log: path.relative(OUT, r.log), tail: ok ? '' : tail(r.log) });
        console.log(`${ok ? 'PASS' : r.timedOut ? 'TIMEOUT' : 'FAIL'} ${name} (${r.seconds}s${a ? `, retry ${a}` : ''})`);
        if (ok) { status = a === 0 ? 'pass' : 'flaky'; break; }
      }
      const last = attempts[attempts.length - 1];
      results.push({ name, status, seconds: attempts.reduce((s, x) => s + x.seconds, 0), attempts, tail: last.ok ? tail(path.join(OUT, last.log), 6) : last.tail });
    }
  } finally {
    await stopVite();
  }
  const counts = results.reduce((c, r) => ((c[r.status] = (c[r.status] || 0) + 1), c), {});
  const summary = { stamp: STAMP, tree: TREE, port: PORT, load: os.loadavg().map((x) => +x.toFixed(2)), counts, totalSeconds: Math.round(results.reduce((s, r) => s + r.seconds, 0)), results };
  fs.writeFileSync(path.join(OUT, 'summary.json'), JSON.stringify(summary, null, 2));
  const md = [`# QA run ${STAMP}`, '', `Tree \`${TREE}\`, port ${PORT}, load at end ${summary.load.join(' ')}.`, `Result: ${Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(', ')} in ${summary.totalSeconds}s.`, '', '| script | status | seconds | attempts |', '|---|---|---:|---:|',
    ...results.map((r) => `| ${r.name} | ${r.status} | ${r.seconds} | ${r.attempts.length} |`), ''];
  for (const r of results.filter((x) => x.status !== 'pass')) {
    md.push(`## ${r.name} (${r.status})`, '');
    for (const a of r.attempts.filter((x) => !x.ok)) md.push(`Attempt ${a.attempt}: ${a.timedOut ? 'timed out' : `exit ${a.exitCode}`}, ${a.seconds}s, log \`${a.log}\``, '', '```', a.tail, '```', '');
  }
  fs.writeFileSync(path.join(OUT, 'summary.md'), md.join('\n'));
  console.log(`\n${Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(', ')}; summary: ${path.join(OUT, 'summary.md')}`);
  process.exitCode = results.some((r) => r.status === 'broken') ? 1 : 0;
}
main().catch(async (e) => { console.error(e.message); await stopVite(); process.exit(2); });
