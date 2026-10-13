'use strict';
/**
 * GM mode (owner 2026-10-13). An account that may GM (role admin / gm, or gm_enabled) plays like everyone else until it switches GM mode
 * on (in game: Settings -> GM mode). Only while it is on does the account count as staff (`isActive`): the authority guards, caps and
 * seals step aside for it. Every switch and every successful write made in GM mode lands in progress_audit, and switching it on marks the
 * account's characters (characters.gm_marked) so the leaderboard shows them as GM. Migration 046.
 *
 *   POST /api/gm/mode { on: bool } -> { success, data: { active } }     (403 for an account that may not GM)
 *
 * Any error reading the account counts as "not in GM mode" (closed, never open).
 */
const CACHE_MS = 10_000;
const WRITE_METHODS = new Set(['POST', 'PATCH', 'PUT', 'DELETE']);

function createGmMode(pool, { verifyToken, now = () => Date.now(), log = console } = {}) {
  const cache = new Map();   // accountId -> { allowed, active, at }

  async function state(accountId, fresh = false) {
    const c = cache.get(accountId);
    if (!fresh && c && now() - c.at < CACHE_MS) return c;
    const [[a]] = await pool.execute('SELECT role, gm_enabled, gm_active FROM accounts WHERE id = ? LIMIT 1', [accountId]);
    const allowed = !!a && (a.role === 'admin' || a.role === 'gm' || !!a.gm_enabled);
    const s = { allowed, active: allowed && !!a.gm_active, at: now() };
    cache.set(accountId, s);
    return s;
  }

  const isActive = async (accountId) => {
    try { return (await state(accountId)).active; } catch { return false; }
  };

  async function audit(accountId, characterId, kind, detail) {
    try {
      await pool.execute('INSERT INTO progress_audit (character_id, account_id, kind, mode, action, detail) VALUES (?, ?, ?, ?, ?, ?)',
        [characterId, accountId, kind, 'gm', 'log', JSON.stringify(detail)]);
    } catch (err) {
      log.error(`[GM] audit insert failed: ${err.code || err.message}`);
    }
  }

  /** Express middleware (before the routes): logs each successful write an account makes while in GM mode. Reads cost nothing. */
  function logWrites(req, res, next) {
    if (!WRITE_METHODS.has(req.method) || req.path === '/api/gm/mode') return next();
    const auth = req.headers && req.headers.authorization;
    let accountId = 0;
    if (auth && auth.startsWith('Bearer ') && verifyToken) {
      try { accountId = Number(verifyToken(auth.slice(7)).accountId) || 0; } catch { accountId = 0; }
    }
    if (accountId) {
      res.on('finish', () => {
        if (res.statusCode >= 400) return;
        isActive(accountId).then((on) => {
          if (!on) return;
          const cid = Number(req.body && req.body.characterId) || 0;
          return audit(accountId, cid, 'gm_write', { path: req.path, status: res.statusCode });
        }).catch(() => {});
      });
    }
    next();
  }

  function mount(app, { requireAuth }) {
    app.post('/api/gm/mode', requireAuth, async (req, res) => {
      const id = req.user.accountId;
      const on = !!(req.body && req.body.on === true);
      try {
        const s = await state(id, true);
        if (!s.allowed) return res.status(403).json({ success: false, error: 'GM mode is for staff accounts.' });
        if (s.active !== on) {
          await pool.execute('UPDATE accounts SET gm_active = ? WHERE id = ?', [on ? 1 : 0, id]);
          if (on) await pool.execute('UPDATE characters SET gm_marked = 1 WHERE account_id = ?', [id]);
          await audit(id, Number(req.body && req.body.characterId) || 0, 'gm_mode', { on });
          log.warn(`[GM] acct#${id} GM mode ${on ? 'on' : 'off'}`);
        }
        cache.delete(id);
        res.json({ success: true, data: { active: on } });
      } catch (err) {
        log.error(`POST /api/gm/mode acct#${id}: ${err.code || err.message}`);
        res.status(503).json({ success: false, error: 'GM mode could not be changed. Try again in a moment.' });
      }
    });
  }

  return { state, isActive, logWrites, mount, _cache: cache };
}

module.exports = { createGmMode };
