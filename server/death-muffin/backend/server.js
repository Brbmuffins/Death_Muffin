require('dotenv').config({ path: __dirname + '/.env' });
const express    = require('express');
const bcrypt     = require('bcrypt');
const jwt        = require('jsonwebtoken');
const mysql      = require('mysql2/promise');
const { execFile } = require('child_process');
const fs         = require('fs');
const crypto     = require('crypto');
const rateLimit  = require('express-rate-limit');
const { mergeOfflineStats } = require('./offline-sync.cjs');
const offlineFull = require('./offline-full-sync.cjs');
const gatheringRules = require('./gathering/gathering-rules.cjs');
const legionRules = require('./gathering/legion-rules.cjs');
const runeRules = require('./gathering/rune-rules.cjs');
const BAG_SLOTS = gatheringRules.BAG_SLOTS;
const inventorySave = require('./inventory-save.cjs');
const authority = require('./authority.cjs');
const kills = require('./kills.cjs');
const session = require('./session.cjs');
const { LEVEL_CAP: MAX_CHARACTER_LEVEL } = require('./gathering/authority-rules.cjs');

const app  = express();
const PORT = process.env.PORT || 5190;
const SALT_ROUNDS = 12;

let maintenanceMode = false;

// ── Zone allowlist (mirrors SceneNames.Zones in the Unity client) ────────────
// VoidDungeon is instanced — characters logging out there are spawned at HUB
// instead, because the instance no longer exists after the session ends.
// GM Island additionally requires gm_enabled on the account.
const VALID_ZONES     = new Set(['HUB','Darkwood','Ashen Wastelands','Toujam Basin','GM Island','VoidDungeon']);
const INSTANCED_ZONES = new Set(['VoidDungeon']);

// ── Combat anti-exploit state (in-process, cleared on restart) ────────────────
// recentHits:   `${accountId}:${charId}:${enemyInstanceId}` → { timestamp, enemyLevel, enemyCategory }
//               Kill endpoint requires an entry here within HIT_WINDOW_MS whose
//               enemyLevel/enemyCategory match the kill request.
//               Entry is consumed on kill so the next kill of the same instance
//               requires a fresh hit.
// lastKillTime: `${charId}:${enemyInstanceId}` → last confirmed kill timestamp.
//               Rejects rapid duplicate reports for the same corpse without
//               discarding legitimate simultaneous kills of different enemies.
const recentHits   = new Map();
const lastKillTime = new Map();
const HIT_WINDOW_MS    = 30_000; // hit must arrive within 30s before kill
const KILL_COOLDOWN_MS =  2_000; // duplicate-report guard per enemy instance

// Prune stale anti-exploit records every minute so the Maps don't grow unbounded.
setInterval(() => {
  const cutoff = Date.now() - HIT_WINDOW_MS;
  for (const [key, hit] of recentHits) if (hit.timestamp < cutoff) recentHits.delete(key);
  for (const [key, timestamp] of lastKillTime) if (timestamp < cutoff) lastKillTime.delete(key);
}, 60_000);

// ── Combat XP (level/category driven, no enemy_templates row required) ────────
const COMBAT_XP_MULTIPLIERS = { grunt: 1, brute: 1.5, elite: 2, boss: 5 };

function isValidEnemyLevel(level) {
  return Number.isInteger(level) && level >= 1 && level <= 100;
}

function isValidEnemyCategory(category) {
  return Object.prototype.hasOwnProperty.call(COMBAT_XP_MULTIPLIERS, category);
}

function calcXpGained(enemyLevel, enemyCategory) {
  const baseXp = 10 * enemyLevel + 5;
  return Math.round(baseXp * COMBAT_XP_MULTIPLIERS[enemyCategory]);
}

app.use(express.json({ limit: '512kb' }));
// Player-facing refusals (4xx) were invisible in the journal: a bag-save 400 loop once ran for minutes unseen.
// Log one line per refusal: method, path (ids collapsed), status and the player-readable error.
app.use((req, res, next) => {
  const json = res.json.bind(res);
  res.json = (body) => {
    // Most module routes refuse a player with a 200 { success: false, error } (the client reads the flag), which this log never saw.
    const refusedBody = res.statusCode < 400 && body && body.success === false && typeof body.error === 'string';
    if ((res.statusCode >= 400 && res.statusCode < 500 && res.statusCode !== 401 && res.statusCode !== 404) || refusedBody) {
      const path = String(req.originalUrl || req.url).split('?')[0].replace(/\/\d+(?=\/|$)/g, '/:id');
      const err = body && typeof body.error === 'string' ? body.error.slice(0, 160) : '';
      console.warn(`[refused] ${req.method} ${path} ${res.statusCode} ${err}`);
    }
    return json(body);
  };
  next();
});
app.set('trust proxy', 'loopback'); // nginx proxies from 127.0.0.1 — trust its X-Forwarded-For

const registerLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 min
  max: 5,                   // 5 signups per IP per window
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many signup attempts, try again later' },
});

// DB connection pool
const pool = mysql.createPool({
  host:     process.env.DB_HOST,
  user:     process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit: 10,
});

const loginLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 30, standardHeaders: true, legacyHeaders: false });
app.post('/login', loginLimiter, async (req, res) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string' || !username || !password)
    return res.status(400).json({ error: 'Username and password are required.' });
  try {
    const [rows] = await pool.execute('SELECT id, username, password_hash, active FROM accounts WHERE username = ? OR email = ? LIMIT 1', [username.trim(), username.trim()]);
    const account = rows[0];
    if (!account || !account.active || !(await bcrypt.compare(password, account.password_hash)))
      return res.status(401).json({ error: 'Invalid username or password.' });
    // Newest login wins: this token's session becomes the account's active one (session.cjs); older windows stop saving.
    const sid = await session.claimSession(pool, account.id);
    res.json({ token: jwt.sign({ accountId: account.id, username: account.username, ...(sid ? { sid } : {}) }, process.env.JWT_SECRET, { expiresIn: '24h' }) });
  } catch (err) {
    console.error('Login error:', err.code || err.message);
    res.status(500).json({ error: 'Account service is unavailable.' });
  }
});
app.post('/register', registerLimiter, async (req, res) => {
  const { username, email, password } = req.body || {};
  // Email is optional (friends-only signup). Supply one and it is still validated and kept unique;
  // omit it and the column is stored NULL, which the UNIQUE index allows any number of.
  const trimmedEmail = typeof email === 'string' ? email.trim() : '';
  const wantsEmail = trimmedEmail !== '';
  if (typeof username !== 'string' || !/^[a-zA-Z0-9_]{3,32}$/.test(username) || typeof password !== 'string' || password.length < 8 || password.length > 72)
    return res.status(400).json({ error: 'Use a username of 3–32 letters, digits or underscores and a password of 8–72 characters.' });
  if (wantsEmail && (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmedEmail) || trimmedEmail.length > 254))
    return res.status(400).json({ error: 'That email is not valid. Leave it blank to sign up without one.' });
  try {
    const hash = await bcrypt.hash(password, SALT_ROUNDS);
    const [result] = await pool.execute('INSERT INTO accounts (username, email, password_hash, active, alpha_access) VALUES (?, ?, ?, 1, 1)', [username, wantsEmail ? trimmedEmail : null, hash]);
    const sid = await session.claimSession(pool, result.insertId);
    res.status(201).json({ token: jwt.sign({ accountId: result.insertId, username, ...(sid ? { sid } : {}) }, process.env.JWT_SECRET, { expiresIn: '24h' }) });
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') return res.status(409).json({ error: 'Username or email is already registered.' });
    console.error('Registration error:', err.code || err.message);
    res.status(500).json({ error: 'Could not create the account.' });
  }
});
app.get('/health', (_, res) => res.json({ status: 'ok' }));
// "Play here": a window that was replaced by a newer login takes the account back. The (replaced) token is still signed and unexpired, so it
// proves who is asking; the reply is a fresh token on a new session, and the other window is the stale one from now on.
app.post('/api/session/claim', async (req, res) => {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'missing or invalid Authorization header' });
  let payload;
  try { payload = jwt.verify(auth.slice(7), process.env.JWT_SECRET); } catch { return res.status(401).json({ error: 'invalid or expired token' }); }
  try {
    const [[acct]] = await pool.execute('SELECT active FROM accounts WHERE id = ? LIMIT 1', [payload.accountId]);
    if (!acct || !acct.active) return res.status(401).json({ error: 'invalid or expired token' });
    const sid = await session.claimSession(pool, payload.accountId);
    const { iat, exp, sid: _old, ...claims } = payload;
    res.json({ token: jwt.sign({ ...claims, ...(sid ? { sid } : {}) }, process.env.JWT_SECRET, { expiresIn: '24h' }) });
  } catch (err) {
    console.error('Session claim error:', err.code || err.message);
    res.status(500).json({ error: 'Account service is unavailable.' });
  }
});
// ─── Character system ─────────────────────────────────────────────────────────

const CLASS_NAMES = ['Engineer', 'Guardian', 'Shadowblade', 'Cleric', 'Arcanist', 'Necromancer'];
// Release 0.3 classes, addressed by `discipline_index` only (POST /character
// still creates against the legacy CLASS_NAMES above). Kept as a separate map
// so indices 1–4 keep reporting exactly the class_name they always have —
// existing characters see no change — while 5–9 stop reporting undefined.
const DISCIPLINE_NAMES = {
  5: 'Grave Warden',
  6: 'Bell Monk',
  7: 'Carrion Witch',
  8: 'Hollow Knight',
  9: 'Veilwalker',
};
/** Highest accepted `discipline_index`. The client presents the names. */
const MAX_DISCIPLINE_INDEX = 9;

// JWT middleware – verifies token and pre-fetches character row
async function verifyJWT(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer '))
    return res.status(401).json({ error: 'missing or invalid Authorization header' });

  let payload;
  try {
    payload = jwt.verify(auth.slice(7), process.env.JWT_SECRET);
  } catch {
    return res.status(401).json({ error: 'invalid or expired token' });
  }

  req.user = payload;
  if (!(await session.checkWrite(pool, req, res))) return;

  try {
    // Character-bound tokens are authoritative. Account-only tokens remain valid
    // for login/character selection and resolve through accounts.active_character_id
    // during the client rollout.
    const [rows] = payload.characterId
      ? await pool.execute(
          'SELECT * FROM characters WHERE id = ? AND account_id = ? LIMIT 1',
          [payload.characterId, payload.accountId]
        )
      : await pool.execute(
          `SELECT c.* FROM characters c
           JOIN accounts a ON a.id = c.account_id
           WHERE c.account_id = ?
           ORDER BY (c.id = a.active_character_id) DESC, c.id ASC
           LIMIT 1`,
          [payload.accountId]
        );
    req.character = rows[0] || null;
  } catch (err) {
    console.error('verifyJWT character fetch error:', err);
    req.character = null;
  }

  try {
    const [[acct]] = await pool.execute(
      'SELECT username, role, gm_enabled, gm_level, gm_permissions FROM accounts WHERE id = ? LIMIT 1',
      [payload.accountId]
    );
    if (acct) {
      // Account role is the authoritative staff assignment. Keep compatibility
      // with the granular GM fields, but never let an admin/GM role authenticate
      // as a normal player because an older dashboard update changed only role.
      const staffRole = acct.role === 'admin' || acct.role === 'gm';
      req.gmFields = {
        gm_enabled: staffRole || !!acct.gm_enabled,
        gm_level: staffRole ? Math.max(1, acct.gm_level || 0) : (acct.gm_level || 0),
        gm_permissions: acct.gm_permissions || (staffRole ? '*' : ''),
        // Only the owner's verified Death Muffin account can use Auto Combat.
        auto_combat_allowed: acct.username.toLowerCase() === 'brbmuffins' && (staffRole || !!acct.gm_enabled),
      };
    } else {
      req.gmFields = { gm_enabled: 0, gm_level: 0, gm_permissions: '' };
    }
  } catch (err) {
    console.error('verifyJWT gm fetch error:', err);
    req.gmFields = { gm_enabled: 0, gm_level: 0, gm_permissions: '' };
  }

  next();
}

