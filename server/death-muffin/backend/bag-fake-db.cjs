/**
 * An in-memory stand-in for the tables vault.cjs, salvage.cjs and inventory-save.cjs touch, dispatched on the SQL text, with real
 * transaction rollback. Test helper only (not a test file).
 */
const ITEMS = {
  staff_oak: { type: 'weapon', rarity: 'common', stack: 1 },
  staff_moon: { type: 'weapon', rarity: 'epic', stack: 1 },
  wand_iron: { type: 'weapon', rarity: 'uncommon', stack: 1 },
  helm_copper: { type: 'armor_head', rarity: 'common', stack: 1 },
  ring_copper: { type: 'ring', rarity: 'common', stack: 1 },
  flask_hp_minor: { type: 'consumable', rarity: 'common', stack: 20 },
  ore_copper: { type: 'material', rarity: 'common', stack: 250 },
  log_oak: { type: 'material', rarity: 'common', stack: 250 },
  ingot_copper: { type: 'material', rarity: 'common', stack: 250 },
  ingot_iron: { type: 'material', rarity: 'uncommon', stack: 250 },
  ingot_gold: { type: 'material', rarity: 'rare', stack: 250 },
  plank_oak: { type: 'material', rarity: 'common', stack: 250 },
  plank_willow: { type: 'material', rarity: 'uncommon', stack: 250 },
  plank_blackthorn: { type: 'material', rarity: 'rare', stack: 250 },
  reagent_grave_dust: { type: 'material', rarity: 'common', stack: 250 },
  reagent_wraith_ectoplasm: { type: 'material', rarity: 'uncommon', stack: 250 },
  reagent_plague_bile: { type: 'material', rarity: 'rare', stack: 250 },
  reagent_cinder_ash: { type: 'material', rarity: 'rare', stack: 250 },
  bone_meal: { type: 'material', rarity: 'common', stack: 250 },
};

