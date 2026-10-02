/**
 * End-to-end check of Relic runes against a REAL MySQL scratch database and the REAL server.js, including migration 024.
 *
 *   1. create a throwaway database whose tables are `CREATE TABLE ... LIKE` the live ones (accounts, characters, items, loot_instances, inventory,
 *      account_vault, professions, character_authority, progress_audit and the offline-save tables), copy the live `items` rows (so the item_type
 *      enum is the LIVE one, without 'rune'), add the live inventory foreign keys by hand (LIKE does not copy them: `ALTER TABLE inventory ADD CONSTRAINT
 *      inventory_ibfk_1 FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE, ADD CONSTRAINT inventory_ibfk_2 FOREIGN KEY (item_id) REFERENCES items (id)`),
 *      and a throwaway MySQL user limited to that database (see the header of tools/qa/affix-db-probe.cjs);
 *   2. NODE_PATH=<a backend node_modules> DM_PROBE_RUNTIME=<an empty scratch dir> DM_PROBE_DB=... DM_PROBE_USER=... DM_PROBE_PASS=... node tools/qa/runes-db-probe.cjs
 *
 * It first proves a rune row cannot exist before the migration, applies migration 024 twice (idempotent), then starts server.js on 127.0.0.1:5356 against
 * the scratch database (never the live one) and drives: stack in the bag -> socket -> swap -> take out -> full bag refusal -> wrong rite -> foreign account ->
 * bag save echoing a socket -> character stats -> Vault -> salvage -> offline full sync (apply + capture) and checks the database after each step.
 * It stops the server it started (by pid). Drop the database and user afterwards.
 */
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');

