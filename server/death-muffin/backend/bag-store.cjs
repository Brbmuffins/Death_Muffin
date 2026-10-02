/**
 * Shared bag and vault storage helpers for vault.cjs and salvage.cjs. All of them run inside the caller's transaction and lock
 * the rows they read (FOR UPDATE), so a vault move, a salvage and a craft can never interleave on the same character.
 */
const gather = require('./gathering/gathering-rules.cjs');
const vaultRules = require('./gathering/vault-rules.cjs');
const { parseAffixes, affix } = require('./loot-instances.cjs');

const num = (v) => Number(v) || 0;

/** Same shape as GET /api/inventory/:id (server.js INV_SELECT uses this too). */
const INV_SELECT = `
  SELECT inv.id, inv.slot_index, inv.quantity, inv.equipped, inv.equipped_slot,
         i.id AS item_id, i.name, i.rarity, i.item_type,
         i.equipment_slot AS item_equipment_slot,
         i.stat_bonus, i.modifiers, i.icon_id, i.sell_value, i.crafted,
         i.stackable, i.max_stack_size,
         inv.instance_id, li.ilvl, li.affixes
  FROM inventory inv
  JOIN items i ON i.id = inv.item_id
  LEFT JOIN loot_instances li ON li.id = inv.instance_id
  WHERE inv.character_id = ?
  ORDER BY inv.slot_index`;

const VAULT_SELECT = `
  SELECT v.slot_index + 1 AS id, v.slot_index, v.quantity, 0 AS equipped, NULL AS equipped_slot,
         i.id AS item_id, i.name, i.rarity, i.item_type,
         i.equipment_slot AS item_equipment_slot,
         i.stat_bonus, i.modifiers, i.icon_id, i.sell_value, i.crafted,
         i.stackable, i.max_stack_size,
         v.instance_id, li.ilvl, li.affixes
  FROM account_vault v
  JOIN items i ON i.id = v.item_id
  LEFT JOIN loot_instances li ON li.id = v.instance_id
  WHERE v.account_id = ?
  ORDER BY v.slot_index`;

/** The rules-row fields of a rolled instance: its id (travels with the row), a sort hint, and what salvage needs. */
function instFields(r) {
  if (!r.instance_id) return {};
  const inst = { ilvl: num(r.ilvl), affixes: parseAffixes(r.affixes) };
  return { inst: num(r.instance_id), power: affix.instancePower(inst), ilvl: inst.ilvl, nAffix: inst.affixes.length };
}

/** The bag rows (slots 0..BAG_SLOTS-1) as rules rows, locked. Equipped rows that sit in a bag slot are `fixed`. */
async function loadBag(conn, characterId) {
  const [rows] = await conn.execute(
    `SELECT inv.slot_index, inv.item_id, inv.quantity, inv.equipped, inv.instance_id, li.ilvl, li.affixes
       FROM inventory inv LEFT JOIN loot_instances li ON li.id = inv.instance_id
      WHERE inv.character_id = ? AND inv.slot_index BETWEEN 0 AND ? ORDER BY inv.slot_index FOR UPDATE`,
    [characterId, gather.BAG_SLOTS - 1],
  );
  return rows.map((r) => ({ slot: num(r.slot_index), itemId: r.item_id, qty: num(r.quantity), ...(num(r.equipped) ? { fixed: true } : {}), ...instFields(r) }));
}

async function loadVault(conn, accountId) {
  const [rows] = await conn.execute(
    `SELECT v.slot_index, v.item_id, v.quantity, v.instance_id, li.ilvl, li.affixes
       FROM account_vault v LEFT JOIN loot_instances li ON li.id = v.instance_id
      WHERE v.account_id = ? ORDER BY v.slot_index FOR UPDATE`,
    [accountId],
  );
  return rows.map((r) => ({ slot: num(r.slot_index), itemId: r.item_id, qty: num(r.quantity), ...instFields(r) }));
}

/** An info(itemId) function for the rules, from the items table. Unknown ids are 1-stack gear-less junk and cannot be moved. */
async function loadInfo(conn, itemIds) {
  const ids = [...new Set(itemIds)];
  const map = new Map();
  if (ids.length) {
    const [rows] = await conn.query('SELECT id, stackable, max_stack_size, item_type, rarity FROM items WHERE id IN (?)', [ids]);
    for (const r of rows) {
      map.set(r.id, { maxStack: num(r.stackable) ? Math.max(1, num(r.max_stack_size) || 1) : 1, itemType: r.item_type, rarity: r.rarity || 'common' });
    }
  }
  return (id) => map.get(id) || { maxStack: 1, itemType: 'material', rarity: 'common' };
}

/** Write the difference between two row lists with the SAME key (slot) into `table`. Deletes first, then updates, then inserts. A row is the same row only if its item AND its instance match. */
async function writeDiff(conn, { table, keyCol, keyVal, before, after, extraCols = '', extraVals = [] }) {
  const old = new Map(before.map((r) => [r.slot, r]));
  const next = new Map(after.map((r) => [r.slot, r]));
  const same = (a, b) => a.itemId === b.itemId && (a.inst ?? null) === (b.inst ?? null);
  for (const [slot, o] of old) {
    const n = next.get(slot);
    if (!n || !same(n, o)) await conn.execute(`DELETE FROM ${table} WHERE ${keyCol} = ? AND slot_index = ?`, [keyVal, slot]);
  }
  for (const [slot, n] of next) {
    const o = old.get(slot);
    if (o && same(o, n) && o.qty !== n.qty) await conn.execute(`UPDATE ${table} SET quantity = ? WHERE ${keyCol} = ? AND slot_index = ?`, [n.qty, keyVal, slot]);
  }
  for (const [slot, n] of next) {
    const o = old.get(slot);
    if (!o || !same(o, n)) {
      await conn.execute(`INSERT INTO ${table} (${keyCol}, slot_index, item_id, quantity, instance_id${extraCols}) VALUES (?, ?, ?, ?, ?${extraVals.map(() => ', ?').join('')})`, [keyVal, slot, n.itemId, n.qty, n.inst ?? null, ...extraVals]);
    }
  }
}

const writeBag = (conn, characterId, before, after) =>
  writeDiff(conn, { table: 'inventory', keyCol: 'character_id', keyVal: characterId, before: before.filter((r) => !r.fixed), after: after.filter((r) => !r.fixed), extraCols: ', equipped, equipped_slot', extraVals: [0, null] });

const writeVault = (conn, accountId, before, after) => writeDiff(conn, { table: 'account_vault', keyCol: 'account_id', keyVal: accountId, before, after });

/** The reply every route sends: the bag exactly as GET /api/inventory/:id, and the vault in the same row shape. */
async function view(conn, characterId, accountId) {
  const [bag] = await conn.execute(INV_SELECT, [characterId]);
  const [vault] = await conn.execute(VAULT_SELECT, [accountId]);
  return { bag, vault };
}

module.exports = { INV_SELECT, VAULT_SELECT, loadBag, loadVault, loadInfo, writeBag, writeVault, view, vaultRules };
