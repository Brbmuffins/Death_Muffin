/**
 * End-to-end check of the server-authority guards (migration 021, docs/SERVER-AUTHORITY.md) against a REAL MySQL scratch database and
 * the REAL server.js, once with AUTHORITY_MODE=report and once with AUTHORITY_MODE=enforce.
 *
 *   1. create a throwaway database from the LIVE SCHEMA (mysqldump --no-data of death_muffin, read-only) plus the live `items` rows,
 *      apply server/death-muffin/backend/migrations/021-server-authority.sql twice (idempotent);
 *   2. create a throwaway MySQL user limited to that database;
 *   3. NODE_PATH=<a backend node_modules> DM_PROBE_RUNTIME=<an empty scratch dir> DM_PROBE_DB=... DM_PROBE_USER=... DM_PROBE_PASS=... \
 *        node tools/qa/authority-db-probe.cjs
 *
 * For each mode it starts server.js on 127.0.0.1:5341/5342 against the scratch database (never the live one), registers a probe
 * account, and drives save-progress, inventory/save, add-item, roll-gear and the offline load over HTTP, checking the character,
 * bag and progress_audit rows after each step. Report mode must leave every save exactly as sent. It stops the servers it started
 * (by pid). Prints one line per check; exits non-zero on the first failure. Drop the database and user afterwards.
 */
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');

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

