/**
 * Release 0404 database probe: migrations 035 / 036 / 037 / 039 and the routes that use them, against a REAL MySQL scratch database and the
 * REAL server.js (reforge.cjs, boss-key.cjs, kills.cjs, loadouts.cjs, session.cjs, level-999 saves). Same recipe as authority-db-probe.cjs.
 *
 *   1. scratch DB = `mysqldump --no-data` of the LIVE death_muffin (read-only) + the live `items` rows; a throwaway user limited to it;
 *      apply 035, 036, 037 BEFORE running (039 is applied by the probe itself, midway, to prove the backend fails open without it);
 *   2. NODE_PATH=<backend node_modules> DM_PROBE_RUNTIME=<empty dir> DM_PROBE_DB=... DM_PROBE_USER=... DM_PROBE_PASS=... node tools/qa/release-0404-db-probe.cjs
 *
 * Starts server.js on 127.0.0.1:5371.. against the scratch DB only, stops what it started. Every check prints `ok`/`FAIL`; exit code 1 if any FAIL.
 * Drop the database and user afterwards.
 */
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');
const jwt = require('jsonwebtoken');

const ROOT = path.join(__dirname, '../..');
const BACKEND = path.join(ROOT, 'server/death-muffin/backend');
const SECRET = 'probe-secret';
let failures = 0;
const check = (v, msg) => { if (v) console.log(`ok   ${msg}`); else { failures++; console.log(`FAIL ${msg}`); } return !!v; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function stageRuntime(dir) {
  fs.mkdirSync(path.join(dir, 'gathering'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'necro-progress'), { recursive: true });
  for (const f of fs.readdirSync(BACKEND)) if (/\.(js|cjs)$/.test(f) && !/\.test\./.test(f) && !/-fake-db/.test(f)) fs.copyFileSync(path.join(BACKEND, f), path.join(dir, f));
  for (const f of fs.readdirSync(path.join(BACKEND, 'gathering'))) if (/\.cjs$/.test(f) && !/\.test\./.test(f)) fs.copyFileSync(path.join(BACKEND, 'gathering', f), path.join(dir, 'gathering', f));
  for (const f of ['necro-rules.cjs', 'necro-progress-routes.cjs', 'mysql-store.cjs']) fs.copyFileSync(path.join(ROOT, 'server/vps-handoff/necro-progress', f), path.join(dir, 'necro-progress', f));
}

/** A port nobody listens on (other agents run vite dev servers on neighbouring ports that PROXY /register etc. to the LIVE backend: never assume a fixed port is ours). */
const freePort = () => new Promise((resolve, reject) => {
  const net = require('net');
  const s = net.createServer();
  s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
  s.on('error', reject);
});

async function startServer(_ignored, extraEnv) {
  const port = await freePort();
  const env = { ...process.env, PORT: String(port), DB_HOST: '127.0.0.1', DB_USER: process.env.DM_PROBE_USER, DB_PASS: process.env.DM_PROBE_PASS, DB_NAME: process.env.DM_PROBE_DB, JWT_SECRET: SECRET, JWT_EXPIRES_IN: '1h', ...extraEnv };
  const child = spawn(process.execPath, [path.join(process.env.DM_PROBE_RUNTIME, 'server.js')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const srv = { child, log: '', base: `http://127.0.0.1:${port}` };
  child.stdout.on('data', (d) => (srv.log += d));
  child.stderr.on('data', (d) => (srv.log += d));
  let up = false;
  for (let i = 0; i < 80 && !up; i++) {
    if (child.exitCode !== null) throw new Error(`server.js exited early: ${srv.log.slice(-400)}`);
    try { const r = await fetch(`${srv.base}/health`); up = r.ok && (await r.json()).status === 'ok' && srv.log.includes(`listening on ${port}`); } catch { /* not up yet */ }
    if (!up) await sleep(250);
  }
  if (!up) throw new Error('server.js did not come up');
  srv.call = async (method, url, body, token) => {
    const res = await fetch(srv.base + url, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => null) };
  };
  srv.stop = () => {
    // Fail-open paths swallow database errors into a log line: surface every one so a SQL typo cannot hide behind "unavailable".
    const bad = srv.log.split('\n').filter((l) => /ER_|unavailable|SQL|Error|failed/i.test(l));
    if (bad.length) console.log(`     server log lines worth reading (${port}):\n${[...new Set(bad)].slice(0, 12).map((l) => '       ' + l.slice(0, 220)).join('\n')}`);
    child.kill('SIGTERM');
  };
  return srv;
}

let seq = 0;
async function newPlayer(srv, db, { gold = 0, level = 1, role = null } = {}) {
  const name = `p${Date.now() % 1e7}_${seq++}`;
  const reg = await srv.call('POST', '/register', { username: name, password: 'probe-password-1' });
  if (!reg.json || !reg.json.token) throw new Error(`register failed: ${JSON.stringify(reg)}`);
  const accountId = jwt.decode(reg.json.token).accountId;
  if (role) await db.execute('UPDATE accounts SET role = ? WHERE id = ?', [role, accountId]);
  const [ins] = await db.execute("INSERT INTO characters (account_id, class_index, class_name, level, discipline_index, gold) VALUES (?, 1, 'Ossuary', ?, 1, ?)", [accountId, level, gold]);
  return { name, accountId, cid: ins.insertId, token: reg.json.token };
}
const put = (db, cid, slot, item, qty = 1, extra = {}) => db.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot, instance_id) VALUES (?, ?, ?, ?, ?, ?, ?)', [cid, slot, item, qty, extra.equipped ? 1 : 0, extra.equipped_slot ?? null, extra.instance ?? null]);
const gold = async (db, cid) => Number((await db.execute('SELECT gold FROM characters WHERE id = ?', [cid]))[0][0].gold);
const sealCount = async (db, cid) => Number((await db.execute("SELECT COALESCE(SUM(quantity),0) AS n FROM inventory WHERE character_id = ? AND item_id = 'covenant_seal'", [cid]))[0][0].n);
const audits = async (db, cid, kind) => (await db.execute('SELECT kind, mode, action FROM progress_audit WHERE character_id = ?' + (kind ? ' AND kind = ?' : ''), kind ? [cid, kind] : [cid]))[0];

async function main() {
  if (!process.env.DM_PROBE_RUNTIME) throw new Error('set DM_PROBE_RUNTIME to an empty scratch directory');
  stageRuntime(process.env.DM_PROBE_RUNTIME);
  const conf = { host: '127.0.0.1', user: process.env.DM_PROBE_USER, password: process.env.DM_PROBE_PASS, database: process.env.DM_PROBE_DB };
  const db = await mysql.createConnection({ ...conf, multipleStatements: true });
  const affixRules = require(path.join(BACKEND, 'gathering/affix-rules.cjs'));
  const killRules = require(path.join(BACKEND, 'gathering/kill-rules.cjs'));
  const sinks = require(path.join(BACKEND, 'gathering/gold-sink-rules.cjs'));
  const [LO, HI] = affixRules.affixRange('p_str', 20);

  const col = async () => (await db.query("SELECT COUNT(*) AS n FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'accounts' AND column_name = 'active_session'"))[0][0].n;
  check(Number(await col()) === 0, 'precondition: accounts.active_session does not exist yet (039 not applied)');

  // ───────────────────────── PHASE 1: 035-037 applied, 039 NOT applied, AUTHORITY_KILLS=off ─────────────────────────
  let srv = await startServer(5371, { AUTHORITY_KILLS: 'off' });
  try {
    console.log('--- phase 1: before 039, kills off');
    const A = await newPlayer(srv, db, { gold: 500000 });
    check(!jwt.decode(A.token).sid, 'register before 039: token has no sid (claim failed open)');
    const login = await srv.call('POST', '/login', { username: A.name, password: 'probe-password-1' });
    check(login.status === 200 && login.json.token && !jwt.decode(login.json.token).sid, 'login before 039 works, token has no sid');
    const w1 = await srv.call('POST', '/api/character/save-progress', { characterId: A.cid, level: 1, xp: 5, gold: 500000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 }, A.token);
    check(w1.json && w1.json.success, 'write before 039 succeeds');
    const forged = jwt.sign({ accountId: A.accountId, username: A.name, sid: 'x-forged' }, SECRET, { expiresIn: '1h' });
    const w2 = await srv.call('POST', '/api/character/save-progress', { characterId: A.cid, level: 1, xp: 6, gold: 500000 }, forged);
    check(w2.status === 200 && w2.json.success, 'a token with a sid but no column: write fails OPEN (200), not 500');
    const s1 = await srv.call('GET', '/api/session', null, forged);
    check(s1.status === 200 && s1.json.active === true, 'GET /api/session before 039 answers active:true');
    const claim0 = await srv.call('POST', '/api/session/claim', null, A.token);
    check(claim0.status === 200 && claim0.json.token && !jwt.decode(claim0.json.token).sid, 'POST /api/session/claim before 039 returns a (sid-less) token instead of 500');

    // 035 routes with the tables present but 039 absent are independent; also prove the friendly fallbacks when 035 tables are missing.
    await db.query('RENAME TABLE loot_reforges TO loot_reforges_h, empowered_summons TO empowered_summons_h');
    try {
      const q = await srv.call('POST', '/api/reforge/quote', { characterId: A.cid }, A.token);
      check(q.status === 200 && q.json.success === false && /cannot reforge yet/.test(q.json.error), 'reforge/quote with 035 missing: readable error, not a 500');
      await put(db, A.cid, 0, 'covenant_seal', 2);
      const st = await srv.call('POST', '/api/boss-key/status', { characterId: A.cid }, A.token);
      check(st.status === 200 && st.json.success === false && /not ready/.test(st.json.error), 'boss-key/status with 035 missing: readable error');
      const sm = await srv.call('POST', '/api/boss-key/summon', { characterId: A.cid, boss: 'gravedigger' }, A.token);
      check(sm.status === 200 && sm.json.success === false && (await sealCount(db, A.cid)) === 2 && (await gold(db, A.cid)) === 500000, 'boss-key/summon with 035 missing: refused and NOTHING charged (transaction rolled back)');
    } finally {
      await db.query('RENAME TABLE loot_reforges_h TO loot_reforges, empowered_summons_h TO empowered_summons');
      await db.execute('DELETE FROM inventory WHERE character_id = ?', [A.cid]);
    }
    // AUTHORITY_KILLS=off: a kill report is acknowledged and nothing is written
    const kr = await srv.call('POST', '/api/kills/report', { characterId: A.cid, seq: Date.now(), groups: [], bosses: [], floors: [] }, A.token);
    check(kr.status === 200 && kr.json.data.mode === 'off', 'kills off: report acknowledged (mode off)');
    check(Number((await db.execute('SELECT COUNT(*) AS n FROM character_kill_ledger WHERE character_id = ?', [A.cid]))[0][0].n) === 0, 'kills off: no ledger row written');
  } finally { srv.stop(); await sleep(500); }

  // ───────────────────────── apply 039 twice ─────────────────────────
  console.log('--- migration 039');
  const m039 = fs.readFileSync(path.join(BACKEND, 'migrations/039-account-session.sql'), 'utf8');
  const before = (await db.query('SELECT id, username, password_hash, role, last_login FROM accounts ORDER BY id'))[0];
  await db.query(m039); await db.query(m039);
  check(Number(await col()) === 1, 'migration 039 applied twice: exactly one active_session column');
  const [[colInfo]] = await db.query("SELECT COLUMN_TYPE AS t, IS_NULLABLE AS n, COLUMN_DEFAULT AS d, COLLATION_NAME AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'accounts' AND column_name = 'active_session'");
  console.log(`     active_session: ${colInfo.t} nullable=${colInfo.n} default=${colInfo.d} collation=${colInfo.c}`);
  const after = (await db.query('SELECT id, username, password_hash, role, last_login FROM accounts ORDER BY id'))[0];
  check(JSON.stringify(before) === JSON.stringify(after), 'migration 039 left existing account rows untouched');

  // ───────────────────────── PHASE 2: all migrations, AUTHORITY_KILLS=off (default) ─────────────────────────
  srv = await startServer(5372, { AUTHORITY_KILLS: 'off' });
  try {
    console.log('--- phase 2: sessions');
    const A = await newPlayer(srv, db, { gold: 1000 });
    const sidA = jwt.decode(A.token).sid;
    check(!!sidA && /^\d{13}-[0-9a-f]{16}$/.test(sidA), `register after 039 mints a session id (${sidA})`);
    const login2 = await srv.call('POST', '/login', { username: A.name, password: 'probe-password-1' });
    const tok2 = login2.json.token;
    const sid2 = jwt.decode(tok2).sid;
    check(sid2 && sid2 !== sidA, 'second login mints a different session id');
    const prog = (token, xp) => srv.call('POST', '/api/character/save-progress', { characterId: A.cid, level: 1, xp, gold: 1000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 }, token);
    const stale = await prog(A.token, 10);
    check(stale.status === 409 && stale.json.code === 'session_replaced', 'the older token is refused with 409 session_replaced on a write');
    check((await srv.call('GET', `/api/inventory/${A.cid}`, null, A.token)).status === 200, 'the older token can still READ (GET)');
    check((await srv.call('GET', '/api/session', null, A.token)).json.active === false, 'GET /api/session says active:false for the stale token');
    check((await prog(tok2, 11)).json.success === true, 'the newer token writes fine');
    const claimed = await srv.call('POST', '/api/session/claim', null, A.token);
    check(claimed.status === 200 && jwt.decode(claimed.json.token).sid !== sid2, '"Play here" (claim with the replaced token) returns a fresh session');
    check((await prog(claimed.json.token, 12)).json.success === true && (await prog(tok2, 13)).status === 409, 'after the claim, the claiming window writes and the other one is stale');
    const legacy = jwt.sign({ accountId: A.accountId, username: A.name }, SECRET, { expiresIn: '1h' });
    check((await prog(legacy, 14)).json.success === true, 'a legacy token (no sid) is exempt');
    const [[acctRow]] = await db.execute('SELECT active_session FROM accounts WHERE id = ?', [A.accountId]);
    await db.execute('UPDATE accounts SET active_session = NULL WHERE id = ?', [A.accountId]);
    check((await prog(A.token, 15)).json.success === true, 'an account with NULL active_session lets any token write');
    await db.execute('UPDATE accounts SET active_session = ? WHERE id = ?', [acctRow.active_session, A.accountId]);
    for (const role of ['gm', 'admin']) {
      await db.execute('UPDATE accounts SET role = ? WHERE id = ?', [role, A.accountId]);
      check((await prog(tok2, 16)).json.success === true, `staff (role=${role}) is exempt from the stale-session refusal`);
    }
    await db.execute("UPDATE accounts SET role = 'player', gm_enabled = 1 WHERE id = ?", [A.accountId]);
    check((await prog(tok2, 17)).json.success === true, 'staff (gm_enabled) is exempt');
    await db.execute('UPDATE accounts SET gm_enabled = 0 WHERE id = ?', [A.accountId]);
    // a character-bound token keeps the sid
    const ch = await srv.call('POST', '/character', { classIndex: 5 }, claimed.json.token).catch(() => null);
    if (ch && ch.json && ch.json.token) check(!!jwt.decode(ch.json.token).sid, 'POST /character: the character token carries the sid');

    console.log('--- phase 2: level 999');
    const L = await newPlayer(srv, db, { gold: 0, level: 1 });
    const lvl = (level, xp) => srv.call('POST', '/api/character/save-progress', { characterId: L.cid, level, xp, gold: 0, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 }, L.token);
    const r999 = await lvl(999, 0);
    const row = async () => (await db.execute('SELECT level, experience FROM characters WHERE id = ?', [L.cid]))[0][0];
    check(r999.json.success && (await row()).level === 999, 'save-progress stores level 999');
    check((await lvl(1000, 0)).json.success && (await row()).level === 999, 'save-progress clamps level 1000 to 999');
    check((await lvl(999, 99899)).json.success && (await row()).experience === 99899, 'level 999 with xp 99899 (level*100-1) is stored');
    const cs = await srv.call('GET', `/api/character/stats/${L.cid}`, null, L.token);
    check(cs.status === 200, `GET /api/character/stats with a level-999 character answers 200 (${cs.status})`);
    // offline sync-stats and offline full load
    const L2 = await newPlayer(srv, db, { gold: 0, level: 1 });
    const charTok = (await srv.call('POST', '/api/session/claim', null, L2.token)).json.token;
    const ssync = await srv.call('POST', '/api/offline/sync-stats', { classIndex: 1, level: 999, experience: 500 }, charTok);
    check(ssync.status === 200 && ssync.json.level === 999, `offline sync-stats accepts level 999 (${ssync.status} ${JSON.stringify(ssync.json)})`);
    const ssync2 = await srv.call('POST', '/api/offline/sync-stats', { classIndex: 1, level: 1000, experience: 5 }, charTok);
    check(ssync2.status === 400, 'offline sync-stats refuses level 1000');
    const snap = await srv.call('GET', '/api/offline/snapshot', null, charTok);
    if (check(snap.json && snap.json.snapshot, 'online snapshot taken')) {
      const forged = JSON.parse(JSON.stringify(snap.json.snapshot));
      forged.character.level = 999; forged.character.experience = 1234; forged.character.gold = 1000;
      const load = await srv.call('POST', '/api/offline/load', { snapshot: forged, expectedFingerprint: snap.json.fingerprint }, charTok);
      check(load.status === 200, `offline full load with level 999 (${load.status} ${JSON.stringify(load.json).slice(0, 120)})`);
      check((await db.execute('SELECT level FROM characters WHERE id = ?', [L2.cid]))[0][0].level === 999, '...stored level 999');
      forged.character.level = 1000;
      const snap2 = await srv.call('GET', '/api/offline/snapshot', null, charTok);
      const bad = await srv.call('POST', '/api/offline/load', { snapshot: forged, expectedFingerprint: snap2.json.fingerprint }, charTok);
      check(bad.status >= 400, `offline full load with level 1000 is refused (${bad.status})`);
    }

    console.log('--- phase 2: reforge');
    const R = await newPlayer(srv, db, { gold: 100000 });
    const mkPiece = async (cid, accountId, slot, value = LO) => {
      const [i] = await db.execute("INSERT INTO loot_instances (account_id, item_id, ilvl, affixes) VALUES (?, 'helm_iron', 20, ?)", [accountId, JSON.stringify([{ id: 'p_str', v: value }])]);
      await put(db, cid, slot, 'helm_iron', 1, { instance: i.insertId });
      return i.insertId;
    };
    const inst = await mkPiece(R.cid, R.accountId, 0);
    const quote = await srv.call('POST', '/api/reforge/quote', { characterId: R.cid }, R.token);
    check(quote.json.success && quote.json.data.gold === 100000 && quote.json.data.pieces.length === 1 && quote.json.data.pieces[0].rerolls === 0, 'quote lists the rolled piece with 0 rerolls');
    const cost0 = sinks.reforgeCost(20, 'uncommon', 1, 0);
    const stale1 = await srv.call('POST', '/api/reforge', { characterId: R.cid, slot_index: 0, affix_index: 0, expect_cost: cost0 + 1 }, R.token);
    check(stale1.json.success === false && /price is now/.test(stale1.json.error) && (await gold(db, R.cid)) === 100000, 'a stale expect_cost is refused and nothing is charged');
    const ok1 = await srv.call('POST', '/api/reforge', { characterId: R.cid, slot_index: 0, affix_index: 0, expect_cost: cost0 }, R.token);
    check(ok1.json.success && ok1.json.data.cost === cost0 && (await gold(db, R.cid)) === 100000 - cost0 && ok1.json.data.rerolls === 1, `reforge charges exactly ${cost0} gold, counts rerolls=1`);
    const [[rf]] = await db.execute('SELECT rerolls FROM loot_reforges WHERE instance_id = ?', [inst]);
    check(Number(rf.rerolls) === 1, 'loot_reforges row written (rerolls=1)');
    const nowAff = JSON.parse(JSON.stringify((await db.execute('SELECT affixes FROM loot_instances WHERE id = ?', [inst]))[0][0].affixes));
    check(nowAff[0].v >= LO && nowAff[0].v <= HI && nowAff[0].id === 'p_str', `new value ${nowAff[0].v} within [${LO},${HI}], affix id unchanged`);
    await db.execute("UPDATE loot_instances SET affixes = ? WHERE id = ?", [JSON.stringify([{ id: 'p_str', v: LO }]), inst]);
    const cost1 = sinks.reforgeCost(20, 'uncommon', 1, 1);
    const stale2 = await srv.call('POST', '/api/reforge', { characterId: R.cid, slot_index: 0, affix_index: 0, expect_cost: cost0 }, R.token);
    check(stale2.json.success === false && /price is now/.test(stale2.json.error), `the old price (${cost0}) is stale after a reforge, new price ${cost1}`);
    // concurrency: gold for exactly one more reforge, two at once
    await db.execute('UPDATE characters SET gold = ? WHERE id = ?', [cost1, R.cid]);
    const both = await Promise.all([1, 2].map(() => srv.call('POST', '/api/reforge', { characterId: R.cid, slot_index: 0, affix_index: 0 }, R.token)));
    const wins = both.filter((b) => b.json.success).length;
    check(wins === 1 && (await gold(db, R.cid)) === 0, `two simultaneous reforges with gold for one: ${wins} succeeded, gold ${await gold(db, R.cid)} (never negative)`);
    const [[rf2]] = await db.execute('SELECT rerolls FROM loot_reforges WHERE instance_id = ?', [inst]);
    check(Number(rf2.rerolls) === 2, 'rerolls counted once for the winner (2 total)');
    await db.execute('UPDATE loot_instances SET affixes = ? WHERE id = ?', [JSON.stringify([{ id: 'p_str', v: LO }]), inst]);
    await db.execute('UPDATE characters SET gold = 5 WHERE id = ?', [R.cid]);
    const poor = await srv.call('POST', '/api/reforge', { characterId: R.cid, slot_index: 0, affix_index: 0 }, R.token);
    check(poor.json.success === false && /costs/.test(poor.json.error) && (await gold(db, R.cid)) === 5, 'not enough gold: refused, gold unchanged');
    const other = await newPlayer(srv, db, { gold: 100000 });
    const foreign = await srv.call('POST', '/api/reforge', { characterId: R.cid, slot_index: 0, affix_index: 0 }, other.token);
    check(foreign.status === 403, "someone else's character: 403");
    const plain = await srv.call('POST', '/api/reforge', { characterId: R.cid, slot_index: 3, affix_index: 0 }, R.token);
    check(plain.json.success === false, 'empty slot refused');
    await db.execute('DELETE FROM loot_instances WHERE id = ?', [inst]);
    check(Number((await db.execute('SELECT COUNT(*) AS n FROM loot_reforges WHERE instance_id = ?', [inst]))[0][0].n) === 0, 'deleting the loot instance cascades its loot_reforges row');
    check((await db.execute('SELECT instance_id FROM inventory WHERE character_id = ? AND slot_index = 0', [R.cid]))[0][0].instance_id === null, '...and the inventory row is detached (SET NULL), as before');

    console.log('--- phase 2: connection pool under a burst (pool limit 10; routes take a connection, then ask ownsCharacter on the pool)');
    await db.execute('UPDATE characters SET gold = 100000 WHERE id = ?', [R.cid]);
    const burst = await Promise.race([
      Promise.all(Array.from({ length: 40 }, () => srv.call('POST', '/api/boss-key/status', { characterId: R.cid }, R.token))),
      sleep(15000).then(() => 'HUNG'),
    ]);
    check(burst !== 'HUNG' && burst.every((b) => b.status === 200), burst === 'HUNG' ? '40 concurrent boss-key/status calls HUNG (pool starvation)' : '40 concurrent boss-key/status calls all answered');
    const alive = await Promise.race([srv.call('GET', '/health'), sleep(5000).then(() => 'HUNG')]);
    check(alive !== 'HUNG', 'the server still answers after the burst');
  } finally { srv.stop(); await sleep(500); }

  // ───────────────────────── PHASE 3: boss keys, kills, loadouts across AUTHORITY_KILLS modes ─────────────────────────
  for (const mode of ['off', 'audit', 'enforce']) {
    srv = await startServer(5380 + ['off', 'audit', 'enforce'].indexOf(mode), { AUTHORITY_KILLS: mode });
    try {
      console.log(`--- phase 3 [${mode}]: boss keys`);
      const tag = `[${mode}]`;
      const P = await newPlayer(srv, db, { gold: 200000 });
      await put(db, P.cid, 0, 'covenant_seal', 4);
      const bk = (route, body, token = P.token) => srv.call('POST', `/api/boss-key/${route}`, { characterId: P.cid, boss: 'gravedigger', ...body }, token);
      const cost = sinks.empowerGold('gravedigger');
      const sealed = await bk('summon', { boss: 'mire' });
      check(sealed.json.success === false && /sealed/.test(sealed.json.error) && (await sealCount(db, P.cid)) === 4, `${tag} a sealed ground refuses the summon, nothing charged`);
      check((await bk('summon', { boss: 'prelate' })).json.success === false, `${tag} a non-empowerable boss is refused`);
      const s1 = await bk('summon', {});
      check(s1.json.success && s1.json.data.cost === cost && !s1.json.data.reused && (await gold(db, P.cid)) === 200000 - cost && (await sealCount(db, P.cid)) === 3, `${tag} summon: ${cost} gold + 1 seal taken, empowered_summons row opened`);
      const s2 = await bk('summon', {});
      check(s2.json.success && s2.json.data.reused && s2.json.data.cost === 0 && s2.json.data.summon_id === s1.json.data.summon_id && (await sealCount(db, P.cid)) === 3, `${tag} second summon reuses the bound one free`);
      {
        const C = await newPlayer(srv, db, { gold: 200000 });
        await put(db, C.cid, 0, 'covenant_seal', 4);
        const par = await Promise.all([1, 2].map(() => srv.call('POST', '/api/boss-key/summon', { characterId: C.cid, boss: 'gravedigger' }, C.token)));
        check(par.every((p) => p.json.success) && par.filter((p) => p.json.data.reused).length === 1 && (await sealCount(db, C.cid)) === 3 && (await gold(db, C.cid)) === 200000 - cost, `${tag} two simultaneous summons of the same boss: exactly one pays (seals ${await sealCount(db, C.cid)}, gold ${await gold(db, C.cid)})`);
        check(Number((await db.execute("SELECT COUNT(*) AS n FROM empowered_summons WHERE character_id = ? AND status = 'open'", [C.cid]))[0][0].n) === 1, `${tag} ...and only one open empowered_summons row`);
      }
      const st = await bk('status', {});
      check(st.json.success && st.json.data.bound.includes('gravedigger'), `${tag} status lists the bound boss`);
      const early = await bk('claim', { discipline: 'ossuary', level: 10 });
      check(early.json.success === false && /barely woken/.test(early.json.error), `${tag} a claim inside the first 10 s is refused`);
      await db.execute("UPDATE empowered_summons SET created_at = created_at - INTERVAL 30 SECOND WHERE character_id = ?", [P.cid]);
      const noKill = await bk('claim', { discipline: 'ossuary', level: 10 });
      if (mode === 'enforce') {
        check(noKill.json.success === false && /not seen that boss die/.test(noKill.json.error), `${tag} claim without a reported kill is refused`);
        // report the kill, naming the summon
        const kr = await srv.call('POST', '/api/kills/report', { characterId: P.cid, seq: Date.now(), groups: [], bosses: [{ boss: 'gravedigger', tier: 0, diff: 'medium', first: true, summon: s1.json.data.summon_id, n: 1 }], floors: [] }, P.token);
        const [[ss]] = await db.execute('SELECT killed_at FROM empowered_summons WHERE id = ?', [s1.json.data.summon_id]);
        check(kr.json.success && kr.json.data.accepted && kr.json.data.accepted.bosses === 1 && ss.killed_at, `${tag} the kill report stamped killed_at on the summon (accepted ${JSON.stringify(kr.json.data && kr.json.data.accepted)})`);
        const withKill = await bk('claim', { discipline: 'ossuary', level: 10 });
        check(withKill.json.success && withKill.json.data.instance_id, `${tag} claim after the reported kill pays the prize`);
      } else {
        check(noKill.json.success && noKill.json.data.instance_id, `${tag} claim pays (kills ${mode})`);
        if (mode === 'audit') check((await audits(db, P.cid, 'boss_key_no_kill')).length === 1, `${tag} audit mode wrote one boss_key_no_kill row`);
      }
      if (noKill.json.success || mode === 'enforce') {
        const [[inst]] = await db.execute("SELECT COUNT(*) AS n FROM loot_instances WHERE account_id = ? AND id IN (SELECT instance_id FROM inventory WHERE character_id = ?) OR account_id = ?", [P.accountId, P.cid, P.accountId]);
        check(Number(inst.n) >= 1, `${tag} the prize is a loot_instances row owned by the account`);
        const claimed = (await db.execute("SELECT status FROM empowered_summons WHERE character_id = ? AND boss = 'gravedigger'", [P.cid]))[0];
        check(claimed.some((c) => c.status === 'claimed'), `${tag} the summon is marked claimed`);
        check((await bk('claim', { discipline: 'ossuary', level: 10 })).json.success === false, `${tag} the prize cannot be claimed twice`);
      }
      // refund path + full bag
      const before = { gold: await gold(db, P.cid), seals: await sealCount(db, P.cid) };
      const s3 = await bk('summon', {});
      check(s3.json.success && !s3.json.data.reused, `${tag} new summon after the claim`);
      const rf = await bk('refund', {});
      check(rf.json.success && (await gold(db, P.cid)) === before.gold && (await sealCount(db, P.cid)) === before.seals, `${tag} refund within two minutes gives gold and seal back`);
      check((await bk('refund', {})).json.success === false, `${tag} nothing left to refund`);
      const s4 = await bk('summon', {});
      await db.execute("UPDATE empowered_summons SET created_at = created_at - INTERVAL 3 MINUTE WHERE id = ?", [s4.json.data.summon_id]);
      check((await bk('refund', {})).json.success === false, `${tag} refund after two minutes is refused`);
      // refund with a full bag: consume bag, then new summon, fill bag, refund must be refused and keep the summon open
      await db.execute("UPDATE empowered_summons SET status = 'refunded' WHERE character_id = ?", [P.cid]);
      await db.execute('DELETE FROM inventory WHERE character_id = ?', [P.cid]);
      await put(db, P.cid, 0, 'covenant_seal', 1);
      for (let i = 1; i < 48; i++) await put(db, P.cid, i, 'ore_copper', 1, {}).catch(() => put(db, P.cid, i, 'helm_copper', 1));
      await db.execute("UPDATE inventory SET item_id = 'helm_copper', quantity = 1 WHERE character_id = ? AND slot_index > 0", [P.cid]);
      const s5 = await bk('summon', {});
      check(s5.json.success && (await sealCount(db, P.cid)) === 0, `${tag} summon with a full bag (the seal's slot frees)`);
      await put(db, P.cid, 0, 'helm_copper', 1);
      const rfFull = await bk('refund', {});
      check(rfFull.json.success === false && /room/.test(rfFull.json.error) && (await db.execute('SELECT status FROM empowered_summons WHERE id = ?', [s5.json.data.summon_id]))[0][0].status === 'open', `${tag} refund into a full bag: refused, summon stays open, gold not returned`);
      // staff skips the enforce kill requirement
      if (mode === 'enforce') {
        const S = await newPlayer(srv, db, { gold: 200000, role: 'gm' });
        await put(db, S.cid, 0, 'covenant_seal', 1);
        const ss = await srv.call('POST', '/api/boss-key/summon', { characterId: S.cid, boss: 'gravedigger' }, S.token);
        await db.execute('UPDATE empowered_summons SET created_at = created_at - INTERVAL 30 SECOND WHERE character_id = ?', [S.cid]);
        const sc = await srv.call('POST', '/api/boss-key/claim', { characterId: S.cid, boss: 'gravedigger', discipline: 'ossuary', level: 5 }, S.token);
        check(ss.json.success && sc.json.success, `${tag} staff may claim without a reported kill`);
      }

      console.log(`--- phase 3 [${mode}]: kill reports`);
      const K = await newPlayer(srv, db, { gold: 0 });
      const now = Date.now();
      const def = killRules.rosterIds('graves').values().next().value;
      const group = { area: 'graves', def, level: 3, elite: false, tier: 0, diff: 'medium', rank: 0, xpMult: 1, goldMult: 1, shardMult: 1, n: 5 };
      const rep = (s, g = [group], extra = {}) => srv.call('POST', '/api/kills/report', { characterId: K.cid, seq: s, groups: g, bosses: [], floors: [], ...extra }, K.token);
      const r1 = await rep(now);
      const led = async () => (await db.execute('SELECT * FROM character_kill_ledger WHERE character_id = ?', [K.cid]))[0][0];
      if (mode === 'off') {
        check(r1.json.data.mode === 'off' && !(await led()), `${tag} off: acknowledged, no ledger row`);
      } else {
        check(r1.json.success && !r1.json.data.unavailable && r1.json.data.accepted.kills > 0, `${tag} first report accepted (${JSON.stringify(r1.json.data)}), def=${def}`);
        const L = await led();
        check(L && Number(L.reports) === 1 && Number(L.kills_total) === r1.json.data.accepted.kills && Number(L.xp_credit) > 0 && Number(L.seq) === now, `${tag} ledger row: reports=1 kills_total=${L && L.kills_total} xp_credit=${L && L.xp_credit} seq=${L && L.seq}`);
        check(L.kill_credit && (typeof L.kill_credit === 'object') && Number(L.kill_credit.graves) === r1.json.data.accepted.kills, `${tag} kill_credit JSON {graves:n} stored`);
        const dup = await rep(now);
        check(dup.json.data.duplicate === true && Number((await led()).reports) === 1, `${tag} a replayed seq is a duplicate, ledger unchanged`);
        const old = await rep(now - 5000);
        check(old.json.data.duplicate === true && (await audits(db, K.cid, 'kill_replay')).length === 1, `${tag} an older seq is ignored and audited as kill_replay`);
        const fut = await rep(now + 3600 * 1000);
        check(fut.status === 400, `${tag} a report dated an hour in the future is 400`);
        const flood = await rep(now + 1000, [{ ...group, n: 999999 }]);
        const Lf = await led();
        check(flood.json.success && flood.json.data.accepted.kills < 5000 && Number(Lf.rejected_kills) > 0, `${tag} a flood is cut by the bucket (accepted ${flood.json.data.accepted.kills}, rejected ${Lf.rejected_kills})`);
        const junk = await srv.call('POST', '/api/kills/report', { characterId: K.cid, reports: [{ seq: 'nope' }] }, K.token);
        check(junk.status === 400, `${tag} an unreadable report is 400`);
        // save-progress with killReports riding along
        const sv = await srv.call('POST', '/api/character/save-progress', { characterId: K.cid, level: 1, xp: 20, gold: 0, killReports: [{ seq: now + 2000, groups: [group], bosses: [], floors: [] }] }, K.token);
        check(sv.json.success, `${tag} save-progress with killReports saves`);
        const xpNow = Number((await db.execute('SELECT experience FROM characters WHERE id = ?', [K.cid]))[0][0].experience);
        check(xpNow === 20, `${tag} ...honest xp 20 stored (${xpNow})`);
        const Ls = await led();
        check(Number(Ls.xp_used) > 0 && Number(Ls.reports) >= 3, `${tag} ...ledger consumed credit (xp_used=${Ls.xp_used}, reports=${Ls.reports})`);
        // chronicle guard
        await srv.call('POST', '/api/chronicle/add', { characterId: K.cid, deltas: { playSeconds: 999999 }, maxes: { 'peak.depth': 500 } }, K.token);
        const chron = (await db.execute('SELECT life FROM character_chronicle WHERE character_id = ?', [K.cid]))[0][0];
        const life = typeof chron.life === 'string' ? JSON.parse(chron.life) : chron.life;
        if (mode === 'enforce') check(life.playSeconds < 999999 && (life['peak.depth'] || 0) < 500, `${tag} chronicle/add is clamped (playSeconds ${life.playSeconds}, peak.depth ${life['peak.depth']})`);
        else check(life.playSeconds === 999999, `${tag} chronicle/add untouched in audit (${life.playSeconds}) and audited: ${(await audits(db, K.cid, 'play_rate')).length} play_rate row(s)`);
        // necro save guard
        const ns = await srv.call('POST', '/api/necro-progress/save', { characterId: K.cid, areaKills: { graves: 1000000 }, shards: 5000000 }, K.token);
        check(ns.status < 500, `${tag} necro-progress/save passes through the guard without a 500 (${ns.status})`);
      }
      // deleting the character cascades everything new
      const dummy = await newPlayer(srv, db, { gold: 100 });
      await put(db, dummy.cid, 0, 'covenant_seal', 1);
      await srv.call('POST', '/api/boss-key/summon', { characterId: dummy.cid, boss: 'gravedigger' }, dummy.token);
      await db.execute('INSERT INTO character_kill_ledger (character_id) VALUES (?) ON DUPLICATE KEY UPDATE seq = seq', [dummy.cid]);
      await srv.call('POST', '/api/loadouts/save', { characterId: dummy.cid, slot: 0, preset: { name: 'x', rites: { primary: 'a', keys: ['b', 'c', 'd', 'e', 'f'] } } }, dummy.token);
      const cnt = async () => Number((await db.query("SELECT (SELECT COUNT(*) FROM empowered_summons WHERE character_id = ?) + (SELECT COUNT(*) FROM character_kill_ledger WHERE character_id = ?) + (SELECT COUNT(*) FROM character_loadouts WHERE character_id = ?) AS n", [dummy.cid, dummy.cid, dummy.cid]))[0][0].n);
      const had = await cnt();
      await db.execute('DELETE FROM characters WHERE id = ?', [dummy.cid]);
      check(had >= 2 && (await cnt()) === 0, `${tag} deleting a character cascades its empowered_summons / ledger / loadout rows (${had} -> 0)`);
    } finally { srv.stop(); await sleep(500); }
  }

  // ───────────────────────── PHASE 4: loadouts ─────────────────────────
  srv = await startServer(5390, { AUTHORITY_KILLS: 'off' });
  try {
    console.log('--- phase 4: loadouts');
    const P = await newPlayer(srv, db, { gold: 0 });
    const lo = (route, body, method = 'POST') => srv.call(method, `/api/loadouts/${route}`, method === 'GET' ? null : { characterId: P.cid, ...body }, P.token);
    const preset = (over = {}) => ({ name: 'Bone Build', rites: { primary: 'bone_needle', keys: ['marrow_spear', 'exhume', 'miasma', 'black_litany', 'bone_needle2'] }, runes: { bone_needle: 'rune_splinter', marrow_spear: 'rune_impale' }, weapon: { itemId: 'dagger_shadow', instanceId: null }, offhand: { itemId: 'grimoire_bone', instanceId: null }, ...over });
    check((await lo('save', { slot: 6, preset: preset() })).status === 400, 'slot 6 rejected (0..5 only)');
    check((await lo('save', { slot: 0, preset: preset({ name: '  ' }) })).json.success === false, 'a blank name is refused (200 + error)');
    check((await lo('save', { slot: 0, preset: preset({ runes: { exhume: 'rune_splinter' } }) })).json.success === false, 'a rune that does not fit its rite is refused');
    const sv = await lo('save', { slot: 0, preset: preset() });
    check(sv.json.success && sv.json.data.length === 1, `save slot 0: ok (${JSON.stringify(sv.json).slice(0, 200)})`);
    const rawRow = (await db.execute('SELECT name, data FROM character_loadouts WHERE character_id = ?', [P.cid]))[0][0];
    check(rawRow.name === 'Bone Build' && rawRow.data.runes.bone_needle === 'rune_splinter', 'JSON column round-trips (runes kept)');
    const sv2 = await lo('save', { slot: 0, preset: preset({ name: 'Renamed' }) });
    check(sv2.json.data.length === 1 && sv2.json.data[0].preset.name === 'Renamed', 'saving the same slot again updates it (ON DUPLICATE KEY)');
    check((await lo('apply', { slot: 3 })).json.success === false, 'applying an empty slot answers "empty"');
    // apply with nothing in the bag: weapon/offhand/rune missing -> skipped, nothing breaks
    const miss = await lo('apply', { slot: 0 });
    check(miss.json.success && miss.json.report.applied.length === 0 && miss.json.report.skipped.length >= 3 && miss.json.report.skipped.every((s) => s.reason === 'missing'), `apply with the items missing: all skipped as "missing" (${miss.json.report && miss.json.report.skipped.length})`);
    // normal apply
    await put(db, P.cid, 0, 'dagger_shadow');
    await put(db, P.cid, 1, 'grimoire_bone');
    await put(db, P.cid, 2, 'rune_splinter', 2);
    await put(db, P.cid, 3, 'rune_impale', 1);
    await put(db, P.cid, 105, 'scythe_iron', 1, { equipped: 1, equipped_slot: 'main_hand' });
    const ap = await lo('apply', { slot: 0 });
    check(ap.json.success && ap.json.report.applied.length === 4 && ap.json.report.skipped.length === 0, `apply: weapon, offhand and two runes applied (${JSON.stringify(ap.json.report)})`);
    const inv = (await db.execute('SELECT slot_index, item_id, quantity, equipped, equipped_slot FROM inventory WHERE character_id = ? ORDER BY slot_index', [P.cid]))[0];
    const at = (s) => inv.find((r) => Number(r.slot_index) === s);
    check(at(105) && at(105).item_id === 'dagger_shadow' && at(105).equipped_slot === 'main_hand', 'dagger_shadow now worn in slot 105');
    check(at(106) && at(106).item_id === 'grimoire_bone' && Number(at(106).equipped) === 1, 'grimoire_bone worn in slot 106');
    check(at(130) && at(130).item_id === 'rune_splinter' && at(130).equipped_slot === 'rune_bone_needle' && at(131) && at(131).item_id === 'rune_impale', 'runes sit in sockets 130 and 131 with equipped_slot rune_<rite>');
    check(inv.some((r) => r.item_id === 'scythe_iron' && Number(r.slot_index) < 48 && !Number(r.equipped)), 'the displaced scythe_iron went back to the bag');
    check(at(2) && at(2).item_id === 'rune_splinter' && Number(at(2).quantity) === 1, 'the rune stack lost exactly one');
    const ap2 = await lo('apply', { slot: 0 });
    check(ap2.json.success && ap2.json.report.unchanged === true, 'applying again changes nothing (idempotent)');
    // swap a socketed rune with the bag one when the bag is full
    await lo('save', { slot: 1, preset: preset({ name: 'Volley', runes: { bone_needle: 'rune_volley' }, weapon: null, offhand: null }) });
    await put(db, P.cid, 4, 'rune_volley', 1);
    for (let i = 5; i < 48; i++) {
      const [e] = await db.execute('SELECT 1 FROM inventory WHERE character_id = ? AND slot_index = ?', [P.cid, i]);
      if (!e.length) await put(db, P.cid, i, 'helm_copper', 1);
    }
    for (let i = 0; i < 48; i++) { const [e] = await db.execute('SELECT 1 FROM inventory WHERE character_id = ? AND slot_index = ?', [P.cid, i]); if (!e.length) await put(db, P.cid, i, 'helm_copper', 1); }
    const full = await lo('apply', { slot: 1 });
    check(full.json.success, 'apply with a full bag does not error');
    const sock = (await db.execute('SELECT item_id FROM inventory WHERE character_id = ? AND slot_index = 130', [P.cid]))[0][0];
    console.log(`     full-bag swap: socket 130 holds ${sock && sock.item_id}; report ${JSON.stringify(full.json.report)}`);
    check(sock && ['rune_splinter', 'rune_volley'].includes(sock.item_id) && (await db.execute("SELECT COUNT(*) AS n FROM inventory WHERE character_id = ? AND item_id IN ('rune_splinter','rune_volley')", [P.cid]))[0][0].n >= 2, 'no rune is lost or duplicated by a full-bag apply');
    // unique keys + no leftover temp slots
    check(Number((await db.execute('SELECT COUNT(*) AS n FROM inventory WHERE character_id = ? AND slot_index < 0', [P.cid]))[0][0].n) === 0, 'no leftover temporary (negative) slots after apply');
    const del = await lo('delete', { slot: 1 });
    check(del.json.success && del.json.data.length === 1, 'delete slot 1 leaves one preset');
    const lst = await lo(`${P.cid}`, null, 'GET');
    check(lst.json.success && lst.json.data.length === 1, 'GET list answers');
    const other = await newPlayer(srv, db, {});
    check((await srv.call('GET', `/api/loadouts/${P.cid}`, null, other.token)).status === 403, "another account's loadouts: 403");
  } finally { srv.stop(); await sleep(300); }

  await db.end();
  console.log(failures ? `\n${failures} CHECK(S) FAILED` : '\nall checks passed');
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error('PROBE ERROR', e); process.exit(2); });
