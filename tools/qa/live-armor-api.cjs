/**
 * Live armor API check (no browser): throwaway account + Gravecaller character on the public domain, grants all ten
 * Gravecall/Epitaph Sovereign pieces through /inventory/add-item, equips a full set, checks the stats endpoint, swaps to the
 * ascended pieces, then deletes the account (same cleanup as live-domain-smoke.cjs).
 *   node tools/qa/live-armor-api.cjs
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const site = 'https://muffindevelopment.com/death-muffin/';
const PARTS = ['head', 'chest', 'hands', 'legs', 'feet'];
const RESERVED = { head: 100, chest: 101, legs: 102, feet: 103, hands: 104 };

async function main() {
  const username = 'dm_domain_probe_' + Date.now();
  const backend = process.env.DM_QA_BACKEND || '/home/ubuntu/death-muffin/backend';
  const env = require(backend + '/node_modules/dotenv').parse(fs.readFileSync(backend + '/.env'));
  const mysql = require(backend + '/node_modules/mysql2/promise');
  const db = await mysql.createConnection({ host: env.DB_HOST, user: env.DB_USER, password: env.DB_PASS, database: env.DB_NAME });
  const post = async (p, body, h) => fetch(site + p, { method: 'POST', headers: { 'Content-Type': 'application/json', ...h }, body: JSON.stringify(body) });
  try {
    const reg = await post('api/register', { username, password: 'ArmorProbe-' + Date.now() });
    assert.equal(reg.status, 201, 'register');
    const { token } = await reg.json();
    const H = { Authorization: 'Bearer ' + token };
    const ch = await post('api/character', { class_index: 2 }, H);
    assert.ok(ch.status === 200 || ch.status === 201, 'create character ' + ch.status);
    const character = await (await fetch(site + 'api/character', { headers: H })).json();
    const id = character.id;
    const stats = async () => (await (await fetch(site + 'api/api/character/stats/' + id, { headers: H })).json());
    const before = await stats();
    for (const set of ['set_gravecaller', 'set_gravecaller_ascended']) for (const p of PARTS) {
      const r = await post('api/api/inventory/add-item', { characterId: id, itemId: `${set}_${p}`, quantity: 1 }, H);
      assert.equal(r.status, 200, `add ${set}_${p}: ${r.status} ${await r.text()}`);
    }
    const bag = async () => { const j = await (await fetch(site + 'api/api/inventory/' + id, { headers: H })).json(); return j.data ?? j; };
    let inv = await bag();
    for (const p of PARTS) {
      const slot = inv.find((s) => s.item_id === `set_gravecaller_${p}`);
      assert.ok(slot, 'first-set piece in bag ' + p);
      const r = await post('api/api/inventory/equip', { characterId: id, slot_index: slot.slot_index, equipped: true }, H);
      assert.equal(r.status, 200, `equip ${p}: ${r.status} ${await r.text()}`);
    }
    inv = await bag();
    for (const p of PARTS) assert.equal(inv.find((s) => s.item_id === `set_gravecaller_${p}`)?.slot_index, RESERVED[p], 'reserved slot ' + p);
    const withSet = await stats();
    console.log('stats before', JSON.stringify(before).slice(0, 300));
    console.log('stats set 1 ', JSON.stringify(withSet).slice(0, 300));
    for (const p of PARTS) {
      const slot = inv.find((s) => s.item_id === `set_gravecaller_ascended_${p}`);
      const r = await post('api/api/inventory/equip', { characterId: id, slot_index: slot.slot_index, equipped: true }, H);
      assert.equal(r.status, 200, `swap ${p}: ${r.status} ${await r.text()}`);
    }
    inv = await bag();
    for (const p of PARTS) {
      assert.equal(inv.find((s) => s.item_id === `set_gravecaller_ascended_${p}`)?.slot_index, RESERVED[p], 'ascended in slot ' + p);
      assert.ok(inv.find((s) => s.item_id === `set_gravecaller_${p}`)?.slot_index < 100, 'first set back in bag ' + p);
    }
    const withAscended = await stats();
    console.log('stats set 2 ', JSON.stringify(withAscended).slice(0, 300));
    const save = await post('api/api/inventory/save', { characterId: id, slots: inv.filter((s) => s.slot_index < 24).map((s) => ({ slot_index: s.slot_index, item_id: s.item_id, quantity: s.quantity, equipped: 0 })) }, H);
    assert.equal(save.status, 200, 'bag-only save with gear equipped: ' + save.status);
    const after = await bag();
    assert.equal(PARTS.every((p) => after.find((s) => s.item_id === `set_gravecaller_ascended_${p}`)?.slot_index === RESERVED[p]), true, 'equipped gear survives a bag-only save');
    console.log('live armor API OK');
  } finally {
    const [[account]] = await db.execute('SELECT id FROM accounts WHERE username=?', [username]);
    if (account) {
      await db.beginTransaction();
      const [characters] = await db.execute('SELECT id FROM characters WHERE account_id=?', [account.id]);
      for (const c of characters) {
        for (const t of ['character_combat_stats', 'character_gear', 'character_quest_objectives', 'character_quests', 'character_talents', 'combat_sessions', 'gold_transactions', 'hero_mastery', 'inventory', 'item_instance', 'professions', 'character_necro_progress', 'character_chronicle', 'character_runs']) {
          try { await db.query('DELETE FROM ?? WHERE character_id=?', [t, c.id]); } catch (e) { if (e.code !== 'ER_NO_SUCH_TABLE') throw e; }
        }
        await db.execute('DELETE FROM characters WHERE id=? AND account_id=?', [c.id, account.id]);
      }
      await db.execute('DELETE FROM accounts WHERE id=? AND username=?', [account.id, username]);
      await db.commit();
      console.log('Temporary account removed.');
    }
    await db.end();
  }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
