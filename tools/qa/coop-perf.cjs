// Co-op perf harness: two real clients (host + guest) on a local relay, a real fight, and per-client numbers.
// Measures wire bytes (Playwright websocket frames), snapshot rates, host makeSnapshot+stringify cost, guest applySnapshot/applyEvents cost,
// main-thread long tasks, __cwDebug.perf() updateMs, the relay's own CPU, and a CDP CPU profile of the guest.
//   VITE_WS_BASE=http://127.0.0.1:5402 npx vite --host 127.0.0.1 --port 5401 --strictPort
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5401/?offline&coop' node tools/qa/coop-perf.cjs
// Env: DM_QA_RT_PORT (5402)  DM_QA_WINDOW_MS (10000)  DM_QA_SCENARIOS (same,split)  DM_QA_AREA (nave)  DM_QA_AREA2 (graves, the guest's area in "split")
//      DM_QA_RINGS (rings of the zone roster, default 3)  DM_QA_PROFILE=0 (skip the guest CPU profile)  DM_QA_OUT (json path)
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5401/?offline&coop';
const PORT = process.env.DM_QA_RT_PORT || '5402';
const WINDOW = +(process.env.DM_QA_WINDOW_MS || 10000);
const SCENARIOS = (process.env.DM_QA_SCENARIOS || 'same,split').split(',');
const AREA = process.env.DM_QA_AREA || 'nave';
const AREA2 = process.env.DM_QA_AREA2 || 'graves';
const RINGS = +(process.env.DM_QA_RINGS || 3);
const PROFILE = process.env.DM_QA_PROFILE !== '0';
const origin = new globalThis.URL(URL).origin;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const cpuTicks = (pid) => { const f = fs.readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' '); return (+f[11] + +f[12]) * 10; }; // utime+stime, ms (100 Hz ticks)
const stats = (a) => (a.length ? { n: a.length, avg: Math.round(a.reduce((s, x) => s + x, 0) / a.length), max: Math.max(...a) } : { n: 0, avg: 0, max: 0 });

function startRealtime() {
  const child = spawn(process.execPath, [path.join(__dirname, '../../server/realtime/server.js')], {
    env: { ...process.env, REALTIME_PORT: PORT, REALTIME_HOST: '127.0.0.1', DEV_TRUST_TOKENS: '1', CORS_ORIGIN: origin, NODE_ENV: 'development' },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  return new Promise((resolve, reject) => {
    child.stdout.on('data', (d) => { if (String(d).includes('listening')) resolve(child); });
    child.once('exit', (c) => reject(new Error(`realtime exited ${c}`)));
    setTimeout(() => reject(new Error('realtime start timeout')), 10000);
  });
}

async function login(browser, name) {
  const ctx = await browser.newContext({ viewport: { width: 800, height: 520 } });
  const page = await ctx.newPage();
  page.setDefaultTimeout(150000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  const frames = { out: [], in: [], lastSnap: null };
  page.on('websocket', (ws) => {
    const rec = (dir) => ({ payload }) => {
      const s = typeof payload === 'string' ? payload : '';
      const m = /^4\d\["([a-z:]+)"/.exec(s);
      if (!m) return;
      frames[dir].push({ ev: m[1], bytes: Buffer.byteLength(s), at: Date.now() });
      if (dir === 'in' && m[1] === 'world:snapshot') frames.lastSnap = s.slice(s.indexOf(',') + 1, -1);
    };
    ws.on('framesent', rec('out'));
    ws.on('framereceived', rec('in'));
  });
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', name);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${name}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded);
  return { page, errors, frames, ctx };
}

// In-page hooks: wrap WorldMirror.applySnapshot/applyEvents, long tasks, frame times.
const INSTALL = async () => {
  const { WorldMirror } = await import('/src/gameplay/sim/snapshot.ts');
  const h = (window.__perfHook = { snapMs: [], evMs: [], long: [], frames: [] });
  if (window.__perfHook0) return; window.__perfHook0 = true;
  if (!WorldMirror.prototype.__wrapped) {
    WorldMirror.prototype.__wrapped = true;
    const aS = WorldMirror.prototype.applySnapshot;
    WorldMirror.prototype.applySnapshot = function (s) { const t = performance.now(); const r = aS.call(this, s); window.__perfHook?.snapMs.push(performance.now() - t); return r; };
    const aE = WorldMirror.prototype.applyEvents;
    WorldMirror.prototype.applyEvents = function (b) { const t = performance.now(); const r = aE.call(this, b); window.__perfHook?.evMs.push(performance.now() - t); return r; };
  }
  try { new PerformanceObserver((l) => { for (const e of l.getEntries()) h.long.push(e.duration); }).observe({ entryTypes: ['longtask'] }); } catch {}
  // Render-free driver: hide the page from the RAF loop and step the game at 30 Hz of real time, so software GL does not drown the numbers.
  Object.defineProperty(document, 'hidden', { get: () => true, configurable: true });
  h.tickMs = [];
  let last = performance.now();
  h.timer = setInterval(() => {
    const n = performance.now(); h.frames.push(n - last); last = n;
    window.__cwDebug.advance(2 / 60, 1 / 60, false);
    h.tickMs.push(performance.now() - n);
  }, 33);
};
const RESET = () => { const h = window.__perfHook; h.snapMs = []; h.evMs = []; h.long = []; h.frames = []; h.tickMs = []; };
const READ = () => {
  const h = window.__perfHook;
  const sum = (a) => a.reduce((s, x) => s + x, 0);
  const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(s.length * p))] : 0; };
  const d = window.__cwDebug;
  return {
    snapApplied: h.snapMs.length, applySnapshotMsAvg: +(sum(h.snapMs) / Math.max(1, h.snapMs.length)).toFixed(3), applySnapshotMsMax: +Math.max(0, ...h.snapMs).toFixed(2),
    evApplied: h.evMs.length, applyEventsMsAvg: +(sum(h.evMs) / Math.max(1, h.evMs.length)).toFixed(3),
    longTasks: h.long.length, longTaskMs: Math.round(sum(h.long)), longTaskMax: Math.round(Math.max(0, ...h.long)),
    ticks: h.frames.length, tickGapMsAvg: +(sum(h.frames) / Math.max(1, h.frames.length)).toFixed(1), tickGapMsP95: +q(h.frames, 0.95).toFixed(1), tickGapMsMax: Math.round(Math.max(0, ...h.frames)),
    updateMsAvg: +(sum(h.tickMs) / Math.max(1, h.tickMs.length) / 2).toFixed(2), updateMsP95: +(q(h.tickMs, 0.95) / 2).toFixed(2), updateMsMax: +(Math.max(0, ...h.tickMs) / 2).toFixed(1),
    counts: d.counts(),
  };
};

async function profileTop(session, n = 14) {
  const { profile } = await session.send('Profiler.stop');
  const dt = profile.timeDeltas; const self = new Map();
  const byId = new Map(profile.nodes.map((x) => [x.id, x]));
  profile.samples.forEach((id, i) => self.set(id, (self.get(id) || 0) + (dt[i] || 0)));
  const agg = new Map(); let total = 0;
  for (const [id, us] of self) {
    const cf = byId.get(id).callFrame; total += us;
    const k = `${cf.functionName || '(anon)'} ${cf.url.replace(/^.*\/(src|node_modules)\//, '$1/')}:${cf.lineNumber + 1}`;
    agg.set(k, (agg.get(k) || 0) + us);
  }
  return [...agg.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, us]) => `${(us / 1000).toFixed(0).padStart(6)} ms ${(100 * us / total).toFixed(1).padStart(5)}%  ${k}`);
}

