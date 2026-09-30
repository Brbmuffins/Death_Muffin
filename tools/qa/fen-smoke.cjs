/**
 * Mourning Fen smoke (offline preview, High quality): the zone and its dry landing, bog slow vs hummocks, each mob (rest pose),
 * the Bog Hag's hex showing on thralls, a Wisp pulse and a Sexton hook, and a perf comparison against the Graves roster.
 *   npm run dev -- --host 127.0.0.1 --port 5306 --strictPort
 *   DM_QA_URL=http://127.0.0.1:5306/?offline node tools/qa/fen-smoke.cjs
 * Screenshots go to DM_QA_ARTIFACT_DIR (default: the system temp dir).
 */
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const OUT = process.env.DM_QA_ARTIFACT_DIR || os.tmpdir();

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  const errors = [];
  const models = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  page.on('response', (r) => r.url().endsWith('.glb') && models.push([r.url().split('/').slice(-2).join('/'), r.status()]));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5306/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `fnqa_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('fnqa@example.invalid');
  await page.fill('#cw-pass', 'TestingFen1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 180000 });
  const shot = async (name) => {
    for (let i = 0; i < 4; i++) {
      try { return await page.screenshot({ path: path.join(OUT, `${name}.png`), timeout: 150000 }); } catch (e) { if (i === 3) throw e; }
    }
  };
  process.on('exit', () => errors.length && console.log('PAGE ERRORS', errors.slice(0, 5)));
  const settle = async () => { await page.waitForTimeout(2500); await page.evaluate(() => window.__cwDebug.advance(0.3)); };

  // --- The zone: arrive on the dry landing, look across the marsh.
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.god(true);
    d.unlockAll();
    d.goto('fen');
    d.advance(0.5);
    d.clear();
    d.zoom(1);
    d.advance(1);
  });
  await settle();
  await shot('fen-landing');
  assert.equal(await page.evaluate(() => window.__cwDebug.player.area), 'fen');

  // --- Bog slow: dry landing 1, open water slower, a hummock dry again.
  const slow = await page.evaluate(() => {
    const d = window.__cwDebug;
    const p = d.player;
    const at = (x, z) => { p.x = x; p.z = z; d.advance(0.1); return +p.moveMult.toFixed(3); };
    return { landing: at(-26, -80), water: at(-50, -78), hummock: at(-42, -80), wet2: at(-44, -70) };
  });
  console.log('slow', JSON.stringify(slow));
  assert.equal(slow.landing, 1);
  assert.equal(slow.hummock, 1);
  assert.ok(slow.water < 0.85 && slow.wet2 < 0.85, 'open water should slow the hero');

  // --- The zone from the marsh heart, then the mobs at rest.
  await page.evaluate(() => {
    const d = window.__cwDebug;
    const p = d.player;
    p.x = -42; p.z = -80;
    d.advance(0.5);
    d.zoom(0.85);
    d.advance(1);
  });
  await settle();
  await shot('fen-marsh');
  await page.evaluate(() => {
    const d = window.__cwDebug;
    const p = d.player;
    ['bog_hag', 'mire_leech', 'fen_wisp', 'drowned_sexton', 'wraith'].forEach((def, i) => {
      const a = i * 1.25 + 0.3;
      const e = d.sim().spawnEnemy(def, 'fen', p.x + Math.sin(a) * 3.8, p.z + Math.cos(a) * 3.8, false, false);
      e.attackCd = 99;
    });
    d.freeze(true);
    d.zoom(0.55);
    d.advance(2);
  });
  await settle();
  await shot('fen-mobs');

  // --- Hag hex on thralls: raise three thralls, plant a hag, watch the ring and the sigils.
  const hex = await page.evaluate(() => {
    const d = window.__cwDebug;
    d.freeze(false);
    d.clear();
    const sim = d.sim();
    const p = d.player;
    p.x = -42; p.z = -80;
    for (let i = 0; i < 4; i++) {
      const x = p.x + 1.5 + i * 0.5;
      sim.addCorpse(x, p.z + i * 0.4, 'normal', 'robber', false, 0, 1, 'fen');
      sim.apply({ t: 'exhume', by: d.self(), x, z: p.z + i * 0.4, r: 1, kind: 'warrior', cap: 8, hp: 9999, damage: 10, attackSpeedMult: 1 });
    }
    d.advance(1.5);
    for (const t of sim.thralls.values()) t.speed = 0;
    const hag = sim.spawnEnemy('bog_hag', 'fen', p.x + 7, p.z, false, false);
    hag.attackCd = 0;
    d.zoom(0.6);
    let cursed = 0;
    for (let i = 0; i < 40; i++) { d.advance(0.1); cursed = Math.max(cursed, [...sim.thralls.values()].filter((t) => t.cursedT > 0).length); if (i === 8) window.__mid = true; }
    return { thralls: sim.thralls.size, cursed };
  });
  console.log('hex', JSON.stringify(hex));
  assert.ok(hex.thralls >= 2 && hex.cursed >= 1, 'the hex never landed on a thrall');
  await settle();
  await shot('fen-hex');

  // --- Wisp pulse + Sexton hook telegraphs.
  const tele = await page.evaluate(() => {
    const d = window.__cwDebug;
    d.clear();
    const sim = d.sim();
    const p = d.player;
    p.x = -36; p.z = -80;
    sim.spawnEnemy('fen_wisp', 'fen', p.x - 6, p.z, false, false).attackCd = 0;
    sim.spawnEnemy('drowned_sexton', 'fen', p.x + 6, p.z + 1, false, false).attackCd = 0;
    const kinds = new Set();
    const emit = sim.emit.bind(sim);
    sim.emit = (ev) => { if (ev.t === 'telegraph') kinds.add(ev.kind); if (ev.t === 'hurt' && ev.pull) kinds.add('pull'); return emit(ev); };
    for (let i = 0; i < 70; i++) d.advance(0.1);
    sim.emit = emit;
    return [...kinds];
  });
  console.log('telegraphs', JSON.stringify(tele));
  assert.ok(tele.includes('pulse') && tele.includes('hook'), 'wisp pulse / sexton hook never telegraphed');
  await settle();
  await shot('fen-telegraphs');

  // --- Perf: 36 enemies, Graves roster vs the Fen roster.
  const perf = await page.evaluate(() => {
    const d = window.__cwDebug;
    const run = (defs, area) => {
      d.clear();
      d.advance(0.2);
      const p = d.player;
      for (let i = 0; i < 36; i++) {
        const e = d.sim().spawnEnemy(defs[i % defs.length], area, p.x + Math.sin(i) * (4 + (i % 5)), p.z + Math.cos(i) * (4 + (i % 5)), false, false);
        e.hp = e.maxHp = 1e6;
      }
      d.advance(1);
      const r = d.perf(120);
      return { calls: r.calls, triangles: r.triangles, updateMs: +r.updateMs.toFixed(3), programs: r.programs };
    };
    const graves = run(['robber', 'hound', 'penitent', 'sac'], 'fen');
    const fen = run(['bog_hag', 'mire_leech', 'fen_wisp', 'drowned_sexton', 'wraith'], 'fen');
    return { graves, fen };
  });
  console.log('perf', JSON.stringify(perf));
  assert.ok(models.every(([, s]) => s === 200 || s === 304), 'a model failed to load');
  assert.deepEqual(errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e)), [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
