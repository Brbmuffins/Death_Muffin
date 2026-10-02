/**
 * An in-memory stand-in for the tables vault.cjs, salvage.cjs and inventory-save.cjs touch, dispatched on the SQL text, with real
 * transaction rollback. Test helper only (not a test file).
 */
const ITEMS = {
  staff_oak: { type: 'weapon', rarity: 'common', stack: 1 },
  helm_iron: { type: 'armor_head', rarity: 'uncommon', stack: 1 },
  staff_moon: { type: 'weapon', rarity: 'epic', stack: 1 },
  wand_iron: { type: 'weapon', rarity: 'uncommon', stack: 1 },
  helm_copper: { type: 'armor_head', rarity: 'common', stack: 1 },
  ring_copper: { type: 'ring', rarity: 'common', stack: 1 },
  chest_iron: { type: 'armor_chest', rarity: 'rare', stack: 1 },
  grimoire_bone: { type: 'offhand', rarity: 'common', stack: 1 },
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
  tool_hatchet_copper: { type: 'material', rarity: 'common', stack: 1 },
  tool_hatchet_iron: { type: 'material', rarity: 'common', stack: 1 },
  tool_hatchet_steel: { type: 'material', rarity: 'uncommon', stack: 1 },
  tool_pickaxe_copper: { type: 'material', rarity: 'common', stack: 1 },
  tool_rod_copper: { type: 'material', rarity: 'common', stack: 1 },
  tool_spade_copper: { type: 'material', rarity: 'common', stack: 1 },
};

