// Golden fixtures for godot/loot_view (ground loot): drives the REAL src/graphics/LootView.ts (three.js runs fine headless once the DOM
// bits are stubbed) through scripted scenarios and records, per tick, what it returned and what is left on the ground. Also the
// Settings -> Loot rule outcome (lootAction) for a grid of gear x rules x keep.
// Run: npx vite-node tools/godot/fixtures-lootview.ts  -> godot/tests/loot_view/fixtures/*.json
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';

const noop = () => {};
const el: any = () => ({ style: {}, addEventListener: noop, removeEventListener: noop, getContext: () => new Proxy({}, { get: () => (() => ({ addColorStop: noop })) }), width: 0, height: 0 });
(globalThis as any).document = { createElement: el, createElementNS: el };
(globalThis as any).window = globalThis;
(globalThis as any).location = { search: '', hostname: 'localhost', pathname: '/', href: 'http://localhost/', origin: 'http://localhost' };
(globalThis as any).localStorage = { getItem: () => null, setItem: noop, removeItem: noop };
const rnd = mulberry32(4242);
Math.random = () => rnd();

const { LootView } = await import('../../src/graphics/LootView');
const { lootAction, DEFAULT_LOOT_RULES, LOOT_TIERS } = await import('../../src/gameplay/lootFilter');
const { addToSlots } = await import('../../src/gameplay/loot');
const { AFFIXES } = await import('../../server/rules/gameplay/affixRules');
const THREE = await import('three');

const out = 'godot/tests/loot_view/fixtures';
mkdirSync(out, { recursive: true });
const w = (name: string, v: unknown) => writeFileSync(`${out}/${name}.json`, JSON.stringify(v) + '\n');

const fx: any = { decal: () => ({ kill: noop }), emit: noop, lightFlash: noop, binbun: new Proxy({}, { get: () => () => ({ kill: noop, setPosition: noop }) }) };
const mk = () => new LootView(new THREE.Scene(), fx);

const plain = ['ore_copper', 'helm_copper', 'ring_copper', 'helm_gold', 'staff_hell', 'set_gravecaller_head', 'leg_legion_unburied_head', 'flask_hp_minor'];
const plainAffix = AFFIXES.filter((a: any) => !a.necro).slice(0, 3).map((a: any) => ({ id: a.id, v: 1 }));
const necroAffix = AFFIXES.filter((a: any) => a.necro).slice(0, 1).map((a: any) => ({ id: a.id, v: 1 }));
const mkDrop = (id: string, aff?: any[]) => ({ item_id: id, quantity: 1, ...(aff ? { instance: { id: 'i' + Math.floor(rnd() * 1e6), ilvl: 10, affixes: aff } } : {}) });

type Op = Record<string, any>;
/** Runs ops against a fresh view, recording each op's result. `hero` is the (x,z) the next tick uses; `bag` toggles tryTakeItem. */
function run(name: string, ops: Op[]) {
  const v = mk();
  let hero = { x: 0, z: 0 };
  let bag = true;
  const rec: Op[] = [];
  for (const op of ops) {
    const r: Op = { ...op };
    if (op.op === 'hero') hero = { x: op.x, z: op.z };
    else if (op.op === 'bag') bag = op.open;
    else if (op.op === 'gold' || op.op === 'shard' || op.op === 'item') {
      const before = v.debugDrops().length;
      if (op.op === 'gold') v.gold(op.x, op.z, op.amount);
      else if (op.op === 'shard') v.shard(op.x, op.z, op.amount);
      else v.item(op.x, op.z, op.drop);
      r.placed = v.debugDrops().slice(before).map((d: any) => ({ x: d.x, z: d.z }));
    } else if (op.op === 'tick') {
      const res = v.update(op.dt, hero.x, hero.z, () => bag);
      r.gold = res.gold; r.shards = res.shards; r.items = res.items.map((i: any) => i.item_id);
      r.count = v.count;
      r.left = v.debugDrops().map((d: any) => [d.kind, d.id, d.prize ? 1 : 0, d.ttl]);
    } else if (op.op === 'clear') {
      r.n = v.clearWithin({ x0: op.x0, z0: op.z0, x1: op.x1, z1: op.z1 });
      r.count = v.count;
    }
    rec.push(r);
  }
  return { name, ops: rec };
}
const tick = (dt: number, n = 1): Op[] => Array.from({ length: n }, () => ({ op: 'tick', dt }));
const sc: unknown[] = [];

