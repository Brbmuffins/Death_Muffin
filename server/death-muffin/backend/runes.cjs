/**
 * Relic runes (rules: gathering/rune-rules.cjs, generated from server/rules/gameplay/runeRules.ts). Owner 2026-10-13: a rune drops as an
 * item, the player clicks Learn on it, and the character knows it for good (table character_runes, migration 044). Each necromancer rite
 * has one socket and takes any learned rune made for it. A socketed rune is a reserved inventory row (slot 130 + the rite's index,
 * `equipped = 1, equipped_slot = 'rune_<rite>'`), the same way the tool belt and the Legion kit are kept, so bag saves, crafting, selling,
 * salvage and the Vault never see it and the live UNIQUE (character_id, equipped_slot) key makes "one rune per rite" a database fact.
 * The socket row is a choice, not an item: putting a rune in or taking it out never touches the bag.
 *
 *   GET  /api/runes/:characterId                -> { success, data: { learned: [rune_id] } }
 *   POST /api/inventory/rune/learn -> { characterId, slot }
 *     Spends one rune from that bag slot and learns it. A rune already learned is refused (the copy stays). When the rite's socket is
 *     empty the new rune goes straight into it. -> { success, data: { bag, learned, rune, socketed } }
 *   POST /api/inventory/rune -> { characterId, rite, itemId }
 *     itemId set:  that learned rune goes into the rite's socket (replacing what was there).
 *     itemId null: the socket is emptied.
 *     -> { success, data: <the bag in the GET /api/inventory/:id shape, socket rows included> }
 *
 * One transaction, every row of the character locked FOR UPDATE, like /api/inventory/kit. The client wraps it in Inventory.exclusive().
 */
const gather = require('./gathering/gathering-rules.cjs');
const rune = require('./gathering/rune-rules.cjs');
const store = require('./bag-store.cjs');

const playerError = (message) => Object.assign(new Error(message), { player: true });

/** The runes a character has learned, in rune order. */
async function learnedOf(conn, characterId, lock = false) {
  const [rows] = await conn.execute(`SELECT rune_id FROM character_runes WHERE character_id = ?${lock ? ' FOR UPDATE' : ''}`, [characterId]);
  const have = new Set(rows.map((r) => r.rune_id));
  return rune.RUNE_IDS.filter((id) => have.has(id));
}

/** The core, on a connection inside the caller's transaction. Throws playerError for refusals. */
async function setRune(conn, characterId, rite, itemId) {
  if (!rune.isRuneRite(rite)) throw playerError('That is not a rite that takes a rune.');
  if (itemId !== null && !rune.runeFits(itemId, rite)) throw playerError(rune.isRuneId(itemId) ? "That rune doesn't fit this rite." : 'That is not a rune.');
  const [rows] = await conn.execute('SELECT id, slot_index, item_id, quantity, equipped, instance_id FROM inventory WHERE character_id = ? FOR UPDATE', [characterId]);
  const current = rows.find((r) => Number(r.slot_index) === rune.runeSlotIndex(rite));
  if (itemId === null) {
    if (!current) throw playerError('That socket is empty.');
    await conn.execute('DELETE FROM inventory WHERE id = ?', [current.id]);
    return;
  }
  if (current && current.item_id === itemId) return; // already there
  if (!(await learnedOf(conn, characterId, true)).includes(itemId)) throw playerError("You haven't learned that rune yet.");
  if (current) await conn.execute('DELETE FROM inventory WHERE id = ?', [current.id]);
  await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, 1, 1, ?)', [characterId, rune.runeSlotIndex(rite), itemId, rune.runeEquippedSlot(rite)]);
}

/** Learn the rune in bag slot `slot`: one is spent, the rune is known for good, and an empty socket of its rite takes it. -> { rune, socketed } */
async function learnRune(conn, characterId, slot) {
  const [rows] = await conn.execute('SELECT id, slot_index, item_id, quantity, equipped, instance_id FROM inventory WHERE character_id = ? FOR UPDATE', [characterId]);
  const from = rows.find((r) => Number(r.slot_index) === slot);
  if (!from || !(slot >= 0 && slot < gather.BAG_SLOTS) || Number(from.equipped) || Number(from.quantity) < 1) throw playerError('There is no rune in that bag slot.');
  if (!rune.isRuneId(from.item_id)) throw playerError('That is not a rune.');
  const id = from.item_id;
  if ((await learnedOf(conn, characterId, true)).includes(id)) throw playerError('You already know this rune. Keep the copy, or grind it in the Bone Grinder for grave dust.');
  if (Number(from.quantity) > 1) await conn.execute('UPDATE inventory SET quantity = quantity - 1 WHERE id = ?', [from.id]);
  else await conn.execute('DELETE FROM inventory WHERE id = ?', [from.id]);
  await conn.execute('INSERT IGNORE INTO character_runes (character_id, rune_id) VALUES (?, ?)', [characterId, id]);
  const rite = rune.runeRiteOf(id);
  const socketed = !rows.some((r) => Number(r.slot_index) === rune.runeSlotIndex(rite));
  if (socketed) await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, 1, 1, ?)', [characterId, rune.runeSlotIndex(rite), id, rune.runeEquippedSlot(rite)]);
  return { rune: id, socketed };
}

module.exports = function mountRunes(app, pool, { requireAuth, ownsCharacter }) {
  const handle = (route, check, fn) => async (req, res) => {
    const body = req.body || {};
    const id = parseInt(body.characterId ?? (req.params && req.params.characterId), 10);
    const bad = !id ? 'characterId required' : check(body);
    if (bad) return res.status(400).json({ success: false, error: bad });
    if (!(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      const out = await fn(conn, id, body);
      await conn.commit();
      res.json({ success: true, ...out });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error(`${route} char#${id}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  };
  const bag = async (conn, id) => (await conn.execute(store.INV_SELECT, [id]))[0];

  app.get('/api/runes/:characterId', requireAuth, handle('GET /api/runes', () => null, async (conn, id) => ({ data: { learned: await learnedOf(conn, id) } })));

  app.post('/api/inventory/rune/learn', requireAuth, handle('POST /api/inventory/rune/learn', (b) => (Number.isInteger(b.slot) ? null : 'characterId and slot required'), async (conn, id, body) => {
    const r = await learnRune(conn, id, body.slot);
    return { data: { bag: await bag(conn, id), learned: await learnedOf(conn, id), ...r } };
  }));

  app.post('/api/inventory/rune', requireAuth, handle('POST /api/inventory/rune', (b) => (typeof b.rite === 'string' && (b.itemId === null || typeof b.itemId === 'string') ? null : 'characterId, rite and itemId (or null) required'), async (conn, id, body) => {
    await setRune(conn, id, body.rite, body.itemId);
    return { data: await bag(conn, id) };
  }));
};
module.exports.setRune = setRune;
module.exports.learnRune = learnRune;
module.exports.learnedOf = learnedOf;
