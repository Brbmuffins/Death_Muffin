/** Full-save write/read probe inside one rolled-back Death Muffin DB transaction. */
const assert = require('node:assert/strict');
const path = require('node:path');
const runtime = '/home/ubuntu/death-muffin/backend';
require(path.join(runtime, 'node_modules/dotenv')).config({ path: path.join(runtime, '.env') });
const mysql = require(path.join(runtime, 'node_modules/mysql2/promise'));
const sync = require('../../server/death-muffin/backend/offline-full-sync.cjs');

async function main() {
  const pool = mysql.createPool({
    host: process.env.DB_HOST, user: process.env.DB_USER, password: process.env.DB_PASS,
    database: process.env.DB_NAME, connectionLimit: 1,
  });
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const username = `offline_probe_${Date.now().toString(36)}`.slice(0, 32);
    const [account] = await conn.execute('INSERT INTO accounts (username, password_hash, active, alpha_access) VALUES (?, ?, 1, 1)', [username, 'rollback-only']);
    const [character] = await conn.execute('INSERT INTO characters (account_id, class_index, class_name, discipline_index) VALUES (?, 5, ?, 2)', [account.insertId, 'Necromancer']);
    const id = character.insertId;
    assert.equal(sync.fingerprint(await sync.capture(conn, id, username)), sync.fingerprint(await sync.capture(conn, id, username)));
    const snapshot = {
      username,
      character: { id, class_index: 2, class_name: 'Ossuary', level: 3, experience: 50, gold: 120,
        stat_str: 5, stat_agi: 5, stat_int: 8, stat_vit: 10,
        pos_x: 0, pos_y: 0, pos_z: 0, pos_map: 'HUB', orientation: 0 },
      slots: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1, equipped: 0 }],
      professions: [{ profession_id: 'mining', skill_level: 3, skill_xp: 10 }],
      necro: { ascension: 1, ashes: 4, areaKills: { graves: 15 }, unlockedAreas: ['chapterhouse', 'graves'] },
      chronicle: { life: { kills: 15 }, run: { kills: 3 }, runNo: 1, runStartedAt: new Date().toISOString(), runs: [] },
      contracts: { day: new Date().toISOString().slice(0, 10), done: [], bonus: false, days: [] },
      garden: {}, labor: {}, cosmetics: { cape: null, pet: null, pets: [] },
    };
    sync.validate(snapshot, 2);
    await sync.apply(conn, id, snapshot);
    const captured = await sync.capture(conn, id, username);
    assert.equal(captured.character.level, 3);
    assert.equal(captured.character.gold, 120);
    assert.equal(captured.slots[0].item_id, 'staff_oak');
    assert.equal(captured.professions[0].skill_level, 3);
    assert.equal(captured.necro.ascension, 1);
    assert.equal(captured.chronicle.life.kills, 15);
    assert.equal(sync.fingerprint(captured), sync.fingerprint(await sync.capture(conn, id, username)));
    console.log('Full save DB probe passed; transaction rolled back.');
  } finally {
    await conn.rollback().catch(() => {});
    conn.release();
    await pool.end();
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
