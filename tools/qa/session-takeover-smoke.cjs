// Two windows, one account: the newer login wins, the older window gets the "Logged in elsewhere" overlay and stops saving, and
// "Play here" takes it back. Needs no database: it starts a stub account service on STUB_PORT that uses the real
// server/death-muffin/backend/session.cjs for the session rules and talks the same /login, /character, /api/session routes.
//   DM_STUB_PORT=5368 DM_QA_URL=http://127.0.0.1:5367/ ; vite started with VITE_API_PROXY_TARGET=http://127.0.0.1:5368 VITE_WS_BASE= (see README)
//   VITE_API_PROXY_TARGET=http://127.0.0.1:5368 VITE_WS_BASE= npx vite --host 127.0.0.1 --port 5367 --strictPort
//   node tools/qa/session-takeover-smoke.cjs
const assert = require('node:assert/strict');
const http = require('node:http');
const { mkdirSync } = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { watchErrors, preloadModules, shot } = require('./lib/qa-common.cjs');
const session = require(path.join(__dirname, '../../server/death-muffin/backend/session.cjs'));

const STUB_PORT = Number(process.env.DM_STUB_PORT || 5368);
const account = { id: 1, active_session: null, role: 'player', gm_enabled: 0, level: 258 };
const writes = []; // every save that was accepted: { sid, level }
const db = {
  async execute(sql, params) {
    if (/^UPDATE accounts SET active_session/.test(sql)) { account.active_session = params[0]; return [{ affectedRows: 1 }]; }
    return [[{ active_session: account.active_session, role: account.role, gm_enabled: 0 }]];
  },
};
const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const dec = (t) => JSON.parse(Buffer.from(t, 'base64url').toString());
const character = () => ({ id: 1, class_index: 5, class_name: 'Necromancer', level: account.level, experience: 10, gold: 500, stat_str: 5, stat_agi: 5, stat_int: 8, stat_vit: 10, discipline_index: 2 });

