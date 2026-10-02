import { describe, expect, it, vi } from 'vitest';
import * as THREE from 'three';
import { UploadQueue, WarmOnce, materialTextures, warmModel } from '../warmModel';

describe('UploadQueue', () => {
  it('uploads at most perFrame textures per scheduled frame, each once', async () => {
    const frames: (() => void)[] = [];
    const upload = vi.fn();
    const q = new UploadQueue(upload, 2, (fn) => frames.push(fn));
    const texs = [0, 1, 2, 3, 4].map(() => new THREE.Texture());
    const ps = texs.map((t) => q.enqueue(t));
    expect(q.enqueue(texs[0])).toBe(ps[0]);
    expect(upload).not.toHaveBeenCalled();
    frames.shift()!();
    expect(upload).toHaveBeenCalledTimes(2);
    frames.shift()!();
    frames.shift()!();
    expect(upload).toHaveBeenCalledTimes(5);
    await Promise.all(ps);
    // Already uploaded: resolves without queueing again.
    await q.enqueue(texs[0]);
    expect(upload).toHaveBeenCalledTimes(5);
    expect(frames.length).toBe(0);
  });

  it('survives an upload that throws', async () => {
    const frames: (() => void)[] = [];
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const q = new UploadQueue(() => { throw new Error('boom'); }, 2, (fn) => frames.push(fn));
    const p = q.enqueue(new THREE.Texture());
    frames.shift()!();
    await p;
    warn.mockRestore();
  });
});

describe('WarmOnce', () => {
  it('runs one warm per template and signature', async () => {
    const w = new WarmOnce();
    const a = {};
    const make = vi.fn().mockResolvedValue(undefined);
    await w.run(a, 'x', make);
    await w.run(a, 'x', make);
    await w.run(a, 'y', make);
    await w.run({}, 'x', make);
    expect(make).toHaveBeenCalledTimes(3);
  });
});

describe('materialTextures', () => {
  it('collects every distinct texture a material references', () => {
    const map = new THREE.Texture();
    const m = new THREE.MeshStandardMaterial({ map, emissiveMap: map, normalMap: new THREE.Texture() });
    expect(materialTextures([m]).size).toBe(2);
  });
});

describe('warmModel', () => {
  it('resolves immediately when no render context exists (tests, early boot)', async () => {
    await expect(warmModel(new THREE.Group(), [], {}, 'a')).resolves.toBeUndefined();
  });
});
