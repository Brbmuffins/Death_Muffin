/**
 * Account preferences: small UI settings that follow the account to any browser or device (table account_prefs, migration 040).
 *
 *   GET  /api/prefs                    -> { success, data: { <key>: <value>, ... } }          only known keys with a valid stored value
 *   POST /api/prefs  { prefs: {...} }  -> { success, data: { ...every pref of the account } }  1 to MAX_PER_REQUEST keys, all or nothing
 *
 * Only keys listed in DEFS are accepted, and each value is checked against its definition, so a pref can never carry free text or
 * grow without bound (a stored value is a JSON scalar of at most VALUE_MAX characters; an account holds at most one row per known key).
 * Preferences are conveniences, never progress: nothing here grants items, gold or levels, and the game works without them.
 * To add a setting: add a DEFS entry (and a matching key in archive/legacy-web:src/net/accountPrefs.ts); no migration needed.
 */
const DEFS = {
  /** Workbench / Acre stations: hide recipes the player lacks the skill or materials for. */
  only_craftable: { type: 'boolean' },
  /** Settings -> Loot: what happens to a freshly dropped piece of gear of each rarity (archive/legacy-web:src/gameplay/lootFilter.ts). Legendaries are never sold. */
  loot_common: { type: 'enum', values: ['ground', 'auto', 'gold'] },
  loot_uncommon: { type: 'enum', values: ['ground', 'auto', 'gold'] },
  loot_rare: { type: 'enum', values: ['ground', 'auto', 'gold'] },
  loot_epic: { type: 'enum', values: ['ground', 'auto', 'gold'] },
  loot_legendary: { type: 'enum', values: ['ground', 'auto'] },
};
const KEY_RE = /^[a-z][a-z0-9_]{0,39}$/;
const MAX_PER_REQUEST = 10;
const VALUE_MAX = 200;

/** Check one value against its definition. Returns { ok: true, value } or { ok: false, error }. */
function checkValue(key, raw) {
  if (typeof key !== 'string' || !KEY_RE.test(key) || !Object.prototype.hasOwnProperty.call(DEFS, key)) return { ok: false, error: 'That setting is not one the account can keep.' };
  const def = DEFS[key];
  if (def.type === 'boolean') return typeof raw === 'boolean' ? { ok: true, value: raw } : { ok: false, error: 'That setting must be on or off.' };
  if (def.type === 'enum') return def.values.includes(raw) ? { ok: true, value: raw } : { ok: false, error: 'That is not a choice for this setting.' };
  if (def.type === 'int') {
    return Number.isInteger(raw) && raw >= def.min && raw <= def.max ? { ok: true, value: raw } : { ok: false, error: `That setting must be a whole number from ${def.min} to ${def.max}.` };
  }
  return { ok: false, error: 'That setting is not one the account can keep.' };
}

/** Validate a POST body. Returns { error } or { prefs: { key: value } }. */
function parsePrefs(body) {
  const raw = body && typeof body === 'object' ? body.prefs : null;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'No settings were sent.' };
  const entries = Object.entries(raw);
  if (!entries.length) return { error: 'No settings were sent.' };
  if (entries.length > MAX_PER_REQUEST) return { error: 'Too many settings at once.' };
  const prefs = {};
  for (const [key, value] of entries) {
    const v = checkValue(key, value);
    if (!v.ok) return { error: v.error };
    if (JSON.stringify(v.value).length > VALUE_MAX) return { error: 'That setting is too long.' };
    prefs[key] = v.value;
  }
  return { prefs };
}

/** Turn stored rows into { key: value }, skipping anything unknown, unparsable or no longer valid (a retired key never reaches the client). */
function readRows(rows) {
  const out = {};
  for (const r of rows) {
    let value;
    try { value = JSON.parse(r.value); } catch { continue; }
    const v = checkValue(r.pref_key, value);
    if (v.ok) out[r.pref_key] = v.value;
  }
  return out;
}

module.exports = function mountPrefs(app, pool, { requireAuth }) {
  const load = async (accountId) => {
    const [rows] = await pool.execute('SELECT pref_key, value FROM account_prefs WHERE account_id = ?', [accountId]);
    return readRows(rows);
  };

  app.get('/api/prefs', requireAuth, async (req, res) => {
    try {
      res.json({ success: true, data: await load(req.user.accountId) });
    } catch (err) {
      // Migration 040 not applied yet: no saved preferences, and the client keeps its browser copy.
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.json({ success: true, data: {} });
      console.error('GET /api/prefs:', err.code || err.message);
      res.status(500).json({ success: false, error: 'Your settings could not be loaded.' });
    }
  });

  app.post('/api/prefs', requireAuth, async (req, res) => {
    const parsed = parsePrefs(req.body);
    if (parsed.error) return res.status(400).json({ success: false, error: parsed.error });
    try {
      for (const [key, value] of Object.entries(parsed.prefs)) {
        await pool.execute(
          'INSERT INTO account_prefs (account_id, pref_key, value) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)',
          [req.user.accountId, key, JSON.stringify(value)],
        );
      }
      res.json({ success: true, data: await load(req.user.accountId) });
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.status(503).json({ success: false, error: 'Settings cannot be saved to the account just yet. Please try again later.' });
      console.error('POST /api/prefs:', err.code || err.message);
      res.status(500).json({ success: false, error: 'Your settings could not be saved.' });
    }
  });
};

module.exports.DEFS = DEFS;
module.exports.checkValue = checkValue;
module.exports.parsePrefs = parsePrefs;
module.exports.readRows = readRows;
module.exports.MAX_PER_REQUEST = MAX_PER_REQUEST;
module.exports.VALUE_MAX = VALUE_MAX;
