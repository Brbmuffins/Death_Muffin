'use strict';
/**
 * Gear dropped from a bag onto the ground of a party session (DECISIONS B16, migration 043).
 *
 * A player drops a piece of gear; it lies on the ground until the session ends (then it is gone). Who may pick it up: the player who
 * dropped it, and party members who were in the session when the piece was FOUND (loot_instances.found_session_id / found_at, stamped
 * by POST /api/loot/roll-gear) and are still in it. Gear only: materials merge into stacks and runes have no instance, so neither can
 * carry where it was found.
 *
 *   POST /api/ground/drop   { characterId, sessionId, slot, x?, z? } -> { dropId, item: { item_id, quantity, instance }, eligible: [characterId], bag }
 *   POST /api/ground/pickup { characterId, dropId }                  -> { bag }
 *
 * The server owns every hand-off: each call is one transaction with the rows locked, so a piece can never be duplicated or lost, and
 * the first pickup wins. While a piece lies on the ground a bag save that names it is refused (inventory-save.cjs). The game only draws
 * the drop (the host relays it to the members in `eligible`); it never decides who gets it. Refusals answer 200 { success: false, error }
 * with a player-readable sentence, like /api/inventory/rune.
 */
const crypto = require('crypto');
const gather = require('./gathering/gathering-rules.cjs');
const store = require('./bag-store.cjs');
const { isLive, LIMITS } = require('./party-sessions.cjs');

/** Pieces one player may have lying on the ground of one session. */
const MAX_DROPS_PER_SESSION = 20;
const ID_RE = /^[0-9a-f]{32}$/;
const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
const playerError = (message, code = 'refused') => Object.assign(new Error(message), { player: true, code });

async function loadSession(conn, id) {
  const [[r]] = await conn.execute('SELECT id, status, last_host_at FROM party_sessions WHERE id = ? FOR UPDATE', [id]);
  return r ? { id: String(r.id), status: String(r.status), lastHostAt: num(r.last_host_at) } : null;
}

async function activeMember(conn, sessionId, characterId) {
  const [[m]] = await conn.execute("SELECT character_id, account_id, joined_at FROM party_session_members WHERE session_id = ? AND character_id = ? AND status = 'active'", [sessionId, characterId]);
  return m ? { characterId: num(m.character_id), accountId: num(m.account_id), joinedAt: num(m.joined_at) } : null;
}

/** Forget every piece lying on the ground of sessions that are over (ended, or the host went silent): rows and instances. */
async function sweepEnded(conn, now) {
  const idleBefore = now - LIMITS.SESSION_IDLE_MS;
  await conn.execute(
    `DELETE li FROM loot_instances li JOIN ground_drops g ON g.instance_id = li.id JOIN party_sessions s ON s.id = g.session_id
      WHERE s.status = 'ended' OR s.last_host_at < ?`, [idleBefore]);
  await conn.execute(
    `DELETE g FROM ground_drops g JOIN party_sessions s ON s.id = g.session_id WHERE s.status = 'ended' OR s.last_host_at < ?`, [idleBefore]);
}

/** The host ended `sessionId`: whatever still lies on its ground is gone (rows and instances). Never fails the caller (the next
 *  ground call sweeps ended sessions anyway). */
async function clearSession(conn, sessionId, log = console) {
  try {
    await conn.execute('DELETE li FROM loot_instances li JOIN ground_drops g ON g.instance_id = li.id WHERE g.session_id = ?', [sessionId]);
    await conn.execute('DELETE FROM ground_drops WHERE session_id = ?', [sessionId]);
  } catch (err) {
    if (!err || err.code !== 'ER_NO_SUCH_TABLE') log.error(`[GROUND] clearing session ${sessionId} failed: ${err && (err.code || err.message)}`);
  }
}