// Returns the 6-slot gear array for a character (null for empty slots)
async function getGearLoadout(characterId) {
  const [rows] = await pool.execute(`
    SELECT
      cg.slot,
      ii.id           AS item_id,
      ii.template_id,
      ii.power, ii.defense, ii.speed, ii.cdr, ii.heal_bonus,
      ii.attune_a, ii.attune_b, ii.obtained_at,
      it.name, it.rarity, it.description, it.class_mask,
      it.power_min,   it.power_max,
      it.defense_min, it.defense_max,
      it.speed_min,   it.speed_max,
      it.cdr_min,     it.cdr_max,
      it.heal_min,    it.heal_max
    FROM character_gear cg
    JOIN item_instance ii ON ii.id  = cg.item_id
    JOIN item_template it ON it.id  = ii.template_id
    WHERE cg.character_id = ?
    ORDER BY cg.slot
  `, [characterId]);

  const gear = new Array(6).fill(null);
  for (const row of rows) {
    gear[row.slot] = {
      slot:        row.slot,
      item_id:     row.item_id,
      template_id: row.template_id,
      name:        row.name,
      rarity:      row.rarity,
      description: row.description,
      class_mask:  row.class_mask,
      stats: {
        power:      row.power,
        defense:    row.defense,
        speed:      row.speed,
        cdr:        row.cdr,
        heal_bonus: row.heal_bonus,
      },
      attunements: { a: row.attune_a, b: row.attune_b },
      stat_ranges: {
        power:      { min: row.power_min,   max: row.power_max },
        defense:    { min: row.defense_min, max: row.defense_max },
        speed:      { min: row.speed_min,   max: row.speed_max },
        cdr:        { min: row.cdr_min,     max: row.cdr_max },
        heal_bonus: { min: row.heal_min,    max: row.heal_max },
      },
      obtained_at: row.obtained_at,
    };
  }
  return gear;
}

// Must match the client's xpToNext (src/gameplay/characterStats.ts): the browser levels the character and
// saves level/XP, so a steeper server curve made xpToNext in GET /character wrong (dormant while unused).
function characterXpToNext(level) {
  return Math.max(1, Number(level) || 1) * 100;
}

// MAX_CHARACTER_LEVEL (999) comes from src/gameplay/authorityRules.ts LEVEL_CAP via gathering/authority-rules.cjs, the same constant the client rules use.

async function normalizeCharacterProgress(char) {
  let level = Math.max(1, Number(char.level) || 1);
  let experience = Math.max(0, Number(char.experience) || 0);
  let xpToNext = characterXpToNext(level);
  // The cap is the level every save path caps at (save-progress, offline sync); XP left over at the cap is trimmed, not turned into levels.
  while (experience >= xpToNext && level < MAX_CHARACTER_LEVEL) {
    experience -= xpToNext;
    level++;
    xpToNext = characterXpToNext(level);
  }
  if (experience >= xpToNext) experience = xpToNext - 1;

  if (level !== Number(char.level) || experience !== Number(char.experience)) {
    await pool.execute(
      'UPDATE characters SET level = ?, experience = ? WHERE id = ?',
      [level, experience, char.id]
    );
    char.level = level;
    char.experience = experience;
    console.log(`[PROGRESS] Normalized char#${char.id} -> Lv${level} ${experience}/${xpToNext}xp`);
  }
  return xpToNext;
}

function formatCharacter(char, gear, gmFields = {}) {
  return {
    id:              char.id,
    class_index:     char.discipline_index ?? char.class_index,
    class_name:      char.discipline_index == null
      ? char.class_name
      : (DISCIPLINE_NAMES[char.discipline_index] ?? CLASS_NAMES[char.discipline_index] ?? char.class_name),
    level:           char.level,
    experience:      char.experience,
    xpToNext:        characterXpToNext(char.level),
    gold:            char.gold     ?? 0,
    stat_str:        char.stat_str ?? 5,
    stat_agi:        char.stat_agi ?? 5,
    stat_int:        char.stat_int ?? 5,
    stat_vit:        char.stat_vit ?? 10,
    pos_x:           char.pos_x,
    pos_y:           char.pos_y,
    pos_z:           char.pos_z,
    pos_map:         char.pos_map,
    map:             char.pos_map,   // Unity reads .map (CharacterResponse.map → RodPlayerAuth.zone)
    orientation:     char.orientation,
    online:          !!char.online,
    last_logout:     char.last_logout,
    created_at:      char.created_at,
    gear,
    gm_enabled:      !!gmFields.gm_enabled,
    gm_level:        gmFields.gm_level     ?? 0,
    gm_permissions:  gmFields.gm_permissions ?? '',
    auto_combat_allowed: !!gmFields.auto_combat_allowed,
  };
}

// POST /character – permanently select one character row per account/class slot.
// Existing progression is never moved between classes.
app.post('/character', verifyJWT, async (req, res) => {
  const class_index = parseInt(req.body.class_index, 10);
  if (isNaN(class_index) || class_index < 0 || class_index >= CLASS_NAMES.length)
    return res.status(400).json({ error: 'class_index must be 0–5' });

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [result] = await conn.execute(
      `INSERT INTO characters (account_id, class_index, class_name)
       VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id), class_name = VALUES(class_name)`,
      [req.user.accountId, class_index, CLASS_NAMES[class_index]]
    );
    const characterId = result.insertId;
    await conn.execute(
      'UPDATE accounts SET active_character_id = ? WHERE id = ?',
      [characterId, req.user.accountId]
    );
    const [[character]] = await conn.execute(
      'SELECT * FROM characters WHERE id = ? AND account_id = ?',
      [characterId, req.user.accountId]
    );
    await conn.commit();

    const characterToken = jwt.sign(
      { accountId: req.user.accountId, username: req.user.username, characterId, ...(req.user.sid ? { sid: req.user.sid } : {}) },
      process.env.JWT_SECRET,
      { expiresIn: process.env.JWT_EXPIRES_IN || '24h' }
    );
    const gear = await getGearLoadout(characterId);
    res.status(result.affectedRows === 1 ? 201 : 200).json({
      ...formatCharacter(character, gear, req.gmFields),
      token: characterToken,
    });
  } catch (err) {
    await conn.rollback();
    console.error('POST /character error:', err);
    res.status(500).json({ error: 'internal server error' });
  } finally {
    conn.release();
  }
});

// GET /character – spawn-path load: character + full gear in one shot
app.get('/character', verifyJWT, async (req, res) => {
  if (!req.character)
    return res.status(404).json({ error: 'no character found for this account' });

  try {
    await normalizeCharacterProgress(req.character);
    // Reaching this route means the authenticated game server is establishing
    // the character session. Position checkpoints must not clear this flag.
    await pool.execute(
      'UPDATE characters SET online = 1 WHERE id = ?',
      [req.character.id]
    );
    req.character.online = 1;
    const gear = await getGearLoadout(req.character.id);
    res.json(formatCharacter(req.character, gear, req.gmFields));
  } catch (err) {
    console.error('GET /character error:', err);
    res.status(500).json({ error: 'internal server error' });
  }
});

// PATCH /character/position – called on disconnect or server shutdown
app.patch('/character/position', verifyJWT, async (req, res) => {
  if (!req.character)
    return res.status(404).json({ error: 'no character found for this account' });

  const x = parseFloat(req.body.x), y = parseFloat(req.body.y), z = parseFloat(req.body.z);
  const orientation = parseFloat(req.body.orientation);
  const isLogout = req.body.logout === true;
  // Finite and bounded (the offline import uses the same 100000): Infinity and 1e30 are not NaN but the position columns cannot hold them.
  if ([x, y, z, orientation].some(v => !Number.isFinite(v) || Math.abs(v) >= 100000))
    return res.status(400).json({ error: 'x, y, z, and orientation must be numbers' });

  let map;
  if (req.body.map && typeof req.body.map === 'string' && req.body.map.trim()) {
    const zone = req.body.map.trim();
    if (!VALID_ZONES.has(zone))
      return res.status(400).json({ error: `unknown zone: ${zone}` });
    if (zone === 'GM Island' && !req.gmFields.gm_enabled)
      return res.status(400).json({ error: 'GM Island requires GM access' });
    // Instanced zones (VoidDungeon) don't persist — store HUB so the player respawns safely
    map = INSTANCED_ZONES.has(zone) ? 'HUB' : zone;
  } else {
    map = req.character.pos_map;
  }

  try {
    if (isLogout) {
      await pool.execute(
        `UPDATE characters
         SET pos_x = ?, pos_y = ?, pos_z = ?, pos_map = ?, orientation = ?,
             last_logout = NOW(), online = 0
         WHERE id = ?`,
        [x, y, z, map, orientation, req.character.id]
      );
      console.log(`[LOGOUT] ${req.user.username} (id:${req.user.accountId}) — ${map} (${x.toFixed(1)}, ${y.toFixed(1)}, ${z.toFixed(1)})`);
      // Only a terminal disconnect is a logout. Periodic and zone-transition
      // checkpoints persist position without changing presence or notifying Discord.

    } else {
      await pool.execute(
        `UPDATE characters
         SET pos_x = ?, pos_y = ?, pos_z = ?, pos_map = ?, orientation = ?
         WHERE id = ?`,
        [x, y, z, map, orientation, req.character.id]
      );
      console.log(`[POSITION] ${req.user.username} (id:${req.user.accountId}) — ${map} (${x.toFixed(1)}, ${y.toFixed(1)}, ${z.toFixed(1)})`);
    }
    res.json({ ok: true });
  } catch (err) {
    console.error('PATCH /character/position error:', err);
    res.status(500).json({ error: 'internal server error' });
  }
});

// POST /character/gear/equip – equip an item_instance owned by this character
app.post('/character/gear/equip', verifyJWT, async (req, res) => {
  if (!req.character)
    return res.status(404).json({ error: 'no character found for this account' });

  const item_id = parseInt(req.body.item_id, 10);
  if (isNaN(item_id) || item_id < 1)
    return res.status(400).json({ error: 'item_id must be a positive integer' });

  try {
    const [rows] = await pool.execute(`
      SELECT ii.id, it.slot
      FROM item_instance ii
      JOIN item_template it ON it.id = ii.template_id
      WHERE ii.id = ? AND ii.character_id = ?
    `, [item_id, req.character.id]);

    if (rows.length === 0)
      return res.status(404).json({ error: 'item not found or does not belong to this character' });

    const { id: instId, slot } = rows[0];

    await pool.execute(
      `INSERT INTO character_gear (character_id, slot, item_id) VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE item_id = ?`,
      [req.character.id, slot, instId, instId]
    );

    const gear = await getGearLoadout(req.character.id);
    res.json({ gear });
  } catch (err) {
    console.error('POST /character/gear/equip error:', err);
    res.status(500).json({ error: 'internal server error' });
  }
});

