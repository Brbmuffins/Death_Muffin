/**
 * Salvaging, the Bone Grinder (rules: gathering/salvage-rules.cjs, generated from src/gameplay/salvageRules.ts).
 *
 *   POST /api/salvage -> { characterId, slots: number[] }
 *        takes the gear in those BAG slots, gives crafting materials and alchemy reagents, awards Salvaging XP.
 *        -> { bag, salvaged: [{ item_id }], gained: [{ item_id, quantity }], xp, level, leveledUp, skillXp, xpToNext }
 *
 * The server owns the bag and the XP. Only unequipped gear inside the bag may be salvaged; if the yield will not fit, the whole
 * request is refused and nothing changes. The client wraps the call in Inventory.exclusive() so no bag save races it.
 */
const gather = require('./gathering/gathering-rules.cjs');
const salvage = require('./gathering/salvage-rules.cjs');
const store = require('./bag-store.cjs');
const { deleteInstances } = require('./loot-instances.cjs');

const num = (v) => Number(v) || 0;
const playerError = (message) => Object.assign(new Error(message), { player: true });

module.exports = function mountSalvage(app, pool, { requireAuth, ownsCharacter, random = Math.random }) {
  app.post('/api/salvage', requireAuth, async (req, res) => {
    // Ownership first, THEN a connection: ownsCharacter queries the same pool, so ten requests each holding a connection while
    // waiting for an eleventh would starve the pool for good (found by the release-0404 DB probe).
    const id = parseInt(req.body && req.body.characterId, 10);
    try {
      if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    } catch (err) {
      console.error('POST /api/salvage:', err.code || err.message);
      return res.status(500).json({ success: false, error: 'internal server error' });
    }
    const conn = await pool.getConnection();
    try {
      const raw = req.body.slots;
      if (!Array.isArray(raw) || !raw.length) throw playerError('Choose some gear to salvage.');
      const slots = raw.map((n) => (Number.isInteger(Number(n)) && n !== null && n !== '' ? Number(n) : NaN));
      if (slots.length > gather.BAG_SLOTS || slots.some((n) => !(n >= 0 && n < gather.BAG_SLOTS)) || new Set(slots).size !== slots.length) {
        throw playerError(`Choose gear in your bag (slots 0 to ${gather.BAG_SLOTS - 1}), each once.`);
      }

      await conn.beginTransaction();
      const bag = await store.loadBag(conn, id);
      const info = await store.loadInfo(conn, bag.map((r) => r.itemId));
      await conn.execute('INSERT IGNORE INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, ?, 1, 0)', [id, salvage.SALVAGE_SKILL]);
      const [[prof]] = await conn.execute('SELECT skill_level, skill_xp FROM professions WHERE character_id = ? AND profession_id = ? FOR UPDATE', [id, salvage.SALVAGE_SKILL]);
      const level = num(prof.skill_level) || 1;

      const taken = new Set(slots);
      const partial = new Map();
      const salvaged = [];
      const yields = [];
      const spentInstances = [];
      let xp = 0;
      for (const slot of slots) {
        const row = bag.find((r) => r.slot === slot);
        if (!row) throw playerError('One of those slots is empty. Nothing was salvaged.');
        if (row.fixed) throw playerError('Equipped gear cannot be salvaged. Unequip it first.');
        const meta = info(row.itemId);
        if (!salvage.isSalvageable(meta.itemType)) throw playerError('Only weapons, armor, rings, trinkets and runes can be salvaged.');
        if (row.inst) spentInstances.push(row.inst);
        // A rune stack is ground one rune at a time (the rest stay in the bag); gear never stacks.
        const isRune = salvage.isSalvageRune(meta.itemType);
        if (isRune && row.qty > 1) partial.set(slot, { ...row, qty: row.qty - 1 });
        for (let n = 0; n < (isRune ? 1 : row.qty); n++) {
          // A rolled piece (item level, affixes) pays a little more; plain gear rolls exactly as before.
          const out = salvage.salvageYield({ id: row.itemId, item_type: meta.itemType, rarity: meta.rarity, ...(row.inst ? { ilvl: row.ilvl, affixes: row.nAffix } : {}) }, level, random);
          salvaged.push({ item_id: row.itemId });
          yields.push(out.items);
          xp += out.xp;
        }
      }
      const gained = salvage.mergeGrants(yields);
      const left = bag.filter((r) => !taken.has(r.slot) || partial.has(r.slot)).map((r) => partial.get(r.slot) ?? r);
      const yieldInfo = await store.loadInfo(conn, gained.map((g) => g.item_id));
      const after = store.vaultRules.addGrants(left, gained.map((g) => ({ itemId: g.item_id, qty: g.quantity })), (item) => yieldInfo(item));
      if (!after) throw playerError('Make room in your bag first: the salvage will not fit. Nothing was salvaged.');
      await store.writeBag(conn, id, bag, after);
      await deleteInstances(conn, spentInstances);

      const next = gather.addSkillXp({ level, xp: num(prof.skill_xp) }, xp);
      await conn.execute('UPDATE professions SET skill_level = ?, skill_xp = ? WHERE character_id = ? AND profession_id = ?', [next.level, next.xp, id, salvage.SALVAGE_SKILL]);
      const [bagRows] = await conn.execute(store.INV_SELECT, [id]);
      await conn.commit();
      res.json({ success: true, data: { bag: bagRows, salvaged, gained, xp, level: next.level, leveledUp: next.leveled > 0, skillXp: next.xp, xpToNext: gather.xpToNext(next.level) } });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error(`${req.method} ${req.path}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};