function fakeDb({ bag = [], vault = [], equipped = [], level = 1, xp = 0 } = {}) {
  let inv = [
    ...bag.map((b, i) => ({ id: i + 1, equipped: 0, equipped_slot: null, character_id: 1, ...b })),
    ...equipped.map((e, i) => ({ id: 800 + i, equipped: 1, equipped_slot: e.equipped_slot || 'main_hand', character_id: 1, ...e })),
  ];
  let vlt = vault.map((v) => ({ account_id: 7, ...v }));
  let prof = { level, xp, exists: level > 1 || xp > 0 };
  const calls = [];

  const joined = (r) => {
    const m = ITEMS[r.item_id] || { type: 'material', rarity: 'common', stack: 1 };
    return { slot_index: r.slot_index, quantity: r.quantity, item_id: r.item_id, name: r.item_id, rarity: m.rarity, item_type: m.type, equipped: r.equipped || 0 };
  };

  const execute = async (sql, p = []) => {
    sql = sql.trim();
    calls.push(sql.split('\n')[0].slice(0, 60));
    if (sql.startsWith('SELECT slot_index, item_id, quantity, equipped FROM inventory')) return [inv.filter((r) => r.slot_index >= 0 && r.slot_index <= p[1]).sort((a, b) => a.slot_index - b.slot_index).map((r) => ({ ...r }))];
    if (sql.startsWith('SELECT slot_index, item_id, equipped, equipped_slot FROM inventory')) return [inv.map((r) => ({ ...r }))];
    if (sql.startsWith('SELECT slot_index, item_id, quantity FROM account_vault')) return [vlt.filter((r) => r.account_id === p[0]).sort((a, b) => a.slot_index - b.slot_index).map((r) => ({ ...r }))];
    if (sql.includes('FROM inventory inv')) return [inv.filter((r) => r.character_id === p[0]).sort((a, b) => a.slot_index - b.slot_index).map(joined)];
    if (sql.includes('FROM account_vault v')) return [vlt.filter((r) => r.account_id === p[0]).sort((a, b) => a.slot_index - b.slot_index).map(joined)];
    if (sql.startsWith('DELETE FROM inventory WHERE character_id = ? AND slot_index = ?')) { inv = inv.filter((r) => !(r.character_id === p[0] && r.slot_index === p[1])); return [{}]; }
    if (sql.startsWith('UPDATE inventory SET quantity = ?')) { inv.find((r) => r.character_id === p[1] && r.slot_index === p[2]).quantity = p[0]; return [{}]; }
    if (sql.startsWith('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, ?, ?, ?)')) {
      if (inv.some((r) => r.character_id === p[0] && r.slot_index === p[1])) throw new Error('Duplicate entry for uq_char_slot');
      inv.push({ id: 5000 + inv.length, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], equipped: p[4], equipped_slot: p[5] });
      return [{}];
    }
    // The bag save (inventory-save.cjs): range delete and upsert.
    if (sql.startsWith('DELETE FROM inventory') && sql.includes('BETWEEN 0 AND ?')) {
      const keep = sql.includes('NOT IN') ? new Set(p.slice(2)) : new Set();
      inv = inv.filter((r) => !(r.character_id === p[0] && r.slot_index >= 0 && r.slot_index <= p[1] && !keep.has(r.slot_index)));
      return [{}];
    }
    if (sql.startsWith('INSERT INTO inventory') && sql.includes('ON DUPLICATE KEY UPDATE')) {
      const row = inv.find((r) => r.character_id === p[0] && r.slot_index === p[1]);
      if (row) Object.assign(row, { item_id: p[2], quantity: p[3], equipped: p[4], equipped_slot: p[5] });
      else inv.push({ id: 6000 + inv.length, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], equipped: p[4], equipped_slot: p[5] });
      return [{}];
    }
    if (sql.startsWith('DELETE FROM account_vault')) { vlt = vlt.filter((r) => !(r.account_id === p[0] && r.slot_index === p[1])); return [{}]; }
    if (sql.startsWith('UPDATE account_vault SET quantity')) { vlt.find((r) => r.account_id === p[1] && r.slot_index === p[2]).quantity = p[0]; return [{}]; }
    if (sql.startsWith('INSERT INTO account_vault')) {
      if (vlt.some((r) => r.account_id === p[0] && r.slot_index === p[1])) throw new Error('Duplicate entry for PRIMARY');
      vlt.push({ account_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3] });
      return [{}];
    }
    if (sql.startsWith('INSERT IGNORE INTO professions')) { prof.exists = true; return [{}]; }
    if (sql.startsWith('SELECT skill_level')) return [[{ skill_level: prof.level, skill_xp: prof.xp }]];
    if (sql.startsWith('UPDATE professions')) { prof = { ...prof, level: p[0], xp: p[1] }; return [{}]; }
    throw new Error(`unexpected SQL: ${sql.slice(0, 90)}`);
  };
  const query = async (sql, p) => {
    if (sql.startsWith('SELECT id, stackable')) return [p[0].filter((id) => ITEMS[id]).map((id) => ({ id, stackable: ITEMS[id].stack > 1 ? 1 : 0, max_stack_size: ITEMS[id].stack, item_type: ITEMS[id].type, rarity: ITEMS[id].rarity }))];
    throw new Error(`unexpected query: ${sql.slice(0, 80)}`);
  };
  let snap = null;
  const conn = {
    execute, query, release: () => {},
    beginTransaction: async () => { snap = { inv: JSON.parse(JSON.stringify(inv)), vlt: JSON.parse(JSON.stringify(vlt)), prof: { ...prof } }; },
    commit: async () => { snap = null; },
    rollback: async () => { if (snap) { inv = snap.inv; vlt = snap.vlt; prof = snap.prof; snap = null; } },
  };
  return {
    get inv() { return inv; }, get vault() { return vlt; }, get prof() { return prof; }, calls, conn,
    pool: { getConnection: async () => conn, execute: (...a) => execute(...a), query },
  };
}

/** Mount a module on a fake express app; returns call(route, { body, params }) -> { status, json }. */
function harness(mount, db, { owned = true, random } = {}) {
  const routes = {};
  const app = { get: (p, _m, h) => (routes[`GET ${p}`] = h), post: (p, _m, h) => (routes[`POST ${p}`] = h) };
  mount(app, db.pool, { requireAuth: () => {}, ownsCharacter: async () => owned, ...(random ? { random } : {}) });
  return async (route, { body, params } = {}) => {
    let status = 200, json;
    await routes[route]({ body, params, method: route.split(' ')[0], path: route, user: { accountId: 7 } }, { status(c) { status = c; return this; }, json(j) { json = j; return this; }, headersSent: false });
    return { status, json };
  };
}

const qty = (rows, id) => rows.filter((r) => r.item_id === id).reduce((n, r) => n + r.quantity, 0);

module.exports = { fakeDb, harness, qty, ITEMS };
