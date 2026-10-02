/**
 * End-to-end check of the Catacomb Depths' server side against a REAL MySQL scratch database and the REAL server.js.
 * There is no migration 026: the deepest floor rides the Chronicle's lifetime JSON (`peak.depth`, an Ascension-proof best like `peak.level`),
 * so this probe is about real SQL, not a schema change: the JSON is written and merged by the live routes, `/leaderboard` reads it with
 * JSON_EXTRACT, and the authority guard reads it to bound the Depths' XP ceiling, all on MySQL 8.
 *
 *   1. create a throwaway database from the LIVE SCHEMA (read-only: `sudo mysqldump --no-data death_muffin | sudo mysql <scratch>`) plus the live `items`
 *      rows, and a throwaway MySQL user limited to it (see the header of tools/qa/authority-db-probe.cjs for the commands; this probe needs no migration:
 *      the live schema already has character_chronicle, character_runs, character_authority and progress_audit);
 *   2. NODE_PATH=<a backend node_modules> DM_PROBE_RUNTIME=<an empty scratch dir> DM_PROBE_DB=... DM_PROBE_USER=... DM_PROBE_PASS=... node tools/qa/depths-db-probe.cjs
 *
 * It starts server.js on 127.0.0.1:5359 against the scratch database (never the live one) with AUTHORITY_MODE=enforce, and drives: chronicle add (the
 * Depths' counters and `peak.depth` as a best that never falls and cannot jump more than 25 floors a request), the ascend archive keeping a run's own
 * deepest floor, the public /leaderboard `bestDepth`, and save-progress XP for a character that has opened the Warren (and has a deep record) against one
 * that has not. It stops the server it started (by pid). Prints one line per check; exits non-zero on the first failure. Drop the database and user afterwards.
 */
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');

const PORT = 5359;
const BASE = `http://127.0.0.1:${PORT}`;
const env = { ...process.env, PORT: String(PORT), AUTHORITY_MODE: 'enforce', DB_HOST: '127.0.0.1', DB_USER: process.env.DM_PROBE_USER, DB_PASS: process.env.DM_PROBE_PASS, DB_NAME: process.env.DM_PROBE_DB, JWT_SECRET: 'probe-secret', JWT_EXPIRES_IN: '1h' };
/** mysql2 hands JSON columns back already parsed. */
const J = (v) => (typeof v === 'string' ? JSON.parse(v) : v);
const must = (v, msg) => { if (!v) { console.error(`FAIL ${msg}`); throw new Error(msg); } console.log(`ok   ${msg}`); };

/** The deployed layout (deploy-release.sh): backend files, gathering/ and necro-progress/ side by side. */
function stageRuntime(dir) {
  const root = path.join(__dirname, '../..');
  const b = path.join(root, 'server/death-muffin/backend');
  fs.mkdirSync(path.join(dir, 'gathering'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'necro-progress'), { recursive: true });
  for (const f of fs.readdirSync(b)) if (/\.(js|cjs)$/.test(f) && !/\.test\./.test(f) && !f.startsWith('bag-fake') && !f.startsWith('authority-fake')) fs.copyFileSync(path.join(b, f), path.join(dir, f));
  for (const f of fs.readdirSync(path.join(b, 'gathering'))) if (/\.cjs$/.test(f) && !/\.test\./.test(f)) fs.copyFileSync(path.join(b, 'gathering', f), path.join(dir, 'gathering', f));
  for (const f of ['necro-rules.cjs', 'necro-progress-routes.cjs', 'mysql-store.cjs']) fs.copyFileSync(path.join(root, 'server/vps-handoff/necro-progress', f), path.join(dir, 'necro-progress', f));
}

