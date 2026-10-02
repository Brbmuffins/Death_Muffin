/**
 * Capes and pets (rules: gathering/cosmetic-rules.cjs, generated from src/gameplay/cosmeticRules.ts).
 *
 *   GET  /api/cosmetics/:characterId   -> every cape (with progress toward it), every pet (adopted or not) and what is worn now
 *   POST /api/cosmetics/select         -> { characterId, cape?, pet? }: wear a cape / call a pet (null puts it away)
 *   POST /api/cosmetics/adopt          -> { characterId, petId }: spend that pet's charm from the bag to keep the companion for good
 *
 * Capes are earned by levels and computed live from `professions`; only the choice is stored. Pets are adopted from charms that
 * turn up while working. The server owns the bag, the levels and what may be worn.
 */
const rules = require('./gathering/cosmetic-rules.cjs');
const { removeFromBag } = require('./contracts.cjs');

const SKILL_IDS = ['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening', 'alchemy', 'salvaging'];
const num = (v) => Number(v) || 0;

module.exports = function mountCosmetics(app, pool, { requireAuth, ownsCharacter }) {
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
    const [rows] = await conn.execute('SELECT profession_id, skill_level FROM professions WHERE character_id = ?', [characterId]);
    const levels = {};
    for (const r of rows) if (SKILL_IDS.includes(r.profession_id)) levels[r.profession_id] = num(r.skill_level) || 1;
    return levels;
  };

  const view = async (conn, characterId) => {
    const levels = await levelsOf(conn, characterId);
    const [sel] = await conn.execute('SELECT cape, pet FROM character_cosmetics WHERE character_id = ?', [characterId]);
    const [owned] = await conn.execute('SELECT pet_id FROM character_pets WHERE character_id = ?', [characterId]);
    const adopted = new Set(owned.map((r) => r.pet_id));
    return {
      totalLevel: rules.totalLevel(levels),
      capes: rules.CAPES.map((c) => ({ id: c.id, name: c.name, lore: c.lore, color: c.color, trim: c.trim, ...rules.capeProgress(c, levels) })),
      pets: rules.PETS.map((p) => ({ id: p.id, name: p.name, charm: p.charm, skill: p.skill, lore: p.lore, adopted: adopted.has(p.id) })),
      selected: { cape: (sel[0] && sel[0].cape) || null, pet: (sel[0] && sel[0].pet) || null },
    };
  };

  const handle = (fn) => async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, (req.params && req.params.characterId) || (req.body && req.body.characterId));
      if (!id) return;
      await conn.beginTransaction();
      const data = await fn(conn, id, req);
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

  app.get('/api/cosmetics/:characterId', requireAuth, handle(async (conn, id) => view(conn, id)));

  app.post('/api/cosmetics/select', requireAuth, handle(async (conn, id, req) => {
    const body = req.body || {};
    const [cur] = await conn.execute('SELECT cape, pet FROM character_cosmetics WHERE character_id = ? FOR UPDATE', [id]);
    let cape = cur[0] ? cur[0].cape : null;
    let pet = cur[0] ? cur[0].pet : null;
    if ('cape' in body) {
      if (body.cape === null) cape = null;
      else if (!rules.capeUnlocked(String(body.cape), await levelsOf(conn, id))) throw playerError('You have not earned that cape yet.');
      else cape = String(body.cape);
    }
    if ('pet' in body) {
      if (body.pet === null) pet = null;
      else {
        const [own] = await conn.execute('SELECT pet_id FROM character_pets WHERE character_id = ? AND pet_id = ?', [id, String(body.pet)]);
        if (!own.length) throw playerError('You have not adopted that companion.');
        pet = String(body.pet);
      }
    }
    await conn.execute('INSERT INTO character_cosmetics (character_id, cape, pet) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE cape = VALUES(cape), pet = VALUES(pet)', [id, cape, pet]);
    return view(conn, id);
  }));

  app.post('/api/cosmetics/adopt', requireAuth, handle(async (conn, id, req) => {
    const def = rules.petDef(String((req.body && req.body.petId) || ''));
    if (!def) throw playerError('There is no such companion.');
    const [own] = await conn.execute('SELECT pet_id FROM character_pets WHERE character_id = ? AND pet_id = ? FOR UPDATE', [id, def.id]);
    if (own.length) throw playerError(`The ${def.name} is already yours. Keep the charm for someone else, or sell it.`);
    if (!(await removeFromBag(conn, id, def.charm, 1))) throw playerError(`You have no ${def.name} Charm in your bag.`);
    await conn.execute('INSERT IGNORE INTO character_pets (character_id, pet_id) VALUES (?, ?)', [id, def.id]);
    // The first companion you adopt walks with you straight away.
    const [sel] = await conn.execute('SELECT cape, pet FROM character_cosmetics WHERE character_id = ? FOR UPDATE', [id]);
    if (!sel[0] || !sel[0].pet) {
      await conn.execute('INSERT INTO character_cosmetics (character_id, cape, pet) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE pet = VALUES(pet)', [id, (sel[0] && sel[0].cape) || null, def.id]);
    }
    return { ...(await view(conn, id)), adopted: def.id };
  }));
};
