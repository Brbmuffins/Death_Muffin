import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';

vi.mock('../fxTextures', async () => {
  const T = await import('three');
  return { fx: { glow: () => new T.Texture(), ring: () => new T.Texture() } };
});
import { LOOT_ITEM_CAP, LOOT_VACUUM_S, LootView } from '../LootView';

const effects = { decal: () => ({ kill() {} }), emit() {}, lightFlash() {}, binbun: { spawn: () => ({ kill() {} }) } } as never;

function view() {
  const v = new LootView(new THREE.Scene(), effects);
  (v as unknown as { loader: { load: () => THREE.Texture } }).loader = { load: () => new THREE.Texture() };
  return v;
}
const step = (v: LootView, seconds: number, take: (d: unknown) => boolean = () => true, at: [number, number] = [0, 0], fit: (d: unknown) => boolean = take) => {
  const got = { gold: 0, shards: 0, items: 0 };
  for (let t = 0; t < seconds; t += 0.1) {
    const r = v.update(0.1, at[0], at[1], take as never, fit as never);
    got.gold += r.gold;
    got.shards += r.shards;
    got.items += r.items.length;
  }
  return got;
};

describe('ground loot does not pile up', () => {
  it('gold and shards left behind drift to the hero and pay out', () => {
    const v = view();
    v.gold(30, 30, 40);
    v.shard(-30, 30, 2);
    expect(step(v, LOOT_VACUUM_S.gold - 5)).toMatchObject({ gold: 0, shards: 0 });
    expect(v.count).toBe(3);
    expect(step(v, 15)).toMatchObject({ gold: 40, shards: 2 });
    expect(v.count).toBe(0);
  });

  it('an item left alone is collected after its time, unless the bag is full', () => {
    const v = view();
    v.item(30, 0, { item_id: 'bone_meal', quantity: 1 });
    expect(step(v, LOOT_VACUUM_S.item - 5).items).toBe(0);
    let full = true;
    expect(step(v, 15, () => !full).items).toBe(0);
    expect(v.count).toBe(1); // a full bag keeps it on the ground
    full = false;
    v.unpark(); // the bag changed
    expect(step(v, LOOT_VACUUM_S.item + 5, () => !full).items).toBe(1);
    expect(v.count).toBe(0);
  });

  it('past the cap the oldest items are called in at once, nothing is deleted', () => {
    const v = view();
    for (let i = 0; i < LOOT_ITEM_CAP + 10; i++) v.item(40, 0, { item_id: 'bone_meal', quantity: 1 });
    const got = step(v, 10);
    expect(got.items).toBeGreaterThanOrEqual(10);
    expect(v.count).toBeLessThanOrEqual(LOOT_ITEM_CAP);
  });

  it('a full bag never makes drops trail the hero, even past the cap', () => {
    const v = view();
    for (let i = 0; i < LOOT_ITEM_CAP + 10; i++) v.item(40, 0, { item_id: 'bone_meal', quantity: 1 });
    // The hero walks around far from the pile with a full bag for longer than the vacuum time.
    for (let t = 0; t < LOOT_VACUUM_S.item + 20; t += 0.1) v.update(0.1, -40 + (t % 20), 10, () => false, () => false);
    expect(v.count).toBe(LOOT_ITEM_CAP + 10);
    for (const d of v.debugDrops()) expect(Math.hypot(d.x - 40, d.z)).toBeLessThan(2);
    // Room again: the next bag change lets them come in.
    v.unpark();
    expect(step(v, LOOT_VACUUM_S.item + 5).items).toBe(LOOT_ITEM_CAP + 10);
  });
});
