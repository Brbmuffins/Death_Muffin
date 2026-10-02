/**
 * End-to-end check of item level + affixes against a REAL MySQL scratch database and the REAL server.js (migration 020 applied).
 *
 *   1. create a throwaway database with copies of the live table definitions (accounts, characters, items, inventory, account_vault,
 *      professions) and `items` rows, apply server/death-muffin/backend/migrations/020-loot-instances.sql twice (idempotent);
 *   2. create a throwaway MySQL user limited to that database;
 *   3. NODE_PATH=<a backend node_modules> DM_PROBE_RUNTIME=<an empty scratch dir> DM_PROBE_DB=... DM_PROBE_USER=... DM_PROBE_PASS=... node tools/qa/affix-db-probe.cjs
 *
 * It starts server.js on 127.0.0.1:5339 against the scratch database (never the live one), drives roll -> save -> equip -> unequip ->
 * Vault -> sort -> salvage -> delete over HTTP, checks the database after each step, and stops the server it started (by pid).
 * Prints one line per check; exits non-zero on the first failure. Drop the database and user afterwards.
 */
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');

const PORT = 5339;
const BASE = `http://127.0.0.1:${PORT}`;
const env = { ...process.env, PORT: String(PORT), DB_HOST: '127.0.0.1', DB_USER: process.env.DM_PROBE_USER, DB_PASS: process.env.DM_PROBE_PASS, DB_NAME: process.env.DM_PROBE_DB, JWT_SECRET: 'probe-secret', JWT_EXPIRES_IN: '1h' };
const must = (v, msg) => { if (!v) { console.error(`FAIL ${msg}`); throw new Error(msg); } console.log(`ok   ${msg}`); };

/** The deployed layout (deploy-release.sh): backend files, gathering/ and necro-progress/ side by side. */
function stageRuntime(dir) {
  const root = path.join(__dirname, '../..');
  const b = path.join(root, 'server/death-muffin/backend');
  fs.mkdirSync(path.join(dir, 'gathering'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'necro-progress'), { recursive: true });
  for (const f of fs.readdirSync(b)) if (/\.(js|cjs)$/.test(f) && !/\.test\./.test(f) && !f.startsWith('bag-fake')) fs.copyFileSync(path.join(b, f), path.join(dir, f));
  for (const f of fs.readdirSync(path.join(b, 'gathering'))) if (/\.cjs$/.test(f) && !/\.test\./.test(f)) fs.copyFileSync(path.join(b, 'gathering', f), path.join(dir, 'gathering', f));
  for (const f of ['necro-rules.cjs', 'necro-progress-routes.cjs', 'mysql-store.cjs']) fs.copyFileSync(path.join(root, 'server/vps-handoff/necro-progress', f), path.join(dir, 'necro-progress', f));
}