// expiry: every rarity incl. prize items, gold and shards go at 60 s, not before
sc.push(run('expiry', [
  { op: 'hero', x: 50, z: 50 },
  { op: 'item', x: 0, z: 0, drop: mkDrop('ore_copper') }, { op: 'item', x: 1, z: 0, drop: mkDrop('helm_copper', plainAffix.slice(0, 1)) },
  { op: 'item', x: 2, z: 0, drop: mkDrop('helm_copper', plainAffix.slice(0, 2)) }, { op: 'item', x: 3, z: 0, drop: mkDrop('helm_copper', plainAffix) },
  { op: 'item', x: 4, z: 0, drop: mkDrop('leg_legion_unburied_head') }, { op: 'gold', x: 5, z: 0, amount: 20 }, { op: 'shard', x: 6, z: 0, amount: 3 },
  ...tick(30), ...tick(29.9), ...tick(0.1), ...tick(0.05),
]));
// the staggered case: drops arrive 10 s apart and fall off one by one
sc.push(run('expiry_staggered', [
  { op: 'hero', x: 50, z: 50 },
  ...[0, 1, 2, 3, 4, 5].flatMap((i) => [{ op: 'item', x: i, z: 0, drop: mkDrop(i % 2 ? 'leg_legion_unburied_head' : 'ore_copper') }, ...tick(10)]),
  ...tick(10, 8),
]));
// cap: ordinary items go first, oldest first, then prize items
const capOps = (n: number, prizeEvery: number) => [{ op: 'hero', x: 50, z: 50 }, ...Array.from({ length: n }, (_, i) => ({ op: 'item', x: i % 9, z: Math.floor(i / 9), drop: mkDrop(i % prizeEvery === 0 ? 'leg_legion_unburied_head' : i % 3 === 0 ? 'ring_copper' : 'ore_copper', i % 5 === 0 ? plainAffix : undefined) })), ...tick(0.01), ...tick(0.01)];
sc.push(run('cap_mixed', capOps(80, 3)));
sc.push(run('cap_mostly_prize', capOps(90, 1)));
sc.push(run('cap_exact', capOps(60, 4)));
sc.push(run('cap_plus_one', capOps(61, 4)));
// walk over: needs 0.35 s of age, within 1.3, bag must have room
sc.push(run('walkover', [
  { op: 'hero', x: 10, z: 10 },
  { op: 'item', x: 10, z: 10, drop: mkDrop('helm_copper') },
  ...tick(0.2), ...tick(0.1), ...tick(0.1),
  { op: 'item', x: 10, z: 10, drop: mkDrop('ring_copper') }, { op: 'bag', open: false }, ...tick(0.5, 3),
  { op: 'bag', open: true }, ...tick(0.1),
  { op: 'item', x: 13, z: 10, drop: mkDrop('ore_copper') }, ...tick(0.5, 2), { op: 'hero', x: 12.2, z: 10 }, ...tick(0.1), { op: 'hero', x: 13, z: 10 }, ...tick(0.1),
]));
// gold and shards: magnet from 3.8, collect inside 0.5, hero walks through a field
const field: Op[] = [{ op: 'hero', x: 0, z: 0 }];
for (let i = 0; i < 6; i++) field.push({ op: 'gold', x: -3 + i, z: 2 - (i % 3), amount: 3 + i * 7 });
field.push({ op: 'shard', x: 2, z: -2, amount: 4 });
for (let k = 0; k < 120; k++) field.push({ op: 'hero', x: k * 0.04, z: 0 }, { op: 'tick', dt: 1 / 60 });
sc.push(run('magnet_walk', field));
sc.push(run('magnet_far', [{ op: 'hero', x: 0, z: 0 }, { op: 'gold', x: 6, z: 0, amount: 10 }, { op: 'shard', x: 0, z: -7, amount: 2 }, ...tick(0.1, 20)]));
// clearWithin rect (Depths leave): inclusive bounds
sc.push(run('clear_within', [
  { op: 'hero', x: 50, z: 50 },
  { op: 'item', x: 0, z: 0, drop: mkDrop('helm_copper') }, { op: 'item', x: 20, z: 0, drop: mkDrop('leg_legion_unburied_head') },
  { op: 'gold', x: 5, z: 5, amount: 10 }, { op: 'shard', x: 40, z: 40, amount: 2 }, ...tick(0.5),
  { op: 'clear', x0: -5, z0: -5, x1: 10, z1: 10 }, ...tick(0.1), { op: 'clear', x0: -100, z0: -100, x1: 100, z1: 100 }, ...tick(0.1),
]));
w('scenarios', sc);

// loot-rule outcome through the view's own path: slot -> lootAction, plus the gold paid (sell_value * quantity)
const rows: unknown[] = [];
const tiers = LOOT_TIERS.map((t: any) => t.id);
const actions = ['ground', 'auto', 'gold'];
for (const id of plain) {
  for (const aff of [undefined, plainAffix.slice(0, 1), plainAffix.slice(0, 2), plainAffix, necroAffix]) {
    const drop = mkDrop(id, aff);
    for (const tier of tiers) for (const action of actions) {
      for (const keep of [false, true]) {
        const rules: any = { ...DEFAULT_LOOT_RULES, [tier]: action };
        const slot = addToSlots([], drop as any)![0];
        const act = lootAction(slot, rules, keep ? () => true : undefined);
        rows.push({ drop, rules, keep, action: act, gold: act === 'gold' ? slot.sell_value * drop.quantity : 0 });
      }
    }
  }
}
w('rules', rows);
console.log(`fixtures-lootview ok: ${sc.length} scenarios, ${rows.length} rule rows`);