async function runMode(mode, port, db) {
  const base = `http://127.0.0.1:${port}`;
  const env = { ...process.env, PORT: String(port), AUTHORITY_MODE: mode, DB_HOST: '127.0.0.1', DB_USER: process.env.DM_PROBE_USER, DB_PASS: process.env.DM_PROBE_PASS, DB_NAME: process.env.DM_PROBE_DB, JWT_SECRET: 'probe-secret', JWT_EXPIRES_IN: '1h' };
  const child = spawn(process.execPath, [path.join(process.env.DM_PROBE_RUNTIME, 'server.js')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  child.stdout.on('data', (d) => (log += d));
  child.stderr.on('data', (d) => (log += d));
  const enforce = mode === 'enforce';
  const tag = `[${mode}]`;
  try {
    for (let i = 0; i < 60; i++) {
      try { if ((await fetch(`${base}/health`)).ok) break; } catch { /* not up yet */ }
      await new Promise((r) => setTimeout(r, 250));
    }
    const call = async (method, url, body, token) => {
      const res = await fetch(base + url, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
      return { status: res.status, json: await res.json().catch(() => null) };
    };
    const reg = await call('POST', '/register', { username: `probe_${mode}_${Date.now() % 100000}`, password: 'probe-password-1' });
    must(reg.status === 201 && reg.json.token, `${tag} registered a probe account`);
    const token = reg.json.token;
    const accountId = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).accountId;
    const [ins] = await db.execute("INSERT INTO characters (account_id, class_index, class_name, level, discipline_index, gold) VALUES (?, 1, 'Ossuary', 1, 1, 100)", [accountId]);
    const cid = ins.insertId;
    const row = async () => (await db.execute('SELECT level, experience, gold, stat_int FROM characters WHERE id = ?', [cid]))[0][0];
    const audit = async () => (await db.execute('SELECT kind, mode, action, detail FROM progress_audit WHERE character_id = ? ORDER BY id', [cid]))[0];
    const progress = (over) => call('POST', '/api/character/save-progress', { characterId: cid, level: 1, xp: 0, gold: 100, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10, ...over }, token);

    // 1. an honest save passes in both modes and leaves no audit row
    const ok = await progress({ xp: 60, gold: 160 });
    must(ok.json.success && !ok.json.authority, `${tag} an honest save is accepted with no notice`);
    must((await row()).experience === 60 && Number((await row()).gold) === 160, `${tag} ...and stored exactly`);
    must((await audit()).length === 0, `${tag} ...and not audited`);

    // 2. an impossible jump
    const jump = await progress({ level: 200, xp: 0, gold: 2000000000 });
    must(jump.json.success, `${tag} the jump request itself succeeds`);
    const r2 = await row();
    if (enforce) {
      must(r2.level < 60 && Number(r2.gold) < 200000, `${tag} enforce: level ${r2.level} and gold ${r2.gold} are clamped to the allowance`);
      must(/faster than play can explain/.test(jump.json.authority.message), `${tag} enforce: the reply explains it in plain words`);
    } else {
      must(r2.level === 200 && Number(r2.gold) === 2000000000, `${tag} report: the save is stored exactly as sent`);
      must(!jump.json.authority, `${tag} report: the reply is unchanged`);
    }
    const a2 = await audit();
    must(a2.some((a) => a.kind === 'xp_rate' && a.mode === mode) && a2.some((a) => a.kind === 'gold_rate'), `${tag} progress_audit has xp_rate and gold_rate rows (${a2.map((a) => a.action).join(',')})`);
    must(a2.every((a) => a.action === (enforce ? 'clamp' : 'report')), `${tag} ...marked ${enforce ? 'clamp' : 'report'}`);

    // 3. a stale save and a stat raise
    const before = await row();
    await progress({ level: 2, xp: 5, gold: Number(before.gold), stat_int: 99 });
    const r3 = await row();
    if (enforce) must(r3.level === before.level && r3.stat_int === 5, `${tag} enforce: a stale save keeps level ${before.level}; stat_int stays 5`);
    else must(r3.level === 2 && r3.stat_int === 99, `${tag} report: the stale save and stat raise are stored as sent`);
    must((await audit()).some((a) => a.kind === 'xp_stale') && (await audit()).some((a) => a.kind === 'stat_raise'), `${tag} xp_stale and stat_raise are audited`);

    // 4. a bag save minting boss ichor
    const save = (slots) => call('POST', '/api/inventory/save', { characterId: cid, slots, bagSize: 48 }, token);
    const honest = await save([{ slot_index: 0, item_id: 'ore_copper', quantity: 30 }]);
    must(honest.json.success && !honest.json.authority, `${tag} picking up 30 copper ore is accepted quietly`);
    const mint = await save([{ slot_index: 0, item_id: 'ore_copper', quantity: 30 }, { slot_index: 1, item_id: 'ichor_prelate', quantity: 50 }]);
    must(mint.json.success, `${tag} the ichor save succeeds`);
    const ichor = mint.json.data.filter((x) => x.item_id === 'ichor_prelate').reduce((n, x) => n + x.quantity, 0);
    if (enforce) {
      must(ichor > 0 && ichor < 50 && /More ichor_prelate/.test(mint.json.authority.message), `${tag} enforce: ${ichor} of 50 ichors kept, with a notice`);
    } else must(ichor === 50 && !mint.json.authority, `${tag} report: all 50 stored, reply unchanged`);
    must((await audit()).some((a) => a.kind === 'item_intro' && a.detail.item === 'ichor_prelate'), `${tag} the ichor save is audited`);
    // selling credits gold: sell everything, then the gold may rise by the sale value
    const sold = await save([]);
    must(sold.json.success, `${tag} selling the bag is accepted`);
    const [[auth]] = await db.execute('SELECT gold_credit FROM character_authority WHERE character_id = ?', [cid]);
    must(Number(auth.gold_credit) > 0, `${tag} the sale credited gold (${auth.gold_credit})`);

    // 5. add-item
    const addPlank = await call('POST', '/api/inventory/add-item', { characterId: cid, itemId: 'plank_oak', quantity: 5 }, token);
    must(enforce ? addPlank.status === 400 : addPlank.json.success, `${tag} add-item of a crafted-only item is ${enforce ? 'refused' : 'allowed (report)'}`);
    const addOre = await call('POST', '/api/inventory/add-item', { characterId: cid, itemId: 'ore_copper', quantity: 5 }, token);
    must(addOre.json.success, `${tag} add-item of an ordinary drop is allowed`);

    // 6. roll-gear
    const roll = await call('POST', '/api/loot/roll-gear', { characterId: cid, drops: [{ item_id: 'plank_oak', level: 5, source: 'kill' }] }, token);
    must(enforce ? roll.json.success === false : roll.json.success === true, `${tag} roll-gear of an item no table drops is ${enforce ? 'refused' : 'allowed (report)'}`);
    must((await audit()).some((a) => a.kind === 'roll_gear'), `${tag} roll-gear is audited`);

    // 7. offline full sync
    const snap = await call('GET', '/api/offline/snapshot', null, token);
    must(snap.json && snap.json.snapshot, `${tag} online snapshot taken`);
    const forged = JSON.parse(JSON.stringify(snap.json.snapshot));
    forged.character.level = 150; forged.character.experience = 0; forged.character.gold = 1000000;
    const load = (confirmImplausible) => call('POST', '/api/offline/load', { snapshot: forged, expectedFingerprint: snap.json.fingerprint, confirmImplausible }, token);
    const first = await load(false);
    if (enforce) {
      must(first.status === 409 && first.json.implausible === true, `${tag} enforce: an implausible offline save needs confirmation (409)`);
      must((await row()).level !== 150, `${tag} ...and nothing was written`);
      const [[v0]] = await db.execute('SELECT COUNT(*) AS n FROM character_save_versions WHERE character_id = ?', [cid]);
      must(Number(v0.n) === 0, `${tag} ...no version rows yet`);
      const second = await load(true);
      must(second.status === 200 && (await row()).level === 150, `${tag} enforce: confirmed, it loads`);
      must((await audit()).some((a) => a.kind === 'offline_load' && a.action === 'confirm'), `${tag} the confirmation is audited`);
    } else {
      must(first.status === 200 && (await row()).level === 150, `${tag} report: the offline save loads as before`);
      must((await audit()).some((a) => a.kind === 'offline_load' && a.action === 'report'), `${tag} report: it is audited as a report`);
    }
    const [[v1]] = await db.execute("SELECT COUNT(*) AS n FROM character_save_versions WHERE character_id = ? AND source IN ('online', 'offline')", [cid]);
    must(Number(v1.n) === 2, `${tag} the online backup and the offline copy are both kept`);

    // 8. fail open: with the authority tables missing, saves still work exactly as before
    await db.execute('RENAME TABLE character_authority TO character_authority_hidden, progress_audit TO progress_audit_hidden');
    try {
      const blind = await progress({ level: 255, xp: 0, gold: 5 });
      must(blind.json.success, `${tag} with the authority tables missing the save still succeeds (fails open)`);
      must((await row()).level === 255, `${tag} ...and is stored as sent`);
    } finally {
      await db.execute('RENAME TABLE character_authority_hidden TO character_authority, progress_audit_hidden TO progress_audit');
    }
    return log;
  } finally {
    child.kill('SIGTERM');
  }
}

async function main() {
  if (!process.env.DM_PROBE_RUNTIME) throw new Error('set DM_PROBE_RUNTIME to an empty scratch directory');
  stageRuntime(process.env.DM_PROBE_RUNTIME);
  const db = await mysql.createConnection({ host: '127.0.0.1', user: process.env.DM_PROBE_USER, password: process.env.DM_PROBE_PASS, database: process.env.DM_PROBE_DB });
  try {
    // The migration is additive and idempotent: running it again must not fail or change anything.
    const sql = fs.readFileSync(path.join(__dirname, '../../server/death-muffin/backend/migrations/021-server-authority.sql'), 'utf8');
    const admin = await mysql.createConnection({ host: '127.0.0.1', user: process.env.DM_PROBE_USER, password: process.env.DM_PROBE_PASS, database: process.env.DM_PROBE_DB, multipleStatements: true });
    await admin.query(sql); await admin.query(sql);
    await admin.end();
    must(true, 'migration 021 applies twice without error');
    const [cols] = await db.execute("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('character_authority', 'progress_audit')");
    must(cols.length >= 18, `both authority tables exist (${cols.length} columns)`);
    const logs = [];
    logs.push(await runMode('report', 5341, db));
    logs.push(await runMode('enforce', 5342, db));
    if (process.env.DM_PROBE_LOG) console.log(logs.join('\n----\n'));
    console.log('done.');
  } finally {
    await db.end().catch(() => {});
  }
}
main().then(() => process.exit(0), (e) => { console.error(e.message); process.exit(1); });