const PORT = 5356;
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
  const db = await mysql.createConnection({ host: '127.0.0.1', user: env.DB_USER, password: env.DB_PASS, database: env.DB_NAME, multipleStatements: true });

  // 0. Migration 024: before it, the live enum refuses a rune; after it (twice), eleven rune rows exist and nothing else changed.
  const [[before]] = await db.query("SELECT COLUMN_TYPE AS t FROM information_schema.columns WHERE table_schema = ? AND table_name = 'items' AND column_name = 'item_type'", [env.DB_NAME]);
  must(!/rune/.test(before.t), `the live item_type enum has no 'rune' yet (${before.t.slice(0, 60)}...)`);
  let refused = false;
  try { await db.query("INSERT INTO items (id, name, rarity, item_type, stackable, max_stack_size) VALUES ('rune_probe', 'x', 'rare', 'rune', 1, 99)"); } catch (e) { refused = true; }
  if (!refused) await db.query("DELETE FROM items WHERE id = 'rune_probe'");
  must(refused, 'a rune row is refused before the migration (strict mode: the enum has no such value)');
  const [[countBefore]] = await db.query('SELECT COUNT(*) AS n FROM items');
  const sql = fs.readFileSync(path.join(__dirname, '../../server/death-muffin/backend/migrations/024-relic-runes.sql'), 'utf8');
  await db.query(sql);
  await db.query(sql);
  const [[after]] = await db.query("SELECT COLUMN_TYPE AS t, COLLATION_NAME AS c, IS_NULLABLE AS nullable FROM information_schema.columns WHERE table_schema = ? AND table_name = 'items' AND column_name = 'item_type'", [env.DB_NAME]);
  must(/'rune'/.test(after.t) && /'consumable'/.test(after.t) && after.c === 'utf8mb4_unicode_ci' && after.nullable === 'NO', `the enum gained 'rune', kept every old value, collation and NOT NULL (${after.t})`);
  const [runeRows] = await db.query("SELECT id, rarity, item_type, stackable, max_stack_size, sell_value, icon_id FROM items WHERE item_type = 'rune' ORDER BY id");
  must(runeRows.length === 11 && runeRows.every((r) => Number(r.stackable) === 1 && Number(r.max_stack_size) === 99 && r.icon_id === r.id), 'eleven rune items, stackable to 99, icon_id = id; applying twice added nothing');
  const [[countAfter]] = await db.query('SELECT COUNT(*) AS n FROM items');
  must(Number(countAfter.n) === Number(countBefore.n) + 11, 'no other item row changed');
  const sells = Object.fromEntries(runeRows.map((r) => [r.id, `${r.rarity}:${r.sell_value}`]));
  must(sells.rune_bone_colossus === 'epic:150' && sells.rune_splinter === 'uncommon:25' && sells.rune_volley === 'rare:60', 'rarities and sell values follow the content');

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
    const reg = await call('POST', '/register', { username: `rune_${Date.now() % 100000}`, password: 'probe-password-1' });
    must(reg.status === 201 && reg.json.token, 'registered a probe account');
    const token = reg.json.token;
    const accountId = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).accountId;
    const [ins] = await db.execute("INSERT INTO characters (account_id, class_index, class_name, level, discipline_index) VALUES (?, 1, 'Ossuary', 10, 1)", [accountId]);
    const cid = ins.insertId;
    const rune = (rite, itemId, tok = token) => call('POST', '/api/inventory/rune', { characterId: cid, rite, itemId }, tok);
    const rows = async () => (await db.execute('SELECT slot_index, item_id, quantity, equipped, equipped_slot, instance_id FROM inventory WHERE character_id = ? ORDER BY slot_index', [cid]))[0];
    const save = (slots) => call('POST', '/api/inventory/save', { characterId: cid, slots, bagSize: 48 }, token);
    const held = async (id) => (await rows()).filter((r) => r.item_id === id).reduce((n, r) => n + Number(r.quantity), 0);

    // 1. A rune stack arrives in the bag through the ordinary bag save (the authority guard, in report mode, lets a few ground drops through).
    const s1 = await save([{ slot_index: 0, item_id: 'rune_volley', quantity: 3 }, { slot_index: 1, item_id: 'rune_bone_colossus', quantity: 1 }, { slot_index: 2, item_id: 'rune_mass_grave', quantity: 2 }, { slot_index: 3, item_id: 'rune_requiem', quantity: 1 }, { slot_index: 4, item_id: 'sword_copper', quantity: 1 }]);
    must(s1.json.success, `the bag saved with runes in it (${s1.json.error ?? ''})`);
    let inv = (await call('GET', `/api/inventory/${cid}`, null, token)).json.data;
    must(inv.find((r) => r.item_id === 'rune_volley' && r.item_type === 'rune' && r.quantity === 3 && r.rarity === 'rare'), 'GET /api/inventory reads a rune with item_type rune, rarity and quantity 3');

    // 2. Socketing moves exactly one, into the reserved slot, equipped as rune_<rite>.
    const a = await rune('bone_needle', 'rune_volley');
    must(a.json.success, `socketed Volley into Bone Needle (${a.json.error ?? ''})`);
    let r = await rows();
    const sock = r.find((x) => x.slot_index === 130);
    must(sock && sock.item_id === 'rune_volley' && Number(sock.quantity) === 1 && Number(sock.equipped) === 1 && sock.equipped_slot === 'rune_bone_needle', 'slot 130 holds Volley: quantity 1, equipped, rune_bone_needle');
    must(r.find((x) => x.slot_index === 0).quantity === 2 && (await held('rune_volley')) === 3, 'the stack went 3 -> 2; no rune created or lost');
    must(a.json.data.some((x) => x.slot_index === 130 && x.item_id === 'rune_volley'), 'the reply carries the socket row (the whole bag, like /kit)');

    // 3. A wrong rite, a rune you lack, a non-rune and an empty socket are refused with the readable words and change nothing.
    const snap = JSON.stringify(await rows());
    const bad = await Promise.all([rune('miasma', 'rune_volley'), rune('black_litany', 'rune_hollow_choir'), rune('exhume', 'sword_copper'), rune('miasma', null), rune('wailing_skull', 'rune_volley')]);
    must(bad.every((x) => x.json.success === false), 'a wrong rite, a missing rune, a sword, an empty socket and a rite without runes are all refused');
    must(/doesn't fit this rite/.test(bad[0].json.error) && /don't have that rune/.test(bad[1].json.error) && /not a rune/.test(bad[2].json.error) && /socket is empty/.test(bad[3].json.error) && /not a rite that takes a rune/.test(bad[4].json.error), 'with readable errors');
    must(JSON.stringify(await rows()) === snap, 'and the database did not change');

    // 4. A swap: the new rune goes in, the old one comes back (onto its stack).
    const sw = await rune('exhume', 'rune_bone_colossus');
    must(sw.json.success, 'Bone Colossus into Exhume');
    const sw2 = await rune('exhume', 'rune_mass_grave');
    must(sw2.json.success, 'then Mass Grave swaps it out');
    r = await rows();
    must(r.find((x) => x.slot_index === 132).item_id === 'rune_mass_grave' && (await held('rune_bone_colossus')) === 1 && !r.some((x) => x.slot_index < 48 && x.item_id === 'rune_bone_colossus' && Number(x.equipped)), 'slot 132 holds Mass Grave; the Colossus rune is back in the bag, unequipped');
    must(r.filter((x) => x.slot_index >= 130).length === 2, 'two sockets in use, each a unique equipped_slot');
    // The live UNIQUE (character_id, equipped_slot): a second row with the same name cannot exist.
    let dup = false;
    try { await db.execute("INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, 50, 'rune_volley', 1, 1, 'rune_bone_needle')", [cid]); } catch { dup = true; }
    must(dup, 'the database itself refuses a second rune in the same rite');

    // 5. Taking out; a full bag refuses and changes nothing; but a swap still works with a full bag.
    const out = await rune('bone_needle', null);
    must(out.json.success && !(await rows()).some((x) => x.slot_index === 130) && (await held('rune_volley')) === 3, 'taking Volley out empties slot 130 and returns it to the bag');
    await rune('bone_needle', 'rune_volley');
    must((await rune('black_litany', 'rune_requiem')).json.success, 'Requiem (the only one held) into Black Litany');
    const have = new Set((await rows()).filter((x) => x.slot_index < 48).map((x) => x.slot_index));
    for (let i = 0; i < 48; i++) if (!have.has(i)) await db.execute("INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped) VALUES (?, ?, 'ring_copper', 1, 0)", [cid, i]);
    const full = JSON.stringify(await rows());
    const fullOut = await rune('black_litany', null);
    must(fullOut.json.success === false && /bag is full/.test(fullOut.json.error) && JSON.stringify(await rows()) === full, 'a full bag refuses the take-out (no stack to join) and changes nothing');
    const fullSwap = await rune('exhume', 'rune_bone_colossus');
    must(fullSwap.json.success && (await rows()).find((x) => x.slot_index === 132).item_id === 'rune_bone_colossus', 'but a swap works with a full bag: the rune leaving the bag frees the slot the other one needs');
    must((await rows()).some((x) => x.slot_index < 48 && x.item_id === 'rune_mass_grave' && Number(x.quantity) === 2), 'Mass Grave (1 in the bag + the one that came back) joined its own stack');
    // clear the filler
    await db.execute("DELETE FROM inventory WHERE character_id = ? AND item_id = 'ring_copper'", [cid]);

    // 6. Ownership.
    const other = await call('POST', '/register', { username: `rune2_${Date.now() % 100000}`, password: 'probe-password-1' });
    const foreign = await rune('exhume', null, other.json.token);
    must(foreign.status === 403, "another account cannot touch this character's sockets");
    const noAuth = await call('POST', '/api/inventory/rune', { characterId: cid, rite: 'exhume', itemId: null });
    must(noAuth.status === 401 || noAuth.status === 403, 'and a request without a token is refused');

    // 7. The bag save ignores echoed socket rows; the stat endpoints never see them.
    const echo = await save([{ slot_index: 0, item_id: 'rune_volley', quantity: 2 }, { slot_index: 1, item_id: 'rune_mass_grave', quantity: 2 }, { slot_index: 130, item_id: 'rune_impale', quantity: 1 }, { slot_index: 131, item_id: 'rune_impale', quantity: 1 }]);
    must(echo.json.success, 'a bag save that echoes socket-range rows is accepted (they are ignored)');
    r = await rows();
    must(r.find((x) => x.slot_index === 130).item_id === 'rune_volley' && !r.some((x) => x.slot_index === 131), 'and the sockets are untouched');
    const stats = (await call('GET', `/api/character/stats/${cid}`, null, token)).json;
    must(stats.success !== false, 'character stats still answer with sockets in the table');
    must(JSON.stringify(stats.data.bonus) === JSON.stringify({ str: 0, agi: 0, int: 0, vit: 0 }) || Object.values(stats.data.bonus).every((v) => !v), `socketed runes add no stats (${JSON.stringify(stats.data.bonus)})`);
    // The game-server equipment endpoint (token-gated, so run its own query here): sockets sit above slot 110 and are not equipment.
    const [worn] = await db.execute("SELECT inv.slot_index FROM inventory inv JOIN items i ON i.id = inv.item_id WHERE inv.character_id = ? AND inv.equipped = 1 AND inv.equipped_slot IS NOT NULL AND inv.slot_index < 110", [cid]);
    must(worn.length === 0, 'the equipment queries (slot_index < 110) never see a socket row');

    // 8. The Vault: Deposit all empties the bag and leaves the sockets; a rune stack rests as one stack and comes back.
    const dep = await call('POST', '/api/vault/deposit-all', { characterId: cid, kind: 'all', exceptSlots: [] }, token);
    must(dep.json.success && (await rows()).filter((x) => x.slot_index >= 100).length === 3, 'Deposit all empties the bag and leaves all three sockets');
    const vault = (await call('GET', `/api/vault/${cid}`, null, token)).json.data.vault;
    must(vault.some((v) => v.item_id === 'rune_volley' && v.quantity === 2 && v.item_type === 'rune') && vault.some((v) => v.item_id === 'rune_mass_grave' && v.quantity === 2), 'runes rest in the Vault as stacks');
    for (const v of vault) await call('POST', '/api/vault/withdraw', { characterId: cid, vaultSlot: v.slot_index }, token);
    must((await held('rune_volley')) === 3 && (await held('rune_mass_grave')) === 2, 'and withdraw back into the bag (3 Volley incl. the socketed one, 2 Mass Grave)');

    // 9. Salvage: ONE rune of a stack, reagents only; the socket slot cannot be named.
    await db.execute("INSERT IGNORE INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, 'salvaging', 1, 0)", [cid]);
    const slotOf = (await rows()).find((x) => x.item_id === 'rune_volley' && x.slot_index < 48);
    const beforeQty = Number(slotOf.quantity);
    const sv = await call('POST', '/api/salvage', { characterId: cid, slots: [slotOf.slot_index] }, token);
    must(sv.json.success, `ground one Volley rune (${sv.json.error ?? ''})`);
    must(sv.json.data.salvaged.length === 1 && Number((await rows()).find((x) => x.slot_index === slotOf.slot_index && x.item_id === 'rune_volley').quantity) === beforeQty - 1, 'one rune consumed, the rest stay');
    must(sv.json.data.gained.length > 0 && sv.json.data.gained.every((g) => /^(reagent_|bone_meal)/.test(g.item_id)) && sv.json.data.xp > 0, `it paid reagents only (${sv.json.data.gained.map((g) => `${g.quantity}x ${g.item_id}`).join(', ')}) and Salvaging XP`);
    const sv2 = await call('POST', '/api/salvage', { characterId: cid, slots: [130] }, token);
    must(sv2.json.success === false && (await rows()).some((x) => x.slot_index === 130), 'the Grinder refuses a socket slot');

    // 10. Offline full sync: the sockets travel in a snapshot, apply files them as rune_<rite>, and a rune in the wrong rite is refused.
    const sync = require(path.join(process.env.DM_PROBE_RUNTIME, 'offline-full-sync.cjs'));
    const snapshot = await sync.capture(db, cid, 'probe');
    must(snapshot.slots.some((s) => s.slot_index === 130 && s.item_id === 'rune_volley' && s.equipped_slot === 'rune_bone_needle') && snapshot.slots.some((s) => s.slot_index === 132 && s.item_id === 'rune_bone_colossus'), 'capture carries both sockets');
    sync.validate({ ...snapshot, character: { ...snapshot.character, class_index: 1 } }, 1);
    await db.beginTransaction();
    await sync.apply(db, cid, { ...snapshot, slots: [...snapshot.slots.filter((s) => s.slot_index < 100), { slot_index: 131, item_id: 'rune_impale', quantity: 1, equipped: 1 }, { slot_index: 133, item_id: 'rune_contagion', quantity: 1, equipped: 1 }] });
    await db.commit();
    r = await rows();
    must(r.find((x) => x.slot_index === 131)?.equipped_slot === 'rune_marrow_spear' && r.find((x) => x.slot_index === 133)?.equipped_slot === 'rune_miasma' && !r.some((x) => x.slot_index === 130), 'apply replaced the sockets with the snapshot\'s (131 and 133 in, 130 gone), each with its rune_<rite> name');
    let wrong = false;
    await db.beginTransaction();
    try { await sync.apply(db, cid, { ...snapshot, slots: [{ slot_index: 133, item_id: 'rune_volley', quantity: 1, equipped: 1 }] }); } catch (e) { wrong = e instanceof RangeError; }
    await db.rollback();
    must(wrong, 'a rune in the wrong rite\'s socket is refused by the real apply');

    // 11. The item foreign key: an unknown rune id cannot be a row, and deleting the character takes its sockets with it (the foreign key cascades).
    let unknown = false;
    try { await db.execute("INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped) VALUES (?, 40, 'rune_not_in_items', 1, 0)", [cid]); } catch { unknown = true; }
    must(unknown, 'a rune id that is not in items cannot be a row (the item foreign key)');
    await db.execute('DELETE FROM characters WHERE id = ?', [cid]);
    const [[left]] = await db.execute('SELECT COUNT(*) AS n FROM inventory WHERE character_id = ?', [cid]);
    must(Number(left.n) === 0, 'deleting the character leaves no socket rows behind');
    console.log('done.');
  } finally {
    child.kill('SIGTERM');
    await db.end().catch(() => {});
    if (process.env.DM_PROBE_LOG) console.log(log);
  }
}
main().then(() => process.exit(0), (e) => { console.error(e.message); process.exit(1); });
