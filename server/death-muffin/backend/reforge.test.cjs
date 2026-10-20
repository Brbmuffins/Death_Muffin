// Run: node --test server/death-muffin/backend/reforge.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountReforge = require('./reforge.cjs');
const { fakeDb, harness } = require('./bag-fake-db.cjs');
const sinks = require('./gathering/gold-sink-rules.cjs');
const affix = require('./gathering/affix-rules.cjs');

const [LO, HI] = affix.affixRange('p_str', 20);
const fmt = (n) => Number(n).toLocaleString('en-US');
/** The stock piece below: item level 20, an uncommon base (the fake items table says so). Its price with this many affixes and reforges done. */
const ILVL = 20;
const price = (affixCount, rerolls = 0) => sinks.reforgeCost(ILVL, 'uncommon', affixCount, rerolls);
/** More gold than any reforge can ever cost. */
const RICH = sinks.REFORGE.cap * 2;

/** The reforge SQL on top of fakeDb: the character's gold, the reforge counter, and instance rows (shared with fakeDb's loot table). */
function setup({ gold = RICH, bag, equipped, loot, otherAccount = false } = {}) {
  const state = { gold, rerolls: new Map(), calls: 0 };
  let db;
  const extra = (sql, p) => {
    if (sql.startsWith('SELECT account_id, gold FROM characters')) return [[{ account_id: 7, gold: state.gold }]];
    if (sql.startsWith('SELECT id, item_id, instance_id FROM inventory')) {
      const row = db.inv.find((r) => r.character_id === p[0] && r.slot_index === p[1]);
      return [row ? [{ id: row.id, item_id: row.item_id, instance_id: row.instance_id ?? null }] : []];
    }
    if (sql.startsWith('SELECT id, account_id, ilvl, affixes FROM loot_instances')) {
      const l = db.loot.find((x) => x.id === p[0]);
      return [l ? [{ id: l.id, account_id: otherAccount ? 99 : l.account_id, ilvl: l.ilvl, affixes: l.affixes }] : []];
    }
    if (sql.startsWith('SELECT rarity, item_type FROM items')) return [[{ rarity: 'uncommon', item_type: 'armor_head' }]];
    if (sql.startsWith('SELECT rerolls FROM loot_reforges')) return [state.rerolls.has(p[0]) ? [{ rerolls: state.rerolls.get(p[0]) }] : []];
    if (sql.startsWith('UPDATE loot_instances SET affixes')) { db.loot.find((x) => x.id === p[1]).affixes = JSON.parse(p[0]); return [{}]; }
    if (sql.startsWith('INSERT INTO loot_reforges')) { state.rerolls.set(p[0], (state.rerolls.get(p[0]) ?? 0) + 1); return [{}]; }
    if (sql.startsWith('UPDATE characters SET gold = gold -')) { state.gold -= p[0]; return [{}]; }
    return null;
  };
  db = fakeDb({
    bag: bag ?? [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: 1000 }, { slot_index: 1, item_id: 'helm_copper', quantity: 1 }],
    equipped,
    loot: loot ?? [{ id: 1000, item_id: 'helm_iron', ilvl: ILVL, affixes: [{ id: 'p_str', v: LO }] }],
    extra,
  });
  const call = (opts) => harness(mountReforge, db, opts);
  return { db, state, call };
}
const go = (c, body) => c('POST /api/reforge', { body: { characterId: 1, slot_index: 0, affix_index: 0, ...body } });
const valueOf = (db, id = 1000) => db.loot.find((l) => l.id === id).affixes;

test('the curve: gold per item level x rarity shown, x growth per reforge, stops rising after maxSteps, capped', () => {
  const R = sinks.REFORGE;
  const expected = (ilvl, shown, rerolls) => Math.min(R.cap, Math.max(1, Math.round(R.goldPerIlvl * ilvl * R.rarityMult[shown] * Math.pow(R.growth, Math.min(R.maxSteps, rerolls)))));
  for (const rerolls of [0, 1, 5, R.maxSteps, R.maxSteps + 80]) {
    assert.equal(sinks.reforgeCost(20, 'uncommon', 1, rerolls), expected(20, affix.effectiveRarity('uncommon', 1), rerolls));
    assert.equal(sinks.reforgeCost(99, 'legendary', 3, rerolls), expected(99, affix.effectiveRarity('legendary', 3), rerolls));
  }
  // the affix count lifts the rarity a piece shows, and a rarer piece never costs less
  assert.equal(sinks.reforgeCost(20, 'uncommon', 2, 0), expected(20, affix.effectiveRarity('uncommon', 2), 0), 'two affixes shows the rarity two affixes make');
  assert.equal(sinks.reforgeCost(99, 'common', 3, 0), expected(99, affix.effectiveRarity('common', 3), 0), 'three affixes shows the rarity three make');
  for (let n = 1; n < 3; n++) assert.ok(sinks.reforgeCost(99, 'common', n + 1, 0) >= sinks.reforgeCost(99, 'common', n, 0), 'more affixes never cost less');
  assert.equal(sinks.reforgeCost(99, 'legendary', 3, R.maxSteps + 80), sinks.reforgeCost(99, 'legendary', 3, R.maxSteps), 'the price stops rising after maxSteps reforges');
  assert.ok(sinks.reforgeCost(99, 'legendary', 3, R.maxSteps + 80) <= R.cap);
  assert.ok(sinks.reforgeCost(20, 'uncommon', 1, 1) > sinks.reforgeCost(20, 'uncommon', 1, 0), 'every reforge raises the price');
});

