/**
 * Sexton's Contracts: the daily delivery board (rules: gathering/contract-rules.cjs, generated from src/gameplay/contractRules.ts).
 *
 *   GET  /api/contracts/:characterId   -> today's board, streak, reset time
 *   POST /api/contracts/deliver        -> { characterId, slot }: takes the items from the bag, pays the reward
 *
 * The server owns the bag: delivery removes the items and grants any reward item in one transaction. Gold is returned to the client
 * (which owns the gold total and saves it, exactly like a gather reply), never written here.
 */
const rules = require('./gathering/contract-rules.cjs');

const BAG = 24;
const BONUS_SLOT = 9;

const SKILL_IDS = ['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening'];
const parse = (v) => (typeof v === 'string' ? JSON.parse(v) : v) || {};

/** Remove `qty` of an item from the bag (unequipped, slots 0-23). Returns false, changing nothing, if the bag holds fewer. */
async function removeFromBag(conn, characterId, itemId, qty) {
  const [rows] = await conn.execute(
    'SELECT id, quantity FROM inventory WHERE character_id = ? AND item_id = ? AND equipped = 0 AND slot_index BETWEEN 0 AND ? ORDER BY slot_index FOR UPDATE',
    [characterId, itemId, BAG - 1],
  );
  if (rows.reduce((n, r) => n + Number(r.quantity), 0) < qty) return false;
  let left = qty;
  for (const r of rows) {
    if (left <= 0) break;
    const take = Math.min(left, Number(r.quantity));
    if (take === Number(r.quantity)) await conn.execute('DELETE FROM inventory WHERE id = ?', [r.id]);
    else await conn.execute('UPDATE inventory SET quantity = quantity - ? WHERE id = ?', [take, r.id]);
    left -= take;
  }
  return true;
}

/** Put `qty` of an item in the bag (stacking first, then free slots 0-23). Returns how many did NOT fit. */
async function addToBag(conn, characterId, itemId, qty) {
  const [[item]] = await conn.execute('SELECT stackable, max_stack_size FROM items WHERE id = ?', [itemId]);
  if (!item) throw new Error(`unknown item: ${itemId}`);
  const maxStack = item.stackable ? Math.max(Number(item.max_stack_size) || 1, 1) : 1;
  const [bag] = await conn.execute(
    'SELECT id, slot_index, item_id, quantity FROM inventory WHERE character_id = ? AND slot_index BETWEEN 0 AND ? ORDER BY slot_index FOR UPDATE',
    [characterId, BAG - 1],
  );
  let left = qty;
  if (item.stackable) {
    for (const row of bag) {
      if (left <= 0) break;
      if (row.item_id !== itemId || Number(row.quantity) >= maxStack) continue;
      const add = Math.min(left, maxStack - Number(row.quantity));
      await conn.execute('UPDATE inventory SET quantity = quantity + ? WHERE id = ?', [add, row.id]);
      left -= add;
    }
  }
  const occupied = new Set(bag.map((r) => Number(r.slot_index)));
  for (let slot = 0; slot < BAG && left > 0; slot++) {
    if (occupied.has(slot)) continue;
    const add = Math.min(left, maxStack);
    await conn.execute(
      'INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, ?, 0, NULL)',
      [characterId, slot, itemId, add],
    );
    left -= add;
  }
  return left;
}