// GET /items – all item templates, no auth (Unity inventory UI)
app.get('/items', async (req, res) => {
  try {
    const [rows] = await pool.execute(
      'SELECT * FROM item_template ORDER BY slot, id'
    );
    res.json(rows);
  } catch (err) {
    console.error('GET /items error:', err);
    res.status(500).json({ error: 'internal server error' });
  }
});

// Catch malformed JSON bodies (body-parser throws SyntaxError with type 'entity.parse.failed').
// Without this, Express dumps a full stack trace to the journal on every bad request.
app.use((err, req, res, next) => {
  if (err.type === 'entity.parse.failed')
    return res.status(400).json({ error: 'invalid JSON body' });
  // The 512 KB body limit: say so in JSON (the client shows server error strings verbatim) instead of Express's HTML page.
  if (err.type === 'entity.too.large')
    return res.status(413).json({ error: 'That request is too large for the server to accept.' });
  next(err);
});

// ─── Lightweight JWT middleware (no character prefetch) ───────────────────────

async function requireJWT(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer '))
    return res.status(401).json({ success: false, error: 'missing or invalid Authorization header' });
  try {
    req.user = jwt.verify(auth.slice(7), process.env.JWT_SECRET);
  } catch {
    return res.status(401).json({ success: false, error: 'invalid or expired token' });
  }
  if (!(await session.checkWrite(pool, req, res))) return;
  next();
}

// Cheap "am I still the active window?" probe for the client (reads are never refused, so a quiet stale window would not otherwise learn it).
app.get('/api/session', requireJWT, async (req, res) => {
  res.json({ success: true, active: !(await session.isReplaced(pool, req.user)) });
});

function requireGameServerToken(req, res, next) {
  const provided = req.get('X-Game-Server-Token') || '';
  const expected = process.env.CROSSWORLDS_GAME_SERVICE_TOKEN ||
                   process.env.GAME_SERVER_TOKEN || '';
  const providedBuffer = Buffer.from(provided);
  const expectedBuffer = Buffer.from(expected);
  if (!expected || providedBuffer.length !== expectedBuffer.length ||
      !crypto.timingSafeEqual(providedBuffer, expectedBuffer))
    return res.status(401).json({ success: false, error: 'invalid game server token' });
  next();
}

async function ownedCharacter(req, res, characterId) {
  const cid = parseInt(characterId, 10);
  if (!cid) { res.status(400).json({ success: false, error: 'invalid characterId' }); return null; }
  const [rows] = await pool.execute(
    'SELECT * FROM characters WHERE id = ? AND account_id = ?',
    [cid, req.user.accountId]
  );
  if (!rows.length) {
    res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
    return null;
  }
  return rows[0];
}

