/**
 * End-to-end check of the Legion kit (thrall gear) against a REAL MySQL scratch database and the REAL server.js. There is no migration for
 * the kit (the live `inventory.equipped_slot` is varchar(32) and slots 120-121 are plain rows), so this proves the real SQL instead:
 *
 *   1. create a throwaway database whose tables are `CREATE TABLE ... LIKE` the live ones (accounts, characters, items, inventory, account_vault,
 *      professions, loot_instances), copy the `items` rows, and a throwaway MySQL user limited to that database (see the header of
 *      tools/qa/affix-db-probe.cjs; same setup, same tear-down);
 *   2. NODE_PATH=<a backend node_modules> DM_PROBE_RUNTIME=<an empty scratch dir> DM_PROBE_DB=... DM_PROBE_USER=... DM_PROBE_PASS=... node tools/qa/thrall-kit-db-probe.cjs
 *
 * It starts server.js on 127.0.0.1:5353 against the scratch database (never the live one), rolls gear, moves it to and from the kit over HTTP,
 * and checks the database after each step: the kit rows (slot, equipped_slot, instance), swaps with a full bag, refusals, the bag save, salvage,
 * the Vault, delete, and that kit stats never reach /api/character/stats. It stops the server it started (by pid). Drop the database and user afterwards.
 */
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');

