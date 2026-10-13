/**
 * Item level and affixes: the only place loot is rolled.
 *
 *   POST /api/loot/roll-gear -> { characterId, drops: [{ item_id, level, source }], sessionId? }   (1-12 drops)
 *        -> data: [{ item_id, instance_id, ilvl, affixes: [{ id, v }] }] in the same order
 *
 * `level` is the level of whatever dropped the item and `source` is 'kill' | 'elite' | 'boss' | 'first_kill' | 'surge'. The server
 * clamps the level to what this character could plausibly reach (affixRules.clampDropLevel), computes the item level, rolls the
 * affixes with its own RNG, stores one `loot_instances` row per piece of gear and answers the ids. Anything that is not gear (or
 * the client has no use for) answers instance_id null. The client then saves the bag with the instance id; it can never send affixes.
 * With `sessionId` (the party session the player is in) a piece remembers where and when it was found (migration 043, ground.cjs).
 * A friends-game trust model: the client says where a drop came from (as it always said what dropped), the server owns the rolls.
 */
const crypto = require('crypto');
const store = require('./loot-instances.cjs');
const { LIMITS } = require('./party-sessions.cjs');

const affix = store.affix;
const MAX_DROPS = 12;
/** Rolled gear nothing points at yet (on the ground). More than this and the client is asked to pick up first. */
const MAX_UNCLAIMED = 300;

const playerError = (message) => Object.assign(new Error(message), { player: true });
/** A uniform float in [0, 1) from the OS CSPRNG. */
const secureRandom = () => crypto.randomInt(0, 2 ** 30) / 2 ** 30;

const SESSION_RE = /^[0-9a-f]{32}$/;
let hasFoundColumn = false;

/**
 * The party session this character is rolling gear in, as { sessionId, at }, or null: an open session whose host was heard from recently and
 * where the character is an active member. Party members who were there may later pick the piece up if someone drops it (ground.cjs).
 * Fails open (null) while migration 041/043 is missing.
 */
async function foundIn(conn, sessionId, characterId, now) {
  if (!SESSION_RE.test(String(sessionId || ''))) return null;
  try {
    const [[r]] = await conn.execute(
      `SELECT s.status, s.last_host_at FROM party_sessions s JOIN party_session_members m ON m.session_id = s.id
        WHERE s.id = ? AND m.character_id = ? AND m.status = 'active'`, [String(sessionId), characterId]);
    if (!r || String(r.status) !== 'open' || now - Number(r.last_host_at) > LIMITS.SESSION_IDLE_MS) return null;
    if (!hasFoundColumn) {
      const [[col]] = await conn.execute("SELECT COUNT(*) AS n FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'loot_instances' AND COLUMN_NAME = 'found_session_id'");
      hasFoundColumn = !!col && Number(col.n) > 0;   // checked until it exists, then never again
    }
    return hasFoundColumn ? { sessionId: String(sessionId), at: now } : null;
  } catch (err) {
    if (err && (err.code === 'ER_NO_SUCH_TABLE' || err.code === 'ER_BAD_FIELD_ERROR')) return null;
    throw err;
  }
}

module.exports = function mountLoot(app, pool, { requireAuth, ownsCharacter, random = secureRandom, limiter, guardRoll }) {
  app.post('/api/loot/roll-gear', ...(limiter ? [limiter] : []), requireAuth, async (req, res) => {
    // Ownership first, on its own pooled query: checking it while holding a connection needs a second one, and ~10 concurrent rolls
    // (one per pool slot) then wait on each other forever and wedge every DB route (2026-10-06 incident, same rule as reforge.cjs).
    const id = parseInt(req.body && req.body.characterId, 10);
    try {
      if (!id || !(await ownsCharacter(req, id))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    } catch (err) {
      console.error(`${req.method} ${req.path}:`, err.code || err.message);
      return res.status(500).json({ success: false, error: 'internal server error' });
    }
    const conn = await pool.getConnection();
    try {
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
      // Authority: only items that exist in a drop table can be rolled (authority.cjs; report mode just logs).
      if (guardRoll) {
        const g = await guardRoll(req, conn, { characterId: id, accountId, itemIds: ids });
        // Nothing has been written yet: commit (keeps the audit row) rather than roll back.
        if (!g.ok) { await conn.commit(); throw playerError(g.message); }
      }

      const wanted = drops.filter((d) => affix.isAffixGear(meta.get(d.item_id).item_type)).length;
      if (wanted) {
        await store.pruneUnclaimed(conn, accountId);
        if ((await store.countUnclaimed(conn, accountId)) + wanted > MAX_UNCLAIMED) throw playerError('Too many unclaimed relics on the ground. Pick some up first.');
      }

      const found = wanted ? await foundIn(conn, req.body.sessionId, id, Date.now()) : null;
      const out = [];
      for (const d of drops) {
        const m = meta.get(d.item_id);
        if (!affix.isAffixGear(m.item_type)) {
          out.push({ item_id: d.item_id, instance_id: null, ilvl: 0, affixes: [] });
          continue;
        }
        const level = affix.clampDropLevel(d.level, Number(char.level) || 1);
        const inst = affix.rollInstance({ rarity: m.rarity || 'common' }, level, d.source, random);
        const instanceId = await store.insertInstance(conn, accountId, d.item_id, inst, found);
        out.push({ item_id: d.item_id, instance_id: instanceId, ilvl: inst.ilvl, affixes: inst.affixes });
      }
      await conn.commit();
      res.json({ success: true, data: out });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      if (err && err.unavailable) return res.status(503).json({ success: false, error: err.message });
      console.error(`${req.method} ${req.path}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};
module.exports.MAX_UNCLAIMED = MAX_UNCLAIMED;
module.exports.MAX_DROPS = MAX_DROPS;