function fakeDb({ bag = [], vault = [], equipped = [], level = 1, xp = 0, loot = [], charLevel = 10, extra = null } = {}) {
  let inv = [
    ...bag.map((b, i) => ({ id: i + 1, equipped: 0, equipped_slot: null, character_id: 1, ...b })),
    ...equipped.map((e, i) => ({ id: 800 + i, equipped: 1, equipped_slot: e.equipped_slot || 'main_hand', character_id: 1, ...e })),
  ];
  let vlt = vault.map((v) => ({ account_id: 7, ...v }));
  // loot_instances: { id, account_id, item_id, ilvl, affixes, created_at }. inventory/account_vault rows point at them with instance_id.
  let lootRows = loot.map((l) => ({ account_id: 7, ilvl: 5, affixes: [], created_at: Date.now(), ...l }));
  let nextLoot = 1000;
  // One UNIQUE key per table (uq_inventory_instance, uq_account_vault_instance); cross-table duplicates are the application's to prevent.
  const uniqueInstance = (id, self, rows) => {
    if (id == null) return;
    if ((rows === 'vlt' ? vlt : inv).some((r) => r !== self && r.instance_id === id)) throw new Error('Duplicate entry for instance_id');
  };
  const dropInstance = (id) => {
    lootRows = lootRows.filter((l) => l.id !== id);
    for (const r of [...inv, ...vlt]) if (r.instance_id === id) r.instance_id = null; // ON DELETE SET NULL
  };
  let prof = { level, xp, exists: level > 1 || xp > 0 };
  const calls = [];

  const joined = (r) => {
    const m = ITEMS[r.item_id] || { type: 'material', rarity: 'common', stack: 1 };
    const li = r.instance_id ? lootRows.find((l) => l.id === r.instance_id) : null;
    return { slot_index: r.slot_index, quantity: r.quantity, item_id: r.item_id, name: r.item_id, rarity: m.rarity, item_type: m.type, equipped: r.equipped || 0, instance_id: r.instance_id ?? null, ilvl: li ? li.ilvl : null, affixes: li ? li.affixes : null };
  };
  const withLoot = (r) => {
    const li = r.instance_id ? lootRows.find((l) => l.id === r.instance_id) : null;
    return { ...r, instance_id: r.instance_id ?? null, ilvl: li ? li.ilvl : null, affixes: li ? li.affixes : null };
  };

  const execute = async (sql, p = []) => {
    sql = sql.trim();
    calls.push(sql.split('\n')[0].slice(0, 60));
    if (sql.startsWith('SELECT inv.slot_index, inv.item_id, inv.quantity, inv.equipped, inv.instance_id')) return [inv.filter((r) => r.character_id === p[0] && r.slot_index >= 0 && r.slot_index <= p[1]).sort((a, b) => a.slot_index - b.slot_index).map(withLoot)];
    // The tool belt (tool-belt.cjs): lock every row, then move rows by id (the unique key is character + slot).
    if (sql.startsWith('SELECT id, slot_index, item_id FROM inventory')) return [inv.filter((r) => r.character_id === p[0]).map((r) => ({ ...r }))];
    if (sql.startsWith('UPDATE inventory SET slot_index = ?')) {
      const row = inv.find((r) => r.id === p[p.length - 1]);
      if (inv.some((r) => r !== row && r.character_id === row.character_id && r.slot_index === p[0])) throw new Error('Duplicate entry for uq_char_slot');
      // The live table also has UNIQUE (character_id, equipped_slot): a name can be held by one row at a time (NULLs are free).
      if (sql.includes('equipped = 1') && p[1] != null && inv.some((r) => r !== row && r.character_id === row.character_id && r.equipped_slot === p[1])) throw new Error('Duplicate entry for uq_inventory_equipped_slot');
      row.slot_index = p[0];
      if (sql.includes('equipped = 1')) Object.assign(row, { equipped: 1, equipped_slot: p[1] });
      else if (sql.includes('equipped = 0')) Object.assign(row, { equipped: 0, equipped_slot: null });
      return [{}];
    }
    if (sql.startsWith('SELECT slot_index, item_id, quantity, equipped, equipped_slot, instance_id FROM inventory')) return [inv.filter((r) => r.character_id === p[0]).map((r) => ({ ...r }))];
    if (sql.startsWith('SELECT v.slot_index, v.item_id, v.quantity, v.instance_id')) return [vlt.filter((r) => r.account_id === p[0]).sort((a, b) => a.slot_index - b.slot_index).map(withLoot)];
    if (sql.includes('FROM inventory inv')) return [inv.filter((r) => r.character_id === p[0]).sort((a, b) => a.slot_index - b.slot_index).map(joined)];
    if (sql.includes('FROM account_vault v')) return [vlt.filter((r) => r.account_id === p[0]).sort((a, b) => a.slot_index - b.slot_index).map(joined)];
    if (sql.startsWith('DELETE FROM inventory WHERE character_id = ? AND slot_index = ?')) { inv = inv.filter((r) => !(r.character_id === p[0] && r.slot_index === p[1])); return [{}]; }
    if (sql.startsWith('UPDATE inventory SET quantity = ?')) { inv.find((r) => r.character_id === p[1] && r.slot_index === p[2]).quantity = p[0]; return [{}]; }
    if (sql.startsWith('INSERT INTO inventory (character_id, slot_index, item_id, quantity, instance_id, equipped, equipped_slot) VALUES (?, ?, ?, ?, ?, ?, ?)')) {
      if (inv.some((r) => r.character_id === p[0] && r.slot_index === p[1])) throw new Error('Duplicate entry for uq_char_slot');
      uniqueInstance(p[4], null, 'inv');
      inv.push({ id: 5000 + inv.length, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], instance_id: p[4], equipped: p[5], equipped_slot: p[6] });
      return [{}];
    }
    if (sql.startsWith('UPDATE inventory SET instance_id = NULL WHERE character_id = ?')) {
      for (const r of inv) if (r.character_id === p[0] && r.slot_index >= 0 && r.slot_index <= p[1]) r.instance_id = null;
      return [{}];
    }
    if (sql.startsWith('SELECT account_id, level FROM characters')) return [[{ account_id: 7, level: charLevel }]];
    if (sql.startsWith('INSERT INTO loot_instances')) {
      const row = { id: nextLoot++, account_id: p[0], item_id: p[1], ilvl: p[2], affixes: JSON.parse(p[3]), created_at: Date.now() };
      lootRows.push(row);
      return [{ insertId: row.id }];
    }
    if (sql.startsWith('SELECT COUNT(*) AS n FROM loot_instances')) {
      return [[{ n: lootRows.filter((l) => l.account_id === p[0] && !inv.some((r) => r.instance_id === l.id) && !vlt.some((r) => r.instance_id === l.id)).length }]];
    }
    if (sql.startsWith('DELETE li FROM loot_instances li')) {
      const old = Date.now() - 2 * 86400000;
      for (const l of [...lootRows]) if (l.account_id === p[0] && l.created_at < old && !inv.some((r) => r.instance_id === l.id) && !vlt.some((r) => r.instance_id === l.id)) dropInstance(l.id);
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
      uniqueInstance(p[4], row, 'inv');
      if (row) Object.assign(row, { item_id: p[2], quantity: p[3], instance_id: p[4], equipped: p[5], equipped_slot: p[6] });
      else inv.push({ id: 6000 + inv.length, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], instance_id: p[4], equipped: p[5], equipped_slot: p[6] });
      return [{}];
    }
    if (sql.startsWith('DELETE FROM account_vault')) { vlt = vlt.filter((r) => !(r.account_id === p[0] && r.slot_index === p[1])); return [{}]; }
    if (sql.startsWith('UPDATE account_vault SET quantity')) { vlt.find((r) => r.account_id === p[1] && r.slot_index === p[2]).quantity = p[0]; return [{}]; }
    if (sql.startsWith('INSERT INTO account_vault')) {
      if (vlt.some((r) => r.account_id === p[0] && r.slot_index === p[1])) throw new Error('Duplicate entry for PRIMARY');
      uniqueInstance(p[4], null, 'vlt');
      vlt.push({ account_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], instance_id: p[4] });
      return [{}];
    }
    // The delete route's relic cleanup (server.js) and the single-id delete used by tests.
    if (sql.startsWith('DELETE FROM loot_instances WHERE id = ?')) { dropInstance(p[0]); return [{}]; }
    if (sql.startsWith('INSERT IGNORE INTO professions')) { prof.exists = true; return [{}]; }
    if (sql.startsWith('SELECT skill_level')) return [[{ skill_level: prof.level, skill_xp: prof.xp }]];
    if (sql.startsWith('UPDATE professions')) { prof = { ...prof, level: p[0], xp: p[1] }; return [{}]; }
    if (extra) { const r = extra(sql, p); if (r) return r; }
    throw new Error(`unexpected SQL: ${sql.slice(0, 90)}`);
  };
  const query = async (sql, p) => {
    sql = sql.trim();
    if (sql.startsWith('SELECT id, account_id, item_id FROM loot_instances')) return [lootRows.filter((l) => p[0].includes(l.id)).map((l) => ({ ...l }))];
    if (sql.startsWith('SELECT instance_id, character_id, slot_index FROM inventory')) return [inv.filter((r) => p[0].includes(r.instance_id)).map((r) => ({ instance_id: r.instance_id, character_id: r.character_id, slot_index: r.slot_index }))];
    if (sql.startsWith('SELECT instance_id FROM account_vault')) return [vlt.filter((r) => p[0].includes(r.instance_id)).map((r) => ({ instance_id: r.instance_id }))];
    if (sql.startsWith('DELETE FROM loot_instances WHERE id IN')) { for (const id of p[0]) dropInstance(id); return [{}]; }
    if (sql.startsWith('SELECT id, item_type, rarity FROM items')) return [p[0].filter((id) => ITEMS[id]).map((id) => ({ id, item_type: ITEMS[id].type, rarity: ITEMS[id].rarity }))];
    if (sql.startsWith('SELECT id, stackable')) return [p[0].filter((id) => ITEMS[id]).map((id) => ({ id, stackable: ITEMS[id].stack > 1 ? 1 : 0, max_stack_size: ITEMS[id].stack, item_type: ITEMS[id].type, rarity: ITEMS[id].rarity }))];
    if (extra) { const r = extra(sql, p); if (r) return r; }
    throw new Error(`unexpected query: ${sql.slice(0, 80)}`);
  };
  let snap = null;
  const conn = {
    execute, query, release: () => {},
    beginTransaction: async () => { snap = { inv: JSON.parse(JSON.stringify(inv)), vlt: JSON.parse(JSON.stringify(vlt)), prof: { ...prof }, loot: JSON.parse(JSON.stringify(lootRows)) }; },
    commit: async () => { snap = null; },
    rollback: async () => { if (snap) { inv = snap.inv; vlt = snap.vlt; prof = snap.prof; lootRows = snap.loot; snap = null; } },
  };
  return {
    get inv() { return inv; }, get vault() { return vlt; }, get prof() { return prof; }, get loot() { return lootRows; }, calls, conn,
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