async function main() {
  if (!process.env.DM_PROBE_RUNTIME) throw new Error('set DM_PROBE_RUNTIME to an empty scratch directory');
  stageRuntime(process.env.DM_PROBE_RUNTIME);
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

    const reg = await call('POST', '/register', { username: `probe_${Date.now() % 100000}`, password: 'probe-password-1' });
    must(reg.status === 201 && reg.json.token, 'registered a probe account');
    const token = reg.json.token;
    const accountId = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).accountId;
    const [ins] = await db.execute("INSERT INTO characters (account_id, class_index, class_name, level, discipline_index) VALUES (?, 1, 'Ossuary', 10, 1)", [accountId]);
    const cid = ins.insertId;
    const inv = async () => (await call('GET', `/api/inventory/${cid}`, null, token)).json.data;
    const roll = (drops) => call('POST', '/api/loot/roll-gear', { characterId: cid, drops }, token);
    const save = (slots) => call('POST', '/api/inventory/save', { characterId: cid, slots, bagSize: 48 }, token);

    // 1. roll
    const r = await roll([{ item_id: 'helm_iron', level: 8, source: 'elite' }, { item_id: 'helm_iron', level: 8, source: 'boss' }, { item_id: 'ring_copper', level: 8, source: 'first_kill' }, { item_id: 'ore_copper', level: 8, source: 'kill' }]);
    if (!r.json.success) console.error(r.status, r.json);
    must(r.json.success && r.json.data.length === 4, 'POST /api/loot/roll-gear answers every drop');
    const [a, b, c, ore] = r.json.data;
    must(a.instance_id && a.ilvl === 10 && b.ilvl === 12 && c.ilvl === 13, 'item levels come from level + source (elite +2, boss +4, first kill +5)');
    must(ore.instance_id === null, 'a material gets no instance');
    must(c.affixes.length >= 2 && b.affixes.length >= 1, 'first kills and bosses guarantee affixes');
    const [[row]] = await db.execute('SELECT account_id, item_id, ilvl, affixes FROM loot_instances WHERE id = ?', [a.instance_id]);
    must(Number(row.account_id) === accountId && row.item_id === 'helm_iron' && Number(row.ilvl) === 10, 'the instance is stored for this account');
    const clamped = await roll([{ item_id: 'helm_iron', level: 99, source: 'kill' }]);
    must(clamped.json.data[0].ilvl <= 10 + 10, 'a level-10 character cannot ask for level-99 loot');

    // 2. save names instances; forged / foreign / duplicate names are refused
    const ok = await save([{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id }, { slot_index: 1, item_id: 'helm_iron', quantity: 1, instance_id: b.instance_id }, { slot_index: 2, item_id: 'ring_copper', quantity: 1, instance_id: c.instance_id }, { slot_index: 3, item_id: 'ore_copper', quantity: 5, instance_id: null }]);
    must(ok.json.success, 'a save naming server-rolled instances is accepted');
    const bag = ok.json.data;
    must(bag.find((x) => x.slot_index === 0).ilvl === 10 && Array.isArray(bag.find((x) => x.slot_index === 0).affixes), 'the bag reply carries ilvl and affixes');
    const forged = await save([{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: 999999 }]);
    must(forged.status === 400 && /could not be verified/.test(forged.json.error), 'an unknown instance id is refused with a readable 400');
    const wrongItem = await save([{ slot_index: 0, item_id: 'staff_moon', quantity: 1, instance_id: a.instance_id }]);
    must(wrongItem.status === 400, 'an instance cannot be moved onto a different item');
    const dup = await save([{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id }, { slot_index: 5, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id }]);
    must(dup.status === 400, 'one instance cannot fill two slots');
    const [[stillThere]] = await db.execute('SELECT COUNT(*) AS n FROM inventory WHERE character_id = ? AND instance_id IS NOT NULL', [cid]);
    must(Number(stillThere.n) === 3, 'refused saves wrote nothing');
    const [[stored]] = await db.execute('SELECT ilvl, affixes FROM loot_instances WHERE id = ?', [a.instance_id]);
    must(Number(stored.ilvl) === 10, 'the stored roll was never touched by a save carrying other numbers');
    const withFake = await save([{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id, ilvl: 99, affixes: [{ id: 'p_thrall_dmg', v: 150 }] }, { slot_index: 1, item_id: 'helm_iron', quantity: 1, instance_id: b.instance_id }, { slot_index: 2, item_id: 'ring_copper', quantity: 1, instance_id: c.instance_id }]);
    must(withFake.json.success && withFake.json.data.find((x) => x.slot_index === 0).ilvl === 10, 'extra ilvl/affixes in a save are ignored');

    // 3. equip / unequip carry the instance
    const eq = await call('POST', '/api/inventory/equip', { characterId: cid, slot_index: 0, equipped: 1 }, token);
    const worn = eq.json.data.find((x) => x.slot_index === 100);
    must(eq.json.success && worn && worn.instance_id === a.instance_id && worn.ilvl === 10, 'equip keeps the roll on the worn row');
    const saveWhileWorn = await save([{ slot_index: 1, item_id: 'helm_iron', quantity: 1, instance_id: b.instance_id }, { slot_index: 2, item_id: 'ring_copper', quantity: 1, instance_id: c.instance_id }]);
    must(saveWhileWorn.json.success && saveWhileWorn.json.data.some((x) => x.slot_index === 100 && x.instance_id === a.instance_id), 'a bag save never detaches or deletes worn gear');
    const stealWorn = await save([{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id }, { slot_index: 1, item_id: 'helm_iron', quantity: 1, instance_id: b.instance_id }, { slot_index: 2, item_id: 'ring_copper', quantity: 1, instance_id: c.instance_id }]);
    must(stealWorn.status === 400, 'a worn instance cannot be named in the bag (no duplicating worn gear)');
    const swap = await call('POST', '/api/inventory/equip', { characterId: cid, slot_index: 1, equipped: 1 }, token);
    must(swap.json.success && swap.json.data.find((x) => x.slot_index === 100).instance_id === b.instance_id && swap.json.data.some((x) => x.slot_index < 48 && x.instance_id === a.instance_id), 'equipping over a worn piece swaps both rolls');
    const un = await call('POST', '/api/inventory/equip', { characterId: cid, slot_index: 100, equipped: 0 }, token);
    must(un.json.success && un.json.data.filter((x) => x.slot_index < 48 && x.instance_id).length === 3, 'unequip returns the roll to the bag');

    // 4. Vault
    const slotOf = (rows, id) => rows.find((x) => x.instance_id === id).slot_index;
    const dep = await call('POST', '/api/vault/deposit', { characterId: cid, bagSlot: slotOf(un.json.data, a.instance_id) }, token);
    must(dep.json.success && dep.json.data.vault.length === 1 && dep.json.data.vault[0].instance_id === a.instance_id && dep.json.data.vault[0].ilvl === 10, 'depositing moves the roll into the Vault');
    const stealVault = await save([...un.json.data.filter((x) => x.slot_index < 48 && x.instance_id !== a.instance_id).map((x) => ({ slot_index: x.slot_index, item_id: x.item_id, quantity: x.quantity, instance_id: x.instance_id })), { slot_index: 20, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id }]);
    must(stealVault.status === 400, 'a vaulted instance cannot also be named in the bag');
    const dep2 = await call('POST', '/api/vault/deposit-all', { characterId: cid, kind: 'all', exceptSlots: [] }, token);
    must(dep2.json.success && dep2.json.data.vault.filter((x) => x.instance_id).length === 3, 'deposit-all moves every rolled piece');
    const sorted = await call('POST', '/api/vault/sort', { characterId: cid }, token);
    must(sorted.json.success && sorted.json.data.vault.filter((x) => x.instance_id).length === 3, 'sorting the Vault keeps every roll');
    const wd = await call('POST', '/api/vault/withdraw', { characterId: cid, vaultSlot: 0 }, token);
    must(wd.json.success && wd.json.data.bag.filter((x) => x.instance_id).length === 1, 'withdrawing moves the roll back to the bag');
    const [[orphans]] = await db.execute('SELECT COUNT(*) AS n FROM loot_instances li WHERE li.account_id = ? AND NOT EXISTS (SELECT 1 FROM inventory i WHERE i.instance_id = li.id) AND NOT EXISTS (SELECT 1 FROM account_vault v WHERE v.instance_id = li.id)', [accountId]);
    must(Number(orphans.n) === 1, 'moving never loses or leaks a roll (only the level-99 probe roll is unclaimed)');

    // 5. salvage and delete
    await db.execute("INSERT IGNORE INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, 'salvaging', 1, 0)", [cid]);
    const bagNow = wd.json.data.bag.find((x) => x.instance_id);
    const sv = await call('POST', '/api/salvage', { characterId: cid, slots: [bagNow.slot_index] }, token);
    must(sv.json.success && sv.json.data.salvaged.length === 1, 'salvaging a rolled piece works');
    const [[gone]] = await db.execute('SELECT COUNT(*) AS n FROM loot_instances WHERE id = ?', [bagNow.instance_id]);
    must(Number(gone.n) === 0, 'salvage deleted the instance with the item');
    const vaultNow = (await call('GET', `/api/vault/${cid}`, null, token)).json.data.vault;
    const w2 = await call('POST', '/api/vault/withdraw', { characterId: cid, vaultSlot: vaultNow[0].slot_index }, token);
    must(w2.json.success, 'withdrew another rolled piece');
    const target = w2.json.data.bag.find((x) => x.instance_id === vaultNow[0].instance_id);
    const del = await call('POST', '/api/inventory/delete', { characterId: cid, slot_index: target.slot_index }, token);
    must(del.json.success, 'the delete route works');
    const [[gone2]] = await db.execute('SELECT COUNT(*) AS n FROM loot_instances WHERE id = ?', [target.instance_id]);
    must(Number(gone2.n) === 0, 'deleting an item deletes its instance');

    for (const v of (await call('GET', `/api/vault/${cid}`, null, token)).json.data.vault) await call('POST', '/api/vault/withdraw', { characterId: cid, vaultSlot: v.slot_index }, token);
    must((await inv()).some((x) => x.slot_index < 48 && x.instance_id), 'rolled pieces are back in the bag for the last checks');

    // 6. a stale tab (no instance_id key at all) keeps the rolls it does not know about
    const bag7 = (await inv()).filter((x) => x.slot_index < 48 && x.instance_id);
    if (bag7.length) {
      const stale = await save((await inv()).filter((x) => x.slot_index < 48).map((x) => ({ slot_index: x.slot_index, item_id: x.item_id, quantity: x.quantity })));
      must(stale.json.success && stale.json.data.filter((x) => x.slot_index < 48 && x.instance_id).length === bag7.length, 'a save from a client that predates affixes keeps every roll');
    }
    // 7. a relic the bag save drops is gone for good (sell, then try to bring it back)
    const bag6 = (await inv()).filter((x) => x.slot_index < 48);
    const victim = bag6.find((x) => x.instance_id);
    const without = bag6.filter((x) => x !== victim).map((x) => ({ slot_index: x.slot_index, item_id: x.item_id, quantity: x.quantity, instance_id: x.instance_id }));
    if (victim) {
      must((await save(without)).json.success, 'a save without the piece (a sale) is accepted');
      const back = await save([...without, { slot_index: 47, item_id: victim.item_id, quantity: 1, instance_id: victim.instance_id }]);
      must(back.status === 400, 'the sold piece cannot be brought back by a later save');
    }

    console.log('done.');
  } finally {
    child.kill('SIGTERM');
    await db.end().catch(() => {});
    if (process.env.DM_PROBE_LOG) console.log(log);
  }
}
main().then(() => process.exit(0), (e) => { console.error(e.message); process.exit(1); });