/** Drop the gear on bag slot `slot` onto the ground of `sessionId`. Inside the caller's transaction. */
async function drop(conn, { characterId, accountId, sessionId, slot, x = 0, z = 0, now }) {
  await sweepEnded(conn, now);
  const s = await loadSession(conn, sessionId);
  if (!s || !isLive({ status: s.status, lastHostAt: s.lastHostAt }, now)) throw playerError('You can only drop gear while you are in the world.', 'no_session');
  if (!(await activeMember(conn, sessionId, characterId))) throw playerError('You can only drop gear while you are in the world.', 'not_member');
  const [[count]] = await conn.execute('SELECT COUNT(*) AS n FROM ground_drops WHERE session_id = ? AND from_character_id = ?', [sessionId, characterId]);
  if (num(count && count.n) >= MAX_DROPS_PER_SESSION) throw playerError(`You have ${MAX_DROPS_PER_SESSION} pieces lying on the ground. Pick some up first.`, 'too_many');
  const [[row]] = await conn.execute('SELECT id, slot_index, item_id, quantity, equipped, instance_id FROM inventory WHERE character_id = ? AND slot_index = ? FOR UPDATE', [characterId, slot]);
  if (!row || num(row.slot_index) < 0 || num(row.slot_index) >= gather.BAG_SLOTS) throw playerError('That bag slot is empty.', 'empty');
  if (num(row.equipped)) throw playerError('Take it off first.', 'equipped');
  if (row.instance_id == null) throw playerError('Only gear can be dropped.', 'not_gear');
  const [[inst]] = await conn.execute('SELECT id, account_id, item_id, ilvl, affixes, found_session_id, found_at FROM loot_instances WHERE id = ? FOR UPDATE', [row.instance_id]);
  if (!inst || num(inst.account_id) !== num(accountId)) throw playerError('That piece could not be verified.', 'unverified');
  await conn.execute('DELETE FROM inventory WHERE id = ?', [row.id]);
  const dropId = crypto.randomBytes(16).toString('hex');
  await conn.execute('INSERT INTO ground_drops (id, session_id, instance_id, item_id, from_character_id, from_account_id, x, z, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [dropId, sessionId, num(inst.id), String(inst.item_id), characterId, accountId, num(x), num(z), now]);
  // Who may take it: the dropper, plus whoever was in this session when it was found (and is still in it).
  const eligible = [characterId];
  if (inst.found_session_id && String(inst.found_session_id) === sessionId && inst.found_at != null) {
    const [members] = await conn.execute("SELECT character_id FROM party_session_members WHERE session_id = ? AND status = 'active' AND joined_at <= ?", [sessionId, num(inst.found_at)]);
    for (const m of members) if (!eligible.includes(num(m.character_id))) eligible.push(num(m.character_id));
  }
  const affixes = typeof inst.affixes === 'string' ? JSON.parse(inst.affixes) : (inst.affixes || []);
  return { dropId, item: { item_id: String(inst.item_id), quantity: 1, instance: { id: num(inst.id), ilvl: num(inst.ilvl), affixes } }, eligible };
}

/** Take a piece off the ground into the first free bag slot. Inside the caller's transaction. */
async function pickup(conn, { characterId, accountId, dropId, now }) {
  await sweepEnded(conn, now);
  const [[g]] = await conn.execute('SELECT id, session_id, instance_id, item_id, from_account_id FROM ground_drops WHERE id = ? FOR UPDATE', [dropId]);
  if (!g) throw playerError('It is gone: someone picked it up, or the session ended.', 'gone');
  const me = await activeMember(conn, String(g.session_id), characterId);
  if (!me) throw playerError('Only the party it was dropped for can pick that up.', 'not_member');
  const [[inst]] = await conn.execute('SELECT id, found_session_id, found_at FROM loot_instances WHERE id = ? FOR UPDATE', [g.instance_id]);
  if (!inst) throw playerError('It is gone: someone picked it up, or the session ended.', 'gone');
  const mine = num(g.from_account_id) === num(accountId);
  const wasThere = inst.found_session_id != null && String(inst.found_session_id) === String(g.session_id) && inst.found_at != null && me.joinedAt <= num(inst.found_at);
  if (!mine && !wasThere) throw playerError('You were not in the party when this was found.', 'not_eligible');
  const [rows] = await conn.execute('SELECT slot_index FROM inventory WHERE character_id = ? AND slot_index >= 0 AND slot_index < ? FOR UPDATE', [characterId, gather.BAG_SLOTS]);
  const used = new Set(rows.map((r) => num(r.slot_index)));
  let free = -1;
  for (let i = 0; i < gather.BAG_SLOTS && free < 0; i++) if (!used.has(i)) free = i;
  if (free < 0) throw playerError('Your bag is full.', 'bag_full');
  await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot, instance_id) VALUES (?, ?, ?, 1, 0, NULL, ?)', [characterId, free, String(g.item_id), num(g.instance_id)]);
  await conn.execute('UPDATE loot_instances SET account_id = ? WHERE id = ?', [accountId, num(g.instance_id)]);
  await conn.execute('DELETE FROM ground_drops WHERE id = ?', [dropId]);
  return { slot: free };
}

/** Instance ids among `ids` that lie on the ground (a bag save may not name them). Fails open while migration 043 is missing. */
async function onGround(conn, ids) {
  if (!ids.length) return [];
  try {
    const [rows] = await conn.query('SELECT instance_id FROM ground_drops WHERE instance_id IN (?)', [ids]);
    return rows.map((r) => num(r.instance_id));
  } catch (err) {
    if (err && err.code === 'ER_NO_SUCH_TABLE') return [];
    throw err;
  }
}

function mountGround(app, pool, { requireAuth, ownsCharacter, now = () => Date.now(), log = console }) {
  const route = (path, parse, run) => app.post(path, requireAuth, async (req, res) => {
    const body = req.body || {};
    const characterId = parseInt(body.characterId, 10);
    const args = parse(body);
    if (!characterId || !args) return res.status(400).json({ success: false, error: 'bad request' });
    // Ownership first, on its own pooled query (never while holding a connection: see loot.cjs).
    try {
      if (!(await ownsCharacter(req, characterId))) return res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    } catch (err) {
      log.error(`POST ${path}:`, err.code || err.message);
      return res.status(500).json({ success: false, error: 'internal server error' });
    }
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      const out = await run(conn, { ...args, characterId, accountId: req.user.accountId, now: now() });
      await conn.commit();
      const [bag] = await conn.execute(store.INV_SELECT, [characterId]);
      res.json({ success: true, data: { ...out, bag } });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, code: err.code, error: err.message });
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.status(503).json({ success: false, error: 'Dropping gear is not available right now.' });
      log.error(`POST ${path} char#${characterId}:`, err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
  route('/api/ground/drop', (b) => {
    const slot = Number(b.slot);
    if (!ID_RE.test(String(b.sessionId)) || !Number.isInteger(slot)) return null;
    const clamp = (v) => Math.max(-1e5, Math.min(1e5, num(v)));
    return { sessionId: String(b.sessionId), slot, x: clamp(b.x), z: clamp(b.z) };
  }, drop);
  route('/api/ground/pickup', (b) => (ID_RE.test(String(b.dropId)) ? { dropId: String(b.dropId) } : null), pickup);
}

module.exports = { mountGround, drop, pickup, sweepEnded, clearSession, onGround, MAX_DROPS_PER_SESSION };