const stub = http.createServer(async (req, res) => {
  const send = (status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  let raw = '';
  for await (const chunk of req) raw += chunk;
  const body = raw ? JSON.parse(raw) : {};
  const url = req.url.split('?')[0];
  let user = null;
  try { user = dec((req.headers.authorization || '').slice(7)); } catch { /* none */ }
  if (url === '/login') {
    const sid = await session.claimSession(db, 1);
    return send(200, { token: enc({ accountId: 1, username: 'twice', sid }) });
  }
  if (url === '/api/session/claim') {
    if (!user) return send(401, { error: 'invalid or expired token' });
    const sid = await session.claimSession(db, 1);
    return send(200, { token: enc({ ...user, sid }) });
  }
  if (!user) return send(401, { success: false, error: 'missing or invalid Authorization header' });
  req.user = user;
  if (!(await session.checkWrite(db, req, { status: (s) => ({ json: (b) => send(s, b) }) }))) return;
  if (url === '/api/session') return send(200, { success: true, active: !(await session.isReplaced(db, user)) });
  if (url === '/character' && req.method === 'GET') return send(200, character());
  if (url === '/api/character/save-progress') {
    account.level = body.level;
    writes.push({ sid: user.sid, level: body.level });
    return send(200, { success: true, data: { ...character(), level: body.level } });
  }
  return send(req.method === 'GET' ? 404 : 200, req.method === 'GET' ? { error: 'not in the stub' } : { success: true, data: {} });
});

async function enter(browser, label) {
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
  const { errors } = watchErrors(page);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5367/');
  await page.fill('#cw-user', 'twice');
  await page.fill('#cw-pass', 'password-123');
  await page.locator('#cw-login-btn').click();
  try {
    await page.waitForFunction(() => window.__cwDebug, null, { timeout: 240000 });
  } catch (err) {
    await shot(page, `${process.env.DM_QA_ARTIFACT_DIR || '/tmp/dm-session-takeover'}/${label}-no-world.png`).catch(() => {});
    throw new Error(`${label} window never reached the world: ${errors.join(' | ')}`);
  }
  await preloadModules(page, { api: '/src/net/api.ts' });
  return { page, errors, label };
}
const trySave = (page, level) => page.evaluate(async (lv) => {
  try { await window.__qaMods.api.saveProgress({ characterId: 1, level: lv, xp: 5, gold: 500 }); return 'saved'; } catch (e) { return `${e.status}:${e.message}`; }
}, level);

async function main() {
  await new Promise((r) => stub.listen(STUB_PORT, '127.0.0.1', r));
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/dm-session-takeover';
  mkdirSync(out, { recursive: true });
  try {
    const old = await enter(browser, 'old');
    assert.equal(await trySave(old.page, 259), 'saved', 'the only window saves');
    const fresh = await enter(browser, 'new'); // same account, second window: newest wins
    assert.equal(await trySave(fresh.page, 260), 'saved', 'the newer window saves');
    const before = writes.length;
    const refused = await trySave(old.page, 261);
    assert.match(refused, /^409:/, `the older window is refused: ${refused}`);
    await old.page.waitForSelector('.dm-session-overlay', { timeout: 10000 });
    assert.match(await old.page.locator('.dm-session-overlay').innerText(), /Logged in elsewhere/);
    assert.equal(await fresh.page.locator('.dm-session-overlay').count(), 0, 'the newer window has no overlay');
    assert.equal(await trySave(old.page, 262), '409:This account was opened somewhere else. This window stopped saving.', 'later writes are blocked locally');
    assert.equal(writes.length, before, 'nothing from the stale window reached the server');
    assert.equal(account.level, 260, 'the newer window progress was not rolled back');
    await shot(old.page, `${out}/stale-window-overlay.png`);
    await old.page.locator('.dm-session-overlay button').click();
    await old.page.waitForFunction(() => !document.querySelector('.dm-session-overlay') && window.__cwDebug, null, { timeout: 240000 });
    await preloadModules(old.page, { api: '/src/net/api.ts' });
    assert.equal(await trySave(old.page, 263), 'saved', 'Play here: the old window saves again');
    assert.match(await trySave(fresh.page, 264), /^409:/, 'and the window that was newer is now the stale one');
    // An automatic reload (update notice / release watch sets dm_auto_reload) must not claim the session back.
    await old.page.evaluate(() => { sessionStorage.setItem('dm_auto_reload', '1'); });
    await old.page.reload();
    await old.page.waitForFunction(() => window.__cwDebug, null, { timeout: 240000 });
    await preloadModules(old.page, { api: '/src/net/api.ts' });
    assert.equal(await fresh.page.evaluate(() => sessionStorage.getItem('dm_auto_reload')), null);
    assert.match(await trySave(fresh.page, 265) + '', /^409:/, 'precondition: fresh is stale after Play here');
    // (fresh window is the stale one here; the window that holds the session is `old`)
    await old.page.waitForTimeout(300);
    assert.equal(await trySave(old.page, 266), 'saved', 'the window that held the session keeps it across an automatic reload');
    // Now make the other window newer, then auto-reload the stale one: it stays stale and shows the overlay.
    const claimed = await fresh.page.evaluate(async () => { const t = sessionStorage.getItem('dm_jwt'); const r = await fetch('/api/session/claim', { method: 'POST', headers: { Authorization: `Bearer ${t}` } }); const j = await r.json(); sessionStorage.setItem('dm_jwt', j.token); return !!j.token; });
    assert.ok(claimed);
    await fresh.page.reload(); // explicit refresh claims (already active, fine)
    await fresh.page.waitForFunction(() => window.__cwDebug, null, { timeout: 240000 });
    await preloadModules(fresh.page, { api: '/src/net/api.ts' });
    await old.page.evaluate(() => { sessionStorage.setItem('dm_auto_reload', '1'); });
    await old.page.reload();
    await old.page.waitForSelector('.dm-session-overlay', { timeout: 60000 });
    assert.equal(await trySave(fresh.page, 267), 'saved', 'the newer window keeps the session after the stale one auto-reloaded');
    for (const w of [old, fresh]) assert.equal(w.errors.filter((e) => !/40[49]/.test(e)).length, 0, `${w.label}: no page errors (stub 404s and the 409 itself ignored): ${w.errors.join(' | ')}`);
    console.log('session takeover smoke: ok');
  } finally {
    await browser.close();
    stub.close();
  }
}
main().catch((err) => { console.error(err); process.exit(1); });
