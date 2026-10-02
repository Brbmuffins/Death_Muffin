/**
 * Relic runes: one socket per necromancer rite (rules: gathering/rune-rules.cjs, generated from src/gameplay/runeRules.ts).
 * A socketed rune is a reserved inventory row (slot 130 + the rite's index, `equipped = 1, equipped_slot = 'rune_<rite>'`), the same way the
 * tool belt and the Legion kit are kept, so bag saves, crafting, selling, salvage and the Vault never see it and the live
 * UNIQUE (character_id, equipped_slot) key makes "one rune per rite" a database fact. No table was added (the proposal's
 * character_rune_sockets is not needed).
 *
 *   POST /api/inventory/rune -> { characterId, rite, itemId }
 *     itemId set:  one rune of that id moves from the bag into the rite's socket. A rune already in the socket goes back to the bag
 *                  (onto a stack, or into the first free slot, which includes the one just emptied), so a swap never needs room.
 *     itemId null: the socketed rune returns to the bag, or the call is refused ("bag is full").
 *   Answers the bag in the GET /api/inventory/:id shape (socket rows included, like equipped gear, the belt and the kit).
 *
 * One transaction, every row of the character locked FOR UPDATE, like /api/inventory/kit. The client wraps it in Inventory.exclusive().
 */
const gather = require('./gathering/gathering-rules.cjs');
const rune = require('./gathering/rune-rules.cjs');
const store = require('./bag-store.cjs');

const playerError = (message) => Object.assign(new Error(message), { player: true });

/** Put one rune back in the bag: onto a stack with room, else the first free bag slot. Mutates the maps; throws if there is no room. */
async function giveBack(conn, characterId, itemId, bySlot, maxStack) {
  for (let i = 0; i < gather.BAG_SLOTS; i++) {
    const r = bySlot.get(i);
    if (r && r.item_id === itemId && !Number(r.equipped) && r.instance_id == null && Number(r.quantity) < maxStack) {
      await conn.execute('UPDATE inventory SET quantity = quantity + 1 WHERE id = ?', [r.id]);
      r.quantity = Number(r.quantity) + 1;
      return;
    }
  }
  for (let i = 0; i < gather.BAG_SLOTS; i++) {
    if (!bySlot.has(i)) {
      const [res] = await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, 1, 0, NULL)', [characterId, i, itemId]);
      bySlot.set(i, { id: res.insertId, slot_index: i, item_id: itemId, quantity: 1, equipped: 0, instance_id: null });
      return;
    }
  }
  throw playerError('Your bag is full. Make room, then take the rune out.');
}

/** The core, on a connection inside the caller's transaction. Throws playerError for refusals. */
async function setRune(conn, characterId, rite, itemId) {
  if (!rune.isRuneRite(rite)) throw playerError('That is not a rite that takes a rune.');
  if (itemId !== null && !rune.runeFits(itemId, rite)) throw playerError(rune.isRuneId(itemId) ? "That rune doesn't fit this rite." : 'That is not a rune.');
  const [rows] = await conn.execute('SELECT id, slot_index, item_id, quantity, equipped, instance_id FROM inventory WHERE character_id = ? FOR UPDATE', [characterId]);
  const bySlot = new Map(rows.map((r) => [Number(r.slot_index), r]));
  const socketSlot = rune.runeSlotIndex(rite);
  const current = bySlot.get(socketSlot);
  const info = await store.loadInfo(conn, [itemId, current && current.item_id].filter(Boolean));

  if (itemId === null) {
    if (!current) throw playerError('That socket is empty.');
    await conn.execute('DELETE FROM inventory WHERE id = ?', [current.id]);
    bySlot.delete(socketSlot);
    await giveBack(conn, characterId, current.item_id, bySlot, info(current.item_id).maxStack);
    return;
  }
  if (current && current.item_id === itemId) return; // already there
  let from = null;
  for (let i = 0; i < gather.BAG_SLOTS && !from; i++) {
    const r = bySlot.get(i);
    if (r && r.item_id === itemId && !Number(r.equipped) && r.instance_id == null && Number(r.quantity) > 0) from = r;
  }
  if (!from) throw playerError("You don't have that rune.");
  if (Number(from.quantity) > 1) {
    await conn.execute('UPDATE inventory SET quantity = quantity - 1 WHERE id = ?', [from.id]);
    from.quantity = Number(from.quantity) - 1;
  } else {
    await conn.execute('DELETE FROM inventory WHERE id = ?', [from.id]);
    bySlot.delete(Number(from.slot_index));
  }
  if (current) {
    await conn.execute('DELETE FROM inventory WHERE id = ?', [current.id]);
    bySlot.delete(socketSlot);
    await giveBack(conn, characterId, current.item_id, bySlot, info(current.item_id).maxStack);
  }
  await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, 1, 1, ?)', [characterId, socketSlot, itemId, rune.runeEquippedSlot(rite)]);
}

module.exports = function mountRunes(app, pool, { requireAuth, ownsCharacter }) {
  app.post('/api/inventory/rune', requireAuth, async (req, res) => {
    const body = req.body || {};
    const id = parseInt(body.characterId, 10);
    if (!id || typeof body.rite !== 'string' || (body.itemId !== null && typeof body.itemId !== 'string')) return res.status(400).json({ success: false, error: 'characterId, rite and itemId (or null) required' });
    if (!(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      await setRune(conn, id, body.rite, body.itemId);
      await conn.commit();
      const [data] = await conn.execute(store.INV_SELECT, [id]);
      res.json({ success: true, data });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error(`POST /api/inventory/rune char#${id}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};
module.exports.setRune = setRune;
