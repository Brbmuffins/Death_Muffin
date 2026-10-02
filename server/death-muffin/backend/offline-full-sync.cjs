const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const runtimeNecro = path.join(__dirname, 'necro-progress/necro-rules.cjs');
const necroRules = require(fs.existsSync(runtimeNecro) ? runtimeNecro : '../../vps-handoff/necro-progress/necro-rules.cjs');
const contractRules = require('./gathering/contract-rules.cjs');
const gather = require('./gathering/gathering-rules.cjs');

const parse = (value, fallback = null) => {
  if (value == null) return fallback;
  return typeof value === 'string' ? JSON.parse(value) : value;
};
const bounded = (value, min, max) => Number.isInteger(value) && value >= min && value <= max;
const itemId = (value) => typeof value === 'string' && /^[a-z0-9_:-]{1,64}$/.test(value);
const dayKey = (value) => String(value).slice(0, 10);

function fingerprint(account) {
  return crypto.createHash('sha256').update(JSON.stringify(account)).digest('hex');
}

function summary(account) {
  const char = account.character;
  return {
    discipline: char.class_name,
    level: char.level,
    experience: char.experience,
    gold: char.gold,
    items: account.slots.length,
    professions: account.professions.length,
    ascension: Number(account.necro?.ascension) || 0,
  };
}

async function capture(conn, characterId, username) {
  const [[c]] = await conn.execute('SELECT * FROM characters WHERE id = ?', [characterId]);
  if (!c) throw new Error('Character not found');
  const character = {
    id: c.id, class_index: c.discipline_index ?? c.class_index, class_name: c.class_name,
    level: Number(c.level), experience: Number(c.experience), gold: Number(c.gold),
    stat_str: Number(c.stat_str), stat_agi: Number(c.stat_agi), stat_int: Number(c.stat_int), stat_vit: Number(c.stat_vit),
    pos_x: Number(c.pos_x), pos_y: Number(c.pos_y), pos_z: Number(c.pos_z), pos_map: c.pos_map, orientation: Number(c.orientation),
  };
  const [inventory] = await conn.execute('SELECT slot_index, item_id, quantity, equipped, equipped_slot FROM inventory WHERE character_id = ? ORDER BY slot_index', [characterId]);
  const [professions] = await conn.execute('SELECT profession_id, skill_level, skill_xp FROM professions WHERE character_id = ? ORDER BY profession_id', [characterId]);
  const [[necroRow]] = await conn.execute('SELECT state FROM character_necro_progress WHERE character_id = ?', [characterId]);
  const [[chronRow]] = await conn.execute('SELECT life, run, run_no, run_started_at FROM character_chronicle WHERE character_id = ?', [characterId]);
  const [runs] = await conn.execute('SELECT run_no, started_at, ended_at, ascension_after, stats FROM character_runs WHERE character_id = ? ORDER BY run_no, id LIMIT 100', [characterId]);
  const [contractRows] = await conn.execute('SELECT DATE_FORMAT(day, "%Y-%m-%d") AS day, slot, done FROM character_contracts WHERE character_id = ? AND done = 1 ORDER BY day, slot', [characterId]);
  const [gardenRows] = await conn.execute('SELECT plot, seed_id, planted_at, ready_at, composted FROM garden_plots WHERE character_id = ? ORDER BY plot', [characterId]);
  const [laborRows] = await conn.execute('SELECT slot, node_type, started_at FROM character_labor WHERE character_id = ? ORDER BY slot', [characterId]);
  const [[cosRow]] = await conn.execute('SELECT cape, pet FROM character_cosmetics WHERE character_id = ?', [characterId]);
  const [petRows] = await conn.execute('SELECT pet_id FROM character_pets WHERE character_id = ? ORDER BY pet_id', [characterId]);
  const today = contractRules.dayKey(Date.now());
  const doneToday = contractRows.filter((r) => r.day === today);
  return {
    username, character,
    slots: inventory.map((row) => ({ slot_index: Number(row.slot_index), item_id: row.item_id, quantity: Number(row.quantity), equipped: Number(row.equipped) ? 1 : 0, equipped_slot: row.equipped_slot })),
    professions: professions.map((row) => ({ profession_id: row.profession_id, skill_level: Number(row.skill_level), skill_xp: Number(row.skill_xp) })),
    necro: necroRules.normalise(parse(necroRow?.state, necroRules.blankState())),
    chronicle: {
      life: parse(chronRow?.life, {}), run: parse(chronRow?.run, {}), runNo: Number(chronRow?.run_no) || 1,
      runStartedAt: new Date(chronRow?.run_started_at ?? c.created_at).toISOString(),
      runs: runs.map((r) => ({ runNo: Number(r.run_no), startedAt: new Date(r.started_at).toISOString(), endedAt: new Date(r.ended_at).toISOString(), ascensionAfter: Number(r.ascension_after), stats: parse(r.stats, {}) })),
    },
    contracts: { day: today, done: doneToday.filter((r) => r.slot < 3).map((r) => Number(r.slot)), bonus: doneToday.some((r) => Number(r.slot) === 9), days: [...new Set(contractRows.filter((r) => Number(r.slot) < 3).map((r) => r.day))] },
    garden: Object.fromEntries(gardenRows.map((r) => [r.plot, { plot: r.plot, seedId: r.seed_id, plantedAt: Number(r.planted_at), readyAt: Number(r.ready_at), composted: !!r.composted }])),
    labor: Object.fromEntries(laborRows.map((r) => [r.slot, { nodeType: r.node_type, startedAt: Number(r.started_at) }])),
    cosmetics: { cape: cosRow?.cape ?? null, pet: cosRow?.pet ?? null, pets: petRows.map((r) => r.pet_id) },
  };
}

