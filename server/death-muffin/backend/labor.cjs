/**
 * Grave Laborers / thrall labour (rules: gathering/labor-rules.cjs, generated from src/gameplay/laborRules.ts).
 *
 *   GET  /api/labor/:characterId   -> the four slots (locked ones included), what each has piled up, the server's clock
 *   POST /api/labor/assign         -> { characterId, slot, nodeType|null }: send a laborer to a post (null recalls it)
 *   POST /api/labor/collect        -> { characterId, slot }: roll and pay what the laborer gathered; it keeps working
 *
 * Work accrues on the server clock up to a cap, so it continues while the player is offline. A collection is repeatable (seeded by
 * the post and its start time), so a refused claim cannot be re-rolled for better luck. Gold is returned for the client to credit.
 */
const labor = require('./gathering/labor-rules.cjs');
const gather = require('./gathering/gathering-rules.cjs');

const num = (v) => Number(v) || 0;
const GATHER = ['woodcutting', 'mining', 'fishing', 'gravedigging'];

module.exports = function mountLabor(app, pool, { requireAuth, ownsCharacter, now: clock = Date.now }) {
  const ownedId = async (req, res, raw) => {
    const id = parseInt(raw, 10);
    if (!id || !(await ownsCharacter(req, id))) {
      res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      return null;
    }
    return id;
  };
  const playerError = (message) => Object.assign(new Error(message), { player: true });

  const levelsOf = async (conn, characterId) => {
    const [rows] = await conn.execute('SELECT profession_id, skill_level, skill_xp FROM professions WHERE character_id = ?', [characterId]);
    const levels = {};
    const xp = {};
    for (const r of rows) {
      levels[r.profession_id] = num(r.skill_level) || 1;
      xp[r.profession_id] = num(r.skill_xp);
    }
    return { levels, xp };
  };

  const rowsOf = async (conn, characterId, lock) => {
    const [rows] = await conn.execute(`SELECT slot, node_type, started_at FROM character_labor WHERE character_id = ?${lock ? ' FOR UPDATE' : ''}`, [characterId]);
    return new Map(rows.map((r) => [num(r.slot), { nodeType: r.node_type, startedAt: num(r.started_at) }]));
  };

  const view = async (conn, characterId, now) => {
    const { levels } = await levelsOf(conn, characterId);
    const total = labor.totalGatherLevel(levels);
    const unlocked = labor.laborSlots(total);
    const rows = await rowsOf(conn, characterId, false);
    const slots = [];
    for (let slot = 0; slot < labor.LABOR.maxSlots; slot++) {
      const row = rows.get(slot);
      const def = row && row.nodeType ? gather.NODES[row.nodeType] : null;
      const elapsed = def ? Math.max(0, Math.min(now - row.startedAt, labor.LABOR.capMs)) : 0;
      const est = def ? labor.estimate(def, levels[def.skill] || 1, elapsed) : null;
      slots.push({
        slot,
        unlocked: slot < unlocked,
        nodeType: def ? def.id : null,
        nodeName: def ? def.name : null,
        skill: def ? def.skill : null,
        item: def ? def.item : null,
        startedAt: def ? row.startedAt : 0,
        elapsedMs: elapsed,
        capped: !!def && now - row.startedAt >= labor.LABOR.capMs,
        pendingActions: est ? est.actions : 0,
        estItems: est ? est.items : 0,
        estXp: est ? est.xp : 0,
      });
    }
    return { now, capMs: labor.LABOR.capMs, totalLevel: total, levelsPerSlot: labor.LABOR.levelsPerSlot, slots };
  };

  const handle = (fn) => async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, (req.params && req.params.characterId) || (req.body && req.body.characterId));
      if (!id) return;
      await conn.beginTransaction();
      const data = await fn(conn, id, req, clock());
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

  app.get('/api/labor/:characterId', requireAuth, handle(async (conn, id, _req, now) => view(conn, id, now)));

  app.post('/api/labor/assign', requireAuth, handle(async (conn, id, req, now) => {
    const slot = Math.trunc(Number(req.body && req.body.slot));
    const nodeType = req.body && req.body.nodeType ? String(req.body.nodeType) : null;
    const { levels } = await levelsOf(conn, id);
    if (!(slot >= 0 && slot < labor.laborSlots(labor.totalGatherLevel(levels)))) throw playerError('You do not command that many laborers yet.');
    const rows = await rowsOf(conn, id, true);
    const row = rows.get(slot);
    const cur = row && row.nodeType ? gather.NODES[row.nodeType] : null;
    if (cur && labor.laborActions(cur, now - row.startedAt) >= 1) throw playerError('Collect what they have gathered first.');
    if (nodeType) {
      const blocked = labor.assignBlocker(nodeType, levels);
      if (blocked) throw playerError(blocked);
    }
    await conn.execute(
      'INSERT INTO character_labor (character_id, slot, node_type, started_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE node_type = VALUES(node_type), started_at = VALUES(started_at)',
      [id, slot, nodeType, nodeType ? now : 0],
    );
    return view(conn, id, now);
  }));

  app.post('/api/labor/collect', requireAuth, handle(async (conn, id, req, now) => {
    const slot = Math.trunc(Number(req.body && req.body.slot));
    const rows = await rowsOf(conn, id, true);
    const row = rows.get(slot);
    const def = row && row.nodeType ? gather.NODES[row.nodeType] : null;
    if (!def) throw playerError('That laborer has no post.');
    const elapsed = Math.min(now - row.startedAt, labor.LABOR.capMs);
    const actions = labor.laborActions(def, elapsed);
    if (actions < 1) throw playerError('They have barely started.');

    const [[skillRow]] = await conn.execute('SELECT skill_level, skill_xp FROM professions WHERE character_id = ? AND profession_id = ? FOR UPDATE', [id, def.skill]);
    const start = { level: num(skillRow && skillRow.skill_level) || 1, xp: num(skillRow && skillRow.skill_xp) };
    const roll = labor.rollLabor(def, start, elapsed, labor.claimRng(labor.hashSeed(id, slot, row.startedAt, actions)));

    // Place the finds: refuse the whole collection (changing nothing) if they will not all fit.
    const [bagRows] = await conn.execute('SELECT slot_index, item_id, quantity, equipped FROM inventory WHERE character_id = ? AND slot_index BETWEEN 0 AND ? FOR UPDATE', [id, gather.BAG_SLOTS - 1]);
    const bag = bagRows.map((r) => ({ slot: num(r.slot_index), itemId: num(r.equipped) ? '' : r.item_id, qty: num(r.quantity) }));
    const ids = [...new Set(roll.items.map((g) => g.itemId))];
    const stacks = new Map();
    if (ids.length) {
      const [stackRows] = await conn.query('SELECT id, stackable, max_stack_size FROM items WHERE id IN (?)', [ids]);
      for (const r of stackRows) stacks.set(r.id, num(r.stackable) ? Math.max(1, num(r.max_stack_size) || 1) : 1);
    }
    for (const g of roll.items) if (!stacks.has(g.itemId)) throw playerError('One of their finds is not available on the server yet.');
    const placed = gather.placeItems(bag, roll.items, (item) => stacks.get(item));
    if (placed.rejected.length) throw playerError(`Make room in your bag: ${placed.rejected.reduce((n, g) => n + g.qty, 0)} of their finds would not fit.`);
    for (const u of placed.updates) await conn.execute('UPDATE inventory SET quantity = ? WHERE character_id = ? AND slot_index = ?', [u.qty, id, u.slot]);
    for (const r of placed.inserts) {
      await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, ?, 0, NULL)', [id, r.slot, r.itemId, r.qty]);
    }
    await conn.execute('INSERT IGNORE INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, ?, 1, 0)', [id, def.skill]);
    await conn.execute('UPDATE professions SET skill_level = ?, skill_xp = ? WHERE character_id = ? AND profession_id = ?', [roll.progress.level, roll.progress.xp, id, def.skill]);
    // The laborer keeps working from now.
    await conn.execute('UPDATE character_labor SET started_at = ? WHERE character_id = ? AND slot = ?', [now, id, slot]);
    return {
      ...(await view(conn, id, now)),
      collected: { slot, node: def.id, skill: def.skill, hours: elapsed / 3_600_000, actions, items: placed.stored, gold: roll.gold, xp: roll.xp, leveledUp: roll.leveled > 0 },
    };
  }));
};

module.exports.GATHER = GATHER;
