import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';

vi.mock('../fxTextures', async () => {
  const T = await import('three');
  return { fx: { glow: () => new T.Texture(), ring: () => new T.Texture() } };
});
import { LOOT_EXPIRE_S, LOOT_ITEM_CAP, LootView } from '../LootView';

const effects = { decal: () => ({ kill() {} }), emit() {}, lightFlash() {}, binbun: { spawn: () => ({ kill() {} }) } } as never;

function view() {
  const v = new LootView(new THREE.Scene(), effects);
  (v as unknown as { loader: { load: () => THREE.Texture } }).loader = { load: () => new THREE.Texture() };
  return v;
}
const step = (v: LootView, seconds: number, take: (d: unknown) => boolean = () => true, at: [number, number] = [0, 0]) => {
  const got = { gold: 0, shards: 0, items: 0 };
  for (let t = 0; t < seconds; t += 0.1) {
    const r = v.update(0.1, at[0], at[1], take as never);
    got.gold += r.gold;
    got.shards += r.shards;
    got.items += r.items.length;
  }
  return got;
};

describe('ground loot: walk over it to take it, otherwise it expires', () => {
  it('loot far away never comes to the hero; it expires instead', () => {
    const v = view();
    v.gold(30, 30, 40);
    v.shard(-30, 30, 2);
    v.item(30, 0, { item_id: 'bone_meal', quantity: 1 });
    expect(step(v, LOOT_EXPIRE_S.gold - 5)).toMatchObject({ gold: 0, shards: 0, items: 0 });
    for (const d of v.debugDrops()) expect(Math.hypot(d.x, d.z)).toBeGreaterThan(25); // nothing drifted toward the hero
    expect(step(v, LOOT_EXPIRE_S.item)).toMatchObject({ gold: 0, shards: 0, items: 0 });
    expect(v.count).toBe(0);
  });

  it('walking over an item takes it; gold pulls in from a few steps away', () => {
    const v = view();
    v.item(10, 0, { item_id: 'bone_meal', quantity: 1 });
    v.gold(-10, 0, 7);
    expect(step(v, 2, () => true, [10, 0]).items).toBe(1);
    expect(step(v, 2, () => true, [-12, 0]).gold).toBe(7);
  });

  it('a full bag leaves the item where it lies until it expires', () => {
    const v = view();
    v.item(0, 0, { item_id: 'bone_meal', quantity: 1 });
    expect(step(v, 10, () => false).items).toBe(0);
    expect(v.count).toBe(1);
    expect(step(v, 5, () => true).items).toBe(1); // room again while still standing on it
  });

  it('past the cap the oldest ordinary items expire first; epic and legendary stay', () => {
    const v = view();
    v.item(40, 0, { item_id: 'bone_meal', quantity: 1, instance: { affixes: [{}, {}, {}, {}] } } as never); // rolled piece
    for (let i = 0; i < LOOT_ITEM_CAP + 10; i++) v.item(40, 0, { item_id: 'bone_meal', quantity: 1 });
    step(v, 1);
    expect(v.count).toBe(LOOT_ITEM_CAP);
    expect(v.debugDrops().filter((d) => d.ttl === LOOT_EXPIRE_S.prizeItem)).toHaveLength(1); // the oldest drop, but epic: kept
  });
});

describe('Depths floors leave their loot behind (owner, 2026-10-04)', () => {
  it('clearWithin removes only the drops inside the rect, without paying them out', () => {
    const v = view();
    v.item(5, 5, { item_id: 'bone_meal', quantity: 1 });
    v.gold(6, 6, 30);
    v.item(100, 100, { item_id: 'bone_meal', quantity: 1 }); // elsewhere in the world: untouched
    expect(v.clearWithin({ x0: 0, z0: 0, x1: 20, z1: 20 })).toBe(2);
    expect(v.count).toBe(1);
    expect(step(v, 5, () => true, [5, 5])).toMatchObject({ gold: 0, items: 0 });
  });
});