function validate(account, onlineClass) {
  if (!account || typeof account !== 'object' || !account.character) throw new RangeError('Invalid offline save');
  const c = account.character;
  if (c.class_index !== onlineClass) throw new RangeError('The saves must use the same discipline');
  if (!bounded(c.level, 1, 255) || !bounded(c.experience, 0, c.level * 100 - 1) ||
      !bounded(c.gold, 0, 2147483647) || ['stat_str', 'stat_agi', 'stat_int', 'stat_vit'].some((key) => !bounded(c[key], 0, 65535)))
    throw new RangeError('Invalid character stats');
  if (!Array.isArray(account.slots) || account.slots.length > gather.BAG_SLOTS + 9 + gather.BELT_SLOT_COUNT) throw new RangeError('Invalid inventory');
  const occupied = new Set();
  for (const slot of account.slots) {
    const index = slot?.slot_index;
    if (!bounded(index, 0, gather.BAG_SLOTS - 1) && !bounded(index, 100, 108) && !gather.isBeltSlot(index)) throw new RangeError('Invalid inventory slot');
    if (occupied.has(index) || !itemId(slot.item_id) || !bounded(slot.quantity, 1, 9999)) throw new RangeError('Invalid inventory item');
    occupied.add(index);
  }
  if (!Array.isArray(account.professions) || account.professions.length > 12) throw new RangeError('Invalid professions');
  const skills = new Set();
  for (const row of account.professions) {
    if (!['woodcutting', 'fishing', 'mining', 'gravedigging', 'gardening', 'alchemy', 'salvaging'].includes(row?.profession_id) ||
        skills.has(row.profession_id) || !bounded(row.skill_level, 1, 100) || !bounded(row.skill_xp, 0, 2147483647)) throw new RangeError('Invalid profession');
    skills.add(row.profession_id);
  }
  for (const key of ['necro', 'chronicle', 'contracts', 'garden', 'labor', 'cosmetics']) {
    if (account[key] != null && JSON.stringify(account[key]).length > 100_000) throw new RangeError(`Invalid ${key} save`);
  }
  return account;
}

const sqlTime = (value) => {
  const d = new Date(value);
  if (!Number.isFinite(d.getTime())) throw new RangeError('Invalid save timestamp');
  return d.toISOString().slice(0, 19).replace('T', ' ');
};

