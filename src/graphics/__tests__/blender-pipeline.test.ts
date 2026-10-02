import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { Document } from '@gltf-transform/core';
import { describe, expect, it } from 'vitest';
// @ts-expect-error plain .mjs tools
import { findBlender, parseArgs } from '../../../tools/blender.mjs';
// @ts-expect-error plain .mjs tools
import { dropRestChannels, packDoc, zeroStart } from '../../../tools/blender/pack.mjs';
// @ts-expect-error plain .mjs tools
import { contactStrideOfClip, legBonesOf, strideOfClip } from '../../../tools/measure-clips.mjs';
import STRIDES from '../../content/strideSpeeds.json';

/** A two-bone doc with an animation: `a` really moves, `b` is sampled but never leaves its rest pose, times start at 1/30. */
function animDoc() {
  const doc = new Document();
  const buf = doc.createBuffer();
  const a = doc.createNode('a').setTranslation([0, 1, 0]);
  const b = doc.createNode('b').setRotation([0, 0, 0, 1]);
  doc.createScene().addChild(a).addChild(b);
  const anim = doc.createAnimation('Animation');
  const times = new Float32Array([1 / 30, 2 / 30, 3 / 30]);
  const mk = (path: 'translation' | 'rotation' | 'scale', node: typeof a, type: 'VEC3' | 'VEC4', vals: number[]) => {
    const s = doc.createAnimationSampler()
      .setInput(doc.createAccessor().setType('SCALAR').setArray(times).setBuffer(buf))
      .setOutput(doc.createAccessor().setType(type).setArray(new Float32Array(vals)).setBuffer(buf));
    anim.addSampler(s).addChannel(doc.createAnimationChannel().setTargetNode(node).setTargetPath(path).setSampler(s));
  };
  mk('translation', a, 'VEC3', [0, 1, 0, 0, 1.2, 0, 0, 1.4, 0]); // moves
  mk('scale', a, 'VEC3', [1, 1, 1, 1, 1, 1, 1, 1, 1]); // rest
  mk('rotation', b, 'VEC4', [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]); // rest
  mk('rotation', a, 'VEC4', [0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1]); // rest, but written with the opposite sign
  return doc;
}

describe('tools/blender/pack.mjs', () => {
  it('drops channels that never leave the rest pose (sign-insensitive for quaternions) and keeps real motion', () => {
    const doc = animDoc();
    expect(dropRestChannels(doc)).toBe(3);
    const left = doc.getRoot().listAnimations()[0].listChannels();
    expect(left.map((c) => c.getTargetPath())).toEqual(['translation']);
  });
  it('shifts key times so the clip starts at 0 and names it', async () => {
    const doc = animDoc();
    zeroStart(doc);
    const t = doc.getRoot().listAnimations()[0].listSamplers()[0].getInput()!.getArray()!;
    expect(t[0]).toBeCloseTo(0, 6);
    expect(t[2]).toBeCloseTo(2 / 30, 6);
    await packDoc(doc, 'run');
    expect(doc.getRoot().listAnimations()[0].getName()).toBe('run');
  });
});

describe('tools/blender.mjs', () => {
  it('parses positionals and flags', () => {
    const { pos, flags } = parseArgs(['skull_rat', 'walk', '--recipe', 'r.json', '--install', '--out', 'o']);
    expect(pos).toEqual(['skull_rat', 'walk']);
    expect(flags).toEqual({ recipe: 'r.json', install: true, out: 'o' });
  });
  const blender = findBlender();
  const have = existsSync(blender) && spawnSync(blender, ['--version']).status === 0;
  it.skipIf(!have)('kinematics agree with Blender (selftest.py)', () => {
    const r = spawnSync(blender, ['-b', '--factory-startup', '--python', 'tools/blender/selftest.py'], { encoding: 'utf8' });
    expect(r.stdout).toContain('SELFTEST OK');
  }, 60000);
});

/**
 * The shipped quadruped gaits are authored so the planted feet move backwards at one constant speed; the measurement is
 * mesh-based (skinned vertices of the recipe's legs touching the floor), so a regression in the rig, the weights or the
 * export shows up here. Before this pass the skull rat's walk measured spread 1.7 with 29% of its planted vertices moving forwards.
 */
describe.each(['skull_rat', 'cinderhound', 'bone_hound'] as const)('%s gait (measured)', (slug) => {
  const file = `public/models/${slug}/character.glb`;
  const recipe = `tools/blender/recipes/${slug}.json`;
  const fwd = (): [number, number] => {
    const f = JSON.parse(readFileSync(recipe, 'utf8')).forward as number[];
    return [f[0], -f[1]];
  };
  it('ships idle, walk and run', () => {
    const clips = JSON.parse(readFileSync(`public/models/${slug}/clips.json`, 'utf8')).clips as string[];
    expect(clips).toEqual(expect.arrayContaining(['idle', 'walk', 'run']));
    const row = (STRIDES as Record<string, { walk?: number; run?: number }>)[slug];
    expect(row.walk).toBeGreaterThan(0);
    expect(row.run).toBeGreaterThan(row.walk!);
  });
  it('walk: planted vertices move back at one steady speed, none forwards', async () => {
    const bones = await legBonesOf(recipe, file);
    const m = await contactStrideOfClip(file, 'walk', { bones, signed: true, fwd: fwd(), contact: 0.01 });
    expect(m.spread).toBeLessThan(0.08);
    expect(m.wrong).toBeLessThan(0.1);
  }, 60000);
  it('run: planted vertices go back, and the foot-bone stride agrees with the mesh', async () => {
    const bones = await legBonesOf(recipe, file);
    const m = await contactStrideOfClip(file, 'run', { bones, signed: true, fwd: fwd() });
    expect(m.wrong).toBeLessThan(0.1);
    const feet = Object.values(JSON.parse(readFileSync(recipe, 'utf8')).legs as Record<string, { paw: string }>).map((l) => l.paw);
    const s = await strideOfClip(file, 'run', { feet });
    expect(Math.abs(m.speed - s.speed) / s.speed).toBeLessThan(0.35);
  }, 60000);
});
