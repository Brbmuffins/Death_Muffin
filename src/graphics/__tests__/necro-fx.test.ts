import * as THREE from 'three';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { settings } from '../../app/settings';
import { Effects } from '../Effects';
import { boneSplinters, crackedGround, graveDirt, motifScale, resetMotifBudget, skullRing, soulMotes, spectralHands } from '../necroFx';

vi.mock('../fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../fxImages', () => ({ fxImage: () => new THREE.Texture() }));

let t = 0;
function fresh() {
  t = 0;
  resetMotifBudget(() => t);
  settings.quality = 'high';
  settings.reducedMotion = false;
  return new Effects(new THREE.Scene());
}

describe('necromantic motifs', () => {
  beforeEach(() => {
    settings.quality = 'high';
    settings.reducedMotion = false;
  });

  it('draws nothing on Graphics: Low', () => {
    const e = fresh();
    settings.quality = 'low';
    expect(motifScale()).toBe(0);
    boneSplinters(e, 0, 1, 0, { n: 8 });
    graveDirt(e, 0, 0, { n: 8 });
    skullRing(e, 0, 0, 3, 0xffffff);
    crackedGround(e, 0, 0, 2, 0xffffff);
    spectralHands(e, 0, 0);
    expect(e.transientLoad).toBe(0);
    expect(e.activeHandFields).toBe(0);
  });

  it('thins under reduced motion and drops the rising billboards and hands', () => {
    const e = fresh();
    settings.reducedMotion = true;
    expect(motifScale()).toBeLessThan(1);
    skullRing(e, 0, 0, 3, 0xffffff);
    spectralHands(e, 0, 0);
    expect(e.transientLoad).toBe(0);
    expect(e.activeHandFields).toBe(0);
  });

  it('keeps thrall-made motifs quieter than the player\'s own', () => {
    expect(motifScale('thrall')).toBeLessThan(motifScale('player'));
    const e = fresh();
    skullRing(e, 0, 0, 3, 0xffffff, { origin: 'thrall' });
    expect(e.transientLoad).toBe(0);
  });

  it('caps billboards per burst and refills slowly', () => {
    const e = fresh();
    for (let i = 0; i < 6; i++) skullRing(e, 0, 0, 3, 0xffffff);
    const burst = e.transientLoad;
    expect(burst).toBeLessThanOrEqual(14);
    expect(burst).toBeGreaterThan(0);
    t += 1000;
    skullRing(e, 0, 0, 3, 0xffffff);
    expect(e.transientLoad).toBeGreaterThan(burst);
    expect(e.transientLoad - burst).toBeLessThanOrEqual(9);
  });

  it('spends one shared particle budget', () => {
    const e = fresh();
    let drawn = 0;
    const emit = e.emit.bind(e);
    e.emit = (o) => ((drawn += o.count), emit(o));
    for (let i = 0; i < 100; i++) soulMotes(e, 0, 0, 0x6fe3c8, { n: 10 });
    expect(drawn).toBeLessThanOrEqual(260);
    t += 1000;
    const before = drawn;
    soulMotes(e, 0, 0, 0x6fe3c8, { n: 10 });
    expect(drawn - before).toBe(10);
  });

  it('limits how many hand fields run at once', () => {
    const e = fresh();
    // Without the prop loaded graveHands falls back to spikes, so only the cap logic is checked here.
    for (let i = 0; i < 8; i++) spectralHands(e, i, 0);
    expect(e.activeHandFields).toBeLessThanOrEqual(3);
  });
});
