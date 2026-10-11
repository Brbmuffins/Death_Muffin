/**
 * The Ossuary Vault: a 120-slot stash shared by every character on the account (rules: gathering/vault-rules.cjs, generated from
 * server/rules/gameplay/vaultRules.ts).
 *
 *   GET  /api/vault/:characterId       -> { bag, vault }
 *   POST /api/vault/deposit            -> { characterId, bagSlot, quantity? }      bag -> vault (whole stack when quantity is omitted)
 *   POST /api/vault/withdraw           -> { characterId, vaultSlot, quantity? }    vault -> bag
 *   POST /api/vault/deposit-all        -> { characterId, kind: 'materials' | 'all', exceptSlots: number[] }
 *   POST /api/vault/sort               -> { characterId }                           merge stacks, order by type, rarity, id
 *   POST /api/vault/move               -> { characterId, from, fromSlot, to, toSlot, quantity? }   from/to = 'bag' | 'vault': a stack to exactly
 *                                         that slot (rearranging within a side too): empty = put, same item = merge, else swap (vaultRules.moveToSlot)
 *
 * Every route answers { bag, vault } (the bag in the GET /api/inventory shape). A move stacks first, then takes free slots; it is
 * one transaction with both sides locked, and a move that will not fit is refused with a readable error, changing nothing.
 * Equipped gear (inventory slots 100-108) is never touched. The client wraps these calls in Inventory.exclusive() so no bag save races.
 */
const gather = require('./gathering/gathering-rules.cjs');
const store = require('./bag-store.cjs');

const rules = store.vaultRules;
const playerError = (message) => Object.assign(new Error(message), { player: true });

module.exports = function mountVault(app, pool, { requireAuth, ownsCharacter }) {
  const ownedId = async (req, res, raw) => {
    const id = parseInt(raw, 10);
    if (!id || !(await ownsCharacter(req, id))) {
      res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      return null;
    }
    return id;
  };

  const handle = (fn) => async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, (req.params && req.params.characterId) || (req.body && req.body.characterId));
      if (!id) return;
      await conn.beginTransaction();
      const accountId = req.user && req.user.accountId;
      const data = await fn(conn, id, accountId, req);
      await conn.commit();
      res.json({ success: true, data });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error(`${req.method} ${req.path}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  };

  /** Lock both sides, run a pure move from the rules, write the difference. */
  const move = async (conn, id, accountId, run) => {
    const bag = await store.loadBag(conn, id);
    const vault = await store.loadVault(conn, accountId);
    const info = await store.loadInfo(conn, [...bag, ...vault].map((r) => r.itemId));
    const result = run(bag, vault, info);
    if (!result.ok) throw playerError(result.error);
    await store.writeBag(conn, id, bag, result.bag);
    await store.writeVault(conn, accountId, vault, result.vault);
    return store.view(conn, id, accountId);
  };

  const int = (v) => (Number.isInteger(Number(v)) && v !== null && v !== '' ? Number(v) : NaN);
  const qtyOf = (raw) => {
    if (raw === undefined || raw === null) return undefined;
    const n = int(raw);
    if (!(n >= 1)) throw playerError('Choose how many to move.');
    return n;
  };

  app.get('/api/vault/:characterId', requireAuth, handle(async (conn, id, accountId) => store.view(conn, id, accountId)));

  app.post('/api/vault/deposit', requireAuth, handle(async (conn, id, accountId, req) => {
    const slot = int(req.body.bagSlot);
    if (!(slot >= 0 && slot < gather.BAG_SLOTS)) throw playerError(`Choose a bag slot between 0 and ${gather.BAG_SLOTS - 1}.`);
    const quantity = qtyOf(req.body.quantity);
    return move(conn, id, accountId, (bag, vault, info) => rules.depositStack(bag, vault, slot, quantity, info));
  }));

  app.post('/api/vault/withdraw', requireAuth, handle(async (conn, id, accountId, req) => {
    const slot = int(req.body.vaultSlot);
    if (!(slot >= 0 && slot < rules.VAULT_SLOTS)) throw playerError(`Choose a Vault slot between 0 and ${rules.VAULT_SLOTS - 1}.`);
    const quantity = qtyOf(req.body.quantity);
    return move(conn, id, accountId, (bag, vault, info) => rules.withdrawStack(bag, vault, slot, quantity, info));
  }));

  app.post('/api/vault/deposit-all', requireAuth, handle(async (conn, id, accountId, req) => {
    const kind = req.body.kind;
    if (kind !== 'materials' && kind !== 'all') throw playerError('Choose what to deposit: materials or everything.');
    const except = Array.isArray(req.body.exceptSlots) ? req.body.exceptSlots.slice(0, 200).map(int).filter((n) => n >= 0 && n < gather.BAG_SLOTS) : [];
    return move(conn, id, accountId, (bag, vault, info) => rules.depositMany(bag, vault, kind, except, info));
  }));

  app.post('/api/vault/move', requireAuth, handle(async (conn, id, accountId, req) => {
    const side = (v) => (v === 'bag' || v === 'vault' ? v : null);
    const from = side(req.body.from), to = side(req.body.to);
    if (!from || !to) throw playerError('Choose where to move it: bag or vault.');
    const size = (s) => (s === 'bag' ? gather.BAG_SLOTS : rules.VAULT_SLOTS);
    const fromSlot = int(req.body.fromSlot), toSlot = int(req.body.toSlot);
    if (!(fromSlot >= 0 && fromSlot < size(from)) || !(toSlot >= 0 && toSlot < size(to))) throw playerError('That slot does not exist.');
    const quantity = qtyOf(req.body.quantity);
    return move(conn, id, accountId, (bag, vault, info) => rules.moveToSlot(bag, vault, from, fromSlot, to, toSlot, quantity, info));
  }));

  app.post('/api/vault/sort', requireAuth, handle(async (conn, id, accountId) => {
    const vault = await store.loadVault(conn, accountId);
    const info = await store.loadInfo(conn, vault.map((r) => r.itemId));
    const sorted = rules.sortVault(vault, info);
    await store.writeVault(conn, accountId, vault, sorted);
    return store.view(conn, id, accountId);
  }));
};