async function apply(conn, characterId, account) {
  const c = account.character;
  const finitePosition = ['pos_x', 'pos_y', 'pos_z', 'orientation'].every((key) => Number.isFinite(c[key]) && Math.abs(c[key]) < 100000);
  // pos_map stays as it is online; the offline edition has no map of its own.
  await conn.execute(
    `UPDATE characters SET level = ?, experience = ?, gold = ?, stat_str = ?, stat_agi = ?, stat_int = ?, stat_vit = ?,
      pos_x = ?, pos_y = ?, pos_z = ?, orientation = ? WHERE id = ?`,
    [c.level, c.experience, c.gold, c.stat_str, c.stat_agi, c.stat_int, c.stat_vit,
      finitePosition ? c.pos_x : 0, finitePosition ? c.pos_y : 0, finitePosition ? c.pos_z : 0,
      finitePosition ? c.orientation : 0, characterId]
  );

  const reservedSlots = { 100: 'head', 101: 'chest', 102: 'legs', 103: 'feet', 104: 'hands', 105: 'main_hand', 106: 'off_hand', 107: 'ring', 108: 'trinket' };
  const ids = [...new Set(account.slots.map((s) => s.item_id))];
  if (ids.length) {
    const [known] = await conn.query('SELECT id, stackable, max_stack_size, equipment_slot FROM items WHERE id IN (?)', [ids]);
    const policy = new Map(known.map((r) => [r.id, r]));
    for (const slot of account.slots) {
      const item = policy.get(slot.item_id);
      if (!item) throw new RangeError(`Unknown item ${slot.item_id}`);
      const max = item.stackable ? Math.max(1, Number(item.max_stack_size) || 1) : 1;
      if (slot.quantity > max) throw new RangeError(`Too many ${slot.item_id} in one slot`);
      // Tool belt (110-113): the slot's tool kind must match the item; gear (100-108): its own equipment slot.
      const beltKind = gather.beltSlotKind(slot.slot_index);
      if (beltKind ? gather.toolKindOf(slot.item_id) !== beltKind : slot.slot_index >= 100 && item.equipment_slot !== reservedSlots[slot.slot_index]) throw new RangeError(`Invalid equipped item ${slot.item_id}`);
    }
  }
  await conn.execute('DELETE FROM inventory WHERE character_id = ?', [characterId]);
  for (const slot of account.slots) {
    await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, ?, ?, ?)',
      [characterId, slot.slot_index, slot.item_id, slot.quantity, slot.slot_index >= 100 ? 1 : 0, reservedSlots[slot.slot_index] ?? (gather.beltSlotKind(slot.slot_index) ? gather.beltEquippedSlot(gather.beltSlotKind(slot.slot_index)) : null)]);
  }

  await conn.execute('DELETE FROM professions WHERE character_id = ?', [characterId]);
  for (const row of account.professions) {
    await conn.execute('INSERT INTO professions (character_id, profession_id, skill_level, skill_xp) VALUES (?, ?, ?, ?)',
      [characterId, row.profession_id, row.skill_level, row.skill_xp]);
  }

  const necro = necroRules.normalise(account.necro ?? necroRules.blankState());
  await conn.execute('INSERT INTO character_necro_progress (character_id, state) VALUES (?, ?) ON DUPLICATE KEY UPDATE state = VALUES(state), version = version + 1',
    [characterId, JSON.stringify(necro)]);

  const chron = account.chronicle ?? {};
  const life = chron.life && typeof chron.life === 'object' ? chron.life : {};
  const run = chron.run && typeof chron.run === 'object' ? chron.run : {};
  await conn.execute(
    'INSERT INTO character_chronicle (character_id, life, run, run_no, run_started_at) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE life = VALUES(life), run = VALUES(run), run_no = VALUES(run_no), run_started_at = VALUES(run_started_at)',
    [characterId, JSON.stringify(life), JSON.stringify(run), bounded(chron.runNo, 1, 1000000) ? chron.runNo : 1, sqlTime(chron.runStartedAt ?? Date.now())]
  );
  await conn.execute('DELETE FROM character_runs WHERE character_id = ?', [characterId]);
  for (const row of (Array.isArray(chron.runs) ? chron.runs : []).slice(0, 100)) {
    if (!bounded(row.runNo, 1, 1000000) || !bounded(row.ascensionAfter, 0, 255)) throw new RangeError('Invalid Chronicle run');
    await conn.execute('INSERT INTO character_runs (character_id, run_no, started_at, ended_at, ascension_after, stats) VALUES (?, ?, ?, ?, ?, ?)',
      [characterId, row.runNo, sqlTime(row.startedAt), sqlTime(row.endedAt), row.ascensionAfter, JSON.stringify(row.stats ?? {})]);
  }

  const contracts = account.contracts ?? {};
  const today = contractRules.dayKey(Date.now());
  await conn.execute('DELETE FROM character_contracts WHERE character_id = ?', [characterId]);
  const levels = Object.fromEntries(account.professions.map((p) => [p.profession_id, p.skill_level]));
  for (const day of [...new Set(Array.isArray(contracts.days) ? contracts.days : [])].slice(-400)) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || day === today) continue;
    await conn.execute('INSERT INTO character_contracts (character_id, day, slot, contract, done, done_at) VALUES (?, ?, 0, ?, 1, CURRENT_TIMESTAMP)',
      [characterId, day, JSON.stringify({ importedOffline: true })]);
  }
  if (contracts.day === today) {
    const board = contractRules.generateBoard(characterId, today, levels);
    const done = new Set(Array.isArray(contracts.done) ? contracts.done.filter((x) => bounded(x, 0, 2)) : []);
    for (const row of board) {
      await conn.execute('INSERT INTO character_contracts (character_id, day, slot, contract, done, done_at) VALUES (?, ?, ?, ?, ?, ?)',
        [characterId, today, row.slot, JSON.stringify(row), done.has(row.slot) ? 1 : 0, done.has(row.slot) ? sqlTime(Date.now()) : null]);
    }
    if (contracts.bonus) await conn.execute('INSERT INTO character_contracts (character_id, day, slot, contract, done, done_at) VALUES (?, ?, 9, ?, 1, CURRENT_TIMESTAMP)',
      [characterId, today, JSON.stringify({ bonus: true })]);
  }

  await conn.execute('DELETE FROM garden_plots WHERE character_id = ?', [characterId]);
  for (const [plot, row] of Object.entries(account.garden ?? {})) {
    if (!/^[a-z0-9_]{1,8}$/.test(plot) || !row || (row.seedId !== null && !itemId(row.seedId)) ||
        !bounded(row.plantedAt, 0, Number.MAX_SAFE_INTEGER) || !bounded(row.readyAt, 0, Number.MAX_SAFE_INTEGER)) throw new RangeError('Invalid garden plot');
    await conn.execute('INSERT INTO garden_plots (character_id, plot, seed_id, planted_at, ready_at, composted) VALUES (?, ?, ?, ?, ?, ?)',
      [characterId, plot, row.seedId, row.plantedAt, row.readyAt, row.composted ? 1 : 0]);
  }
  await conn.execute('DELETE FROM character_labor WHERE character_id = ?', [characterId]);
  for (const [slot, row] of Object.entries(account.labor ?? {})) {
    if (!bounded(Number(slot), 0, 8) || !row || (row.nodeType !== null && !itemId(row.nodeType)) || !bounded(row.startedAt, 0, Number.MAX_SAFE_INTEGER)) throw new RangeError('Invalid laborer');
    await conn.execute('INSERT INTO character_labor (character_id, slot, node_type, started_at) VALUES (?, ?, ?, ?)',
      [characterId, Number(slot), row.nodeType, row.startedAt]);
  }
  const cosmetics = account.cosmetics ?? { cape: null, pet: null, pets: [] };
  for (const value of [cosmetics.cape, cosmetics.pet]) if (value !== null && !itemId(value)) throw new RangeError('Invalid cosmetic');
  await conn.execute('INSERT INTO character_cosmetics (character_id, cape, pet) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE cape = VALUES(cape), pet = VALUES(pet)',
    [characterId, cosmetics.cape, cosmetics.pet]);
  await conn.execute('DELETE FROM character_pets WHERE character_id = ?', [characterId]);
  for (const pet of [...new Set(Array.isArray(cosmetics.pets) ? cosmetics.pets : [])].slice(0, 50)) {
    if (!itemId(pet)) throw new RangeError('Invalid pet');
    await conn.execute('INSERT INTO character_pets (character_id, pet_id) VALUES (?, ?)', [characterId, pet]);
  }
}

/** Saved versions kept per character; older ones are pruned after each load. */
const KEEP_VERSIONS = 20;

async function pruneVersions(conn, characterId) {
  const [rows] = await conn.query('SELECT id FROM character_save_versions WHERE character_id = ? ORDER BY id DESC LIMIT 1 OFFSET ?',
    [characterId, KEEP_VERSIONS - 1]);
  if (rows.length) await conn.execute('DELETE FROM character_save_versions WHERE character_id = ? AND id < ?', [characterId, rows[0].id]);
}

module.exports = { capture, fingerprint, summary, validate, apply, dayKey, pruneVersions, KEEP_VERSIONS };
