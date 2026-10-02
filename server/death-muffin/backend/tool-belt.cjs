/**
 * The gathering tool belt: four reserved inventory slots (gathering-rules BELT_BASE.. = 110 hatchet, 111 pickaxe, 112 rod,
 * 113 spade), one tool each, outside the 48-slot bag. A belt row is `equipped = 1, equipped_slot = 'belt_<kind>'`, so bag saves
 * (inventory-save.cjs), crafting, selling, salvage and the Vault never see it. Gathering reads belt + bag (gathering-routes.cjs).
 *
 *   POST /api/inventory/belt -> { characterId, slot_index, equipped }
 *     equipped 1: slot_index is a BAG slot holding a tool; it moves to its kind's belt slot. A tool already there swaps back into
 *                 the bag slot just freed (so a swap never needs space).
 *     equipped 0: slot_index is a BELT slot; the tool returns to the first free bag slot, or the call is refused ("bag is full").
 *   Answers the bag in the GET /api/inventory/:id shape (belt rows included, like equipped gear).
 *
 * One transaction, every row of the character locked FOR UPDATE, like /api/inventory/equip. The client wraps it in Inventory.exclusive().
 */
const gather = require('./gathering/gathering-rules.cjs');
const store = require('./bag-store.cjs');

const playerError = (message) => Object.assign(new Error(message), { player: true });

/** Pure-ish core on a connection inside the caller's transaction. Throws playerError for refusals. */
async function moveTool(conn, characterId, slotIndex, equipped) {
  const [rows] = await conn.execute('SELECT id, slot_index, item_id FROM inventory WHERE character_id = ? FOR UPDATE', [characterId]);
  const bySlot = new Map(rows.map((r) => [Number(r.slot_index), r]));
  const row = bySlot.get(slotIndex);
  if (equipped) {
    if (!(slotIndex >= 0 && slotIndex < gather.BAG_SLOTS)) throw playerError('Pick a tool from your bag.');
    if (!row) throw playerError('There is nothing in that slot.');
    const kind = gather.toolKindOf(row.item_id);
    if (!kind) throw playerError('Only gathering tools fit on the belt.');
    const target = gather.BELT_BASE + gather.BELT_KINDS.indexOf(kind);
    const other = bySlot.get(target);
    if (other) {
      // Park the old (and free its equipped_slot name: the live table has UNIQUE (character_id, equipped_slot)) belt tool out of the unique key, seat the new one, then put the old one in the freed bag slot.
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [-1000000 - Number(other.id), other.id]);
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 1, equipped_slot = ? WHERE id = ?', [target, gather.beltEquippedSlot(kind), row.id]);
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [slotIndex, other.id]);
    } else {
      await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 1, equipped_slot = ? WHERE id = ?', [target, gather.beltEquippedSlot(kind), row.id]);
    }
  } else {
    if (!gather.isBeltSlot(slotIndex)) throw playerError('That is not a belt slot.');
    if (!row) throw playerError('The belt slot is empty.');
    let free = -1;
    for (let i = 0; i < gather.BAG_SLOTS; i++) if (!bySlot.has(i)) { free = i; break; }
    if (free < 0) throw playerError('Your bag is full. Make room, then take the tool off the belt.');
    await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [free, row.id]);
  }
}

module.exports = function mountToolBelt(app, pool, { requireAuth, ownsCharacter }) {
  app.post('/api/inventory/belt', requireAuth, async (req, res) => {
    const body = req.body || {};
    const id = parseInt(body.characterId, 10);
    const slotIndex = Number(body.slot_index);
    if (!id || !Number.isInteger(slotIndex) || body.equipped === undefined) return res.status(400).json({ success: false, error: 'characterId, slot_index and equipped required' });
    if (!(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      await moveTool(conn, id, slotIndex, !!Number(body.equipped));
      await conn.commit();
      const [data] = await conn.execute(store.INV_SELECT, [id]);
      res.json({ success: true, data });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error(`POST /api/inventory/belt char#${id}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};
module.exports.moveTool = moveTool;
