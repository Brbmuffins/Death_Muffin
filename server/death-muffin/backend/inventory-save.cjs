/**
 * Bag saves from the client (POST /api/inventory/save), kept out of server.js so the stale-client rule is testable.
 *
 * The client saves its whole bag and the server deletes bag rows missing from the payload. A browser tab still running the
 * old 24-slot client sends only slots 0-23 and no `bagSize`: it must never be able to delete slots 24 and up, so a save only
 * ever deletes and replaces within 0..bagSize-1, where bagSize defaults to 24 when absent.
 */
const gather = require('./gathering/gathering-rules.cjs');

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

/** Replace the bag rows 0..bagSize-1 with `slots` (inside the caller's transaction). Slots above bagSize are never touched. */
async function replaceBag(conn, characterId, slots, bagSize) {
  const incoming = slots.map((s) => parseInt(s.slot_index, 10));
  const [existingRows] = await conn.execute('SELECT slot_index, item_id, equipped, equipped_slot FROM inventory WHERE character_id = ?', [characterId]);
  const existingBySlot = new Map(existingRows.map((row) => [Number(row.slot_index), row]));
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
  for (const s of slots) {
    const existing = existingBySlot.get(Number(s.slot_index));
    const preserveEquipment = existing && existing.item_id === s.item_id;
    await conn.execute(
      `INSERT INTO inventory
         (character_id, slot_index, item_id, quantity, equipped, equipped_slot)
       VALUES (?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE item_id=VALUES(item_id), quantity=VALUES(quantity),
         equipped=VALUES(equipped), equipped_slot=VALUES(equipped_slot)`,
      [characterId, s.slot_index, s.item_id, s.quantity ?? 1, preserveEquipment && existing.equipped ? 1 : 0, preserveEquipment ? existing.equipped_slot : null],
    );
  }
}

module.exports = { LEGACY_BAG_SLOTS, saveBagSize, slotProblem, replaceBag };
