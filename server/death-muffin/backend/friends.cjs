/**
 * Friends (owner 2026-10-13, Social window O): mutual friendships between accounts (table friendships, migration 045).
 *
 *   GET  /api/friends                          -> { success, data: View }
 *   POST /api/friends/request { username }     -> { success, data: View, message }   asks; if they already asked you, you are friends at once
 *   POST /api/friends/accept  { accountId }    -> { success, data: View, message }   accepts their request
 *   POST /api/friends/remove  { accountId }    -> { success, data: View }            unfriend, decline a request or cancel your own (one row, gone)
 *
 * View = { friends: [{ accountId, username, disciplineIndex, level }], incoming: [{ accountId, username }], outgoing: [{ accountId, username }] }
 * `disciplineIndex` / `level` are the friend's active character (null when they have none yet): what they last played.
 * A pair is one row, lower account id first. Only active accounts are found or listed. Friends are social only: nothing here grants anything.
 */
const MAX_FRIENDS = 100;          // accepted + pending rows an account may be part of
const MAX_OUTGOING = 20;          // requests an account may have waiting at once
const USERNAME_MAX = 32;

const pairOf = (a, b) => (a < b ? [a, b] : [b, a]);

/** Rows of SELECT_VIEW (from the account `me`'s side) -> View. */
function viewOf(rows, me) {
  const out = { friends: [], incoming: [], outgoing: [] };
  for (const r of rows) {
    const who = { accountId: Number(r.id), username: String(r.username) };
    if (r.status === 'accepted') {
      out.friends.push({ ...who, disciplineIndex: r.discipline_index == null ? null : Number(r.discipline_index), level: r.level == null ? null : Number(r.level) });
    } else if (Number(r.requested_by) === me) out.outgoing.push(who);
    else out.incoming.push(who);
  }
  const byName = (x, y) => x.username.localeCompare(y.username, 'en', { sensitivity: 'base' });
  out.friends.sort(byName); out.incoming.sort(byName); out.outgoing.sort(byName);
  return out;
}

/** A positive account id from a body field, or 0. */
function accountIdOf(body) {
  const v = body && typeof body === 'object' ? body.accountId : null;
  return Number.isInteger(v) && v > 0 ? v : 0;
}

const SELECT_VIEW =
  'SELECT f.status, f.requested_by, a.id, a.username, c.discipline_index, c.level FROM friendships f ' +
  'JOIN accounts a ON a.id = IF(f.account_lo = ?, f.account_hi, f.account_lo) AND a.active = 1 ' +
  'LEFT JOIN characters c ON c.id = a.active_character_id ' +
  'WHERE f.account_lo = ? OR f.account_hi = ?';

