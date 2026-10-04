'use strict';
/**
 * One active session per account: the newest login wins (migration 039, accounts.active_session).
 *
 * Every login/registration/claim mints a session id and stores it on the account; the id rides in the JWT as `sid`. A write request
 * (anything but GET/HEAD/OPTIONS) from a token whose `sid` is no longer the account's active one is refused with 409
 * `{ code: 'session_replaced' }`, so a stale window can no longer roll progress back. Reads stay open.
 *
 * Fail open, like authority.cjs: a token without `sid` (issued before this shipped), an account with no active session, staff accounts
 * (admin/gm/gm_enabled) and any database error (migration not applied) all let the request through.
 * The id starts with its mint time in ms so the realtime relay (no database) can tell which of two sessions is newer.
 */
const crypto = require('crypto');

const SESSION_REPLACED = 'This account was opened somewhere else. This window stopped saving.';

function newSessionId() {
  return `${Date.now()}-${crypto.randomBytes(8).toString('hex')}`;
}

/** Make a new session the account's active one. Returns the id, or null when the column is missing (migration 039 not applied). */
async function claimSession(db, accountId) {
  const sid = newSessionId();
  try {
    await db.execute('UPDATE accounts SET active_session = ? WHERE id = ?', [sid, accountId]);
    return sid;
  } catch (err) {
    console.warn(`[session] claim unavailable: ${err.code || err.message}`);
    return null;
  }
}

/** Express-style guard: true when the request may go on, false after it answered 409. */
async function checkWrite(db, req, res) {
  const method = String(req.method || 'GET').toUpperCase();
  const sid = req.user && req.user.sid;
  if (!sid || method === 'GET' || method === 'HEAD' || method === 'OPTIONS') return true;
  if (await isReplaced(db, req.user)) {
    res.status(409).json({ success: false, error: SESSION_REPLACED, code: 'session_replaced' });
    return false;
  }
  return true;
}

/** Is this token's session no longer the account's active one? Staff and errors are never "replaced". */
async function isReplaced(db, user) {
  if (!user || !user.sid) return false;
  try {
    const [[acct]] = await db.execute('SELECT active_session, role, gm_enabled FROM accounts WHERE id = ? LIMIT 1', [user.accountId]);
    if (!acct || !acct.active_session || acct.active_session === user.sid) return false;
    if (acct.role === 'admin' || acct.role === 'gm' || acct.gm_enabled) return false;
    return true;
  } catch (err) {
    console.warn(`[session] check unavailable: ${err.code || err.message}`);
    return false;
  }
}

module.exports = { newSessionId, claimSession, checkWrite, isReplaced, SESSION_REPLACED };
