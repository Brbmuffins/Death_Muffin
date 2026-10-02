// Run: node --test server/death-muffin/backend/gear-slots.test.cjs
// Migration 026: legacy gear rows (Iron Augment...) had a NULL equipment_slot, so /api/inventory/equip refused them with
// "item is not configured as equippable". The migration must map every gear item type onto a slot the equip route can place.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const sql = fs.readFileSync(path.join(__dirname, 'migrations', '026-gear-equipment-slots.sql'), 'utf8');
const server = fs.readFileSync(path.join(__dirname, 'server.js'), 'utf8');
const body = sql.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');

const whens = Object.fromEntries([...body.matchAll(/WHEN '(\w+)'\s+THEN '(\w+)'/g)].map((m) => [m[1], m[2]]));
const reserved = Object.fromEntries([...server.match(/const reservedSlots = \{([^}]*)\}/)[1].matchAll(/(\w+):\s*(\d+)/g)].map((m) => [m[1], Number(m[2])]));

test('every gear type maps to a slot the equip route can place (augments/trinkets -> trinket, slot 108)', () => {
  assert.deepEqual(Object.keys(whens).sort(), ['armor_chest', 'armor_feet', 'armor_hands', 'armor_head', 'armor_legs', 'offhand', 'ring', 'trinket', 'weapon']);
  for (const [type, slot] of Object.entries(whens)) assert.ok(slot in reserved, `${type} -> ${slot} is a reserved equip slot`);
  assert.equal(whens.trinket, 'trinket');
  assert.equal(reserved.trinket, 108);
});

test('the migration is additive and idempotent: it only fills NULL slots of gear-typed rows', () => {
  assert.match(body, /WHERE equipment_slot IS NULL/);
  const inList = body.match(/item_type IN \(([^)]*)\)/)[1].match(/'(\w+)'/g).map((s) => s.slice(1, -1)).sort();
  assert.deepEqual(inList, Object.keys(whens).sort());
  assert.ok(!/material|consumable|rune/.test(body), 'never touches materials, consumables or runes');
  assert.ok(!/DELETE|DROP|ALTER|INSERT/i.test(body));
});

test('the equip route accepts a trinket once it has a slot (and still refuses a NULL one)', () => {
  const gate = server.match(/if \(equipped && \(([^)]*\)?[^)]*)\)\) \{/);
  assert.ok(gate && /!inv\.equipment_slot/.test(gate[1]), 'the equip route gate is still equipment_slot-based');
  const canEquip = (row) => !(!row.equipment_slot || row.item_type === 'material');
  assert.equal(canEquip({ item_type: 'trinket', equipment_slot: null }), false);
  assert.equal(canEquip({ item_type: 'trinket', equipment_slot: whens.trinket }), true);
  assert.equal(reserved[whens.trinket], 108);
});