test('a reforge redraws only the value, charges the server price and counts the reforge', async () => {
  const t = setup();
  const r = (await go(t.call({ random: () => 0.999 }))).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data.cost, price(1));
  assert.equal(r.data.gold, RICH - price(1));
  assert.equal(t.state.gold, RICH - price(1));
  assert.deepEqual(valueOf(t.db), [{ id: 'p_str', v: HI }], 'same affix, new value, inside the range');
  assert.equal(r.data.from, LO);
  assert.equal(r.data.to, HI);
  assert.equal(r.data.rerolls, 1);
  assert.ok(Array.isArray(r.data.bag) && r.data.bag.length > 0, 'the reply carries the bag');
});

test('the price rises with every reforge of the same piece and follows the affix count', async () => {
  const t = setup({ loot: [{ id: 1000, item_id: 'helm_iron', ilvl: ILVL, affixes: [{ id: 'p_str', v: LO }, { id: 's_vit', v: affix.affixRange('s_vit', ILVL)[0] }] }] });
  const c = t.call({ random: () => 0.999 });
  const first = (await go(c, { affix_index: 0 })).json;
  const second = (await go(c, { affix_index: 1 })).json;
  assert.equal(first.data.cost, price(2, 0));
  assert.equal(second.data.cost, price(2, 1));
  assert.ok(second.data.cost > first.data.cost);
  assert.equal(t.state.gold, RICH - price(2, 0) - price(2, 1));
});

test('a roll already at the top of its range is refused for free', async () => {
  const t = setup({ loot: [{ id: 1000, item_id: 'helm_iron', ilvl: ILVL, affixes: [{ id: 'p_str', v: HI }] }] });
  const r = (await go(t.call())).json;
  assert.equal(r.success, false);
  assert.match(r.error, /as high/);
  assert.equal(t.state.gold, RICH);
});

test('not enough gold changes nothing', async () => {
  const t = setup({ gold: price(1) - 1 });
  const r = (await go(t.call({ random: () => 0.999 }))).json;
  assert.equal(r.success, false);
  assert.match(r.error, new RegExp(`${fmt(price(1))} gold \\(you have ${fmt(price(1) - 1)}\\)`));
  assert.equal(t.state.gold, price(1) - 1);
  assert.equal(valueOf(t.db)[0].v, LO);
  assert.equal(t.state.rerolls.size, 0);
});

test('a price the player did not see is refused (another reforge landed first)', async () => {
  const t = setup();
  const r = (await go(t.call({ random: () => 0.999 }), { expect_cost: price(1) - 1 })).json;
  assert.equal(r.success, false);
  assert.match(r.error, new RegExp(`price is now ${fmt(price(1))}`));
  assert.equal(t.state.gold, RICH);
  const ok = (await go(t.call({ random: () => 0.999 }), { expect_cost: price(1) })).json;
  assert.equal(ok.success, true);
});

test('tampering: a client-sent price, value, gold or item is ignored', async () => {
  const t = setup();
  const r = (await go(t.call({ random: () => 0 }), { cost: 1, price: 1, value: 9999, v: 9999, gold: 1e9, item_id: 'helm_gold', affixes: [{ id: 'p_str', v: 9999 }] })).json;
  assert.equal(r.success, true);
  assert.equal(t.state.gold, RICH - price(1));
  const v = valueOf(t.db)[0].v;
  assert.ok(v >= LO && v <= HI, 'the value is the server\'s draw');
});

test('refusals: other accounts, empty slots, plain gear, bad indexes, someone else\'s instance', async () => {
  assert.equal((await go(setup().call({ owned: false }))).status, 403);
  const t = setup();
  const c = t.call();
  assert.match((await go(c, { slot_index: 9 })).json.error, /nothing in that slot/);
  assert.match((await go(c, { slot_index: 1 })).json.error, /Only rolled gear/);
  assert.match((await go(c, { affix_index: 3 })).json.error, /Choose one of the affixes/);
  assert.match((await go(c, { affix_index: -1 })).json.error, /Choose one of the affixes/);
  assert.match((await go(c, { slot_index: 'x' })).json.error, /Choose a piece/);
  assert.match((await go(setup({ otherAccount: true }).call())).json.error, /cannot be reforged/);
  assert.equal(t.state.gold, RICH);
  assert.equal(valueOf(t.db)[0].v, LO);
});

test('worn gear can be reforged too', async () => {
  const t = setup({ bag: [], equipped: [{ slot_index: 105, item_id: 'helm_iron', quantity: 1, equipped_slot: 'head', instance_id: 1000 }] });
  const r = (await go(t.call({ random: () => 0.999 }), { slot_index: 105 })).json;
  assert.equal(r.success, true, r.error);
  assert.equal(valueOf(t.db)[0].v, HI);
});

test('quote lists rolled pieces with their counts and the character gold', async () => {
  const t = setup();
  t.db.pool.execute = async (sql) => {
    if (sql.startsWith('SELECT gold FROM characters')) return [[{ gold: 4242 }]];
    return [[{ slot_index: 0, instance_id: 1000, rerolls: 2 }]];
  };
  const r = (await t.call()('POST /api/reforge/quote', { body: { characterId: 1 } })).json;
  assert.equal(r.success, true);
  assert.deepEqual(r.data, { gold: 4242, pieces: [{ slot_index: 0, instance_id: 1000, rerolls: 2 }] });
});
