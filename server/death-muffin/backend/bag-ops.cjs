/**
 * The bag's own operations (DECISIONS B25): the player asks, the server changes its bag and answers it. No route takes a bag from the
 * client (the whole-bag save is GM mode only), so what a bag holds is only ever what the server put there.
 *
 *   POST /api/inventory/sort  { characterId, locked?: number[] }                    -> { bag, moves: { oldSlot: newSlot } }
 *   POST /api/inventory/use   { characterId, uses: [{ item_id, slot_index?, quantity }] }  -> { bag, used: [{ item_id, quantity }] }
 *
 * Sort merges stacks (never a rolled piece or a locked slot) and orders the bag (vaultRules.sortBag). Use spends consumables (flasks, brews,
 * meals) the client drank, batched; what the bag no longer holds is skipped, and the answer is the truth the client adopts.
 * Moving, equipping, selling, salvaging, dropping and learning are their own routes (vault.cjs move, server.js equip, sell.cjs, salvage.cjs,
 * ground.cjs, runes.cjs). Every route is one transaction with the bag rows locked (bag-store.cjs).
 */
const gather = require('./gathering/gathering-rules.cjs');
const store = require('./bag-store.cjs');

const rules = store.vaultRules;
const playerError = (message) => Object.assign(new Error(message), { player: true });
const int = (v) => (Number.isInteger(Number(v)) && v !== null && v !== '' ? Number(v) : NaN);

module.exports = function mountBagOps(app, pool, { requireAuth, ownsCharacter, limiter = (_q, _s, next) => next(), log = console }) {
  const handle = (fn) => async (req, res) => {
    const id = parseInt(req.body && req.body.characterId, 10);
    if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      const data = await fn(conn, id, req.body);
      await conn.commit();
      res.json({ success: true, data });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      log.error(`${req.method} ${req.path}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  };

  const bagReply = async (conn, id) => {
    const [bag] = await conn.execute(store.INV_SELECT, [id]);
    return bag;
  };

  app.post('/api/inventory/sort', requireAuth, limiter, handle(async (conn, id, body) => {
    const locked = Array.isArray(body.locked) ? body.locked.slice(0, gather.BAG_SLOTS).map(int).filter((n) => n >= 0 && n < gather.BAG_SLOTS) : [];
    const bag = await store.loadBag(conn, id);
    const info = await store.loadInfo(conn, bag.map((r) => r.itemId));
    const sorted = rules.sortBag(bag, info, locked);
    await store.writeBag(conn, id, bag, sorted.bag);
    return { bag: await bagReply(conn, id), moves: sorted.moves };
  }));

  app.post('/api/inventory/use', requireAuth, limiter, handle(async (conn, id, body) => {
    const raw = Array.isArray(body.uses) ? body.uses : null;
    if (!raw || !raw.length) throw playerError('Nothing to use.');
    if (raw.length > rules.MAX_USES) throw playerError(`At most ${rules.MAX_USES} uses at a time.`);
    const uses = [];
    for (const u of raw) {
      const qty = int(u && u.quantity);
      if (!u || typeof u.item_id !== 'string' || !u.item_id || !(qty >= 1 && qty <= 1000)) throw playerError('Each use needs an item and a quantity.');
      const slot = int(u.slot_index);
      uses.push({ itemId: u.item_id, qty, ...(slot >= 0 && slot < gather.BAG_SLOTS ? { slot } : {}) });
    }
    const bag = await store.loadBag(conn, id);
    const info = await store.loadInfo(conn, [...bag.map((r) => r.itemId), ...uses.map((u) => u.itemId)]);
    const out = rules.useItems(bag, uses, info);
    await store.writeBag(conn, id, bag, out.bag);
    return { bag: await bagReply(conn, id), used: out.used.map((u) => ({ item_id: u.itemId, quantity: u.qty })) };
  }));
};
