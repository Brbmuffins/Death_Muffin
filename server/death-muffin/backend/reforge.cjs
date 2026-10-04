/**
 * Reforge, the Workbench's gold sink (rules: gathering/gold-sink-rules.cjs, generated from src/gameplay/goldSinkRules.ts).
 *
 *   POST /api/reforge/quote  -> { characterId }
 *        -> { gold, pieces: [{ slot_index, instance_id, rerolls }] }: every rolled piece the character carries or wears and how many times
 *           it has been reforged. The client prices with the same rules; the server prices again on every reforge.
 *   POST /api/reforge        -> { characterId, slot_index, affix_index, expect_cost? }
 *        re-rolls the VALUE of one affix on the piece in that slot (bag, worn, or a legion kit slot), uniformly over the range its item level
 *        allows today, for gold that rises with every reforge of the piece. `expect_cost` is the price the player saw: if the real price
 *        differs (another reforge landed first) nothing is charged and the reply says so. The client never sends a price or a value.
 *        -> { gold, cost, from, to, rerolls, bag }
 *
 * One transaction: the character row (gold) and the inventory rows are locked FOR UPDATE, so two reforges, a craft, a salvage and a bag
 * save never interleave. Gold lives in characters.gold; the client brings its own gold up to date with save-progress before it calls,
 * exactly as for a Damage tier, and adopts the `gold` in the reply.
 */
const crypto = require('crypto');
const store = require('./bag-store.cjs');
const { parseAffixes, affix } = require('./loot-instances.cjs');
const sinks = require('./gathering/gold-sink-rules.cjs');

const num = (v) => Number(v) || 0;
const playerError = (message) => Object.assign(new Error(message), { player: true });
const secureRandom = () => crypto.randomInt(0, 2 ** 30) / 2 ** 30;
const fmt = (n) => Number(n).toLocaleString('en-US');

module.exports = function mountReforge(app, pool, { requireAuth, ownsCharacter, random = secureRandom }) {
  const lockedCharacter = async (conn, id) => {
    const [[char]] = await conn.execute('SELECT account_id, gold FROM characters WHERE id = ? FOR UPDATE', [id]);
    if (!char) throw playerError('Character not found.');
    return char;
  };

  app.post('/api/reforge/quote', requireAuth, async (req, res) => {
    try {
      const id = parseInt(req.body && req.body.characterId, 10);
      if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      const [[char]] = await pool.execute('SELECT gold FROM characters WHERE id = ?', [id]);
      const [rows] = await pool.execute(
        `SELECT inv.slot_index, inv.instance_id, COALESCE(rf.rerolls, 0) AS rerolls
           FROM inventory inv LEFT JOIN loot_reforges rf ON rf.instance_id = inv.instance_id
          WHERE inv.character_id = ? AND inv.instance_id IS NOT NULL ORDER BY inv.slot_index`,
        [id],
      );
      res.json({ success: true, data: { gold: num(char && char.gold), pieces: rows.map((r) => ({ slot_index: num(r.slot_index), instance_id: num(r.instance_id), rerolls: num(r.rerolls) })) } });
    } catch (err) {
      // The table arrives with migration 035: until then the quote says so instead of a bare 500.
      console.error(`${req.method} ${req.path}:`, err.code || err.message);
      if (!res.headersSent) res.status(200).json({ success: false, error: 'The Workbench cannot reforge yet. Try again after the next update.' });
    }
  });

  app.post('/api/reforge', requireAuth, async (req, res) => {
    const body = req.body || {};
    const id = parseInt(body.characterId, 10);
    // Ownership is checked BEFORE a connection is taken: ownsCharacter queries the same pool, so ten requests each holding a connection and
    // waiting for an eleventh would starve it for good.
    try {
      if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    } catch (err) {
      console.error(`${req.method} ${req.path}:`, err.code || err.message);
      return res.status(500).json({ success: false, error: 'internal server error' });
    }
    const conn = await pool.getConnection();
    try {
      const slot = Number(body.slot_index);
      const index = Number(body.affix_index);
      if (!Number.isInteger(slot) || !Number.isInteger(index)) throw playerError('Choose a piece and one of its affixes.');

      await conn.beginTransaction();
      const char = await lockedCharacter(conn, id);
      const [[row]] = await conn.execute('SELECT id, item_id, instance_id FROM inventory WHERE character_id = ? AND slot_index = ? FOR UPDATE', [id, slot]);
      if (!row) throw playerError('There is nothing in that slot.');
      if (!row.instance_id) throw playerError('Only rolled gear (a piece with affixes) can be reforged.');
      const [[inst]] = await conn.execute('SELECT id, account_id, ilvl, affixes FROM loot_instances WHERE id = ? FOR UPDATE', [row.instance_id]);
      if (!inst || num(inst.account_id) !== num(char.account_id)) throw playerError('That piece cannot be reforged.');
      const [[meta]] = await conn.execute('SELECT rarity, item_type FROM items WHERE id = ?', [row.item_id]);
      const data = { ilvl: num(inst.ilvl), affixes: parseAffixes(inst.affixes) };
      if (!data.affixes.length) throw playerError('This piece has no affixes to reforge.');
      const problem = sinks.reforgeProblem(data, index);
      if (problem) throw playerError(problem);

      const [[rf]] = await conn.execute('SELECT rerolls FROM loot_reforges WHERE instance_id = ? FOR UPDATE', [inst.id]);
      const rerolls = num(rf && rf.rerolls);
      const cost = sinks.reforgeCost(data.ilvl, (meta && meta.rarity) || 'common', data.affixes.length, rerolls);
      if (body.expect_cost !== undefined && num(body.expect_cost) !== cost) throw playerError(`The price is now ${fmt(cost)} gold. Check it and try again.`);
      const have = num(char.gold);
      if (have < cost) throw playerError(`Reforging this piece costs ${fmt(cost)} gold (you have ${fmt(have)}).`);

      const from = data.affixes[index].v;
      const to = sinks.reforgeValue(data.affixes[index].id, data.ilvl, random);
      const next = { ilvl: data.ilvl, affixes: data.affixes.map((a, i) => (i === index ? { id: a.id, v: to } : { id: a.id, v: a.v })) };
      // The affix list itself keeps its order and ids; a roll the current rules could not produce (a legacy range) is never written.
      if (affix.instanceProblem(next, (meta && meta.item_type) || 'ring')) throw playerError('That reroll could not be applied.');
      await conn.execute('UPDATE loot_instances SET affixes = ? WHERE id = ?', [JSON.stringify(next.affixes), inst.id]);
      await conn.execute('INSERT INTO loot_reforges (instance_id, rerolls) VALUES (?, 1) ON DUPLICATE KEY UPDATE rerolls = rerolls + 1', [inst.id]);
      await conn.execute('UPDATE characters SET gold = gold - ? WHERE id = ?', [cost, id]);
      const [bag] = await conn.execute(store.INV_SELECT, [id]);
      await conn.commit();
      console.log(`[REFORGE] char#${id} ${row.item_id} affix ${data.affixes[index].id} ${from} -> ${to} for ${cost} gold (reforge #${rerolls + 1})`);
      res.json({ success: true, data: { gold: have - cost, cost, from, to, rerolls: rerolls + 1, bag } });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.status(200).json({ success: false, error: 'The Workbench cannot reforge yet. Try again after the next update.' });
      console.error(`${req.method} ${req.path}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};
