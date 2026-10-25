/**
 * pack.mjs - tidy a GLB that Blender exported so tools/build-characters.mjs can take its clip:
 *   - key times start at 0 (Blender writes frame/fps),
 *   - channels that never leave the node's rest transform are dropped (Blender samples every bone's T/R/S),
 *   - the animation gets the requested name.
 * Pure functions work on a glTF-Transform Document so they can be unit tested without Blender.
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { prune } from '@gltf-transform/functions';

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

function constantAt(arr, stride, rest, eps, signless = false) {
  const n = arr.length / stride;
  for (let i = 0; i < n; i++) {
    let sign = 1;
    if (signless) {
      let dot = 0;
      for (let c = 0; c < stride; c++) dot += arr[i * stride + c] * rest[c];
      sign = dot < 0 ? -1 : 1;
    }
    for (let c = 0; c < stride; c++) if (Math.abs(arr[i * stride + c] * sign - rest[c]) > eps) return false;
  }
  return true;
}

/** Drop channels that equal the node's rest value on every key. Returns the number dropped. */
export function dropRestChannels(doc, eps = 1e-5) {
  let dropped = 0;
  for (const anim of doc.getRoot().listAnimations()) {
    for (const ch of anim.listChannels()) {
      const node = ch.getTargetNode();
      const out = ch.getSampler()?.getOutput();
      if (!node || !out) continue;
      const path = ch.getTargetPath();
      const rest = path === 'translation' ? node.getTranslation() : path === 'rotation' ? node.getRotation() : path === 'scale' ? node.getScale() : null;
      if (!rest) continue;
      if (constantAt(out.getArray(), rest.length, rest, eps, path === 'rotation')) {
        const s = ch.getSampler();
        ch.dispose();
        if (!anim.listChannels().some((c) => c.getSampler() === s)) s.dispose();
        dropped++;
      }
    }
  }
  return dropped;
}

/** Shift every sampler's key times so the animation starts at t = 0. */
export function zeroStart(doc) {
  for (const anim of doc.getRoot().listAnimations()) {
    let t0 = Infinity;
    for (const s of anim.listSamplers()) t0 = Math.min(t0, s.getInput().getArray()[0]);
    if (!(t0 > 1e-9) || !isFinite(t0)) continue;
    const seen = new Set();
    for (const s of anim.listSamplers()) {
      const a = s.getInput();
      if (seen.has(a)) continue;
      seen.add(a);
      a.setArray(a.getArray().map((t) => Math.max(0, t - t0)));
    }
  }
}

/**
 * Add the first animation of `src` to `dst` as `name`, by joint name (as tools/build-characters.mjs copies clips), replacing a clip of
 * that name; mesh, skin and textures are untouched. With `align`, the keys are shifted to start where `dst`'s clip `align` starts: a
 * re-bake of a shipped clip keeps its timing (Tripo clips start a frame in; zeroStart moved the re-bake to 0). Returns the channels copied.
 */
export function addClip(dst, src, name, align = null) {
  const root = dst.getRoot();
  for (const old of root.listAnimations().filter((a) => a.getName() === name)) {
    for (const s of old.listSamplers()) {
      const used = [s.getInput(), s.getOutput()];
      s.dispose();
      for (const acc of used) if (acc && !acc.listParents().some((p) => p !== root)) acc.dispose();
    }
    old.dispose();
  }
  const from = src.getRoot().listAnimations()[0];
  if (!from) return 0;
  const start = (anim) => Math.min(...anim.listSamplers().map((s) => s.getInput().getArray()[0]));
  const base = align ? root.listAnimations().find((a) => a.getName() === align) : null;
  const shift = base ? start(base) - start(from) : 0;
  const byName = new Map(root.listNodes().map((n) => [n.getName(), n]));
  const buffer = root.listBuffers()[0];
  const anim = dst.createAnimation(name);
  let channels = 0;
  for (const ch of from.listChannels()) {
    const target = byName.get(ch.getTargetNode()?.getName());
    if (!target) continue;
    const s = ch.getSampler();
    const input = dst.createAccessor().setType('SCALAR').setArray(s.getInput().getArray().map((t) => t + shift)).setBuffer(buffer);
    const output = dst.createAccessor().setType(s.getOutput().getType()).setArray(s.getOutput().getArray().slice()).setBuffer(buffer);
    const sampler = dst.createAnimationSampler().setInput(input).setOutput(output).setInterpolation(s.getInterpolation());
    anim.addSampler(sampler);
    anim.addChannel(dst.createAnimationChannel().setTargetNode(target).setTargetPath(ch.getTargetPath()).setSampler(sampler));
    channels++;
  }
  return channels;
}

export async function packDoc(doc, name) {
  zeroStart(doc);
  const dropped = dropRestChannels(doc);
  if (name) for (const a of doc.getRoot().listAnimations()) a.setName(name);
  await doc.transform(prune());
  return dropped;
}

export async function packFile(path, name, out = path) {
  const doc = await io.read(path);
  const dropped = await packDoc(doc, name);
  await io.write(out, doc);
  return { file: out, dropped, channels: doc.getRoot().listAnimations().reduce((n, a) => n + a.listChannels().length, 0) };
}