const summarize = (frames, t0, t1) => {
  const o = {};
  for (const dir of ['out', 'in']) {
    const by = {};
    for (const f of frames[dir]) if (f.at >= t0 && f.at <= t1) (by[f.ev] ||= []).push(f.bytes);
    o[dir] = Object.fromEntries(Object.entries(by).map(([ev, a]) => [ev, { perSec: +(a.length / ((t1 - t0) / 1000)).toFixed(1), kbPerSec: +(a.reduce((s, x) => s + x, 0) / 1024 / ((t1 - t0) / 1000)).toFixed(1), ...stats(a), over96k: a.filter((x) => x > 96 * 1024).length }]));
  }
  return o;
};

(async () => {
  const rt = await startRealtime();
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const results = {};
  try {
    const n = Date.now() % 1000000;
    const H = await login(browser, `cpH_${n}`);
    await H.page.waitForFunction(() => window.__cwDebug.net().connected);
    const G = await login(browser, `cpG_${n}`);
    await G.page.waitForFunction(() => window.__cwDebug.net().connected);
    await H.page.waitForFunction(() => window.__cwDebug.counts().remotes === 1);
    const nets = [await H.page.evaluate(() => window.__cwDebug.net()), await G.page.evaluate(() => window.__cwDebug.net())];
    if (!nets[0].host || nets[1].host) throw new Error('expected first client to be the host');
    for (const P of [H, G]) await P.page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
    for (const P of [H, G]) await P.page.evaluate(INSTALL); // render-free from here on (software GL shader compiles would stall the sockets)

    for (const sc of SCENARIOS) {
      const guestArea = sc === 'split' ? AREA2 : AREA;
      // Host: fight in AREA — thralls, corpses, rings of the whole zone roster (moving, god mode keeps the host alive).
      await H.page.evaluate(async ({ area, rings }) => {
        const d = window.__cwDebug; d.goto(area); d.advance(0.5, 1 / 60, false); d.clear();
        const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const sim = d.sim(); const m = sc.discipline.mods; const p = d.player;
        for (let i = 0; i < m.thrallCap; i++) {
          const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5;
          sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area);
          sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap: m.thrallCap, kind: m.thrallKind, hp: 1e6, damage: 0, attackSpeedMult: 1 });
        }
        d.advance(1.5, 1 / 60, false);
        const roster = (await import('/src/content/areas.ts')).AREAS[area].enemies.map((e) => e.id);
        for (let k = 0; k < rings; k++) roster.forEach((id, i) => d.ring(id, 4, 6 + i * 1.2 + k * 0.5, i === 0));
        for (let i = 0; i < 40; i++) d.sim().addCorpse(p.x + 4 + (i % 8) * 1.2, p.z - 3 - Math.floor(i / 8) * 1.5, 'normal', 'robber', false, 0, 1, p.area);
        d.advance(0.6, 1 / 60, false);
      }, { area: AREA, rings: RINGS });
      await G.page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(0.5, 1 / 60, false); d.zoom(0.8); }, guestArea);
      if (sc === 'split') await H.page.evaluate(async (a) => { // a second, busy zone around the guest, so the host simulates two live areas
        const d = window.__cwDebug; const sim = d.sim(); const { AREAS } = await import('/src/content/areas.ts');
        const r = AREAS[a].rect; const cx = (r.x0 + r.x1) / 2, cz = (r.z0 + r.z1) / 2 + 4;
        AREAS[a].enemies.forEach((e, i) => { for (let k = 0; k < 8; k++) sim.spawnEnemy(e.id, a, cx + Math.cos(k + i) * (5 + i), cz + Math.sin(k + i) * (5 + i), i === 0, false); });
      }, guestArea);
      await wait(3000); // settle: let the world run and the guest get the state

      for (const P of [H, G]) await P.page.evaluate(RESET);
      const gs = PROFILE ? await G.ctx.newCDPSession(G.page) : null;
      if (gs) { await gs.send('Profiler.enable'); await gs.send('Profiler.setSamplingInterval', { interval: 500 }); await gs.send('Profiler.start'); }
      const r0 = cpuTicks(rt.pid); const t0 = Date.now();
      // host micro-bench on the live sim, in the same window (after we sample wire traffic)
      await wait(WINDOW);
      const t1 = Date.now(); const r1 = cpuTicks(rt.pid);
      const prof = gs ? await profileTop(gs) : null;
      const hostRead = await H.page.evaluate(READ); const guestRead = await G.page.evaluate(READ);
      const bench = await H.page.evaluate(async () => {
        const { makeSnapshot } = await import('/src/gameplay/sim/snapshot.ts'); const sim = window.__cwDebug.sim();
        const time = (fn, k = 200) => { fn(); const t = performance.now(); for (let i = 0; i < k; i++) fn(); return +((performance.now() - t) / k).toFixed(3); };
        return {
          enemies: sim.enemies.size, thralls: sim.thralls.size, corpses: sim.corpses.size, zones: sim.zones.size,
          makeSnapshotMs: time(() => makeSnapshot(sim, false)), makeSnapshotFullMs: time(() => makeSnapshot(sim, true)),
          stringifyMs: (() => { const o = makeSnapshot(sim, false); return time(() => JSON.stringify(o)); })(), stringifyFullMs: (() => { const o = makeSnapshot(sim, true); return time(() => JSON.stringify(o)); })(),
        };
      });
      const guestBench = await G.page.evaluate(async (snap) => {
        const { WorldMirror } = await import('/src/gameplay/sim/snapshot.ts'); const s = JSON.parse(snap);
        const m = new WorldMirror(); m.applySnapshot(s);
        const t = performance.now(); for (let i = 0; i < 200; i++) m.applySnapshot(s);
        const a = (performance.now() - t) / 200; const t2 = performance.now(); for (let i = 0; i < 200; i++) JSON.parse(snap); 
        return { enemyRows: s.enemies.length, thrallRows: s.thralls.length, applyMs: +a.toFixed(3), parseMs: +((performance.now() - t2) / 200).toFixed(3) };
      }, G.frames.lastSnap);
      const perf = null; // __cwDebug.perf() renders (shader compiles under software GL); the driver's updateMs* above is the same CPU-update measure
      results[sc] = {
        guestArea, windowMs: t1 - t0,
        relayCpuPctOfOneCore: +((100 * (r1 - r0)) / (t1 - t0)).toFixed(1),
        hostSent: summarize(H.frames, t0, t1).out, guestRecv: summarize(G.frames, t0, t1).in, guestSent: summarize(G.frames, t0, t1).out,
        hostBench: bench, guestBench, hostPage: hostRead, guestPage: guestRead, perf,
      };
      console.log('all ws events seen:', JSON.stringify([...new Set([...H.frames.out, ...G.frames.in].map((f) => f.ev))]));
      console.log(`\n=== ${sc} ===\n${JSON.stringify(results[sc], null, 1)}`);
      if (prof) { console.log('guest CPU profile (self time):'); console.log(prof.join('\n')); results[sc].guestProfile = prof; }
    }
    results.errors = [...H.errors, ...G.errors];
    if (results.errors.length) console.log('PAGE ERRORS', results.errors);
    if (process.env.DM_QA_OUT) fs.writeFileSync(process.env.DM_QA_OUT, JSON.stringify(results, null, 1));
  } finally {
    await browser.close();
    try { rt.removeAllListeners('exit'); rt.kill('SIGKILL'); } catch {}
  }
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