// Dedicated Unity servers synchronize Loot Forge definitions at startup.
app.post('/api/game/items/definitions', requireGameServerToken, async (req, res) => {
  const itemId = typeof req.body.itemId === 'string' ? req.body.itemId.trim().toLowerCase() : '';
  const displayName = typeof req.body.displayName === 'string' ? req.body.displayName.trim() : '';
  const rarity = req.body.rarity;
  const itemType = req.body.itemType;
  const equipmentSlot = typeof req.body.equipmentSlot === 'string' && req.body.equipmentSlot.trim()
    ? req.body.equipmentSlot.trim() : null;
  const iconId = typeof req.body.iconId === 'string' && req.body.iconId.trim()
    ? req.body.iconId.trim() : null;
  const sellValue = Math.max(parseInt(req.body.sellValue, 10) || 0, 0);
  const crafted = req.body.crafted ? 1 : 0;
  const stackable = req.body.stackable ? 1 : 0;
  const twoHanded = req.body.twoHanded ? 1 : 0;
  const maxStackSize = stackable
    ? Math.min(Math.max(parseInt(req.body.maxStackSize, 10) || 1, 1), 999999)
    : 1;
  const validRarities = new Set(['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic']);
  const validItemTypes = new Set([
    'material', 'weapon', 'armor_head', 'armor_chest', 'armor_legs',
    'armor_feet', 'armor_hands', 'offhand', 'ring', 'trinket'
  ]);
  const validEquipmentSlots = new Set([
    'head', 'chest', 'legs', 'feet', 'hands', 'main_hand', 'off_hand', 'ring', 'trinket'
  ]);
  const statBonus = {
    stat_str: Math.max(parseInt(req.body.statStr, 10) || 0, 0),
    stat_agi: Math.max(parseInt(req.body.statAgi, 10) || 0, 0),
    stat_int: Math.max(parseInt(req.body.statInt, 10) || 0, 0),
    stat_vit: Math.max(parseInt(req.body.statVit, 10) || 0, 0),
  };

  if (!/^[a-z0-9_-]{1,64}$/.test(itemId))
    return res.status(400).json({ success: false, error: 'invalid itemId' });
  if (!displayName || displayName.length > 128)
    return res.status(400).json({ success: false, error: 'invalid displayName' });
  if (!validRarities.has(rarity) || !validItemTypes.has(itemType))
    return res.status(400).json({ success: false, error: 'invalid rarity or itemType' });
  if (itemType === 'material' && equipmentSlot !== null)
    return res.status(400).json({ success: false, error: 'materials cannot have an equipment slot' });
  if (itemType !== 'material' && !validEquipmentSlots.has(equipmentSlot))
    return res.status(400).json({ success: false, error: 'equipmentSlot is required for equipment' });

  try {
    await pool.execute(
      `INSERT INTO items
         (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus,
          icon_id, sell_value, crafted, stackable, max_stack_size)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
         name=VALUES(name), rarity=VALUES(rarity), item_type=VALUES(item_type),
         equipment_slot=VALUES(equipment_slot), two_handed=VALUES(two_handed), stat_bonus=VALUES(stat_bonus),
         icon_id=VALUES(icon_id), sell_value=VALUES(sell_value), crafted=VALUES(crafted),
         stackable=VALUES(stackable), max_stack_size=VALUES(max_stack_size)`,
      [itemId, displayName, rarity, itemType, equipmentSlot, twoHanded, JSON.stringify(statBonus),
       iconId, sellValue, crafted, stackable, maxStackSize]
    );
    res.json({ success: true, data: { itemId, equipmentSlot, stackable: !!stackable, maxStackSize } });
  } catch (err) {
    console.error(`POST /api/game/items/definitions ${itemId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Progression ──────────────────────────────────────────────────────────────

const offlineSyncLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 10, standardHeaders: true, legacyHeaders: false });
app.get('/api/offline/snapshot', verifyJWT, async (req, res) => {
  if (!req.character) return res.status(404).json({ error: 'Create an online character before syncing.' });
  try {
    const snapshot = await offlineFull.capture(pool, req.character.id, req.user.username);
    res.json({ snapshot, fingerprint: offlineFull.fingerprint(snapshot), summary: offlineFull.summary(snapshot) });
  } catch (err) {
    console.error('Offline snapshot error:', err.code || err.message);
    res.status(500).json({ error: 'Could not load online save.' });
  }
});

app.get('/api/offline/versions', verifyJWT, async (req, res) => {
  if (!req.character) return res.status(404).json({ error: 'Online character not found.' });
  try {
    const [rows] = await pool.execute('SELECT id, source, snapshot, created_at FROM character_save_versions WHERE account_id = ? AND character_id = ? ORDER BY id DESC LIMIT 20',
      [req.user.accountId, req.character.id]);
    res.json({ versions: rows.map((row) => ({ id: row.id, source: row.source, createdAt: row.created_at, summary: offlineFull.summary(typeof row.snapshot === 'string' ? JSON.parse(row.snapshot) : row.snapshot) })) });
  } catch (err) {
    console.error('Offline versions error:', err.code || err.message);
    res.status(500).json({ error: 'Could not load saved versions.' });
  }
});

async function loadOfflineVersion(req, res, source, account, expectedFingerprint, confirmed = false) {
  if (!req.character) return res.status(404).json({ error: 'Create an online character before syncing.' });
  if (typeof expectedFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(expectedFingerprint))
    return res.status(400).json({ error: 'Refresh the online save comparison before loading a version.' });
  try { offlineFull.validate(account, Number(req.character.discipline_index ?? req.character.class_index)); }
  catch (err) { return res.status(400).json({ error: err.message }); }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [[locked]] = await conn.execute('SELECT id FROM characters WHERE id = ? AND account_id = ? FOR UPDATE',
      [req.character.id, req.user.accountId]);
    if (!locked) { await conn.rollback(); return res.status(404).json({ error: 'Online character not found.' }); }
    const before = await offlineFull.capture(conn, locked.id, req.user.username);
    if (offlineFull.fingerprint(before) !== expectedFingerprint) {
      await conn.rollback();
      return res.status(409).json({ error: 'The online save changed. Compare the saves again before choosing.', summary: offlineFull.summary(before) });
    }
    // Plausibility check of a browser-only save against the online one (authority.cjs). Report mode only logs. In enforce mode an
    // implausible jump needs the player's explicit confirmation; nothing has been written yet, so the audit rows are committed.
    if (source === 'offline') {
      const check = await authority.guardOfflineLoad(conn, { characterId: locked.id, accountId: req.user.accountId, online: before, offline: account, confirmed: confirmed === true, account: { staff: await isStaffAccount(req).catch(() => false) } });
      if (check.needsConfirm) {
        await conn.commit();
        return res.status(409).json({ error: check.message, implausible: true, summary: offlineFull.summary(account) });
      }
    }
    await conn.execute('INSERT INTO character_save_versions (account_id, character_id, source, snapshot) VALUES (?, ?, ?, ?)',
      [req.user.accountId, locked.id, 'online', JSON.stringify(before)]);
    await conn.execute('INSERT INTO character_save_versions (account_id, character_id, source, snapshot) VALUES (?, ?, ?, ?)',
      [req.user.accountId, locked.id, source, JSON.stringify(account)]);
    await offlineFull.apply(conn, locked.id, account);
    await offlineFull.pruneVersions(conn, locked.id);
    const after = await offlineFull.capture(conn, locked.id, req.user.username);
    await conn.commit();
    // The load rewrote level, XP, necromancer kills and the Chronicle: the kill ledger starts again from them (step 2).
    if (kills.killsMode() !== 'off') await kills.rebase(pool, locked.id);
    res.json({ summary: offlineFull.summary(after), fingerprint: offlineFull.fingerprint(after) });
  } catch (err) {
    await conn.rollback().catch(() => {});
    if (err instanceof RangeError) return res.status(400).json({ error: err.message });
    console.error('Offline full save error:', err.code || err.message);
    res.status(500).json({ error: 'Could not load the selected save.' });
  } finally { conn.release(); }
}

app.post('/api/offline/load', offlineSyncLimiter, verifyJWT, async (req, res) => {
  await loadOfflineVersion(req, res, 'offline', req.body?.snapshot, req.body?.expectedFingerprint, req.body?.confirmImplausible === true);
});

app.post('/api/offline/restore', offlineSyncLimiter, verifyJWT, async (req, res) => {
  if (!req.character || !Number.isInteger(req.body?.versionId)) return res.status(400).json({ error: 'Choose a saved version.' });
  try {
    const [[row]] = await pool.execute('SELECT snapshot FROM character_save_versions WHERE id = ? AND account_id = ? AND character_id = ?',
      [req.body.versionId, req.user.accountId, req.character.id]);
    if (!row) return res.status(404).json({ error: 'Saved version not found.' });
    const account = typeof row.snapshot === 'string' ? JSON.parse(row.snapshot) : row.snapshot;
    await loadOfflineVersion(req, res, 'restored', account, req.body.expectedFingerprint);
  } catch (err) {
    console.error('Offline restore error:', err.code || err.message);
    res.status(500).json({ error: 'Could not restore saved version.' });
  }
});


app.post('/api/offline/sync-stats', offlineSyncLimiter, verifyJWT, async (req, res) => {
  if (!req.character)
    return res.status(404).json({ error: 'Create an online character before syncing offline stats.' });
  const offlineClass = req.body?.classIndex;
  if (!Number.isInteger(offlineClass) || offlineClass !== Number(req.character.discipline_index ?? req.character.class_index))
    return res.status(400).json({ error: 'The offline and online characters must use the same discipline.' });

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [[online]] = await conn.execute(
      'SELECT level, experience FROM characters WHERE id = ? AND account_id = ? FOR UPDATE',
      [req.character.id, req.user.accountId]
    );
    if (!online) { await conn.rollback(); return res.status(404).json({ error: 'Online character not found.' }); }
    let merged;
    try { merged = mergeOfflineStats(online, req.body); }
    catch { await conn.rollback(); return res.status(400).json({ error: 'Invalid offline level or XP.' }); }
    if (merged.improved) {
      const check = await authority.guardOfflineStats(conn, { characterId: req.character.id, accountId: req.user.accountId, online, level: merged.level, experience: merged.experience, confirmed: req.body?.confirmImplausible === true, account: { staff: await isStaffAccount(req).catch(() => false) } });
      if (check.needsConfirm) {
        await conn.commit();
        return res.status(409).json({ error: check.message, implausible: true });
      }
      await conn.execute('UPDATE characters SET level = ?, experience = ? WHERE id = ?',
        [merged.level, merged.experience, req.character.id]);
    }
    await conn.commit();
    res.json({ level: merged.level, experience: merged.experience, improved: merged.improved });
  } catch (err) {
    await conn.rollback();
    console.error('Offline stats sync error:', err.code || err.message);
    res.status(500).json({ error: 'Could not sync offline stats.' });
  } finally { conn.release(); }
});

app.post('/api/character/save-progress', requireJWT, async (req, res) => {
  const { characterId } = req.body;
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    // Only a number (or a non-blank numeric string) is a value: Number(null), Number(''), Number([]) and Number(false) are all 0 and used to wipe the field.
    const bounded = (value, fallback, min, max) => {
      const n = typeof value === 'number' ? value : typeof value === 'string' && value.trim() !== '' ? Number(value) : NaN;
      return Number.isFinite(n) ? Math.min(max, Math.max(min, Math.trunc(n))) : fallback;
    };
    const next = {
      level: bounded(req.body.level, char.level, 1, MAX_CHARACTER_LEVEL), xp: bounded(req.body.xp, char.experience, 0, 2147483647), gold: bounded(req.body.gold, char.gold, 0, 2147483647),
      stat_str: bounded(req.body.stat_str, char.stat_str, 0, 65535), stat_agi: bounded(req.body.stat_agi, char.stat_agi, 0, 65535),
      stat_int: bounded(req.body.stat_int, char.stat_int, 0, 65535), stat_vit: bounded(req.body.stat_vit, char.stat_vit, 0, 65535),
    };
    // Step 2: kill reports ride along with the save (one request, so the credits are there before the gain is judged); AUTHORITY_KILLS=off ignores them.
    const staff = await isStaffAccount(req).catch(() => false);
    let reportNotice = '';
    if (Array.isArray(req.body.killReports) && req.body.killReports.length && kills.killsMode() !== 'off') {
      reportNotice = (await kills.handleReports(pool, { char, accountId: req.user.accountId, reports: req.body.killReports, account: { staff } })).message;
    }
    // Plausibility guard (authority.cjs): AUTHORITY_MODE=report logs and changes nothing; enforce holds back what play cannot explain.
    const verdict = await authority.guardProgress(pool, { char, next, account: { staff } });
    if (reportNotice) verdict.message = [reportNotice, verdict.message].filter(Boolean).join(' ');
    const w = verdict.write;
    await pool.execute(
      'UPDATE characters SET level=?, experience=?, gold=?, stat_str=?, stat_agi=?, stat_int=?, stat_vit=? WHERE id=?',
      [w.level, w.xp, w.gold, w.stat_str, w.stat_agi, w.stat_int, w.stat_vit, char.id]
    );
    const [[updated]] = await pool.execute('SELECT * FROM characters WHERE id = ?', [char.id]);
    console.log(`[PROGRESS] ${req.user.username} char#${char.id} → Lv${updated.level} ${updated.experience}xp ${updated.gold}g`);
    res.json({ success: true, data: updated, ...(verdict.message ? { authority: { message: verdict.message } } : {}) });
  } catch (err) {
    console.error(`POST /api/character/save-progress char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Inventory ────────────────────────────────────────────────────────────────




const { INV_SELECT } = require('./bag-store.cjs');

app.get('/api/inventory/:characterId', requireJWT, async (req, res) => {
  try {
    const char = await ownedCharacter(req, res, req.params.characterId);
    if (!char) return;
    const [rows] = await pool.execute(INV_SELECT, [char.id]);
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error(`GET /api/inventory/${req.params.characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

app.post('/api/inventory/add-item', requireJWT, async (req, res) => {
  const characterId = Number(req.body.characterId);
  const itemId = typeof req.body.itemId === 'string' ? req.body.itemId.trim() : '';
  const quantity = Number(req.body.quantity);
  if (!Number.isInteger(characterId) || characterId <= 0 || !itemId ||
      !Number.isInteger(quantity) || quantity < 1 || quantity > 9999) {
    return res.status(400).json({
      success: false,
      error: 'characterId, itemId, and a quantity from 1 to 9999 are required'
    });
  }

  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    const [[item]] = await pool.execute(
      'SELECT id, stackable, max_stack_size FROM items WHERE id = ?',
      [itemId]
    );
    if (!item)
      return res.status(404).json({ success: false, error: `unknown item: ${itemId}` });
    const addCheck = await authority.guardAddItem(pool, { characterId: char.id, accountId: char.account_id, itemId, quantity, account: { staff: await isStaffAccount(req).catch(() => false) } });
    if (!addCheck.allowed) return res.status(400).json({ success: false, error: addCheck.message });

    const stackable = !!item.stackable;
    const maxStack = stackable ? Math.max(Number(item.max_stack_size) || 1, 1) : 1;
    const conn = await pool.getConnection();
    let remaining = quantity;
    try {
      await conn.beginTransaction();
      const [bagRows] = await conn.execute(
        `SELECT id, slot_index, item_id, quantity
           FROM inventory
          WHERE character_id = ? AND slot_index BETWEEN 0 AND ?
          ORDER BY slot_index FOR UPDATE`,
        [char.id, BAG_SLOTS - 1]
      );

      if (stackable) {
        for (const row of bagRows) {
          if (remaining <= 0) break;
          if (row.item_id !== itemId || Number(row.quantity) >= maxStack) continue;
          const added = Math.min(remaining, maxStack - Number(row.quantity));
          await conn.execute(
            'UPDATE inventory SET quantity = quantity + ? WHERE id = ?',
            [added, row.id]
          );
          remaining -= added;
        }
      }

      const occupied = new Set(bagRows.map(row => Number(row.slot_index)));
      for (let slot = 0; slot < BAG_SLOTS && remaining > 0; slot++) {
        if (occupied.has(slot)) continue;
        const added = Math.min(remaining, maxStack);
        await conn.execute(
          `INSERT INTO inventory
             (character_id, slot_index, item_id, quantity, equipped, equipped_slot)
           VALUES (?, ?, ?, ?, 0, NULL)`,
          [char.id, slot, itemId, added]
        );
        remaining -= added;
      }
      await conn.commit();
    } catch (error) {
      await conn.rollback();
      throw error;
    } finally {
      conn.release();
    }

    const stored = quantity - remaining;
    console.log(`[INVENTORY] ${req.user.username} char#${char.id} added ${itemId} x${stored}` +
                (remaining > 0 ? ` (${remaining} rejected: inventory full)` : ''));
    res.json({ success: true, data: { stored, rejected: remaining } });
  } catch (err) {
    console.error(`POST /api/inventory/add-item char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

app.post('/api/inventory/save', requireJWT, async (req, res) => {
  const body = req.body || {};
  const { characterId } = body;
  if (!Array.isArray(body.slots))
    return res.status(400).json({ success: false, error: 'slots must be an array' });
  // Equipped gear lives in reserved slots 100-108 (managed by /equip), the tool belt in 110-113 (/belt), the Legion kit in 120-121 (/kit) and the rune sockets in 130-134 (/rune).
  // Older clients echo those rows back with the bag, which made every save fail; the save owns the bag only, so ignore them.
  const slots = body.slots.filter(s => !(Number(s && s.slot_index) >= 100 && Number(s.slot_index) <= runeRules.RUNE_BASE + runeRules.RUNE_SLOT_COUNT - 1));
  // A stale 24-slot tab sends no bagSize; the save then only touches slots 0-23 (see inventory-save.cjs).
  const bagSize = inventorySave.saveBagSize(body.bagSize);
  if (bagSize === null)
    return res.status(400).json({ success: false, error: `bagSize must be a whole number from 1 to ${BAG_SLOTS}` });
  const slotError = inventorySave.slotProblem(slots, bagSize);
  if (slotError) return res.status(400).json({ success: false, error: slotError });
  if (slots.some(s => typeof s.item_id !== 'string' || !s.item_id.trim() ||
      !Number.isInteger(Number(s.quantity)) || Number(s.quantity) < 1))
    return res.status(400).json({ success: false, error: 'each slot requires an item_id and positive integer quantity' });
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    const itemIds = [...new Set(slots.map(s => s.item_id.trim()))];
    const itemPolicies = new Map();
    if (itemIds.length > 0) {
      const placeholders = itemIds.map(() => '?').join(',');
      const [items] = await pool.execute(
        `SELECT id, stackable, max_stack_size FROM items WHERE id IN (${placeholders})`,
        itemIds
      );
      for (const item of items) itemPolicies.set(item.id, item);
    }
    for (const s of slots) {
      const policy = itemPolicies.get(s.item_id.trim());
      if (!policy)
        return res.status(400).json({ success: false, error: `unknown item: ${s.item_id}` });
      const maxStack = policy.stackable ? Math.max(Number(policy.max_stack_size) || 1, 1) : 1;
      if (Number(s.quantity) > maxStack)
        return res.status(400).json({
          success: false,
          error: `${s.item_id} exceeds its maximum stack size of ${maxStack}`
        });
    }
    const staff = await isStaffAccount(req).catch(() => false);
    let notice = '';
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      const guard = (existingRows, sent) => authority.guardBagSave(conn, { characterId: char.id, accountId: char.account_id, existingRows, slots: sent, bagSize, account: { staff } });
      ({ notice } = await inventorySave.replaceBag(conn, char.id, slots, bagSize, char.account_id, guard));
      await conn.commit();
    } catch (e) {
      await conn.rollback();
      throw e;
    } finally {
      conn.release();
    }
    const [rows] = await pool.execute(INV_SELECT, [char.id]);
    res.json({ success: true, data: rows, ...(notice ? { authority: { message: notice } } : {}) });
  } catch (err) {
    // A save that names a relic it does not own (or one it cannot prove) is refused, readably, and nothing was written.
    if (err && err.refusal) return res.status(400).json({ success: false, error: err.message });
    console.error(`POST /api/inventory/save char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

app.post('/api/inventory/equip', requireJWT, async (req, res) => {
  const { characterId, slot_index, equipped } = req.body;
  if (slot_index === undefined || equipped === undefined)
    return res.status(400).json({ success: false, error: 'slot_index and equipped required' });
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      const [[inv]] = await conn.execute(
        `SELECT inv.id, inv.slot_index, inv.item_id, inv.equipped,
                i.item_type, i.equipment_slot, i.two_handed
           FROM inventory inv JOIN items i ON i.id = inv.item_id
          WHERE inv.character_id = ? AND inv.slot_index = ? FOR UPDATE`,
        [char.id, slot_index]
      );
      if (!inv) {
        await conn.rollback();
        return res.status(404).json({ success: false, error: 'slot not found' });
      }
      if (equipped && (!inv.equipment_slot || inv.item_type === 'material')) {
        await conn.rollback();
        return res.status(400).json({ success: false, error: 'item is not configured as equippable' });
      }
      const reservedSlots = {
        head: 100, chest: 101, legs: 102, feet: 103, hands: 104,
        main_hand: 105, off_hand: 106, ring: 107, trinket: 108
      };
      const [allRows] = await conn.execute(
        `SELECT inv.id, inv.slot_index, inv.equipped_slot, i.two_handed
           FROM inventory inv JOIN items i ON i.id = inv.item_id
          WHERE inv.character_id = ? FOR UPDATE`,
        [char.id]
      );
      const occupiedBag = new Set(allRows
        .filter(row => row.id !== inv.id && row.slot_index >= 0 && row.slot_index < BAG_SLOTS)
        .map(row => Number(row.slot_index)));
      const freeBag = [];
      for (let i = 0; i < BAG_SLOTS; i++) if (!occupiedBag.has(i)) freeBag.push(i);

      if (equipped) {
        const reservedSlot = reservedSlots[inv.equipment_slot];
        if (reservedSlot === undefined) {
          await conn.rollback();
          return res.status(400).json({ success: false, error: 'unsupported equipment slot' });
        }
        const displaced = allRows.filter(row => {
          if (row.id === inv.id || !row.equipped_slot) return false;
          if (row.equipped_slot === inv.equipment_slot) return true;
          if (inv.two_handed && row.equipped_slot === 'off_hand') return true;
          return inv.equipment_slot === 'off_hand' && row.equipped_slot === 'main_hand' && row.two_handed;
        });
        if (freeBag.length < displaced.length) {
          await conn.rollback();
          return res.status(409).json({ success: false, error: 'Not enough inventory space to swap equipment.' });
        }
        for (const row of displaced) {
          await conn.execute(
            `UPDATE inventory
                SET slot_index = ?, equipped = 0, equipped_slot = NULL
              WHERE id = ?`,
            [-1000000 - Number(row.id), row.id]
          );
        }
        await conn.execute(
          `UPDATE inventory SET slot_index = ?, equipped = 1, equipped_slot = ? WHERE id = ?`,
          [reservedSlot, inv.equipment_slot, inv.id]
        );
        for (let i = 0; i < displaced.length; i++) {
          await conn.execute(
            `UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?`,
            [freeBag[i], displaced[i].id]
          );
        }
      } else {
        if (!inv.equipped) {
          await conn.rollback();
          return res.status(400).json({ success: false, error: 'item is not equipped' });
        }
        if (freeBag.length === 0) {
          await conn.rollback();
          return res.status(409).json({ success: false, error: 'Inventory is full.' });
        }
        await conn.execute(
          `UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?`,
          [freeBag[0], inv.id]
        );
      }
      await conn.commit();
    } catch (error) {
      await conn.rollback();
      throw error;
    } finally {
      conn.release();
    }
    const [rows] = await pool.execute(INV_SELECT, [char.id]);
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error(`POST /api/inventory/equip char#${characterId} slot${slot_index}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

app.get('/api/game/equipment/:characterId', requireGameServerToken, async (req, res) => {
  const characterId = parseInt(req.params.characterId, 10);
  if (!characterId)
    return res.status(400).json({ success: false, error: 'invalid characterId' });
  try {
    const [items] = await pool.execute(
      `SELECT inv.slot_index, inv.item_id, inv.equipped_slot, i.stat_bonus
         FROM inventory inv JOIN items i ON i.id = inv.item_id
        WHERE inv.character_id = ? AND inv.equipped = 1 AND inv.equipped_slot IS NOT NULL AND inv.slot_index < 110
        ORDER BY inv.equipped_slot`,
      [characterId]
    );
    const bonus = { stat_str: 0, stat_agi: 0, stat_int: 0, stat_vit: 0 };
    for (const item of items) {
      const stats = typeof item.stat_bonus === 'string'
        ? JSON.parse(item.stat_bonus || '{}') : (item.stat_bonus || {});
      for (const key of Object.keys(bonus)) bonus[key] += Number(stats[key]) || 0;
      delete item.stat_bonus;
    }
    res.json({ success: true, data: { items, bonus } });
  } catch (err) {
    console.error(`GET /api/game/equipment/${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

app.post('/api/inventory/delete', requireJWT, async (req, res) => {
  const { characterId } = req.body;
  const slotIndex = Number(req.body.slot_index);
  if (!Number.isInteger(slotIndex) || slotIndex < 0 || slotIndex >= BAG_SLOTS)
    return res.status(400).json({ success: false, error: `slot_index must be between 0 and ${BAG_SLOTS - 1}` });

  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    const [[slot]] = await pool.execute(
      'SELECT item_id, quantity, equipped, instance_id FROM inventory WHERE character_id = ? AND slot_index = ?',
      [char.id, slotIndex]
    );
    if (!slot)
      return res.status(404).json({ success: false, error: 'slot not found' });

    await pool.execute(
      'DELETE FROM inventory WHERE character_id = ? AND slot_index = ?',
      [char.id, slotIndex]
    );
    if (slot.instance_id) await pool.execute('DELETE FROM loot_instances WHERE id = ?', [slot.instance_id]);
    console.log(`[INVENTORY] ${req.user.username} char#${char.id} deleted ${slot.item_id} x${slot.quantity} from slot ${slotIndex}`);
    const [rows] = await pool.execute(INV_SELECT, [char.id]);
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error(`POST /api/inventory/delete char#${characterId} slot${slotIndex}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Professions ──────────────────────────────────────────────────────────────

app.get('/api/professions/:characterId', requireJWT, async (req, res) => {
  try {
    const char = await ownedCharacter(req, res, req.params.characterId);
    if (!char) return;
    let [rows] = await pool.execute(
      'SELECT profession_id, skill_level, skill_xp FROM professions WHERE character_id = ?',
      [char.id]
    );
    if (rows.length === 0) {
      await pool.execute(
        'INSERT IGNORE INTO professions (character_id, profession_id) VALUES (?, ?)',
        [char.id, 'mining']
      );
      rows = [{ profession_id: 'mining', skill_level: 1, skill_xp: 0 }];
    }
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error(`GET /api/professions/${req.params.characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});


// ── POST /api/professions/award-xp ──────────────────────────────────────────

const PROFESSION_NAMES = Object.freeze({
  woodcutting: 'Woodcutting',
  fishing: 'Fishing',
  mining: 'Mining',
  gravedigging: 'Gravedigging',
  gardening: 'Grave Gardening',
  alchemy: 'Alchemy',
  salvaging: 'Salvaging'
});
const VALID_PROFESSION_IDS = new Set(Object.keys(PROFESSION_NAMES));

// One XP curve for gathering and crafting (gathering-rules.cjs → XP_CURVE).
function xpToNextLevel(currentLevel) {
  return gatheringRules.xpToNext(currentLevel);
}

// Retired for clients: it trusted a client-sent xpAmount. Skill XP now comes only
// from POST /api/gather (server-rolled, time-budgeted) and POST /api/craft.
app.post('/api/professions/award-xp', requireJWT, (req, res) => {
  res.status(410).json({ success: false, error: 'Skill XP is earned by gathering and crafting now.' });
});

// The original handler, kept unreachable for reference until the route is deleted.
async function legacyAwardXp(req, res) {
  const { characterId, professionId, xpAmount } = req.body;

  if (!characterId || professionId === undefined || !xpAmount)
    return res.json({ success: false, error: 'Missing characterId, professionId, or xpAmount' });

  const professionKey = typeof professionId === 'string' ? professionId.toLowerCase().trim() : '';
  if (!VALID_PROFESSION_IDS.has(professionKey))
    return res.json({ success: false, error: 'Invalid professionId' });

  const xp = Math.min(Math.max(parseInt(xpAmount, 10), 1), 500);

  const [chars] = await pool.query(
    'SELECT id FROM characters WHERE id = ? AND account_id = ?',
    [characterId, req.user.accountId]
  );
  if (!chars.length)
    return res.json({ success: false, error: 'Character not found or not yours' });

  // Upsert — create row if first time this profession is used
  await pool.query(
    `INSERT INTO professions (character_id, profession_id, skill_level, skill_xp)
     VALUES (?, ?, 1, 0)
     ON DUPLICATE KEY UPDATE skill_xp = skill_xp`,
    [characterId, professionKey]
  );

  const [[prof]] = await pool.query(
    'SELECT skill_level, skill_xp FROM professions WHERE character_id = ? AND profession_id = ?',
    [characterId, professionKey]
  );

  let { skill_level, skill_xp } = prof;
  skill_xp += xp;

  let leveled_up = false;
  while (skill_level < gatheringRules.LEVEL_CAP && skill_xp >= xpToNextLevel(skill_level)) {
    skill_xp  -= xpToNextLevel(skill_level);
    skill_level++;
    leveled_up = true;
  }

  await pool.query(
    `UPDATE professions SET skill_level = ?, skill_xp = ?
     WHERE character_id = ? AND profession_id = ?`,
    [skill_level, skill_xp, characterId, professionKey]
  );

  const profName = PROFESSION_NAMES[professionKey];
  if (leveled_up)
    console.log(`[PROF] char ${characterId} — ${profName} leveled to ${skill_level}`);

  return res.json({
    success: true,
    data: { skill_level, skill_xp, leveled_up, profession_id: professionKey }
  });
}
void legacyAwardXp;

// ── GET /api/professions/recipes/:characterId ───────────────────────────────

app.get('/api/professions/recipes/:characterId', requireJWT, async (req, res) => {
  const { characterId } = req.params;

  const [chars] = await pool.query(
    'SELECT id FROM characters WHERE id = ? AND account_id = ?',
    [characterId, req.user.accountId]
  );
  if (!chars.length)
    return res.json({ success: false, error: 'Character not found or not yours' });

  // Load all profession levels for this character
  const [profs] = await pool.query(
    'SELECT profession_id, skill_level FROM professions WHERE character_id = ?',
    [characterId]
  );
  const levels = { woodcutting: 1, fishing: 1, mining: 1, gravedigging: 1, gardening: 1, alchemy: 1, salvaging: 1 }; // defaults
  for (const p of profs) levels[p.profession_id] = p.skill_level;

  // Load all recipes with ingredients + result item name
  const [rows] = await pool.query(`
    SELECT
      r.id            AS recipe_id,
      r.profession_id,
      r.skill_level_required,
      r.result_item_id,
      r.recipe_type,
      r.craft_time_seconds,
      i.name          AS result_name,
      i.rarity        AS result_rarity,
      ri.item_id      AS ing_item_id,
      ri.quantity     AS ing_quantity,
      ii.name         AS ing_name
    FROM recipes r
    JOIN items i  ON i.id = r.result_item_id
    LEFT JOIN recipe_ingredients ri ON ri.recipe_id = r.id
    LEFT JOIN items ii ON ii.id = ri.item_id
    ORDER BY r.recipe_type, r.profession_id, r.skill_level_required
  `);

  // Group into recipe objects
  const recipeMap = {};
  for (const row of rows) {
    if (!recipeMap[row.recipe_id]) {
      recipeMap[row.recipe_id] = {
        recipe_id:            row.recipe_id,
        profession_id:        row.profession_id,
        skill_level_required: row.skill_level_required,
        result_item_id:       row.result_item_id,
        result_name:          row.result_name,
        result_rarity:        row.result_rarity,
        recipe_type:          row.recipe_type,
        craft_time_seconds:   row.craft_time_seconds,
        unlocked:             levels[row.profession_id] >= row.skill_level_required,
        ingredients:          []
      };
    }
    if (row.ing_item_id) {
      recipeMap[row.recipe_id].ingredients.push({
        item_id:  row.ing_item_id,
        name:     row.ing_name,
        quantity: row.ing_quantity
      });
    }
  }

  const all    = Object.values(recipeMap);
  const smelt  = all.filter(r => r.recipe_type === 'smelt');
  const craft  = all.filter(r => r.recipe_type !== 'smelt');

  return res.json({
    success: true,
    data: {
      skill_levels: levels,
      smelt,
      craft
    }
  });
});

// ── POST /api/craft ──────────────────────────────────────────────────────────

app.post('/api/craft', requireJWT, async (req, res) => {
  const { characterId: claimedCharacterId, recipeId } = req.body;
  if (!claimedCharacterId || !recipeId)
    return res.json({ success: false, error: 'Missing characterId or recipeId' });

  const char = await ownedCharacter(req, res, claimedCharacterId);
  if (!char) return;
  // Ownership was proven for the parsed id: parseInt('1e1') is 1 but MySQL reads the string '1e1' as 10, so never query with the raw value.
  const characterId = char.id;

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [[recipe]] = await conn.query(
      `SELECT r.*, i.name AS result_name, i.rarity AS result_rarity,
              i.stackable, i.max_stack_size
       FROM recipes r JOIN items i ON i.id = r.result_item_id
       WHERE r.id = ?`,
      [recipeId]
    );
    if (!recipe) {
      const err = new Error('Recipe not found');
      err.playerMessage = err.message;
      throw err;
    }
    if (!VALID_PROFESSION_IDS.has(recipe.profession_id)) {
      const err = new Error('Recipe has an invalid profession');
      err.playerMessage = 'This recipe is temporarily unavailable';
      throw err;
    }

    const [[profRow]] = await conn.query(
      'SELECT skill_level FROM professions WHERE character_id = ? AND profession_id = ? FOR UPDATE',
      [characterId, recipe.profession_id]
    );
    const skillLevel = profRow?.skill_level ?? 1;
    if (skillLevel < recipe.skill_level_required) {
      const err = new Error(`Requires ${PROFESSION_NAMES[recipe.profession_id]} level ${recipe.skill_level_required}`);
      err.playerMessage = err.message;
      throw err;
    }

    const [ingredients] = await conn.query(
      `SELECT ri.item_id, ri.quantity, i.name
       FROM recipe_ingredients ri JOIN items i ON i.id = ri.item_id
       WHERE ri.recipe_id = ?`,
      [recipeId]
    );
    if (!ingredients.length || ingredients.some(ing => Number(ing.quantity) <= 0)) {
      const err = new Error(`Recipe ${recipeId} has no valid ingredients`);
      err.playerMessage = 'This recipe is temporarily unavailable';
      throw err;
    }

    // Lock all unequipped inventory rows before validating or deducting. This
    // makes concurrent craft requests serialize and prevents equipped gear from
    // ever being consumed as an ingredient.
    const [invRows] = await conn.query(
      `SELECT slot_index, item_id, quantity
       FROM inventory
       WHERE character_id = ? AND equipped = 0
       FOR UPDATE`,
      [characterId]
    );
    const invMap = {};
    for (const row of invRows) {
      invMap[row.item_id] = invMap[row.item_id] || [];
      invMap[row.item_id].push({ slot: row.slot_index, qty: row.quantity });
    }
    for (const ing of ingredients) {
      const slots = invMap[ing.item_id] ?? [];
      const total = slots.reduce((sum, row) => sum + row.qty, 0);
      if (total < ing.quantity) {
        const err = new Error(`Not enough ${ing.name} (need ${ing.quantity})`);
        err.playerMessage = err.message;
        throw err;
      }
    }

    // Deduct ingredients
    for (const ing of ingredients) {
      let needed = ing.quantity;
      for (const slot of invMap[ing.item_id] ?? []) {
        if (needed <= 0) break;
        const take = Math.min(slot.qty, needed);
        if (slot.qty - take <= 0) {
          await conn.query('DELETE FROM inventory WHERE character_id = ? AND slot_index = ?', [characterId, slot.slot]);
        } else {
          await conn.query('UPDATE inventory SET quantity = quantity - ? WHERE character_id = ? AND slot_index = ?',
            [take, characterId, slot.slot]);
        }
        slot.qty -= take;
        needed   -= take;
      }
    }

    // Award the result while honoring stack limits and the bag boundary.
    let remaining = Math.max(1, Number(recipe.result_quantity) || 1);
    const maxStack = recipe.stackable ? Math.max(1, Number(recipe.max_stack_size) || 1) : 1;
    if (recipe.stackable) {
      const [existingStacks] = await conn.query(
        `SELECT slot_index, quantity FROM inventory
         WHERE character_id = ? AND item_id = ? AND equipped = 0 AND quantity < ?
         ORDER BY slot_index FOR UPDATE`,
        [characterId, recipe.result_item_id, maxStack]
      );
      for (const stack of existingStacks) {
        if (remaining <= 0) break;
        const add = Math.min(remaining, maxStack - stack.quantity);
        await conn.query(
          'UPDATE inventory SET quantity = quantity + ? WHERE character_id = ? AND slot_index = ?',
          [add, characterId, stack.slot_index]
        );
        remaining -= add;
      }
    }

    const [occupiedRows] = await conn.query(
      'SELECT slot_index FROM inventory WHERE character_id = ? FOR UPDATE',
      [characterId]
    );
    const usedSlots = new Set(occupiedRows.map(row => row.slot_index));
    while (remaining > 0) {
      let emptySlot = 0;
      while (emptySlot < BAG_SLOTS && usedSlots.has(emptySlot)) emptySlot++;
      if (emptySlot >= BAG_SLOTS) {
        const err = new Error('Inventory is full');
        err.playerMessage = err.message;
        throw err;
      }
      const add = Math.min(remaining, maxStack);
      await conn.query(
        'INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped) VALUES (?, ?, ?, ?, 0)',
        [characterId, emptySlot, recipe.result_item_id, add]
      );
      usedSlots.add(emptySlot);
      remaining -= add;
    }

    // Award profession XP
    const craftXp = Math.max(1, recipe.skill_level_required) * 5;
    await conn.query(
      `INSERT INTO professions (character_id, profession_id, skill_level, skill_xp)
       VALUES (?, ?, 1, ?)
       ON DUPLICATE KEY UPDATE skill_xp = skill_xp + ?`,
      [characterId, recipe.profession_id, craftXp, craftXp]
    );

    // Level-up loop for profession
    const [[profAfter]] = await conn.query(
      'SELECT skill_level, skill_xp FROM professions WHERE character_id = ? AND profession_id = ?',
      [characterId, recipe.profession_id]
    );
    let { skill_level, skill_xp } = profAfter;
    let leveled_up = false;
    while (skill_level < gatheringRules.LEVEL_CAP && skill_xp >= xpToNextLevel(skill_level)) {
      skill_xp  -= xpToNextLevel(skill_level);
      skill_level++;
      leveled_up = true;
    }
    await conn.query(
      'UPDATE professions SET skill_level = ?, skill_xp = ? WHERE character_id = ? AND profession_id = ?',
      [skill_level, skill_xp, characterId, recipe.profession_id]
    );

    await conn.commit();

    const profName = PROFESSION_NAMES[recipe.profession_id];
    console.log(`[CRAFT] char ${characterId} ${recipe.recipe_type} → ${recipe.result_item_id} (+${craftXp} ${profName} xp)`);
    if (leveled_up)
      console.log(`[PROF]  char ${characterId} — ${profName} leveled to ${skill_level} via crafting`);

    return res.json({
      success: true,
      data: {
        result_item_id:     recipe.result_item_id,
        result_name:        recipe.result_name,
        result_rarity:      recipe.result_rarity,
        recipe_type:        recipe.recipe_type,
        craft_time_seconds: recipe.craft_time_seconds,
        xp_gained:          craftXp,
        leveled_up,
        skill_level
      }
    });
  } catch (err) {
    await conn.rollback();
    console.error(`POST /api/craft char#${characterId}: ${err.message}`);
    return res.json({ success: false, error: err.playerMessage || 'Craft failed — please try again' });
  } finally {
    conn.release();
  }
});


// ─── Items ───────────────────────────────────────────────────────────────────

app.get('/api/items', async (req, res) => {
  try {
    const [rows] = await pool.execute(
      'SELECT id, name, rarity, item_type, stat_bonus, modifiers, icon_id, sell_value, crafted FROM items ORDER BY item_type, id'
    );
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error(`GET /api/items: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Recipes ─────────────────────────────────────────────────────────────────

app.get('/api/recipes', async (req, res) => {
  const profession = (req.query.profession || '').toLowerCase().trim();
  try {
    let sql = `
      SELECT r.id, r.name, r.profession_id, r.skill_level_required,
             r.result_item_id, r.result_quantity,
             ri.item_id AS ingredient_id, ri.quantity AS ingredient_qty,
             i.name     AS ingredient_name
      FROM recipes r
      LEFT JOIN recipe_ingredients ri ON ri.recipe_id = r.id
      LEFT JOIN items i               ON i.id = ri.item_id`;
    const params = [];
    if (profession) { sql += ' WHERE r.profession_id = ?'; params.push(profession); }
    sql += ' ORDER BY r.skill_level_required, r.id';
    const [rows] = await pool.execute(sql, params);
    const map = new Map();
    for (const row of rows) {
      if (!map.has(row.id)) {
        map.set(row.id, {
          id: row.id, name: row.name, profession_id: row.profession_id,
          skill_level_required: row.skill_level_required,
          result_item_id: row.result_item_id, result_quantity: row.result_quantity,
          ingredients: [],
        });
      }
      if (row.ingredient_id !== null) {
        map.get(row.id).ingredients.push({
          item_id: row.ingredient_id, quantity: row.ingredient_qty, name: row.ingredient_name,
        });
      }
    }
    res.json({ success: true, data: [...map.values()] });
  } catch (err) {
    console.error(`GET /api/recipes: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Health ───────────────────────────────────────────────────────────────────

app.get('/api/health', async (req, res) => {
  let db = 'connected';
  try { await pool.execute('SELECT 1'); } catch { db = 'error'; }
  res.json({ status: 'ok', uptime: process.uptime(), db, timestamp: new Date().toISOString() });
});

// The old Crossworlds reward routes (combat/kill, loot/roll, loot/drop) pay XP, gold or items for an enemy instance id the client simply makes
// up; the browser never calls them. Report mode leaves them as they were (nothing is enforced there); enforce mode (docs/SERVER-AUTHORITY.md)
// would otherwise have a hole next to its guards, so only staff may use them.
async function legacyRewardAllowed(req) {
  if (authority.authorityMode() !== 'enforce') return true;
  return isStaffAccount(req).catch(() => false);
}
const LEGACY_REWARD_CLOSED = { success: false, error: 'This reward route is closed.' };

// ─── Loot ────────────────────────────────────────────────────────────────────

const LOOT_TABLES = {
  grunt: [
    { weight: 60, type: 'nothing' },
    { weight: 30, type: 'item',   item_id: 'copper_shard', qty: [1, 2], gold: [1, 5] },
    { weight: 10, type: 'item',   item_id: 'copper_bar',   qty: [1, 1], gold: [1, 5] },
  ],
  ranged: [
    { weight: 50, type: 'nothing' },
    { weight: 35, type: 'item',   item_id: 'copper_shard', qty: [1, 2], gold: [2, 8] },
    { weight: 15, type: 'item',   item_id: 'copper_bar',   qty: [1, 1], gold: [2, 8] },
  ],
  elite: [
    { weight: 20, type: 'nothing' },
    { weight: 30, type: 'item',   item_id: 'copper_bar',   qty: [1, 2], gold: [10, 25] },
    { weight: 30, type: 'item',   item_id: 'copper_shard', qty: [2, 4], gold: [10, 25] },
    { weight: 10, type: 'equip',  pool: ['sword_copper','plate_copper','ring_copper','dagger_shadow'], qty: [1, 1], gold: [10, 25] },
    { weight: 10, type: 'multi',  items: [{ item_id: 'copper_shard', qty: [3, 5] }, { item_id: 'copper_bar', qty: [1, 1] }], gold: [10, 25] },
  ],
};

function rollLoot(enemyType) {
  const table = LOOT_TABLES[enemyType];
  if (!table) return null;
  const total = table.reduce((s, e) => s + e.weight, 0);
  let r = Math.random() * total;
  for (const entry of table) {
    r -= entry.weight;
    if (r <= 0) return entry;
  }
  return table[table.length - 1];
}

function randInt(min, max) { return min + Math.floor(Math.random() * (max - min + 1)); }

app.post('/api/loot/roll', requireJWT, async (req, res) => {
  const { characterId, enemyType } = req.body;
  if (!['grunt', 'ranged', 'elite'].includes(enemyType))
    return res.status(400).json({ success: false, error: 'enemyType must be grunt, ranged, or elite' });
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    if (!(await legacyRewardAllowed(req))) return res.status(403).json(LEGACY_REWARD_CLOSED);

    const entry = rollLoot(enemyType);
    if (!entry || entry.type === 'nothing')
      return res.json({ success: true, data: { items: [], gold: 0 } });

    const goldGained = randInt(entry.gold[0], entry.gold[1]);
    const drops = [];

    if (entry.type === 'item') {
      drops.push({ item_id: entry.item_id, quantity: randInt(entry.qty[0], entry.qty[1]) });
    } else if (entry.type === 'equip') {
      const item_id = entry.pool[Math.floor(Math.random() * entry.pool.length)];
      drops.push({ item_id, quantity: 1 });
    } else if (entry.type === 'multi') {
      for (const i of entry.items) drops.push({ item_id: i.item_id, quantity: randInt(i.qty[0], i.qty[1]) });
    }

    const [invRows] = await pool.execute(
      'SELECT slot_index FROM inventory WHERE character_id = ?', [char.id]
    );
    const usedSlots = new Set(invRows.map(r => r.slot_index));

    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();

      for (const drop of drops) {
        let slot = null;
        for (let i = 0; i < BAG_SLOTS; i++) { if (!usedSlots.has(i)) { slot = i; usedSlots.add(i); break; } } // the bag only: 100+ are equipment, belt, kit and rune rows
        if (slot === null) break; // inventory full — skip remaining drops silently
        await conn.execute(
          'INSERT INTO inventory (character_id, slot_index, item_id, quantity) VALUES (?, ?, ?, ?)',
          [char.id, slot, drop.item_id, drop.quantity]
        );
      }

      await conn.execute(
        'UPDATE characters SET gold = gold + ? WHERE id = ?', [goldGained, char.id]
      );

      await conn.commit();
    } catch (e) { await conn.rollback(); throw e; }
    finally { conn.release(); }

    for (const d of drops) console.log(`[LOOT] ${req.user.username} char#${char.id} received ${d.quantity}x${d.item_id} from ${enemyType}`);
    if (goldGained) console.log(`[LOOT] ${req.user.username} char#${char.id} received ${goldGained}g from ${enemyType}`);

    res.json({ success: true, data: { items: drops, gold: goldGained } });
  } catch (err) {
    console.error(`POST /api/loot/roll char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Loot (DB-backed) ────────────────────────────────────────────────────────

// Rolls a loot drop from loot_tables for a given source_name and, if something
// drops, inserts it into the character's inventory. Must be called inside an
// open transaction on `conn`. Returns the item_id string or null (no drop /
// inventory full).
async function rollDbLoot(conn, charId, sourceId) {
  const [entries] = await conn.execute(
    'SELECT new_item_id, weight, min_quantity, max_quantity FROM loot_tables WHERE source_name = ?',
    [sourceId]
  );
  if (!entries.length) return null;

  const total = entries.reduce((s, e) => s + e.weight, 0);
  let r = Math.random() * total;
  let picked = null;
  for (const e of entries) { r -= e.weight; if (r <= 0) { picked = e; break; } }
  if (!picked) picked = entries[entries.length - 1];
  if (!picked.new_item_id) return null;

  const [invRows] = await conn.execute(
    'SELECT slot_index FROM inventory WHERE character_id = ?', [charId]
  );
  const usedSlots = new Set(invRows.map(r => r.slot_index));
  let slot = null;
  for (let i = 0; i < BAG_SLOTS; i++) { if (!usedSlots.has(i)) { slot = i; break; } } // the bag only: 100+ are equipment, belt, kit and rune rows
  if (slot === null) return null;

  const qty = picked.min_quantity + Math.floor(Math.random() * (picked.max_quantity - picked.min_quantity + 1));
  await conn.execute(
    'INSERT INTO inventory (character_id, slot_index, item_id, quantity) VALUES (?, ?, ?, ?)',
    [charId, slot, picked.new_item_id, qty]
  );
  return picked.new_item_id;
}

app.post('/api/loot/drop', requireJWT, async (req, res) => {
  const { characterId, sourceId } = req.body;
  if (!sourceId || typeof sourceId !== 'string')
    return res.status(400).json({ success: false, error: 'sourceId is required' });
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    if (!(await legacyRewardAllowed(req))) return res.status(403).json(LEGACY_REWARD_CLOSED);

    const conn = await pool.getConnection();
    let dropped = null;
    try {
      await conn.beginTransaction();
      dropped = await rollDbLoot(conn, char.id, sourceId);
      await conn.commit();
    } catch (e) { await conn.rollback(); throw e; }
    finally { conn.release(); }

    if (dropped) console.log(`[LOOT] char#${char.id} received ${dropped} from ${sourceId}`);
    else         console.log(`[LOOT] char#${char.id} no drop from ${sourceId}`);

    res.json({ success: true, data: { dropped } });
  } catch (err) {
    console.error(`POST /api/loot/drop char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Gold ────────────────────────────────────────────────────────────────────

const GOLD_MAX = 2147483647;
// Gold is earned in play and saved through /save-progress (plausibility-guarded). The browser never calls this route, and it used to
// let any player credit any amount, which bypassed that guard entirely: crediting is staff-only, spending (negative) stays open.
app.post('/api/gold/adjust', requireJWT, async (req, res) => {
  const { characterId, amount } = req.body || {};
  if (amount === undefined || typeof amount !== 'number' || !Number.isInteger(amount) || Math.abs(amount) > GOLD_MAX)
    return res.status(400).json({ success: false, error: 'amount must be an integer' });
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    if (amount > 0 && !(await isStaffAccount(req).catch(() => false)))
      return res.status(403).json({ success: false, error: 'gold cannot be added directly' });

    // Read-modify-write under the row lock so two requests cannot both spend the same coins.
    const conn = await pool.getConnection();
    let newGold;
    try {
      await conn.beginTransaction();
      const [[locked]] = await conn.execute('SELECT gold FROM characters WHERE id = ? FOR UPDATE', [char.id]);
      const have = Number(locked && locked.gold) || 0;
      newGold = have + amount;
      if (newGold < 0) {
        await conn.rollback();
        return res.status(400).json({ success: false, error: `insufficient funds (have ${have}, need ${-amount})` });
      }
      if (newGold > GOLD_MAX) {
        await conn.rollback();
        return res.status(400).json({ success: false, error: 'gold would exceed the maximum' });
      }
      await conn.execute('UPDATE characters SET gold = ? WHERE id = ?', [newGold, char.id]);
      await conn.commit();
    } catch (e) {
      await conn.rollback().catch(() => {});
      throw e;
    } finally {
      conn.release();
    }
    console.log(`[GOLD] ${req.user.username} char#${char.id} gold adjusted by ${amount > 0 ? '+' : ''}${amount} (total: ${newGold})`);
    res.json({ success: true, data: { gold: newGold } });
  } catch (err) {
    console.error(`POST /api/gold/adjust char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Character stats ──────────────────────────────────────────────────────────

app.get('/api/character/stats/:characterId', requireJWT, async (req, res) => {
  try {
    const char = await ownedCharacter(req, res, req.params.characterId);
    if (!char) return;

    const [equipped] = await pool.execute(`
      SELECT i.stat_bonus
      FROM inventory inv
      JOIN items i ON i.id = inv.item_id
      WHERE inv.character_id = ? AND inv.equipped = 1 AND inv.slot_index < 110
    `, [char.id]);

    const bonus = { str: 0, agi: 0, int: 0, vit: 0 };
    for (const row of equipped) {
      if (!row.stat_bonus) continue;
      const b = typeof row.stat_bonus === 'string' ? JSON.parse(row.stat_bonus) : row.stat_bonus;
      if (b.stat_str) bonus.str += b.stat_str;
      if (b.stat_agi) bonus.agi += b.stat_agi;
      if (b.stat_int) bonus.int += b.stat_int;
      if (b.stat_vit) bonus.vit += b.stat_vit;
    }

    const base = { str: char.stat_str ?? 5, agi: char.stat_agi ?? 5, int: char.stat_int ?? 5, vit: char.stat_vit ?? 10 };
    res.json({
      success: true,
      data: {
        base,
        bonus,
        total: { str: base.str + bonus.str, agi: base.agi + bonus.agi, int: base.int + bonus.int, vit: base.vit + bonus.vit },
        level: char.level,
        gold:  char.gold ?? 0,
      },
    });
  } catch (err) {
    console.error(`GET /api/character/stats/${req.params.characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Combat ───────────────────────────────────────────────────────────────────

app.post('/api/combat/hit', requireJWT, async (req, res) => {
  const { characterId, enemyLevel, enemyCategory, enemyInstanceId, damageDealt } = req.body;
  if (!isValidEnemyLevel(enemyLevel))
    return res.status(400).json({ success: false, error: 'enemyLevel must be an integer from 1-100' });
  if (!isValidEnemyCategory(enemyCategory))
    return res.status(400).json({ success: false, error: 'unknown enemyCategory' });
  if (!enemyInstanceId)
    return res.status(400).json({ success: false, error: 'enemyInstanceId is required' });
  if (typeof damageDealt !== 'number')
    return res.status(400).json({ success: false, error: 'damageDealt (number) is required' });
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;

    // Record hit (with the validated level/category) so the kill gate can
    // verify combat actually happened against a matching enemy.
    const hitKey = `${req.user.accountId}:${char.id}:${enemyInstanceId}`;
    recentHits.set(hitKey, { timestamp: Date.now(), enemyLevel, enemyCategory });

    console.log(`[COMBAT] char#${char.id} hit ${enemyCategory} L${enemyLevel} (${enemyInstanceId}) for ${damageDealt}`);
    res.json({ success: true, data: { validated: true } });
  } catch (err) {
    console.error(`POST /api/combat/hit char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

app.post('/api/combat/kill', requireJWT, async (req, res) => {
  const { characterId, enemyLevel, enemyCategory, enemyInstanceId } = req.body;
  if (!isValidEnemyLevel(enemyLevel))
    return res.status(400).json({ success: false, error: 'enemyLevel must be an integer from 1-100' });
  if (!isValidEnemyCategory(enemyCategory))
    return res.status(400).json({ success: false, error: 'unknown enemyCategory' });
  if (!enemyInstanceId)
    return res.status(400).json({ success: false, error: 'enemyInstanceId is required' });
  try {
    const char = await ownedCharacter(req, res, characterId);
    if (!char) return;
    if (!(await legacyRewardAllowed(req))) return res.status(403).json(LEGACY_REWARD_CLOSED);

    // ── Duplicate kill rate limiter ──────────────────────────────────────────
    const now      = Date.now();
    const killKey  = `${char.id}:${enemyInstanceId}`;
    const lastKill = lastKillTime.get(killKey) || 0;
    if (now - lastKill < KILL_COOLDOWN_MS) {
      console.warn(`[COMBAT] char#${char.id} duplicate kill rejected for ${enemyInstanceId} (${now - lastKill}ms)`);
      return res.status(429).json({ success: false, error: 'duplicate kill confirmation' });
    }

    // ── Hit gate ─────────────────────────────────────────────────────────────
    const hitKey = `${req.user.accountId}:${char.id}:${enemyInstanceId}`;
    const hit = recentHits.get(hitKey);
    if (!hit || now - hit.timestamp > HIT_WINDOW_MS) {
      console.warn(`[COMBAT] char#${char.id} kill rejected — no recent hit on ${enemyInstanceId}`);
      return res.status(400).json({ success: false, error: 'no recent hit on this enemy recorded' });
    }
    if (hit.enemyLevel !== enemyLevel || hit.enemyCategory !== enemyCategory) {
      console.warn(`[COMBAT] char#${char.id} kill rejected — level/category mismatch with recorded hit`);
      return res.status(400).json({ success: false, error: 'enemyLevel/enemyCategory does not match recorded hit' });
    }
    recentHits.delete(hitKey); // consume gate — next kill of this instance needs a fresh hit
    lastKillTime.set(killKey, now);

    // XP is derived purely from level/category — never trust a client-supplied amount.
    const xpGained   = calcXpGained(enemyLevel, enemyCategory);
    const goldGained = Math.round(xpGained * 0.3 * (0.7 + Math.random() * 0.6));

    const conn = await pool.getConnection();
    let itemDropped = null;
    let updatedProgress = null;
    try {
      await conn.beginTransaction();
      const [[lockedChar]] = await conn.execute(
        'SELECT level, experience, gold FROM characters WHERE id = ? FOR UPDATE',
        [char.id]
      );
      if (!lockedChar) throw new Error('character disappeared during kill transaction');

      let newLevel = Math.max(1, Number(lockedChar.level) || 1);
      let newExperience = Math.max(0, Number(lockedChar.experience) || 0) + xpGained;
      let xpToNext = Math.round(100 * Math.pow(newLevel + 1, 1.5));
      while (newExperience >= xpToNext) {
        newExperience -= xpToNext;
        newLevel += 1;
        xpToNext = Math.round(100 * Math.pow(newLevel + 1, 1.5));
      }

      await conn.execute(
        'UPDATE characters SET level = ?, experience = ?, gold = gold + ? WHERE id = ?',
        [newLevel, newExperience, goldGained, char.id]
      );
      itemDropped = await rollDbLoot(conn, char.id, enemyCategory);
      updatedProgress = {
        level: newLevel,
        experience: newExperience,
        xpToNext,
        leveledUp: newLevel > (Number(lockedChar.level) || 1),
        gold: (Number(lockedChar.gold) || 0) + goldGained,
      };
      await conn.commit();
    } catch (e) { await conn.rollback(); throw e; }
    finally { conn.release(); }

    console.log(`[COMBAT] char#${char.id} killed ${enemyCategory} L${enemyLevel} (${enemyInstanceId}) +${xpGained}xp +${goldGained}g`);
    if (itemDropped) console.log(`[LOOT]   char#${char.id} received ${itemDropped} from ${enemyCategory}`);

    res.json({ success: true, data: { xpGained, goldGained, itemDropped, ...updatedProgress } });
  } catch (err) {
    console.error(`POST /api/combat/kill char#${characterId}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

// ─── Enemies ──────────────────────────────────────────────────────────────────

app.get('/api/enemies', async (req, res) => {
  try {
    const [rows] = await pool.execute('SELECT * FROM enemy_templates ORDER BY id');
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error(`GET /api/enemies: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});

app.get('/api/enemies/:id', async (req, res) => {
  try {
    const [rows] = await pool.execute('SELECT * FROM enemy_templates WHERE id = ?', [req.params.id]);
    if (!rows.length) return res.status(404).json({ success: false, error: 'enemy not found' });
    res.json({ success: true, data: rows[0] });
  } catch (err) {
    console.error(`GET /api/enemies/${req.params.id}: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});


// Staff = dev access (admin / gm role or gm_enabled): skips level and area gates, never budgets or rate limits.
const isStaffAccount = async (req) => {
  const [[acct]] = await pool.execute('SELECT role, gm_enabled FROM accounts WHERE id = ? LIMIT 1', [req.user.accountId]);
  return !!acct && (acct.role === 'admin' || acct.role === 'gm' || !!acct.gm_enabled);
};
// Server authority, step 2 (kills.cjs, AUTHORITY_KILLS=off|audit|enforce, default off): the browser reports its kills in batches; the ledger turns the
// believable part into credits that the save routes pay out of. 'off' acknowledges and ignores a report, so this is safe to ship before it is switched on.
const killReportLimiter = rateLimit({ windowMs: 60 * 1000, max: 40, standardHeaders: true, legacyHeaders: false });
app.post('/api/kills/report', killReportLimiter, requireJWT, async (req, res) => {
  try {
    const char = await ownedCharacter(req, res, req.body && req.body.characterId);
    if (!char) return;
    const reports = Array.isArray(req.body.reports) ? req.body.reports : [req.body];
    const out = await kills.handleReports(pool, { char, accountId: req.user.accountId, reports, account: { staff: await isStaffAccount(req).catch(() => false) } });
    res.status(out.status).json(out.body);
  } catch (err) {
    console.error(`POST /api/kills/report: ${err.message}`);
    res.status(500).json({ success: false, error: 'internal server error' });
  }
});
const ownsCharacterRow = async (req, characterId) => {
  const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
  return rows.length === 1;
};
// Necromancer saves claim kills and shards: in enforce mode only what the ledger backs is accepted (registered before the routes it guards).
app.post('/api/necro-progress/save', requireJWT, kills.necroGuard({ pool, ownsCharacter: ownsCharacterRow, isStaff: isStaffAccount }));
// A one-time browser-save import rewrites the necromancer record outside the ledger: take the imported kills as the new base.
app.post('/api/necro-progress/import', requireJWT, (req, res, next) => {
  res.on('finish', () => { if (res.statusCode < 400 && Number(req.body && req.body.characterId) > 0 && kills.killsMode() !== 'off') kills.rebase(pool, Number(req.body.characterId)); });
  next();
});
const { mountNecroProgress } = require('./necro-progress/necro-progress-routes.cjs');
const { createMysqlStore } = require('./necro-progress/mysql-store.cjs');
mountNecroProgress(app, {
  store: createMysqlStore(pool),
  requireAuth: requireJWT,
  isStaff: isStaffAccount,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
const { mountGathering } = require('./gathering/gathering-routes.cjs');
const { createMysqlGatherStore } = require('./gathering/gather-store.cjs');
mountGathering(app, {
  store: createMysqlGatherStore(pool),
  requireAuth: requireJWT,
  // Staff (dev access) skip gathering level gates only; the budget and rate limit still apply.
  isStaff: isStaffAccount,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
const invalidateLeaderboard = require('./leaderboard.cjs')(app, pool, { killsMode: () => kills.killsMode() });
require('./chronicle.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
  invalidateLeaderboard,
  // Step 2: play time, deepest floor and run count may only rise as far as real time, the kill ledger and the Ascension record allow.
  guardAdd: async (req, conn, args) => kills.guardChronicleAdd(conn, { ...args, accountId: req.user.accountId, account: { staff: await isStaffAccount(req).catch(() => false) } }),
  guardAscend: async (req, conn, args) => kills.mayArchiveRun(conn, { ...args, accountId: req.user.accountId, account: { staff: await isStaffAccount(req).catch(() => false) } }),
});
require('./cosmetics.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./labor.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./garden.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./loot.cjs')(app, pool, {
  requireAuth: requireJWT,
  guardRoll: async (req, db, args) => authority.guardRollGear(db, { ...args, account: { staff: await isStaffAccount(req).catch(() => false) } }),
  // A horde can drop several pieces a second at most; this only stops a script hammering the roll.
  limiter: rateLimit({ windowMs: 60 * 1000, max: 600, standardHeaders: true, legacyHeaders: false }),
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./vault.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./tool-belt.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./thrall-kit.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./runes.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./loadouts.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./salvage.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./reforge.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
const mountBossKey = require('./boss-key.cjs');
mountBossKey(app, pool, {
  requireAuth: requireJWT,
  isStaff: isStaffAccount,
  areaOpen: mountBossKey.areaOpenFromRecord,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./contracts.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./bug-reports.cjs')(app, pool, {
  requireAuth: requireJWT,
  ownsCharacter: async (req, characterId) => {
    const [rows] = await pool.execute('SELECT id FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId]);
    return rows.length === 1;
  },
});
require('./prefs.cjs')(app, pool, { requireAuth: requireJWT });
require('./discipline.cjs')(app, pool, { verifyJWT, formatCharacter, getGearLoadout, invalidateLeaderboard, maxIndex: MAX_DISCIPLINE_INDEX });
// Last resort for anything a route throws outside its own try (Express 5 forwards a rejected async handler here): JSON like every other
// failure, one journal line instead of a stack dump, and nothing internal in the reply.
app.use((err, req, res, next) => {
  if (res.headersSent) return next(err);
  const status = Number(err && err.status) >= 400 && Number(err.status) < 500 ? Number(err.status) : 500;
  if (status >= 500) console.error(`${req.method} ${String(req.originalUrl || req.url).split('?')[0]}: ${err && err.message}`);
  res.status(status).json(status >= 500 ? { success: false, error: 'internal server error' } : { success: false, error: 'That request could not be read.' });
});
app.listen(PORT, '127.0.0.1', () => console.log(`Death Muffin account service listening on ${PORT}`));
