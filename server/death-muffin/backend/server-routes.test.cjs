// Run: node --test server/death-muffin/backend/server-routes.test.cjs
// Routes defined in server.js itself, called through server-harness.cjs (no database, no socket).
const test = require('node:test');
const assert = require('node:assert');
const { loadServer } = require('./server-harness.cjs');

/** A pool that knows one account (id 1) owning one character (id 1) and logs every statement that reaches a connection. */
function fakePool({ onQuery, character = {} } = {}) {
  const log = [];
  const owned = { id: 1, account_id: 1, level: 5, experience: 10, gold: 100, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10, ...character };
  const run = async (sql, params = []) => {
    log.push({ sql, params });
    if (onQuery) { const r = await onQuery(sql, params); if (r !== undefined) return r; }
    return [[]];
  };
  const base = async (sql, params = []) => {
    if (/FROM characters WHERE id = \? AND account_id = \?/.test(sql)) return params[0] === 1 && params[1] === 1 ? [[owned]] : [[]];
    if (/FROM accounts WHERE id/.test(sql)) return [[{ role: 'player', gm_enabled: 0 }]];
    return run(sql, params);
  };
  const conn = { execute: run, query: run, beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  return { log, owned, pool: { execute: base, query: base, getConnection: async () => conn } };
}

test('craft works on the character that ownership was proven for, not on the raw request value', async () => {
  // parseInt("1e1") is 1 (the caller's own character) but MySQL reads the string '1e1' as 10: another player's bag.
  const f = fakePool({
    onQuery: (sql) => {
      if (/FROM recipes r JOIN items/.test(sql)) return [[{ id: 'r1', profession_id: 'mining', skill_level_required: 1, result_item_id: 'copper_bar', result_quantity: 1, recipe_type: 'craft', stackable: 1, max_stack_size: 250 }]];
      if (/FROM professions WHERE character_id/.test(sql)) return [[{ skill_level: 5 }]];
      if (/FROM recipe_ingredients/.test(sql)) return [[{ item_id: 'copper_shard', quantity: 2, name: 'Copper Shard' }]];
    },
  });
  const srv = loadServer({ pool: f.pool });
  const r = await srv.call('POST /api/craft', { body: { characterId: '1e1', recipeId: 'r1' } });
  assert.equal(r.json.success, false, 'no ingredients in the bag, so the craft is refused');
  const touched = f.log.filter((q) => /character_id/.test(q.sql)).map((q) => q.params[0]);
  assert.ok(touched.length >= 2, 'the craft reached the profession and inventory queries');
  assert.deepEqual([...new Set(touched)], [1], 'every query used the verified numeric character id');
});
