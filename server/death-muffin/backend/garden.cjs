/**
 * Grave Gardening (rules: gathering/garden-rules.cjs, generated from src/gameplay/gardeningRules.ts).
 *
 *   GET  /api/garden/:characterId   -> the six plots (empty ones included), the gardening level and the server's clock
 *   POST /api/garden/plant          -> { characterId, plot, seedId, compost? }: takes the seed (and a bone meal) from the bag
 *   POST /api/garden/harvest        -> { characterId, plot }: gives the crop (and sometimes a seed back) and gardening XP
 *
 * Growth is computed from server timestamps, so a plot keeps growing while the player is offline. The server owns the bag
 * and the XP; nothing here trusts the client's clock.
 */
const garden = require('./gathering/garden-rules.cjs');
const gather = require('./gathering/gathering-rules.cjs');
const { removeFromBag } = require('./contracts.cjs');

const SKILL = 'gardening';
const num = (v) => Number(v) || 0;

module.exports = function mountGarden(app, pool, { requireAuth, ownsCharacter, random = Math.random }) {
  const ownedId = async (req, res, raw) => {
    const id = parseInt(raw, 10);
    if (!id || !(await ownsCharacter(req, id))) {
      res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      return null;
    }
    return id;
  };

  const skill = async (conn, characterId, lock) => {
    await conn.execute('INSERT IGNORE INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, ?, 1, 0)', [characterId, SKILL]);
    const [[row]] = await conn.execute(`SELECT skill_level, skill_xp FROM professions WHERE character_id = ? AND profession_id = ?${lock ? ' FOR UPDATE' : ''}`, [characterId, SKILL]);
    return { level: num(row.skill_level) || 1, xp: num(row.skill_xp) };
  };

  const plotRows = async (conn, characterId, lock) => {
    const [rows] = await conn.execute(`SELECT plot, seed_id, planted_at, ready_at, composted FROM garden_plots WHERE character_id = ?${lock ? ' FOR UPDATE' : ''}`, [characterId]);
    return new Map(rows.map((r) => [r.plot, { plot: r.plot, seedId: r.seed_id, plantedAt: num(r.planted_at), readyAt: num(r.ready_at), composted: !!r.composted }]));
  };

  const view = async (conn, characterId, now) => {
    const rows = await plotRows(conn, characterId, false);
    const { level, xp } = await skill(conn, characterId, false);
    return {
      now,
      level,
      xp,
      xpToNext: gather.xpToNext(level),
      plots: garden.PLOTS.map((p) => {
        const row = rows.get(p.id);
        return { plot: p.id, kind: p.kind, label: p.label, seedId: (row && row.seedId) || null, plantedAt: row ? row.plantedAt : 0, readyAt: row ? row.readyAt : 0, composted: !!(row && row.composted), state: garden.stateOf(row, now) };
      }),
    };
  };

  const playerError = (message) => Object.assign(new Error(message), { player: true });

  const handle = (fn) => async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, (req.params && req.params.characterId) || (req.body && req.body.characterId));
      if (!id) return;
      await conn.beginTransaction();
      const data = await fn(conn, id, req, Date.now());
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

  app.get('/api/garden/:characterId', requireAuth, handle(async (conn, id, _req, now) => view(conn, id, now)));

  app.post('/api/garden/plant', requireAuth, handle(async (conn, id, req, now) => {
    const { plot, seedId, compost } = req.body || {};
    const seed = garden.seedDef(String(seedId));
    const def = garden.plotDef(String(plot));
    const rows = await plotRows(conn, id, true);
    const { level, xp } = await skill(conn, id, true);
    const blocked = garden.plantBlocker(def, String(seedId), level, rows.get(String(plot)), now);
    if (blocked) throw playerError(blocked);
    if (!(await removeFromBag(conn, id, seed.id, 1))) throw playerError('You have no such seed in your bag.');
    const composted = !!compost;
    if (composted && !(await removeFromBag(conn, id, garden.COMPOST_ITEM, 1))) throw playerError('You have no bone meal in your bag.');
    const readyAt = now + garden.growMs(seed, composted);
    await conn.execute(
      'INSERT INTO garden_plots (character_id, plot, seed_id, planted_at, ready_at, composted) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE seed_id = VALUES(seed_id), planted_at = VALUES(planted_at), ready_at = VALUES(ready_at), composted = VALUES(composted)',
      [id, def.id, seed.id, now, readyAt, composted ? 1 : 0],
    );
    const next = gather.addSkillXp({ level, xp }, seed.plantXp);
    await conn.execute('UPDATE professions SET skill_level = ?, skill_xp = ? WHERE character_id = ? AND profession_id = ?', [next.level, next.xp, id, SKILL]);
    return { ...(await view(conn, id, now)), gainedXp: seed.plantXp, leveledUp: next.leveled > 0 };
  }));

  app.post('/api/garden/harvest', requireAuth, handle(async (conn, id, req, now) => {
    const def = garden.plotDef(String(req.body && req.body.plot));
    if (!def) throw playerError('There is no such plot.');
    const rows = await plotRows(conn, id, true);
    const row = rows.get(def.id);
    if (garden.stateOf(row, now) === 'empty') throw playerError('Nothing is growing there.');
    if (garden.stateOf(row, now) !== 'ready') throw playerError('It is not ready yet.');
    const seed = garden.seedDef(row.seedId);
    const crop = garden.rollHarvest(seed, random);

    // Where the crop lands: top up stacks, then free slots. Refuse the whole harvest (changing nothing) if it will not all fit.
    const [bagRows] = await conn.execute('SELECT slot_index, item_id, quantity, equipped FROM inventory WHERE character_id = ? AND slot_index BETWEEN 0 AND 23 FOR UPDATE', [id]);
    const bag = bagRows.map((r) => ({ slot: num(r.slot_index), itemId: num(r.equipped) ? '' : r.item_id, qty: num(r.quantity) }));
    const grants = [{ itemId: crop.itemId, qty: crop.qty }, ...(crop.seedBack ? [{ itemId: crop.seedBack, qty: 1 }] : [])];
    const ids = [...new Set(grants.map((g) => g.itemId))];
    const [stackRows] = await conn.query('SELECT id, stackable, max_stack_size FROM items WHERE id IN (?)', [ids]);
    const stacks = new Map(stackRows.map((r) => [r.id, num(r.stackable) ? Math.max(1, num(r.max_stack_size) || 1) : 1]));
    const placed = gather.placeItems(bag, grants, (item) => stacks.get(item) || 1);
    if (placed.rejected.length) throw playerError('Make room in your bag before you harvest.');
    for (const u of placed.updates) await conn.execute('UPDATE inventory SET quantity = ? WHERE character_id = ? AND slot_index = ?', [u.qty, id, u.slot]);
    for (const r of placed.inserts) {
      await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, ?, 0, NULL)', [id, r.slot, r.itemId, r.qty]);
    }

    await conn.execute("UPDATE garden_plots SET seed_id = NULL, planted_at = 0, ready_at = 0, composted = 0 WHERE character_id = ? AND plot = ?", [id, def.id]);
    const { level, xp } = await skill(conn, id, true);
    const next = gather.addSkillXp({ level, xp }, crop.xp);
    await conn.execute('UPDATE professions SET skill_level = ?, skill_xp = ? WHERE character_id = ? AND profession_id = ?', [next.level, next.xp, id, SKILL]);
    return { ...(await view(conn, id, now)), items: grants, gainedXp: crop.xp, leveledUp: next.leveled > 0 };
  }));
};