const PORT = 5353;
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
    const reg = await call('POST', '/register', { username: `kit_${Date.now() % 100000}`, password: 'probe-password-1' });
    must(reg.status === 201 && reg.json.token, 'registered a probe account');
    const token = reg.json.token;
    const accountId = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).accountId;
    const [ins] = await db.execute("INSERT INTO characters (account_id, class_index, class_name, level, discipline_index) VALUES (?, 1, 'Ossuary', 10, 1)", [accountId]);
    const cid = ins.insertId;
    const inv = async () => (await call('GET', `/api/inventory/${cid}`, null, token)).json.data;
    const kit = (slot, equipped) => call('POST', '/api/inventory/kit', { characterId: cid, slot_index: slot, equipped }, token);
    const save = (slots) => call('POST', '/api/inventory/save', { characterId: cid, slots, bagSize: 48 }, token);
    const rows = async () => (await db.execute('SELECT slot_index, item_id, equipped, equipped_slot, instance_id FROM inventory WHERE character_id = ? ORDER BY slot_index', [cid]))[0];
    const stats = async () => (await call('GET', `/api/character/stats/${cid}`, null, token)).json.data.bonus;

    // 1. A bag of rolled gear: a sword-type weapon, an off-hand, a chestplate, a helm, a ring and a material.
    const r = await call('POST', '/api/loot/roll-gear', { characterId: cid, drops: [
      { item_id: 'staff_iron', level: 8, source: 'boss' }, { item_id: 'chest_iron', level: 8, source: 'boss' }, { item_id: 'helm_iron', level: 8, source: 'elite' },
      { item_id: 'ring_copper', level: 8, source: 'elite' }, { item_id: 'ore_copper', level: 8, source: 'kill' }, { item_id: 'staff_oak', level: 8, source: 'kill' },
    ] }, token);
    must(r.json.success && r.json.data.length === 6, 'rolled six drops');
    const [staff, chest, helm, ring, ore, oak] = r.json.data;
    const ok = await save([
      { slot_index: 0, item_id: 'staff_iron', quantity: 1, instance_id: staff.instance_id }, { slot_index: 1, item_id: 'chest_iron', quantity: 1, instance_id: chest.instance_id },
      { slot_index: 2, item_id: 'helm_iron', quantity: 1, instance_id: helm.instance_id }, { slot_index: 3, item_id: 'ring_copper', quantity: 1, instance_id: ring.instance_id },
      { slot_index: 4, item_id: 'ore_copper', quantity: 5, instance_id: null }, { slot_index: 5, item_id: 'staff_oak', quantity: 1, instance_id: oak.instance_id },
    ]);
    must(ok.json.success, 'saved the bag');
    const before = await stats();

    // 2. Weapon and armour go to their slots; the bag slot frees; the row keeps its roll.
    const w = await kit(0, 1);
    must(w.json.success, `the staff goes to the legion (${w.json.error ?? ''})`);
    let db1 = await rows();
    const wRow = db1.find((x) => x.slot_index === 120);
    must(wRow && wRow.item_id === 'staff_iron' && Number(wRow.equipped) === 1 && wRow.equipped_slot === 'kit_weapon' && Number(wRow.instance_id) === staff.instance_id, 'slot 120 holds the staff: equipped, kit_weapon, roll kept');
    must(!db1.some((x) => x.slot_index === 0), 'the bag slot was freed');
    must(w.json.data.some((x) => x.slot_index === 120 && x.ilvl === staff.ilvl && Array.isArray(x.affixes)), 'the reply carries the kit row with its item level and affixes');
    const a = await kit(1, 1);
    must(a.json.success && (await rows()).find((x) => x.slot_index === 121)?.equipped_slot === 'kit_armor', 'the chestplate goes to slot 121 as kit_armor');
    const bad = await Promise.all([kit(3, 1), kit(4, 1), kit(9, 1), kit(120, 1), kit(2, 0), kit(122, 0)]);
    must(bad.every((x) => x.json.success === false), 'a ring, a material, an empty slot, a kit slot as source, a bag slot as target are all refused');
    must(/weapons and armour only/.test(bad[0].json.error) && /not a legion slot/.test(bad[4].json.error), 'with readable errors');

    // 3. Swap: a second weapon replaces the first, which lands in the freed bag slot. The first never needs free space.
    const sw = await kit(5, 1);
    must(sw.json.success, 'a second weapon swaps in');
    db1 = await rows();
    must(db1.find((x) => x.slot_index === 120).item_id === 'staff_oak' && db1.find((x) => x.slot_index === 5).item_id === 'staff_iron' && Number(db1.find((x) => x.slot_index === 5).equipped) === 0 && db1.find((x) => x.slot_index === 5).equipped_slot === null, 'the old staff is back in bag slot 5, unequipped');
    must(Number(db1.find((x) => x.slot_index === 5).instance_id) === staff.instance_id, 'with its roll');
    await kit(5, 1);
    must((await rows()).find((x) => x.slot_index === 120).item_id === 'staff_iron', 'and back again');

    // 4. Kit pieces never reach the stat endpoints.
    const after = await stats();
    must(JSON.stringify(before) === JSON.stringify(after), `/api/character/stats ignores kit stats (${JSON.stringify(after)})`);
    const gameEquip = await db.execute('SELECT 1');
    void gameEquip;

    // 5. The bag save, salvage, Vault and delete cannot touch the kit.
    const save2 = await save([{ slot_index: 7, item_id: 'ore_copper', quantity: 2, instance_id: null }, { slot_index: 120, item_id: 'staff_oak', quantity: 1 }, { slot_index: 121, item_id: 'ore_copper', quantity: 1 }]);
    must(save2.json.success, 'a bag save that echoes kit-range rows is accepted (they are ignored)');
    db1 = await rows();
    must(db1.find((x) => x.slot_index === 120).item_id === 'staff_iron' && db1.find((x) => x.slot_index === 121).item_id === 'chest_iron', 'and the kit rows are untouched');
    await db.execute("INSERT IGNORE INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, 'salvaging', 1, 0)", [cid]);
    const sv = await call('POST', '/api/salvage', { characterId: cid, slots: [120] }, token);
    must(sv.json.success === false && (await rows()).some((x) => x.slot_index === 120), 'salvage refuses a kit slot');
    const dep = await call('POST', '/api/vault/deposit-all', { characterId: cid, kind: 'all', exceptSlots: [] }, token);
    must(dep.json.success && (await rows()).filter((x) => x.slot_index >= 100).length === 2, 'Deposit all empties the bag and leaves both kit rows');
    const del = await call('POST', '/api/inventory/delete', { characterId: cid, slot_index: 120 }, token);
    must(del.status === 400 && (await rows()).some((x) => x.slot_index === 120), 'the delete route refuses a kit slot');
    for (const v of (await call('GET', `/api/vault/${cid}`, null, token)).json.data.vault) await call('POST', '/api/vault/withdraw', { characterId: cid, vaultSlot: v.slot_index }, token);

    // 6. Taking a piece off: first free bag slot; a full bag refuses and changes nothing.
    const off = await kit(121, 0);
    must(off.json.success && !(await rows()).some((x) => x.slot_index === 121), 'taking the armour off frees slot 121');
    const bagNow = (await rows()).filter((x) => x.slot_index < 48);
    const back = bagNow.find((x) => x.item_id === 'chest_iron');
    must(back && Number(back.equipped) === 0 && back.equipped_slot === null && Number(back.instance_id) === chest.instance_id, 'the chestplate is in the bag with its roll');
    const have = new Set(bagNow.map((x) => x.slot_index));
    const filler = [];
    for (let i = 0; i < 48; i++) if (!have.has(i)) filler.push([cid, i, 'ring_copper', 1, 0]);
    for (const f of filler) await db.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped) VALUES (?, ?, ?, ?, ?)', f);
    const snapshot = JSON.stringify(await rows());
    const full = await kit(120, 0);
    must(full.json.success === false && /bag is full/.test(full.json.error) && JSON.stringify(await rows()) === snapshot, 'a full bag refuses the take-off and changes nothing');
    const fullSwap = await kit(back.slot_index, 1);
    must(fullSwap.json.success, 'but putting armour on works with a full bag (the slot it frees is not needed)');

    // 7. Ownership.
    const other = await call('POST', '/register', { username: `kit2_${Date.now() % 100000}`, password: 'probe-password-1' });
    const foreign = await call('POST', '/api/inventory/kit', { characterId: cid, slot_index: 120, equipped: 0 }, other.json.token);
    must(foreign.status === 403, "another account cannot touch this character's kit");
    console.log('done.');
  } finally {
    child.kill('SIGTERM');
    await db.end().catch(() => {});
    if (process.env.DM_PROBE_LOG) console.log(log);
  }
}
main().then(() => process.exit(0), (e) => { console.error(e.message); process.exit(1); });
