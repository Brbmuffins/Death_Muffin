/**
 * The Legion kit (thrall gear): two reserved inventory slots (legion-rules KIT_BASE.. = 120 weapon, 121 armour), one spare piece
 * each, outside the 48-slot bag. A kit row is `equipped = 1, equipped_slot = 'kit_<id>'`, so bag saves (inventory-save.cjs),
 * crafting, selling, salvage and the Vault never see it, the same way they never see the tool belt. The thralls wear it; the bonus is
 * computed on the client from the row (legion-rules.cjs), so nothing here changes combat.
 *
 *   POST /api/inventory/kit -> { characterId, slot_index, equipped }
 *     equipped 1: slot_index is a BAG slot holding a weapon / off-hand (weapon slot) or one of the five armour pieces (armour slot);
 *                 it moves to that kit slot. A piece already there swaps back into the bag slot just freed (a swap never needs space).
 *     equipped 0: slot_index is a KIT slot; the piece returns to the first free bag slot, or the call is refused ("bag is full").
 *   Answers the bag in the GET /api/inventory/:id shape (kit rows included, like equipped gear and the belt).
 *
 * One transaction, every row of the character locked FOR UPDATE, like /api/inventory/equip and /api/inventory/belt. The client wraps it
 * in Inventory.exclusive(). A rolled piece keeps its loot_instances row (the instance id travels with the inventory row), so its item
 * level and affixes survive the trip.
 */
const gather = require('./gathering/gathering-rules.cjs');
const legion = require('./gathering/legion-rules.cjs');
const store = require('./bag-store.cjs');

const playerError = (message) => Object.assign(new Error(message), { player: true });

/** Pure-ish core on a connection inside the caller's transaction. Throws playerError for refusals. */
async function moveKit(conn, characterId, slotIndex, equipped) {
  const [rows] = await conn.execute('SELECT id, slot_index, item_id FROM inventory WHERE character_id = ? FOR UPDATE', [characterId]);
  const bySlot = new Map(rows.map((r) => [Number(r.slot_index), r]));
  const row = bySlot.get(slotIndex);
  if (equipped) {
    if (!(slotIndex >= 0 && slotIndex < gather.BAG_SLOTS)) throw playerError('Pick a piece from your bag.');
    if (!row) throw playerError('There is nothing in that slot.');
    const info = await store.loadInfo(conn, [row.item_id]);
    const kit = legion.kitIdForType(info(row.item_id).itemType);
    if (!kit) throw playerError('The legion wears weapons and armour only.');
    const target = legion.kitSlotIndex(kit);
    const other = bySlot.get(target);
    if (other) {
      // Park the old (and free its equipped_slot name: the live table has UNIQUE (character_id, equipped_slot)) kit piece out of the unique key, seat the new one, then put the old one in the freed bag slot.
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [-1000000 - Number(other.id), other.id]);
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 1, equipped_slot = ? WHERE id = ?', [target, legion.kitEquippedSlot(kit), row.id]);
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [slotIndex, other.id]);
    } else {
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 1, equipped_slot = ? WHERE id = ?', [target, legion.kitEquippedSlot(kit), row.id]);
    }
  } else {
    if (!legion.isKitSlot(slotIndex)) throw playerError('That is not a legion slot.');
    if (!row) throw playerError('The legion slot is empty.');
    let free = -1;
    for (let i = 0; i < gather.BAG_SLOTS; i++) if (!bySlot.has(i)) { free = i; break; }
    if (free < 0) throw playerError('Your bag is full. Make room, then take the piece off the legion.');
    await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [free, row.id]);
  }
}

module.exports = function mountThrallKit(app, pool, { requireAuth, ownsCharacter }) {
  app.post('/api/inventory/kit', requireAuth, async (req, res) => {
    const body = req.body || {};
    const id = parseInt(body.characterId, 10);
    const slotIndex = Number(body.slot_index);
    if (!id || !Number.isInteger(slotIndex) || body.equipped === undefined) return res.status(400).json({ success: false, error: 'characterId, slot_index and equipped required' });
    if (!(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      await moveKit(conn, id, slotIndex, !!Number(body.equipped));
      await conn.commit();
      const [data] = await conn.execute(store.INV_SELECT, [id]);
      res.json({ success: true, data });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error(`POST /api/inventory/kit char#${id}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};
module.exports.moveKit = moveKit;
