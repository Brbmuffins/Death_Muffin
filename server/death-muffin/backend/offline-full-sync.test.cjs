const { test } = require('node:test');
const assert = require('node:assert/strict');
const sync = require('./offline-full-sync.cjs');

const save = (patch = {}) => ({
  username: 'tester',
  character: { id: 7, class_index: 2, class_name: 'Ossuary', level: 4, experience: 120, gold: 50,
    stat_str: 5, stat_agi: 5, stat_int: 8, stat_vit: 10, pos_x: 0, pos_y: 0, pos_z: 0, pos_map: 'HUB', orientation: 0 },
  slots: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1, equipped: 0 }],
  professions: [{ profession_id: 'mining', skill_level: 3, skill_xp: 10 }],
  necro: { ascension: 0 }, garden: {}, labor: {}, cosmetics: { cape: null, pet: null, pets: [] },
  ...patch,
});

test('a well-formed save validates', () => {
  assert.doesNotThrow(() => sync.validate(save(), 2));
});

test('the saves must share a discipline', () => {
  assert.throws(() => sync.validate(save(), 3), RangeError);
});

test('levels past the old 255 cap validate, up to 999', () => {
  for (const level of [256, 300, 999]) {
    const s = save();
    Object.assign(s.character, { level, experience: level * 100 - 1 });
    assert.doesNotThrow(() => sync.validate(s, 2), `level ${level}`);
  }
});

test('character stats are bounded', () => {
  for (const bad of [{ level: 0 }, { level: 1000 }, { experience: -1 }, { gold: -5 }, { gold: 1.5 }, { stat_vit: 70000 }]) {
    const s = save();
    Object.assign(s.character, bad);
    assert.throws(() => sync.validate(s, 2), RangeError, JSON.stringify(bad));
  }
});

test('inventory slots must be bag (0-47) or equipment (100-108), unique, with sane ids and quantities', () => {
  const bad = [
    [{ slot_index: 48, item_id: 'staff_oak', quantity: 1 }],
    [{ slot_index: 99, item_id: 'staff_oak', quantity: 1 }],
    [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 0, item_id: 'bone_meal', quantity: 1 }],
    [{ slot_index: 1, item_id: 'DROP TABLE', quantity: 1 }],
    [{ slot_index: 1, item_id: 'bone_meal', quantity: 0 }],
    [{ slot_index: 1, item_id: 'bone_meal', quantity: 10000 }],
  ];
  for (const slots of bad) assert.throws(() => sync.validate(save({ slots }), 2), RangeError, JSON.stringify(slots));
  assert.doesNotThrow(() => sync.validate(save({ slots: [{ slot_index: 47, item_id: 'staff_oak', quantity: 1 }] }), 2));
  assert.doesNotThrow(() => sync.validate(save({ slots: [{ slot_index: 105, item_id: 'staff_oak', quantity: 1 }] }), 2));
});

test('professions must be known, unique and in range', () => {
  for (const professions of [
    [{ profession_id: 'hacking', skill_level: 1, skill_xp: 0 }],
    [{ profession_id: 'mining', skill_level: 1, skill_xp: 0 }, { profession_id: 'mining', skill_level: 2, skill_xp: 0 }],
    [{ profession_id: 'mining', skill_level: 101, skill_xp: 0 }],
  ]) assert.throws(() => sync.validate(save({ professions }), 2), RangeError);
});

test('oversized side state is refused', () => {
  assert.throws(() => sync.validate(save({ necro: { blob: 'x'.repeat(100_001) } }), 2), RangeError);
});

test('fingerprint is stable and sensitive to any change', () => {
  const a = save();
  assert.equal(sync.fingerprint(a), sync.fingerprint(save()));
  const b = save();
  b.character.gold += 1;
  assert.notEqual(sync.fingerprint(a), sync.fingerprint(b));
  assert.match(sync.fingerprint(a), /^[a-f0-9]{64}$/);
});

test('summary reports the comparable headline numbers', () => {
  assert.deepEqual(sync.summary(save()), { discipline: 'Ossuary', level: 4, experience: 120, gold: 50, items: 1, professions: 1, ascension: 0 });
});

test('pruneVersions keeps only the newest KEEP_VERSIONS rows', async () => {
  const calls = [];
  const conn = {
    async query(sql, params) { calls.push(['query', sql, params]); return [[{ id: 41 }]]; },
    async execute(sql, params) { calls.push(['execute', sql, params]); return [{}]; },
  };
  await sync.pruneVersions(conn, 7);
  assert.deepEqual(calls[0][2], [7, sync.KEEP_VERSIONS - 1]);
  assert.match(calls[1][1], /DELETE FROM character_save_versions WHERE character_id = \? AND id < \?/);
  assert.deepEqual(calls[1][2], [7, 41]);

  const quiet = { async query() { return [[]]; }, async execute() { throw new Error('should not delete'); } };
  await sync.pruneVersions(quiet, 7);
});

test('experience must stay below the client level curve (level * 100)', () => {
  const ok = save();
  Object.assign(ok.character, { level: 4, experience: 399 });
  assert.doesNotThrow(() => sync.validate(ok, 2));
  const over = save();
  Object.assign(over.character, { level: 4, experience: 400 });
  assert.throws(() => sync.validate(over, 2), RangeError);
});

test('tool belt slots 110-113 are valid for their own tool kind only', () => {
  const ok = (slot_index, item_id) => sync.validate(save({ slots: [{ slot_index, item_id, quantity: 1, equipped: 1 }] }), 2);
  assert.doesNotThrow(() => ok(110, 'tool_hatchet_copper'));
  assert.doesNotThrow(() => ok(113, 'tool_spade_moon'));
  assert.throws(() => ok(114, 'tool_spade_moon'), RangeError);
  assert.throws(() => ok(109, 'tool_spade_moon'), RangeError);
  assert.throws(() => sync.validate(save({ slots: Array.from({ length: 48 + 9 + 4 + 1 }, (_, i) => ({ slot_index: i, item_id: 'bone_meal', quantity: 1 })) }), 2), RangeError);
});

test('applying a save writes belt rows as equipped with their belt equipped_slot, and rejects a mismatched tool', async () => {
  const inserts = [];
  const conn = {
    async execute(sql, p) { if (sql.startsWith('INSERT INTO inventory')) inserts.push(p); return [{}]; },
    async query(sql) {
      if (sql.includes('FROM items')) return [[{ id: 'tool_rod_copper', stackable: 0, max_stack_size: 1, equipment_slot: null }, { id: 'tool_spade_copper', stackable: 0, max_stack_size: 1, equipment_slot: null }]];
      return [[]];
    },
  };
  const good = save({ slots: [{ slot_index: 112, item_id: 'tool_rod_copper', quantity: 1, equipped: 1 }] });
  await sync.apply(conn, 7, good).catch((e) => { if (!(e instanceof TypeError)) throw e; });
  assert.deepEqual(inserts[0], [7, 112, 'tool_rod_copper', 1, 1, 'belt_rod']);
  const wrong = save({ slots: [{ slot_index: 112, item_id: 'tool_spade_copper', quantity: 1, equipped: 1 }] });
  await assert.rejects(() => sync.apply(conn, 7, wrong), /Invalid equipped item/);
});