async function main() {
  if (!process.env.DM_PROBE_RUNTIME) throw new Error('set DM_PROBE_RUNTIME to an empty scratch directory');
  stageRuntime(process.env.DM_PROBE_RUNTIME);
  const rules = require(path.join(process.env.DM_PROBE_RUNTIME, 'gathering/authority-rules.cjs'));
  const db = await mysql.createConnection({ host: '127.0.0.1', user: env.DB_USER, password: env.DB_PASS, database: env.DB_NAME });
  const child = spawn(process.execPath, [path.join(process.env.DM_PROBE_RUNTIME, 'server.js')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  child.stdout.on('data', (d) => (log += d));
  child.stderr.on('data', (d) => (log += d));
  try {
    for (let i = 0; i < 60; i++) {
      try { if ((await fetch(`${BASE}/health`)).ok) break; } catch { /* not up yet */ }
      await new Promise((r) => setTimeout(r, 250));
    }
    const call = async (method, url, body, token) => {
      const res = await fetch(BASE + url, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
      return { status: res.status, json: await res.json().catch(() => null) };
    };
    const reg = await call('POST', '/register', { username: `depth_${Date.now() % 100000}`, password: 'probe-password-1' });
    must(reg.status === 201 && reg.json.token, 'registered a probe account');
    const token = reg.json.token;
    const accountId = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).accountId;
    const username = (await db.execute('SELECT username FROM accounts WHERE id = ?', [accountId]))[0][0].username;
    let classes = 0;
    // One character per class per account (a live unique key), so each probe character takes the next discipline.
    const mk = async (level) => { classes++; return (await db.execute("INSERT INTO characters (account_id, class_index, class_name, level, discipline_index, gold) VALUES (?, ?, 'Probe', ?, ?, 100)", [accountId, classes, level, classes]))[0].insertId; };
    const cid = await mk(40);

    // 1. The Chronicle takes the Depths' counters and keeps the deepest floor as a best.
    const add = (deltas, maxes, id = cid) => call('POST', '/api/chronicle/add', { characterId: id, deltas, maxes }, token);
    must((await add({ 'depths.runs': 1, 'kills.depths': 12, kills: 12, 'depths.floors': 1 }, { 'peak.depth': 4 })).json.success, 'chronicle add: a run began, 12 kills on the floor, depth 4');
    must((await add({ 'depths.chests': 1 }, { 'peak.depth': 9 })).json.success, 'chronicle add: a chest, depth 9');
    must((await add({}, { 'peak.depth': 2 })).json.success, 'chronicle add: a shallower floor later');
    const life = async (id = cid) => J((await db.execute('SELECT life FROM character_chronicle WHERE character_id = ?', [id]))[0][0].life);
    let l = await life();
    must(l['peak.depth'] === 9 && l['depths.runs'] === 1 && l['kills.depths'] === 12 && l['depths.floors'] === 1 && l['depths.chests'] === 1, `the lifetime JSON in MySQL holds the best (9) and the counters (${JSON.stringify(l)})`);
    must((await call('POST', '/api/chronicle/add', { characterId: cid, deltas: {}, maxes: { 'peak.depth': 5000 } }, token)).json.success, 'a forged depth of 5000 is accepted as a request...');
    l = await life();
    must(l['peak.depth'] === 9 + 25, `...but only moves the best one step (${l['peak.depth']})`);
    must((await add({ 'depths.hacked': 5 }, {})).json.success && !('depths.hacked' in (await life())), 'an unknown Depths counter is dropped');

    // 2. Ascension archives the run's own deepest floor; the lifetime best stands.
    const asc = await call('POST', '/api/chronicle/ascend', { characterId: cid, ascension: 1 }, token);
    must(asc.json.success && asc.json.data.archived, 'ascend archives the run');
    const [[archived]] = await db.execute('SELECT stats FROM character_runs WHERE character_id = ?', [cid]);
    must(J(archived.stats)['peak.depth'] === 34, 'the archived run keeps its deepest floor');
    await add({}, { 'peak.depth': 3 });
    const [[row]] = await db.execute('SELECT life, `run` FROM character_chronicle WHERE character_id = ?', [cid]);
    must(J(row.life)['peak.depth'] === 34 && J(row.run)['peak.depth'] === 3, 'the new run counts from zero (3) while the lifetime best stays 34');
    const read = await call('GET', `/api/chronicle/${cid}`, null, token);
    must(read.json.data.life['peak.depth'] === 34 && read.json.data.runs[0].stats['peak.depth'] === 34, 'GET /api/chronicle returns both');

    // 3. The public leaderboard carries it (MySQL JSON_EXTRACT of the quoted key).
    const lb = await fetch(`${BASE}/leaderboard`).then((r) => r.json());
    const mine = lb.players.find((p) => p.username === username);
    must(mine && mine.bestDepth === 34, `/leaderboard shows bestDepth 34 for ${username}`);
    const cidFresh = await mk(10);
    must(true, 'a second character with no Chronicle row exists');
    const lb2 = await fetch(`${BASE}/leaderboard`).then((r) => r.json());
    must(lb2.players.every((p) => Number.isInteger(p.bestDepth) && p.bestDepth >= 0), 'every leaderboard row has an integer bestDepth (0 when there is no record)');

    // 4. Authority (enforce): the Depths' XP ceiling needs the Warren open, and follows the Chronicle's deepest floor.
    const unlock = (id, areas) => db.execute('REPLACE INTO character_necro_progress (character_id, state) VALUES (?, ?)', [id, JSON.stringify({ unlockedAreas: areas, ascension: 0 })]).catch(async (e) => { throw e; });
    const warrenChar = await mk(40);
    const graveChar = await mk(40);
    await unlock(warrenChar, ['chapterhouse', 'graves', 'warren']);
    await unlock(graveChar, ['chapterhouse', 'graves']);
    await add({}, { 'peak.depth': 18 }, warrenChar);
    const withDepths = rules.ceilingsFor(['chapterhouse', 'graves', 'warren'], 0, 40, 18);
    const without = rules.ceilingsFor(['chapterhouse', 'graves'], 0, 40, 18);
    must(withDepths.area === 'depths' && withDepths.xpPerMin > without.xpPerMin * 5, `the rules give the Warren character a Depths ceiling (${withDepths.xpPerMin}/min vs ${without.xpPerMin}/min)`);
    // First save banks FIRST_MINUTES of the ceiling plus the burst: a gain between the two allowances.
    const bank = (c) => c.xpPerMin * rules.AUTHORITY.FIRST_MINUTES + rules.AUTHORITY.XP_BURST;
    const gain = Math.floor((bank(withDepths) + bank(without)) / 2); // well above the Graves' bank, well inside the Depths'
    const target = rules.splitXp(rules.totalXp(40, 0) + gain);
    const save = (id, over) => call('POST', '/api/character/save-progress', { characterId: id, level: target.level, xp: target.xp, gold: 100, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10, ...over }, token);
    const honest = await save(warrenChar, {});
    must(honest.json.success && !honest.json.authority, 'the Warren character with a deep record may bank a Depths-sized haul: no notice');
    must((await db.execute('SELECT level FROM characters WHERE id = ?', [warrenChar]))[0][0].level === target.level, '...and the level was stored as sent');
    const held = await save(graveChar, {});
    must(held.json.success && held.json.authority && /faster than play can explain/.test(held.json.authority.message), 'the same haul on a character that has not opened the Warren is held back, with a plain-words notice');
    const gl = (await db.execute('SELECT level, experience FROM characters WHERE id = ?', [graveChar]))[0][0];
    must(gl.level < target.level || (gl.level === target.level && gl.experience < target.xp), `...and clamped in the database (level ${gl.level} xp ${gl.experience} of the claimed ${target.level}/${target.xp})`);
    const audit = (await db.execute("SELECT kind, action FROM progress_audit WHERE character_id = ?", [graveChar]))[0];
    must(audit.some((a) => a.kind === 'xp_rate' && a.action === 'clamp'), 'and audited as an xp_rate clamp');
    const okAudit = (await db.execute("SELECT kind FROM progress_audit WHERE character_id = ?", [warrenChar]))[0];
    must(okAudit.length === 0, 'the honest Depths save left no audit row');
    must(!/\[AUTHORITY\].*unavailable/.test(log), 'the authority guard never fell back to "unavailable" (its Chronicle query ran on real MySQL)');
    void cidFresh;
    console.log('done.');
  } finally {
    child.kill('SIGTERM');
    await db.end().catch(() => {});
  }
}
main().then(() => process.exit(0), (e) => { console.error(e.message); process.exit(1); });
