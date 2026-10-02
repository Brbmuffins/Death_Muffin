/**
 * Bag saves from the client (POST /api/inventory/save), kept out of server.js so the stale-client rule is testable.
 *
 * The client saves its whole bag and the server deletes bag rows missing from the payload. A browser tab still running the
 * old 24-slot client sends only slots 0-23 and no `bagSize`: it must never be able to delete slots 24 and up, so a save only
 * ever deletes and replaces within 0..bagSize-1, where bagSize defaults to 24 when absent.
 */
const gather = require('./gathering/gathering-rules.cjs');
const { SaveRefusal, deleteInstances } = require('./loot-instances.cjs');

const LEGACY_BAG_SLOTS = 24;

/** The bag size a save speaks for: current clients send BAG_SLOTS, a stale tab sends nothing (24). null = invalid. */
function saveBagSize(raw) {
  if (raw === undefined || raw === null) return LEGACY_BAG_SLOTS;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 && n <= gather.BAG_SLOTS ? n : null;
}

/** Player-readable problem with a save's slot list, or null. `slots` already excludes the reserved equipment rows. */
function slotProblem(slots, bagSize) {
  const indexes = slots.map((s) => parseInt(s.slot_index, 10));
  if (slots.length > bagSize) return `inventory cannot exceed ${bagSize} slots`;
  if (indexes.some((n) => isNaN(n) || n < 0 || n >= bagSize)) return `each slot_index must be between 0 and ${bagSize - 1}`;
  if (new Set(indexes).size !== indexes.length) return 'duplicate slot_index values are not allowed';
  return null;
}

const CANT_VERIFY = 'One of your relics could not be verified. Reload the game to refresh your Reliquary.';

/**
 * Which rolled instance each incoming slot refers to. A save can only NAME an instance (`instance_id`); it can never carry affixes.
 * Every named instance must exist, belong to this account, match the slot's item, be unique in the payload, and not be held by anything
 * outside the bag range being replaced (another character, an equipped slot, the Vault). Anything else is refused and nothing is written.
 *
 * A slot that omits `instance_id` entirely (a stale tab from before affixes) keeps the instance already on that slot when the item is
 * the same; an explicit null (or a different item) detaches it, and a detached instance is deleted: a sold or thrown-away relic
 * cannot be brought back by a later save.
 */
async function resolveInstances(conn, accountId, characterId, slots, existingBySlot, bagSize) {
  const out = new Map(); // slot_index -> instance id
  const claimed = new Set();
  for (const s of slots) {
    const slot = Number(s.slot_index);
    let id = null;
    if (s.instance_id === undefined) {
      const ex = existingBySlot.get(slot);
      if (ex && ex.instance_id && ex.item_id === s.item_id) id = Number(ex.instance_id);
    } else if (s.instance_id !== null) {
      id = Number(s.instance_id);
      if (!Number.isInteger(id) || id < 1) throw new SaveRefusal(CANT_VERIFY);
    }
    if (id === null) continue;
    if (claimed.has(id)) throw new SaveRefusal(CANT_VERIFY);
    if (Number(s.quantity ?? 1) !== 1) throw new SaveRefusal(CANT_VERIFY);
    claimed.add(id);
    out.set(slot, id);
  }
  if (claimed.size) {
    const ids = [...claimed];
    const [rows] = await conn.query('SELECT id, account_id, item_id FROM loot_instances WHERE id IN (?) FOR UPDATE', [ids]);
    const known = new Map(rows.map((r) => [Number(r.id), r]));
    for (const s of slots) {
      const id = out.get(Number(s.slot_index));
      if (id === undefined) continue;
      const row = known.get(id);
      if (!row || Number(row.account_id) !== Number(accountId) || row.item_id !== s.item_id) throw new SaveRefusal(CANT_VERIFY);
    }
    const [inBags] = await conn.query('SELECT instance_id, character_id, slot_index FROM inventory WHERE instance_id IN (?)', [ids]);
    for (const r of inBags) {
      const mine = Number(r.character_id) === Number(characterId) && Number(r.slot_index) >= 0 && Number(r.slot_index) < bagSize;
      if (!mine) throw new SaveRefusal(CANT_VERIFY);
    }
    const [inVault] = await conn.query('SELECT instance_id FROM account_vault WHERE instance_id IN (?)', [ids]);
    if (inVault.length) throw new SaveRefusal(CANT_VERIFY);
  }
  return { bySlot: out, claimed };
}

/**
 * Replace the bag rows 0..bagSize-1 with `slots` (inside the caller's transaction). Slots above bagSize are never touched.
 * `guard` (optional, authority.cjs) sees the rows the bag holds and the slots sent, and may return fewer units of an item it does not
 * believe; it never adds anything. Returns { notice } (a player-readable sentence, '' when the save was taken whole).
 */
async function replaceBag(conn, characterId, slots, bagSize, accountId, guard) {
  const [existingRows] = await conn.execute('SELECT slot_index, item_id, quantity, equipped, equipped_slot, instance_id FROM inventory WHERE character_id = ?', [characterId]);
  let notice = '';
  if (guard) {
    const checked = await guard(existingRows, slots);
    slots = checked.slots;
    notice = checked.message || '';
  }
  const incoming = slots.map((s) => parseInt(s.slot_index, 10));
  const existingBySlot = new Map(existingRows.map((row) => [Number(row.slot_index), row]));
  const { bySlot, claimed } = await resolveInstances(conn, accountId, characterId, slots, existingBySlot, bagSize);
  // Instances on this bag's rows that the save no longer names are gone (sold, dropped): delete them, not just detach.
  const detached = existingRows
    .filter((r) => r.instance_id && Number(r.slot_index) >= 0 && Number(r.slot_index) < bagSize && !claimed.has(Number(r.instance_id)))
    .map((r) => Number(r.instance_id));
  if (incoming.length > 0) {
    const ph = incoming.map(() => '?').join(',');
    await conn.execute(
      `DELETE FROM inventory
        WHERE character_id = ? AND slot_index BETWEEN 0 AND ?
          AND slot_index NOT IN (${ph})`,
      [characterId, bagSize - 1, ...incoming],
    );
  } else {
    await conn.execute('DELETE FROM inventory WHERE character_id = ? AND slot_index BETWEEN 0 AND ?', [characterId, bagSize - 1]);
  }
  // Two pieces may swap slots in one save: free every instance link in the bag range first (the key is unique), then set them.
  await conn.execute('UPDATE inventory SET instance_id = NULL WHERE character_id = ? AND slot_index BETWEEN 0 AND ? AND instance_id IS NOT NULL', [characterId, bagSize - 1]);
  for (const s of slots) {
    const existing = existingBySlot.get(Number(s.slot_index));
    const preserveEquipment = existing && existing.item_id === s.item_id;
    await conn.execute(
      `INSERT INTO inventory
         (character_id, slot_index, item_id, quantity, instance_id, equipped, equipped_slot)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE item_id=VALUES(item_id), quantity=VALUES(quantity), instance_id=VALUES(instance_id),
         equipped=VALUES(equipped), equipped_slot=VALUES(equipped_slot)`,
      [characterId, s.slot_index, s.item_id, s.quantity ?? 1, bySlot.get(Number(s.slot_index)) ?? null, preserveEquipment && existing.equipped ? 1 : 0, preserveEquipment ? existing.equipped_slot : null],
    );
  }
  await deleteInstances(conn, detached);
  return { notice };
}

module.exports = { LEGACY_BAG_SLOTS, saveBagSize, slotProblem, replaceBag, resolveInstances, CANT_VERIFY };
