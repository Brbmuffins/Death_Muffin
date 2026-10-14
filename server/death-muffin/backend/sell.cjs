'use strict';
/**
 * Selling (DECISIONS B23): the server takes the items out of the bag and pays their price itself, an affixed piece at its affixed price
 * (affixRules instanceSellValue, what the Reliquary shows). It used to be the client's sum, saved as a new gold total.
 *
 *   POST /api/inventory/sell { characterId, items: [{ slot_index, quantity }] } -> { sold, gold, goldTotal, bag }
 *
 * Bag slots only (0..BAG_SLOTS-1), never worn gear; the whole sale is refused, changing nothing, if any line is not in the bag.
 */
const gather = require('./gathering/gathering-rules.cjs');
const affix = require('./gathering/affix-rules.cjs');
const store = require('./loot-instances.cjs');
const { INV_SELECT } = require('./bag-store.cjs');

const BAG = gather.BAG_SLOTS;
const MAX_LINES = BAG;
const num = (v) => Number(v) || 0;
const playerError = (message) => Object.assign(new Error(message), { player: true });

async function sellItems(pool, { characterId, items }) {
  if (!Array.isArray(items) || !items.length || items.length > MAX_LINES) throw playerError('Nothing to sell.');
  const want = new Map();
  for (const it of items) {
    const slot = Math.trunc(num(it && it.slot_index));
    const qty = Math.trunc(num(it && it.quantity));
    if (slot < 0 || slot >= BAG || qty < 1 || want.has(slot)) throw playerError('That sale could not be made.');
    want.set(slot, qty);
  }
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [rows] = await conn.execute(
      `SELECT inv.id, inv.slot_index, inv.item_id, inv.quantity, inv.equipped, inv.instance_id, i.sell_value, li.ilvl, li.affixes
         FROM inventory inv JOIN items i ON i.id = inv.item_id LEFT JOIN loot_instances li ON li.id = inv.instance_id
        WHERE inv.character_id = ? AND inv.slot_index BETWEEN 0 AND ? FOR UPDATE`, [characterId, BAG - 1]);
    const bySlot = new Map(rows.map((r) => [num(r.slot_index), r]));
    let gold = 0;
    let sold = 0;
    const gone = [];
    for (const [slot, qty] of want) {
      const r = bySlot.get(slot);
      if (!r || num(r.equipped) || qty > num(r.quantity)) throw playerError('That item is no longer in your bag.');
      const inst = r.instance_id != null ? { ilvl: num(r.ilvl), affixes: store.parseAffixes(r.affixes) } : null;
      gold += Math.max(0, Math.floor(affix.instanceSellValue(num(r.sell_value), inst))) * qty;
      sold += qty;
      if (qty === num(r.quantity)) {
        await conn.execute('DELETE FROM inventory WHERE id = ?', [r.id]);
        if (r.instance_id != null) gone.push(num(r.instance_id));
      } else {
        await conn.execute('UPDATE inventory SET quantity = quantity - ? WHERE id = ?', [qty, r.id]);
      }
    }
    if (gone.length) await store.deleteInstances(conn, gone);
    await conn.execute('UPDATE characters SET gold = LEAST(2147483647, gold + ?) WHERE id = ?', [gold, characterId]);
    const [[g]] = await conn.execute('SELECT gold FROM characters WHERE id = ?', [characterId]);
    await conn.commit();
    const [bag] = await pool.execute(INV_SELECT, [characterId]);
    return { sold, gold, goldTotal: num(g && g.gold), bag };
  } catch (err) {
    await conn.rollback().catch(() => {});
    throw err;
  } finally {
    conn.release();
  }
}

module.exports = function mountSell(app, pool, { requireAuth, ownsCharacter, limiter }) {
  app.post('/api/inventory/sell', ...(limiter ? [limiter] : []), requireAuth, async (req, res) => {
    const id = parseInt(req.body && req.body.characterId, 10);
    try {
      // Ownership first, on its own pooled query (the same rule as loot.cjs / reforge.cjs).
      if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      res.json({ success: true, data: await sellItems(pool, { characterId: id, items: req.body.items }) });
    } catch (err) {
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error(`POST /api/inventory/sell: ${err.code || err.message}`);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    }
  });
};
module.exports.sellItems = sellItems;
