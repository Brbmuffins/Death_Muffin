/**
 * Item level and affixes: the only place loot is rolled.
 *
 *   POST /api/loot/roll-gear -> { characterId, drops: [{ item_id, level, source }] }          (1-12 drops)
 *        -> data: [{ item_id, instance_id, ilvl, affixes: [{ id, v }] }] in the same order
 *
 * `level` is the level of whatever dropped the item and `source` is 'kill' | 'elite' | 'boss' | 'first_kill' | 'surge'. The server
 * clamps the level to what this character could plausibly reach (affixRules.clampDropLevel), computes the item level, rolls the
 * affixes with its own RNG, stores one `loot_instances` row per piece of gear and answers the ids. Anything that is not gear (or
 * the client has no use for) answers instance_id null. The client then saves the bag with the instance id; it can never send affixes.
 * A friends-game trust model: the client says where a drop came from (as it always said what dropped), the server owns the rolls.
 */
const crypto = require('crypto');
const store = require('./loot-instances.cjs');

const affix = store.affix;
const MAX_DROPS = 12;
/** Rolled gear nothing points at yet (on the ground). More than this and the client is asked to pick up first. */
const MAX_UNCLAIMED = 300;

const playerError = (message) => Object.assign(new Error(message), { player: true });
/** A uniform float in [0, 1) from the OS CSPRNG. */
const secureRandom = () => crypto.randomInt(0, 2 ** 30) / 2 ** 30;

module.exports = function mountLoot(app, pool, { requireAuth, ownsCharacter, random = secureRandom, limiter }) {
  app.post('/api/loot/roll-gear', ...(limiter ? [limiter] : []), requireAuth, async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = parseInt(req.body && req.body.characterId, 10);
      if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      const drops = req.body.drops;
      if (!Array.isArray(drops) || !drops.length || drops.length > MAX_DROPS) throw playerError(`Roll between 1 and ${MAX_DROPS} drops at a time.`);
      for (const d of drops) {
        if (!d || typeof d.item_id !== 'string' || !/^[a-z0-9_:-]{1,64}$/.test(d.item_id) || !affix.DROP_SOURCES.includes(d.source)) throw playerError('That drop could not be rolled.');
      }

      await conn.beginTransaction();
      const [[char]] = await conn.execute('SELECT account_id, level FROM characters WHERE id = ? FOR UPDATE', [id]);
      const accountId = char.account_id;
      const ids = [...new Set(drops.map((d) => d.item_id))];
      const [items] = await conn.query('SELECT id, item_type, rarity FROM items WHERE id IN (?)', [ids]);
      const meta = new Map(items.map((r) => [r.id, r]));
      if (ids.some((x) => !meta.has(x))) throw playerError('Unknown item.');

      const wanted = drops.filter((d) => affix.isAffixGear(meta.get(d.item_id).item_type)).length;
      if (wanted) {
        await store.pruneUnclaimed(conn, accountId);
        if ((await store.countUnclaimed(conn, accountId)) + wanted > MAX_UNCLAIMED) throw playerError('Too many unclaimed relics on the ground. Pick some up first.');
      }

      const out = [];
      for (const d of drops) {
        const m = meta.get(d.item_id);
        if (!affix.isAffixGear(m.item_type)) {
          out.push({ item_id: d.item_id, instance_id: null, ilvl: 0, affixes: [] });
          continue;
        }
        const level = affix.clampDropLevel(d.level, Number(char.level) || 1);
        const inst = affix.rollInstance({ rarity: m.rarity || 'common' }, level, d.source, random);
        const instanceId = await store.insertInstance(conn, accountId, d.item_id, inst);
        out.push({ item_id: d.item_id, instance_id: instanceId, ilvl: inst.ilvl, affixes: inst.affixes });
      }
      await conn.commit();
      res.json({ success: true, data: out });
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
module.exports.MAX_UNCLAIMED = MAX_UNCLAIMED;
module.exports.MAX_DROPS = MAX_DROPS;
