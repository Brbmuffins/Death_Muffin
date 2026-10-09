/**
 * Loadout presets: rites + socketed runes + worn weapon/off-hand saved together (rules: gathering/loadout-rules.cjs, generated from
 * server/rules/gameplay/loadoutRules.ts). Table character_loadouts (migration 037), one row per (character, slot 0..5).
 *
 *   GET  /api/loadouts/:characterId                      -> { success, data: [{ slot, preset }] }
 *   POST /api/loadouts/save   { characterId, slot, preset } -> { success, data: [{ slot, preset }] }   (validated; slot 0..5)
 *   POST /api/loadouts/delete { characterId, slot }          -> { success, data: [...] }
 *   POST /api/loadouts/apply  { characterId, slot }          -> { success, data: <bag, GET /api/inventory/:id shape>, report, preset }
 *
 * Apply loads the preset from the table (the client never sends the gear to wear), locks every inventory row of the character, runs the same
 * pure rules the offline mock runs (applyLoadout) and writes the difference in ONE transaction. A piece that is not in the bag (sold,
 * salvaged, in the Vault) or has no room to swap is skipped and named in `report.skipped`; the rest is applied. Rites are not stored on the
 * server's inventory; the client applies `preset.rites` itself.
 */
const rules = require('./gathering/loadout-rules.cjs');
const store = require('./bag-store.cjs');

const parseData = (v) => (typeof v === 'string' ? JSON.parse(v) : v);

async function listPresets(conn, characterId) {
  const [rows] = await conn.execute('SELECT slot, name, data FROM character_loadouts WHERE character_id = ? ORDER BY slot', [characterId]);
  const out = [];
  for (const r of rows) {
    let data;
    try { data = parseData(r.data); } catch { continue; }
    const v = rules.normalizePreset({ ...data, name: r.name });
    if (v.ok) out.push({ slot: Number(r.slot), preset: v.preset });
  }
  return out;
}

const validSlot = (s) => Number.isInteger(s) && s >= 0 && s < rules.MAX_PRESETS;

const norm = (v) => (v == null ? null : v);
const eqSlot = (r) => (r.equipped_slot == null ? null : r.equipped_slot);

/** Write the difference between the rows as loaded and the rows the rules produced. Moves go through temporary slots so no unique key trips. */
async function persist(conn, characterId, before, after) {
  const byId = new Map(before.map((r) => [r.id, r]));
  const keep = new Set(after.filter((r) => r.id != null).map((r) => r.id));
  for (const r of before) if (!keep.has(r.id)) await conn.execute('DELETE FROM inventory WHERE id = ?', [r.id]);
  const moved = [];
  for (const r of after) {
    if (r.id == null) continue;
    const old = byId.get(r.id);
    if (Number(old.quantity) !== Number(r.quantity)) await conn.execute('UPDATE inventory SET quantity = ? WHERE id = ?', [r.quantity, r.id]);
    if (Number(old.slot_index) !== Number(r.slot_index) || Number(old.equipped) !== Number(r.equipped) || eqSlot(old) !== eqSlot(r)) moved.push(r);
  }
  for (const r of moved) await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [-1000000 - Number(r.id), r.id]);
  for (const r of moved) {
    if (Number(r.equipped)) await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 1, equipped_slot = ? WHERE id = ?', [r.slot_index, r.equipped_slot, r.id]);
    else await conn.execute('UPDATE inventory SET slot_index = ?, equipped = 0, equipped_slot = NULL WHERE id = ?', [r.slot_index, r.id]);
  }
  for (const r of after) {
    if (r.id != null) continue;
    if (Number(r.equipped)) await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, 1, 1, ?)', [characterId, r.slot_index, r.item_id, r.equipped_slot]);
    else await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, 1, 0, NULL)', [characterId, r.slot_index, r.item_id]);
  }
}