module.exports = function mountFriends(app, pool, { requireAuth, limiter }) {
  const mw = limiter ? [requireAuth, limiter] : [requireAuth];
  const view = async (me) => {
    const [rows] = await pool.execute(SELECT_VIEW, [me, me, me]);
    return viewOf(rows, me);
  };
  const pairRow = async (a, b) => {
    const [lo, hi] = pairOf(a, b);
    const [rows] = await pool.execute('SELECT requested_by, status FROM friendships WHERE account_lo = ? AND account_hi = ?', [lo, hi]);
    return rows[0] || null;
  };
  const accept = async (me, other) => {
    const [lo, hi] = pairOf(me, other);
    const [r] = await pool.execute(
      "UPDATE friendships SET status = 'accepted', accepted_at = CURRENT_TIMESTAMP WHERE account_lo = ? AND account_hi = ? AND status = 'pending' AND requested_by <> ?",
      [lo, hi, me]);
    return r.affectedRows === 1;
  };
  const fail = (res, err, what) => {
    if (err && err.code === 'ER_NO_SUCH_TABLE') return res.status(503).json({ success: false, error: 'Friends are not available just yet. Please try again later.' });
    console.error(`${what}:`, (err && (err.code || err.message)) || err);
    res.status(500).json({ success: false, error: 'Your friends list could not be updated.' });
  };

  app.get('/api/friends', ...mw, async (req, res) => {
    try {
      res.json({ success: true, data: await view(req.user.accountId) });
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.json({ success: true, data: { friends: [], incoming: [], outgoing: [] } });
      console.error('GET /api/friends:', err.code || err.message);
      res.status(500).json({ success: false, error: 'Your friends list could not be loaded.' });
    }
  });

  app.post('/api/friends/request', ...mw, async (req, res) => {
    const me = req.user.accountId;
    const name = req.body && typeof req.body.username === 'string' ? req.body.username.trim() : '';
    if (!name || name.length > USERNAME_MAX) return res.status(400).json({ success: false, error: 'Enter the name your friend logs in with.' });
    try {
      const [found] = await pool.execute('SELECT id, username FROM accounts WHERE username = ? AND active = 1 LIMIT 1', [name]);
      const other = found[0];
      if (!other) return res.status(404).json({ success: false, error: `Nobody is called "${name}".` });
      const them = Number(other.id);
      if (them === me) return res.status(400).json({ success: false, error: 'That is you.' });
      const row = await pairRow(me, them);
      if (row && row.status === 'accepted') return res.status(409).json({ success: false, error: `${other.username} is already your friend.` });
      if (row && Number(row.requested_by) === me) return res.status(409).json({ success: false, error: `You already asked ${other.username}. They need to accept.` });
      if (row) {   // they asked first: asking back is accepting
        await accept(me, them);
        return res.json({ success: true, data: await view(me), message: `You and ${other.username} are friends now.` });
      }
      const [[mine]] = await pool.execute(
        'SELECT COUNT(*) AS total, SUM(status = \'pending\' AND requested_by = ?) AS outgoing FROM friendships WHERE account_lo = ? OR account_hi = ?', [me, me, me]);
      if (Number(mine.total) >= MAX_FRIENDS) return res.status(409).json({ success: false, error: `Your friends list is full (${MAX_FRIENDS}).` });
      if (Number(mine.outgoing || 0) >= MAX_OUTGOING) return res.status(409).json({ success: false, error: `You have ${MAX_OUTGOING} requests waiting already. Cancel some first.` });
      const [[theirs]] = await pool.execute('SELECT COUNT(*) AS total FROM friendships WHERE account_lo = ? OR account_hi = ?', [them, them]);
      if (Number(theirs.total) >= MAX_FRIENDS) return res.status(409).json({ success: false, error: `${other.username}'s friends list is full.` });
      const [lo, hi] = pairOf(me, them);
      try {
        await pool.execute("INSERT INTO friendships (account_lo, account_hi, requested_by, status) VALUES (?, ?, ?, 'pending')", [lo, hi, me]);
      } catch (err) {
        if (!err || err.code !== 'ER_DUP_ENTRY') throw err;
        if (!(await accept(me, them))) return res.status(409).json({ success: false, error: `You already asked ${other.username}. They need to accept.` });   // both asked at once
        return res.json({ success: true, data: await view(me), message: `You and ${other.username} are friends now.` });
      }
      res.json({ success: true, data: await view(me), message: `Friend request sent to ${other.username}.` });
    } catch (err) {
      fail(res, err, 'POST /api/friends/request');
    }
  });

  app.post('/api/friends/accept', ...mw, async (req, res) => {
    const me = req.user.accountId;
    const them = accountIdOf(req.body);
    if (!them || them === me) return res.status(400).json({ success: false, error: 'That request could not be found.' });
    try {
      if (!(await accept(me, them))) return res.status(404).json({ success: false, error: 'That request is gone. They may have cancelled it.' });
      const data = await view(me);
      const f = data.friends.find((x) => x.accountId === them);
      res.json({ success: true, data, message: f ? `You and ${f.username} are friends now.` : 'Request accepted.' });
    } catch (err) {
      fail(res, err, 'POST /api/friends/accept');
    }
  });

  app.post('/api/friends/remove', ...mw, async (req, res) => {
    const me = req.user.accountId;
    const them = accountIdOf(req.body);
    if (!them || them === me) return res.status(400).json({ success: false, error: 'That friend could not be found.' });
    try {
      const [lo, hi] = pairOf(me, them);
      await pool.execute('DELETE FROM friendships WHERE account_lo = ? AND account_hi = ?', [lo, hi]);
      res.json({ success: true, data: await view(me) });
    } catch (err) {
      fail(res, err, 'POST /api/friends/remove');
    }
  });
};

module.exports.viewOf = viewOf;
module.exports.pairOf = pairOf;
module.exports.MAX_FRIENDS = MAX_FRIENDS;
module.exports.MAX_OUTGOING = MAX_OUTGOING;