module.exports = function mountContracts(app, pool, { requireAuth, ownsCharacter }) {
  const ownedId = async (req, res, raw) => {
    const id = parseInt(raw, 10);
    if (!id || !(await ownsCharacter(req, id))) {
      res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      return null;
    }
    return id;
  };

  async function skillLevels(conn, characterId) {
    const [rows] = await conn.execute('SELECT profession_id, skill_level FROM professions WHERE character_id = ?', [characterId]);
    const out = {};
    for (const r of rows) if (SKILL_IDS.includes(r.profession_id)) out[r.profession_id] = Number(r.skill_level) || 1;
    return out;
  }

  /** Today's rows, generated on first sight (INSERT IGNORE keeps two racing requests on the same board). */
  async function boardRows(conn, characterId, day, lock) {
    let [rows] = await conn.execute(`SELECT slot, contract, done FROM character_contracts WHERE character_id = ? AND day = ? AND slot < ? ORDER BY slot${lock ? ' FOR UPDATE' : ''}`, [characterId, day, rules.CONTRACT_SLOTS]);
    if (rows.length < rules.CONTRACT_SLOTS) {
      const board = rules.generateBoard(characterId, day, await skillLevels(conn, characterId));
      for (const c of board) {
        await conn.execute('INSERT IGNORE INTO character_contracts (character_id, day, slot, contract) VALUES (?, ?, ?, ?)', [characterId, day, c.slot, JSON.stringify(c)]);
      }
      [rows] = await conn.execute(`SELECT slot, contract, done FROM character_contracts WHERE character_id = ? AND day = ? AND slot < ? ORDER BY slot${lock ? ' FOR UPDATE' : ''}`, [characterId, day, rules.CONTRACT_SLOTS]);
    }
    return rows.map((r) => ({ ...parse(r.contract), done: !!r.done }));
  }

  async function names(conn, ids) {
    if (!ids.length) return new Map();
    const [rows] = await conn.query('SELECT id, name, rarity FROM items WHERE id IN (?)', [ids]);
    return new Map(rows.map((r) => [r.id, { name: r.name, rarity: r.rarity }]));
  }

  async function streak(conn, characterId, today) {
    const [rows] = await conn.execute(
      'SELECT DISTINCT DATE_FORMAT(day, "%Y-%m-%d") AS d FROM character_contracts WHERE character_id = ? AND done = 1 AND slot < ? ORDER BY d DESC LIMIT 400',
      [characterId, rules.CONTRACT_SLOTS],
    );
    return rules.streakOf(rows.map((r) => r.d), today);
  }

  const view = async (conn, characterId, now) => {
    const day = rules.dayKey(now);
    const board = await boardRows(conn, characterId, day, false);
    const nm = await names(conn, [...new Set(board.flatMap((c) => [c.itemId, c.rewardItem && c.rewardItem.itemId].filter(Boolean)).concat(['gem_grave_garnet']))]);
    const [bonusRows] = await conn.execute('SELECT done FROM character_contracts WHERE character_id = ? AND day = ? AND slot = ?', [characterId, day, BONUS_SLOT]);
    const bonus = rules.bonusFor(board);
    const label = (id) => (nm.get(id) && nm.get(id).name) || id;
    return {
      day,
      resetsAt: new Date(rules.nextResetMs(now)).toISOString(),
      contracts: board.map((c) => ({ ...c, name: label(c.itemId), rarity: (nm.get(c.itemId) || {}).rarity || 'common', rewardItem: c.rewardItem && { ...c.rewardItem, name: label(c.rewardItem.itemId) } })),
      bonus: { gold: bonus.gold, item: { ...bonus.item, name: label(bonus.item.itemId) }, claimed: !!(bonusRows[0] && bonusRows[0].done) },
      streak: await streak(conn, characterId, day),
    };
  };

  app.get('/api/contracts/:characterId', requireAuth, async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, req.params.characterId);
      if (!id) return;
      res.json({ success: true, data: await view(conn, id, Date.now()) });
    } catch (err) {
      console.error('GET /api/contracts:', err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });

  app.post('/api/contracts/deliver', requireAuth, async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, req.body && req.body.characterId);
      if (!id) return;
      const slot = Math.trunc(Number(req.body.slot));
      if (!(slot >= 0 && slot < rules.CONTRACT_SLOTS)) return res.status(400).json({ success: false, error: 'unknown contract' });
      const now = Date.now();
      const day = rules.dayKey(now);
      await conn.beginTransaction();
      const board = await boardRows(conn, id, day, true);
      const contract = board[slot];
      if (!contract) throw Object.assign(new Error('unknown contract'), { player: true });
      if (contract.done) throw Object.assign(new Error('That order is already filled.'), { player: true });

      if (!(await removeFromBag(conn, id, contract.itemId, contract.qty))) {
        throw Object.assign(new Error(`You need ${contract.qty} of that in your bag.`), { player: true });
      }
      const granted = [];
      if (contract.rewardItem) {
        if (await addToBag(conn, id, contract.rewardItem.itemId, contract.rewardItem.qty)) throw Object.assign(new Error('Make room in your bag for the reward.'), { player: true });
        granted.push(contract.rewardItem);
      }
      await conn.execute('UPDATE character_contracts SET done = 1, done_at = CURRENT_TIMESTAMP WHERE character_id = ? AND day = ? AND slot = ?', [id, day, slot]);

      let gold = contract.rewardGold;
      let bonus = null;
      const allDone = board.every((c, i) => (i === slot ? true : c.done));
      if (allDone) {
        const [claimed] = await conn.execute('SELECT done FROM character_contracts WHERE character_id = ? AND day = ? AND slot = ? FOR UPDATE', [id, day, BONUS_SLOT]);
        if (!claimed.length || !claimed[0].done) {
          const b = rules.bonusFor(board);
          if (await addToBag(conn, id, b.item.itemId, b.item.qty)) throw Object.assign(new Error('Make room in your bag for the day’s bonus.'), { player: true });
          await conn.execute('INSERT INTO character_contracts (character_id, day, slot, contract, done, done_at) VALUES (?, ?, ?, ?, 1, CURRENT_TIMESTAMP) ON DUPLICATE KEY UPDATE done = 1', [id, day, BONUS_SLOT, JSON.stringify({ bonus: true })]);
          gold += b.gold;
          granted.push(b.item);
          bonus = { gold: b.gold, item: b.item };
        }
      }
      await conn.commit();
      res.json({ success: true, data: { ...(await view(conn, id, now)), gold, items: granted, paidBonus: bonus } });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      console.error('POST /api/contracts/deliver:', err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};

module.exports.removeFromBag = removeFromBag;
module.exports.addToBag = addToBag;