/** The core, inside the caller's transaction: lock, apply, write. Returns the report. */
async function applyPreset(conn, characterId, preset) {
  const [rows] = await conn.execute('SELECT id, slot_index, item_id, quantity, equipped, equipped_slot, instance_id FROM inventory WHERE character_id = ? FOR UPDATE', [characterId]);
  const before = rows.map((r) => ({ id: r.id, slot_index: Number(r.slot_index), item_id: r.item_id, quantity: Number(r.quantity), equipped: Number(r.equipped), equipped_slot: norm(r.equipped_slot), instance_id: norm(r.instance_id) }));
  const [infoRows] = await conn.query('SELECT id, stackable, max_stack_size, equipment_slot, two_handed FROM items WHERE id IN (?)', [[...new Set(before.map((r) => r.item_id).concat([preset.weapon && preset.weapon.itemId, preset.offhand && preset.offhand.itemId].filter(Boolean), Object.values(preset.runes)))]]);
  const map = new Map(infoRows.map((r) => [r.id, { maxStack: Number(r.stackable) ? Math.max(1, Number(r.max_stack_size) || 1) : 1, equipSlot: r.equipment_slot || null, twoHanded: !!Number(r.two_handed) }]));
  const info = (id) => map.get(id) || { maxStack: 1, equipSlot: null, twoHanded: false };
  const { rows: after, report } = rules.applyLoadout(before, info, preset);
  await persist(conn, characterId, before, after);
  return report;
}

module.exports = function mountLoadouts(app, pool, { requireAuth, ownsCharacter }) {
  const guard = async (req, res) => {
    const id = parseInt((req.body && req.body.characterId) ?? (req.params && req.params.characterId), 10);
    if (!id) { res.status(400).json({ success: false, error: 'characterId required' }); return null; }
    if (!(await ownsCharacter(req, id))) { res.status(403).json({ success: false, error: 'character not found or not owned by this account' }); return null; }
    return id;
  };
  const fail500 = (route, id, err, res) => {
    console.error(`${route} char#${id}:`, err.code || err.message);
    if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
  };

  app.get('/api/loadouts/:characterId', requireAuth, async (req, res) => {
    const id = await guard(req, res);
    if (!id) return;
    try {
      res.json({ success: true, data: await listPresets(pool, id) });
    } catch (err) { fail500('GET /api/loadouts', id, err, res); }
  });

  app.post('/api/loadouts/save', requireAuth, async (req, res) => {
    const id = await guard(req, res);
    if (!id) return;
    const body = req.body || {};
    if (!validSlot(body.slot)) return res.status(400).json({ success: false, error: `slot must be 0 to ${rules.MAX_PRESETS - 1}` });
    const v = rules.normalizePreset(body.preset);
    if (!v.ok) return res.status(200).json({ success: false, error: v.error });
    try {
      await pool.execute(
        'INSERT INTO character_loadouts (character_id, slot, name, data) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), data = VALUES(data)',
        [id, body.slot, v.preset.name, JSON.stringify({ rites: v.preset.rites, runes: v.preset.runes, weapon: v.preset.weapon, offhand: v.preset.offhand })],
      );
      res.json({ success: true, data: await listPresets(pool, id) });
    } catch (err) { fail500('POST /api/loadouts/save', id, err, res); }
  });

  app.post('/api/loadouts/delete', requireAuth, async (req, res) => {
    const id = await guard(req, res);
    if (!id) return;
    const slot = (req.body || {}).slot;
    if (!validSlot(slot)) return res.status(400).json({ success: false, error: `slot must be 0 to ${rules.MAX_PRESETS - 1}` });
    try {
      await pool.execute('DELETE FROM character_loadouts WHERE character_id = ? AND slot = ?', [id, slot]);
      res.json({ success: true, data: await listPresets(pool, id) });
    } catch (err) { fail500('POST /api/loadouts/delete', id, err, res); }
  });

  app.post('/api/loadouts/apply', requireAuth, async (req, res) => {
    const id = await guard(req, res);
    if (!id) return;
    const slot = (req.body || {}).slot;
    if (!validSlot(slot)) return res.status(400).json({ success: false, error: `slot must be 0 to ${rules.MAX_PRESETS - 1}` });
    const conn = await pool.getConnection();
    try {
      const preset = (await listPresets(conn, id)).find((p) => p.slot === slot);
      if (!preset) { return res.status(200).json({ success: false, error: 'That loadout is empty.' }); }
      await conn.beginTransaction();
      const report = await applyPreset(conn, id, preset.preset);
      await conn.commit();
      const [data] = await conn.execute(store.INV_SELECT, [id]);
      res.json({ success: true, data, report, preset: preset.preset });
    } catch (err) {
      await conn.rollback().catch(() => {});
      if (err && err.player) return res.status(200).json({ success: false, error: err.message });
      fail500('POST /api/loadouts/apply', id, err, res);
    } finally {
      conn.release();
    }
  });
};
module.exports.applyPreset = applyPreset;
