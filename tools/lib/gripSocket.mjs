/** Shared by tools/gen-grip-sockets.mjs and the socket fit (src/graphics/__tests__/gripSocketFit.test.ts). */
import * as THREE from 'three';
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { readFileSync } from 'node:fs';

export const HEROES = ['hero_ossuary', 'hero_gravecaller', 'hero_mourner', 'hero_rotweaver'];
export const KINDS = { main_hand: ['staff', 'scythe', 'wand', 'sickle'], off_hand: ['skull_focus', 'grimoire', 'mourning_bell'] };
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const BIPED_YAW = -Math.PI / 2;
const IDLE_T = 0;

/** GRIPS from gearProps.ts (single source of truth): { lean: [out, fwd], offset?: [x, y, z], roll }. */
export function readGrips() {
  const src = readFileSync('src/graphics/gearProps.ts', 'utf8');
  const block = src.slice(src.indexOf('export const GRIPS'), src.indexOf('export interface Grip {'));
  const GRIPS = {};
  for (const m of block.matchAll(/^\s+(\w+): \{ lean: \[([-\d.]+), ([-\d.]+)\](?:, offset: \[([-\d., ]+)\])?(?:, roll: ([-\d.]+))?, follow: ([\d.]+) \},/gm)) {
    GRIPS[m[1]] = { lean: [+m[2], +m[3]], offset: m[4] ? m[4].split(',').map(Number) : undefined, roll: m[5] ? +m[5] : 0 };
  }
  return GRIPS;
}

export async function loadRig(hero) {
  const doc = await io.read(`public/models/${hero}/character.glb`);
  const root = new THREE.Group();
  const model = new THREE.Group();
  model.rotation.y = BIPED_YAW;
  root.add(model);
  const nodes = new Map(doc.getRoot().listNodes().map((n) => {
    const b = new THREE.Bone();
    b.name = THREE.PropertyBinding.sanitizeNodeName(n.getName());
    b.position.fromArray(n.getTranslation());
    b.quaternion.fromArray(n.getRotation());
    b.scale.fromArray(n.getScale());
    return [n, b];
  }));
  for (const [n, b] of nodes) (nodes.get(n.getParentNode()) ?? model).add(b);
  const idle = doc.getRoot().listAnimations().find((a) => a.getName() === 'idle');
  const tracks = idle.listChannels().map((c) => {
    const s = c.getSampler();
    const prop = { translation: 'position', rotation: 'quaternion', scale: 'scale' }[c.getTargetPath()];
    const name = `${THREE.PropertyBinding.sanitizeNodeName(c.getTargetNode().getName())}.${prop}`;
    const T = prop === 'quaternion' ? THREE.QuaternionKeyframeTrack : THREE.VectorKeyframeTrack;
    return new T(name, s.getInput().getArray(), s.getOutput().getArray());
  });
  const mixer = new THREE.AnimationMixer(model);
  mixer.clipAction(new THREE.AnimationClip('idle', -1, tracks)).play();
  mixer.setTime(IDLE_T);
  root.updateMatrixWorld(true);
  return { root, bone: (n) => root.getObjectByName(n) };
}

export const Y = new THREE.Vector3(0, 1, 0);

/**
 * Bone-local socket for a grip spec: +Y along the lean direction (character frame), rolled, shifted by `offset`.
 * `fit` ({ out, fwd, shift } deltas from tools/grip-fit.json) nudges the lean and pushes the grip outward.
 */
export function socket(rig, boneName, side, spec, fit = {}) {
  const bone = rig.bone(boneName);
  const rootQ = rig.root.getWorldQuaternion(new THREE.Quaternion());
  const boneQ = bone.getWorldQuaternion(new THREE.Quaternion());
  const inv = boneQ.clone().invert();
  // Same construction as the old runtime calibration: the shortest arc from the bone's +Y to the aim, in the bone's frame.
  const lean = [spec.lean[0] + (fit.out ?? 0), spec.lean[1] + (fit.fwd ?? 0)];
  const dir = new THREE.Vector3(side * lean[0], 1, lean[1]).normalize().applyQuaternion(rootQ).applyQuaternion(inv);
  const q = new THREE.Quaternion().setFromUnitVectors(Y, dir);
  if (spec.roll) q.multiply(new THREE.Quaternion().setFromAxisAngle(Y, spec.roll));
  const o = spec.offset ?? [0, 0, 0];
  const pos = new THREE.Vector3(side * (o[0] + (fit.shift ?? 0)), o[1], o[2]).applyQuaternion(rootQ).applyQuaternion(inv);
  return { q, pos };
}
