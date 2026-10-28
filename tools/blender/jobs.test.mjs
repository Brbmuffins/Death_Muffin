// Blender jobs without Blender: the kinds list, job validation, the model rows and the merge back into a shipped model (merge.mjs), on
// made-up models. Blender itself is exercised by running a job (docs/BLENDER-PIPELINE.md "Jobs").
//   node --test tools/blender/jobs.test.mjs      (CI: "Blender jobs")
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Document } from '@gltf-transform/core';
import { Matrix4, Quaternion, Vector3 } from 'three';
import { ARM_DEFAULTS, CAPE, armLimits, capeLimits, cloakModel, rebakeCloak } from './cloak.mjs';
import { KINDS, KIND_RUN, maskBlend, rowsOf, staffPlan, updateRow, validateJob } from './jobs.mjs';
import { invAffine, mul, transplantClip, transplantGeometry } from './merge.mjs';
import { addClip } from './pack.mjs';

const STAFF = JSON.parse(readFileSync(new URL('./recipes/staff.json', import.meta.url), 'utf8'));

const T = (x, y, z) => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1];
const S = (s) => [s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1];
const near = (a, b, eps = 1e-5) => a.length === b.length && Array.from(a).every((v, i) => Math.abs(v - b[i]) <= eps);

/** A skinned model: joints (name, parent, translation), one triangle per joint, each vertex on its own joint, IBMs given. */
function model(joints, ibms, { positions, normals } = {}) {
  const doc = new Document();
  const buf = doc.createBuffer();
  const nodes = {};
  const scene = doc.createScene();
  for (const j of joints) {
    nodes[j.name] = doc.createNode(j.name).setTranslation(j.t ?? [0, 0, 0]);
    if (j.parent) nodes[j.parent].addChild(nodes[j.name]); else scene.addChild(nodes[j.name]);
  }
  const skin = doc.createSkin();
  for (const j of joints) skin.addJoint(nodes[j.name]);
  skin.setInverseBindMatrices(doc.createAccessor().setType('MAT4').setArray(new Float32Array(ibms.flat())).setBuffer(buf));
  const n = joints.length * 3;
  const pos = positions ?? Array.from({ length: n }, (_, v) => [v % 3, Math.floor(v / 3), 0]).flat();
  const nor = normals ?? Array.from({ length: n }, () => [0, 0, 1]).flat();
  const jts = Array.from({ length: n }, (_, v) => [Math.floor(v / 3), 0, 0, 0]).flat();
  const wts = Array.from({ length: n }, () => [1, 0, 0, 0]).flat();
  const prim = doc.createPrimitive()
    .setAttribute('POSITION', doc.createAccessor().setType('VEC3').setArray(new Float32Array(pos)).setBuffer(buf))
    .setAttribute('NORMAL', doc.createAccessor().setType('VEC3').setArray(new Float32Array(nor)).setBuffer(buf))
    .setAttribute('JOINTS_0', doc.createAccessor().setType('VEC4').setArray(new Uint16Array(jts)).setBuffer(buf))
    .setAttribute('WEIGHTS_0', doc.createAccessor().setType('VEC4').setArray(new Float32Array(wts)).setBuffer(buf))
    .setIndices(doc.createAccessor().setType('SCALAR').setArray(new Uint16Array(Array.from({ length: n }, (_, i) => i))).setBuffer(buf))
    .setMaterial(doc.createMaterial('skin'));
  const mesh = doc.createNode('body').setMesh(doc.createMesh('body').addPrimitive(prim)).setSkin(skin);
  scene.addChild(mesh);
  return { doc, nodes };
}
const ibmsOf = (doc) => Array.from(doc.getRoot().listSkins()[0].getInverseBindMatrices().getArray());
const prim = (doc) => doc.getRoot().listMeshes()[0].listPrimitives()[0];

// The shipped model's bind carries a scale (as Tripo's do), Blender's export is normalised: IBM_shipped = IBM_blender * D^-1 with D = scale 2.
const D = S(2);
const BONES = [{ name: 'Root' }, { name: 'Spine', parent: 'Root', t: [0, 1, 0] }, { name: 'Head', parent: 'Spine', t: [0, 1, 0] }];
const SHIPPED_IBM = [invAffine(T(0, 0, 0)), invAffine(T(0, 1, 0)), invAffine(T(0, 2, 0))];
const BLENDER_IBM = SHIPPED_IBM.map((m) => mul(m, D));

test('the kinds list and the handlers agree, and every kind is well formed', () => {
  assert.deepEqual(Object.keys(KINDS).sort(), Object.keys(KIND_RUN).sort());
  for (const [k, v] of Object.entries(KINDS)) {
    assert.ok(typeof v.what === 'string' && v.what.length > 20, `${k}: what`);
    assert.ok(Array.isArray(v.targets) && v.targets.length && v.targets.every((t) => ['character', 'prop'].includes(t)), `${k}: targets`);
    for (const [p, s] of Object.entries(v.params)) assert.ok(['int', 'number', 'bool', 'string', 'strings', 'map'].includes(s.type), `${k}.${p}: type ${s.type}`);
  }
});

test('a job is checked against the kinds before anything runs', () => {
  const ok = { model: 'skull_rat', note: 'why', steps: [{ kind: 'cleanup', clip: 'walk', loop: true }, { kind: 'reshape', bone: 'tripo::Head_0', scale: 1.4 }] };
  assert.deepEqual(validateJob(ok), []);
  assert.match(validateJob({ ...ok, colour: 1 }).join(), /unknown field colour/);
  assert.match(validateJob({ ...ok, model: '../etc' }).join(), /model must be a model id/);
  assert.match(validateJob({ ...ok, steps: [] }).join(), /1 to 8 steps/);
  assert.match(validateJob({ ...ok, steps: Array(9).fill({ kind: 'inspect' }) }).join(), /1 to 8 steps/);
  assert.match(validateJob({ ...ok, steps: [{ kind: 'sculpt' }] }).join(), /unknown kind sculpt/);
  assert.match(validateJob({ ...ok, steps: [{ kind: 'reshape', bone: 'Head' }] }).join(), /reshape needs scale/);
  assert.match(validateJob({ ...ok, steps: [{ kind: 'reshape', bone: 'Head', scale: 9 }] }).join(), /scale must be number from 0\.5 up to 2/);
  assert.match(validateJob({ ...ok, steps: [{ kind: 'cleanup', clip: 'walk', wobble: true }] }).join(), /cleanup takes no wobble/);
  assert.match(validateJob({ ...ok, steps: [{ kind: 'decimate', triangles: 1.5 }] }).join(), /triangles must be int/);
  assert.match(validateJob({ model: 'prop_lantern', steps: [{ kind: 'reshape', bone: 'Head', scale: 1.2 }] }).join(), /reshape does not apply to a prop/);
  assert.deepEqual(validateJob({ model: 'prop_lantern', steps: [{ kind: 'recolor', hue: 30 }] }), []);
  assert.deepEqual(validateJob({ model: 'hero_new', steps: [{ kind: 'retarget', from: 'hero_gravecaller' }] }), []);
});

test('a staff step re-bakes the recipe\'s clips on the recipe\'s heroes only, and its preview shows at most four', () => {
  const hero = STAFF.heroes[0];
  const all = Object.keys(STAFF.clips);
  const have = [...all, 'death', 'hurt'];
  assert.deepEqual(validateJob({ model: hero, steps: [{ kind: 'staff' }, { kind: 'staff', clips: [all[0]] }] }), []);
  assert.match(validateJob({ model: hero, steps: [{ kind: 'staff', clips: [] }] }).join(), /clips must be strings from 1/);
  assert.match(validateJob({ model: 'prop_lantern', steps: [{ kind: 'staff' }] }).join(), /staff does not apply to a prop/);

  const every = staffPlan(hero, {}, have, STAFF);
  assert.deepEqual(every.clips, all, 'no clips: every clip of the recipe');
  assert.deepEqual(every.show, STAFF.preview.filter((c) => all.includes(c)).slice(0, 4), 'the recipe\'s preview clips');
  const named = staffPlan(hero, { clips: [all[1], all[0]] }, have, STAFF);
  assert.deepEqual(named, { clips: [all[1], all[0]], show: [all[1], all[0]] }, 'named clips are re-baked and shown');
  assert.ok(staffPlan(hero, { clips: all }, have, STAFF).show.length <= 4);

  assert.throws(() => staffPlan('hero_leg_plague_choir', {}, have, STAFF), /staff recipe's heroes/);
  assert.throws(() => staffPlan(hero, { clips: [`${all[0]}_staff`] }, have, STAFF), /no clip .*_staff .*not its _staff copy/);
  assert.throws(() => staffPlan(hero, {}, have.filter((c) => c !== all[0]), STAFF), new RegExp(`model has no clip ${all[0]}`));
});

test('a re-baked clip replaces its old copy and starts where the clip it re-bakes starts', () => {
  const { doc: dst, nodes } = model(BONES, SHIPPED_IBM);
  const clip = (doc, node, name, times) => {
    const s = doc.createAnimationSampler().setInput(doc.createAccessor().setType('SCALAR').setArray(new Float32Array(times)))
      .setOutput(doc.createAccessor().setType('VEC4').setArray(new Float32Array(times.flatMap(() => [0, 0, 0, 1]))));
    doc.createAnimation(name).addSampler(s).addChannel(doc.createAnimationChannel().setTargetNode(node).setTargetPath('rotation').setSampler(s));
  };
  clip(dst, nodes.Spine, 'run', [0.5, 1, 1.5]);
  clip(dst, nodes.Spine, 'run_staff', [0.5, 1.5]);
  const accessors = dst.getRoot().listAccessors().length;
  const { doc: src, nodes: sn } = model(BONES, BLENDER_IBM);
  clip(src, sn.Head, 'Action', [0, 0.5, 1]);
  assert.equal(addClip(dst, src, 'run_staff', 'run'), 1);
  const staff = dst.getRoot().listAnimations().filter((a) => a.getName() === 'run_staff');
  assert.equal(staff.length, 1, 'the old copy is replaced, not doubled');
  assert.equal(staff[0].listChannels()[0].getTargetNode(), nodes.Head);
  assert.deepEqual([...staff[0].listSamplers()[0].getInput().getArray()], [0.5, 1, 1.5], 'aligned to run\'s start');
  assert.equal(dst.getRoot().listAccessors().length, accessors, 'the old copy\'s data is gone');
});

test('a model row follows the job: clip order kept, renames carry their stride and timings, dropped clips leave', () => {
  const data = { list: [{ slug: 'ghoul', clips: ['idle', 'walk', 'dig', 'attack'], stride: { walk: 0.5 }, timings: { attack: [1, 0.4] } }, { slug: 'rat', clips: ['idle'] }] };
  const rows = rowsOf(data, 'ghoul');
  assert.equal(rows.length, 1);
  updateRow(rows[0], { clips: ['idle', 'walk', 'dig_up', 'attack3'], renamed: { dig: 'dig_up' }, stride: { walk: 0.62 }, timings: { attack3: [1.53, 0.4] } });
  assert.deepEqual(data.list[0], { slug: 'ghoul', clips: ['idle', 'walk', 'dig_up', 'attack3'], stride: { walk: 0.62 }, timings: { attack3: [1.53, 0.4] } });
  assert.deepEqual(data.list[1], { slug: 'rat', clips: ['idle'] }, 'another model\'s row is left alone');
});

test('a masked recolour changes texels near the colour and leaves the rest', () => {
  const px = Buffer.from([200, 10, 10, 255, 10, 200, 10, 255]);
  const mod = Buffer.from([10, 10, 200, 255, 10, 10, 200, 255]);
  const out = maskBlend(px, mod, { color: '#c80a0a', within: 0.2 });
  assert.deepEqual([...out], [10, 10, 200, 255, 10, 200, 10, 255]);
  assert.throws(() => maskBlend(px, mod, { color: 'red' }), /#rrggbb/);
});

test('a clip from Blender lands on the shipped skeleton by bone name and replaces the clip of that name', () => {
  const { doc: dst, nodes } = model(BONES, SHIPPED_IBM);
  const old = dst.createAnimation('walk');
  const s0 = dst.createAnimationSampler().setInput(dst.createAccessor().setType('SCALAR').setArray(new Float32Array([0, 1]))).setOutput(dst.createAccessor().setType('VEC3').setArray(new Float32Array(6)));
  old.addSampler(s0).addChannel(dst.createAnimationChannel().setTargetNode(nodes.Root).setTargetPath('translation').setSampler(s0));
  const { doc: src, nodes: sn } = model(BONES, BLENDER_IBM);
  const extra = src.createNode('Blender_only');
  sn.Head.addChild(extra);
  const a = src.createAnimation('Action');
  for (const [node, path, out] of [[sn.Head, 'rotation', [0, 0, 0, 1, 0, 0.7071, 0, 0.7071]], [extra, 'translation', [0, 0, 0, 1, 1, 1]]]) {
    const s = src.createAnimationSampler().setInput(src.createAccessor().setType('SCALAR').setArray(new Float32Array([0, 1.5]))).setOutput(src.createAccessor().setType(path === 'rotation' ? 'VEC4' : 'VEC3').setArray(new Float32Array(out)));
    a.addSampler(s).addChannel(src.createAnimationChannel().setTargetNode(node).setTargetPath(path).setSampler(s));
  }
  const r = transplantClip(dst, src, 'walk');
  assert.deepEqual(r, { channels: 1, skipped: 1, seconds: 1.5 });
  const walks = dst.getRoot().listAnimations().filter((x) => x.getName() === 'walk');
  assert.equal(walks.length, 1, 'the old walk is replaced, not doubled');
  assert.equal(walks[0].listChannels()[0].getTargetNode(), nodes.Head);
  assert.throws(() => transplantClip(dst, src, 'walk', 'missing'), /no clip missing/);
  // a second skeleton with the same bone names (a retarget's source exported beside its target) is refused, not mixed in
  const twinHead = src.createNode('Head');
  src.getRoot().listScenes()[0].addChild(twinHead);
  const s2 = src.createAnimationSampler().setInput(src.createAccessor().setType('SCALAR').setArray(new Float32Array([0, 1.5]))).setOutput(src.createAccessor().setType('VEC4').setArray(new Float32Array([0, 0, 0, 1, 0, 0, 0, 1])));
  a.addSampler(s2).addChannel(src.createAnimationChannel().setTargetNode(twinHead).setTargetPath('rotation').setSampler(s2));
  assert.throws(() => transplantClip(dst, src, 'walk'), /two channels drive Head rotation/);
});

test('edited geometry from Blender is moved into the shipped bind space; skin indices follow the bone names', () => {
  const { doc: dst } = model(BONES, SHIPPED_IBM);
  // Blender lists the joints in another order and has a smaller (decimated) mesh with tilted normals
  const order = [2, 0, 1];
  const { doc: src } = model(order.map((i) => ({ ...BONES[i], parent: undefined })), order.map((i) => BLENDER_IBM[i]), {
    positions: [0, 0.5, 0, 1, 0.5, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0.5, 0, 0, 0.25, 0, 0.5, 0.25, 0, 0, 0.5, 0],
    normals: Array(9).fill([0, 3, 4]).flat(),
  });
  const before = dst.getRoot().listMaterials()[0];
  const r = transplantGeometry(dst, src);
  assert.deepEqual(r, { triangles: [3, 3], addedBones: [] });
  const p = prim(dst);
  assert.ok(near(p.getAttribute('POSITION').getArray().slice(0, 6), [0, 1, 0, 2, 1, 0]), 'positions scaled by D into the shipped space');
  assert.ok(near(p.getAttribute('NORMAL').getArray().slice(0, 3), [0, 0.6, 0.8]), 'normals stay unit length');
  // src joint 0 is Head (shipped index 2), 1 is Root (0), 2 is Spine (1)
  assert.deepEqual([...p.getAttribute('JOINTS_0').getArray()].filter((_, i) => i % 4 === 0), [2, 2, 2, 0, 0, 0, 1, 1, 1]);
  assert.equal(p.getMaterial(), before, 'the material is the shipped one');
  assert.ok(near(ibmsOf(dst), SHIPPED_IBM.flat()), 'the shipped bind is unchanged');
});

test('a bone that moved in Blender is refused; a new bone joins the skin under its parent', () => {
  const moved = BLENDER_IBM.map((m, i) => (i === 2 ? mul(invAffine(T(0, 2.4, 0)), D) : m));
  assert.throws(() => transplantGeometry(model(BONES, SHIPPED_IBM).doc, model(BONES, moved).doc), /bone Head moved in Blender/);

  const { doc: dst, nodes } = model(BONES, SHIPPED_IBM);
  const withJaw = [...BONES, { name: 'Jaw', parent: 'Head', t: [0, -0.25, 0.25] }];
  const jawIbm = mul(invAffine(T(0, 1.75, 0.25)), D);
  const r = transplantGeometry(dst, model(withJaw, [...BLENDER_IBM, jawIbm]).doc);
  assert.deepEqual(r.addedBones, ['Jaw']);
  const jaw = dst.getRoot().listSkins()[0].listJoints()[3];
  assert.equal(jaw.getName(), 'Jaw');
  assert.equal(jaw.getParentNode(), nodes.Head);
  assert.ok(near(ibmsOf(dst).slice(48), mul(jawIbm, invAffine(D))), 'its bind is in the shipped space');
  assert.ok(near(ibmsOf(dst).slice(0, 48), SHIPPED_IBM.flat()), 'the other binds are unchanged');
});

// ---------- the cloak job (cloak.mjs) ----------
/**
 * A small T-pose biped with the shared skeleton's names (Y up, facing +X, the arms along Z, no rotations, bind = rest). `points`: [x, y, z,
 * bone] vertices; `cape` adds a grid of cloth hanging well behind the back, on the spine and the thigh as Tripo weights it.
 */
function biped(points, { cape = false } = {}) {
  const at = { Root: [0, 0, 0], Hip: [0, 1, 0], Waist: [0, 1.1, 0], Spine01: [0, 1.25, 0], Spine02: [0, 1.4, 0], NeckTwist01: [0, 1.6, 0], Head: [0, 1.7, 0] };
  const parent = { Hip: 'Root', Waist: 'Hip', Spine01: 'Waist', Spine02: 'Spine01', NeckTwist01: 'Spine02', Head: 'NeckTwist01' };
  for (const [s, z] of [['L', 1], ['R', -1]]) {
    const bones = { Clavicle: [[0, 1.5, 0.1 * z], 'Spine02'], Upperarm: [[0, 1.5, 0.2 * z], 'Clavicle'], UpperarmTwist01: [[0, 1.5, 0.32 * z], 'Upperarm'],
      Forearm: [[0, 1.5, 0.45 * z], 'Upperarm'], Hand: [[0, 1.5, 0.7 * z], 'Forearm'], Thigh: [[0, 1, 0.1 * z], 'Hip'], Calf: [[0, 0.55, 0.1 * z], 'Thigh'],
      Foot: [[0, 0.1, 0.1 * z], 'Calf'], ToeBase: [[0.15, 0.02, 0.1 * z], 'Foot'] };
    for (const [b, [p, par]] of Object.entries(bones)) { at[`${s}_${b}`] = p; parent[`${s}_${b}`] = par === 'Hip' || par === 'Spine02' ? par : `${s}_${par}`; }
  }
  const pts = [...points, [0, 1.75, 0, 'Head'], [0.1, 0, 0.1, 'L_Foot'], [0.1, 1.3, 0, 'Spine01']];
  if (cape) for (let y = 1.35; y > 0.14; y -= 0.05) for (const z of [-0.1, 0, 0.1]) pts.push([-0.4, y, z, y > 1.25 ? 'Spine02' : y > 1 ? 'Waist' : 'L_Thigh']);
  const names = Object.keys(at);
  const joints = names.map((n) => ({ name: n, parent: parent[n], t: parent[n] ? at[n].map((v, i) => v - at[parent[n]][i]) : at[n] }));
  const { doc, nodes } = model(joints, names.map((n) => invAffine(T(...at[n]))), { positions: Array(names.length * 9).fill(0) });
  const p = prim(doc), buf = doc.getRoot().listBuffers()[0];
  p.setAttribute('POSITION', doc.createAccessor().setType('VEC3').setArray(new Float32Array(pts.flatMap((q) => q.slice(0, 3)))).setBuffer(buf));
  p.setAttribute('NORMAL', null);
  p.setAttribute('JOINTS_0', doc.createAccessor().setType('VEC4').setArray(new Uint8Array(pts.flatMap((q) => [names.indexOf(q[3]), 0, 0, 0]))).setBuffer(buf));
  p.setAttribute('WEIGHTS_0', doc.createAccessor().setType('VEC4').setArray(new Float32Array(pts.flatMap(() => [1, 0, 0, 0]))).setBuffer(buf));
  p.setIndices(null);
  return { doc, nodes };
}

/** Add a clip keyed at t = 0 and 1: {bone: [rotation at 0, rotation at 1]}. */
function clip(doc, nodes, name, rots) {
  const a = doc.createAnimation(name), buf = doc.getRoot().listBuffers()[0];
  for (const [bone, [q0, q1]] of Object.entries(rots)) {
    const s = doc.createAnimationSampler().setInput(doc.createAccessor().setType('SCALAR').setArray(new Float32Array([0, 1])).setBuffer(buf))
      .setOutput(doc.createAccessor().setType('VEC4').setArray(new Float32Array([...q0, ...q1])).setBuffer(buf));
    a.addSampler(s).addChannel(doc.createAnimationChannel().setTargetNode(nodes[bone]).setTargetPath('rotation').setSampler(s));
  }
}
const about = (axis, deg) => new Quaternion().setFromAxisAngle(new Vector3(...axis), deg * Math.PI / 180).toArray();
const NONE = [0, 0, 0, 1];

/** Bone positions and rotations in a clip at a key time (rest where a bone has no channel). */
function poseAt(doc, name, t) {
  const anim = doc.getRoot().listAnimations().find((a) => a.getName() === name);
  const val = new Map();
  for (const ch of anim.listChannels()) {
    const s = ch.getSampler(), k = Array.from(s.getInput().getArray()).findIndex((x) => Math.abs(x - t) < 1e-6), n = ch.getTargetPath() === 'rotation' ? 4 : 3;
    assert.ok(k >= 0, `${ch.getTargetNode().getName()} has a key at ${t}`);
    val.set(`${ch.getTargetNode().getName()}.${ch.getTargetPath()}`, Array.from(s.getOutput().getArray().slice(k * n, k * n + n)));
  }
  const memo = new Map();
  const world = (node) => {
    if (!node) return new Matrix4();
    if (!memo.has(node)) {
      const g = (p, rest) => val.get(`${node.getName()}.${p}`) ?? rest;
      memo.set(node, world(node.getParentNode()).clone().multiply(new Matrix4().compose(new Vector3(...g('translation', node.getTranslation())), new Quaternion(...g('rotation', node.getRotation())), new Vector3(...g('scale', node.getScale())))));
    }
    return memo.get(node);
  };
  const byName = (n) => world(doc.getRoot().listNodes().find((x) => x.getName() === n));
  return { at: (n) => new Vector3().setFromMatrixPosition(byName(n)), rot: (n) => new Quaternion().setFromRotationMatrix(byName(n)) };
}
const elevation = (d, up = new Vector3(0, 1, 0)) => Math.asin(d.clone().normalize().dot(up)) * 180 / Math.PI;

/** Each vertex's {bone: weight}. */
function weightsOf(doc) {
  const names = doc.getRoot().listSkins()[0].listJoints().map((j) => j.getName());
  const J = prim(doc).getAttribute('JOINTS_0').getArray(), W = prim(doc).getAttribute('WEIGHTS_0').getArray();
  return Array.from({ length: J.length / 4 }, (_, v) => {
    const m = {};
    for (let k = 0; k < 4; k++) if (W[v * 4 + k] > 0) m[names[J[v * 4 + k]]] = (m[names[J[v * 4 + k]]] ?? 0) + W[v * 4 + k];
    return m;
  });
}

// the arm's sleeve on the arm line, a side panel hanging well below it (both sides)
const ARM_POINTS = [[0, 1.5, 0.35, 'L_Upperarm'], [0, 1.49, 0.6, 'L_Forearm'], [0, 1.15, 0.55, 'L_Forearm'], [0, 1.15, -0.55, 'R_Forearm']];
// idle: arms down; slam: arms overhead while the back bows forward 70 degrees (forward is +X)
const IDLE = { L_Upperarm: [about([1, 0, 0], 80), about([1, 0, 0], 80)], R_Upperarm: [about([1, 0, 0], -80), about([1, 0, 0], -80)] };
const SLAM = { L_Upperarm: [NONE, about([1, 0, 0], -80)], R_Upperarm: [NONE, about([1, 0, 0], 80)], Spine01: [NONE, about([0, 0, 1], -70)] };

test('the arm cloak: panels below the arm ride a copy that never rises over the limit; arms down are the arm\'s own keys', () => {
  const { doc, nodes } = biped(ARM_POINTS);
  clip(doc, nodes, 'idle', IDLE);
  clip(doc, nodes, 'slam', SLAM);
  const bindBefore = ibmsOf(doc);
  const r = cloakModel(doc);
  assert.deepEqual(r.added.sort(), ['L_CloakForearm', 'L_CloakHand', 'L_CloakUpperarm', 'L_CloakUpperarmTwist01', 'R_CloakForearm', 'R_CloakHand', 'R_CloakUpperarm', 'R_CloakUpperarmTwist01']);
  assert.equal(r.cape, null, 'no cape unless asked');
  const joints = doc.getRoot().listSkins()[0].listJoints().map((j) => j.getName());
  const ibm = ibmsOf(doc);
  assert.ok(near(ibm.slice(0, bindBefore.length), bindBefore), 'the shared bones keep their binds');
  for (const c of r.added) {
    const arm = c.replace('Cloak', '');
    assert.ok(near(ibm.slice(joints.indexOf(c) * 16, joints.indexOf(c) * 16 + 16), ibm.slice(joints.indexOf(arm) * 16, joints.indexOf(arm) * 16 + 16)), `${c} has ${arm}'s bind`);
    assert.equal(doc.getRoot().listNodes().find((n) => n.getName() === c).getParentNode().getName(), arm === 'L_Upperarm' || arm === 'R_Upperarm' ? arm.replace('Upperarm', 'Clavicle') : nodes[arm].getParentNode().getName().replace(/^([LR])_/, '$1_Cloak'));
  }
  const w = weightsOf(doc);
  assert.deepEqual(w[0], { L_Upperarm: 1 }, 'the sleeve keeps the arm');
  assert.deepEqual(w[1], { L_Forearm: 1 });
  assert.deepEqual(w[2], { L_CloakForearm: 1 }, 'the panel rides the cloak');
  assert.deepEqual(w[3], { R_CloakForearm: 1 });
  for (const m of w) assert.ok(Math.abs(Object.values(m).reduce((a, b) => a + b, 0) - 1) < 1e-6, 'weights sum to 1');

  // idle: the copy carries the arm's own keys
  const idle = doc.getRoot().listAnimations().find((a) => a.getName() === 'idle');
  const keys = (n) => Array.from(idle.listChannels().find((c) => c.getTargetNode().getName() === n && c.getTargetPath() === 'rotation').getSampler().getOutput().getArray());
  assert.ok(near(keys('L_CloakUpperarm'), keys('L_Upperarm')));
  assert.equal(r.arms.clips.idle.L[0], 0);
  // slam: the arm goes 80 degrees over the chest's level, the copy at most `top`; before the swing it is the arm
  const top = ARM_DEFAULTS.top;
  for (const t of [0, 1]) {
    const p = poseAt(doc, 'slam', t), up = new Vector3(0, 1, 0).applyQuaternion(p.rot('Spine02'));
    for (const s of ['L', 'R']) {
      const arm = elevation(p.at(`${s}_Forearm`).sub(p.at(`${s}_Upperarm`)), up), cl = elevation(p.at(`${s}_CloakForearm`).sub(p.at(`${s}_CloakUpperarm`)), up);
      const fore = elevation(p.at(`${s}_CloakHand`).sub(p.at(`${s}_CloakForearm`)), up);
      if (t === 0) assert.ok(Math.abs(cl - arm) < 1e-3, `${s} at rest: the copy is the arm`);
      else {
        assert.ok(arm > 75, `${s} arm overhead (${arm})`);
        assert.ok(cl <= top + 0.5 && cl > 0, `${s} cloak upper arm ${cl} <= ${top}`);
        assert.ok(fore <= top + 0.5, `${s} cloak forearm ${fore} <= ${top}`);
        assert.ok(p.at(`${s}_CloakUpperarm`).distanceTo(p.at(`${s}_Upperarm`)) < 1e-5, 'the copy hangs from the same shoulder');
      }
    }
  }
  // a re-run with the same settings changes nothing; another top re-tunes the keys and is saved in the file
  const again = cloakModel(doc);
  assert.deepEqual(again.added, []);
  assert.deepEqual(weightsOf(doc), w);
  cloakModel(doc, { top: 40 });
  assert.equal(armLimits(doc).top, 40);
  const hi = poseAt(doc, 'slam', 1), up = new Vector3(0, 1, 0).applyQuaternion(hi.rot('Spine02'));
  const e = elevation(hi.at('L_CloakForearm').sub(hi.at('L_CloakUpperarm')), up);
  assert.ok(e > top + 1 && e <= 40.5, `re-tuned to 40 (${e})`);
});

test('the cape: a chain down the back cloth hangs instead of standing up when the body bows; the rest pose is unchanged', () => {
  assert.throws(() => cloakModel(biped(ARM_POINTS).doc, { arms: false, cape: true }), /no cloth hangs behind/);
  assert.throws(() => cloakModel(biped(ARM_POINTS).doc, { arms: false }), /needs arms or cape/);
  const { doc, nodes } = biped(ARM_POINTS, { cape: true });
  clip(doc, nodes, 'idle', IDLE);
  clip(doc, nodes, 'slam', SLAM);
  const rest = (n) => { let m = new Matrix4(); for (let x = doc.getRoot().listNodes().find((y) => y.getName() === n); x; x = x.getParentNode()) m = new Matrix4().compose(new Vector3(...x.getTranslation()), new Quaternion(...x.getRotation()), new Vector3(...x.getScale())).multiply(m); return m; };
  const r = cloakModel(doc, { arms: false, cape: true });
  assert.deepEqual(r.added, CAPE);
  assert.equal(r.arms, null);
  assert.equal(nodes.Spine02.listChildren().find((c) => c.getName() === 'Cape01')?.getName(), 'Cape01', 'the cape hangs from the chest');
  const joints = doc.getRoot().listSkins()[0].listJoints().map((j) => j.getName()), ibm = ibmsOf(doc);
  for (const c of CAPE) assert.ok(near(rest(c).multiply(new Matrix4().fromArray(ibm, joints.indexOf(c) * 16)).toArray(), new Matrix4().toArray()), `${c}: bind = rest, so the still model is unchanged`);
  // the cloth behind rides the chain, by height; the chest's front keeps its bone
  const w = weightsOf(doc);
  const pts = Array.from(prim(doc).getAttribute('POSITION').getArray());
  const at = (x, y, z) => w[Array.from({ length: pts.length / 3 }, (_, v) => v).find((v) => Math.abs(pts[v * 3] - x) < 1e-4 && Math.abs(pts[v * 3 + 1] - y) < 1e-4 && Math.abs(pts[v * 3 + 2] - z) < 1e-4)];
  assert.deepEqual(at(0.1, 1.3, 0), { Spine01: 1 });
  assert.ok(Object.keys(at(-0.4, 0.6, 0)).every((b) => /^Cape0[1-3]$/.test(b)), 'the low back cloth is all cape');
  for (const m of w) assert.ok(Math.abs(Object.values(m).reduce((a, b) => a + b, 0) - 1) < 1e-6, 'weights sum to 1');
  // bowing 70 degrees would lift the lowest link 70 degrees: carried by the chest, it hangs at most lift + give above its rest
  const { lift, give } = capeLimits(doc);
  const p0 = poseAt(doc, 'slam', 0), p1 = poseAt(doc, 'slam', 1);
  for (let k = 0; k + 1 < CAPE.length; k++) {
    const restE = elevation(p0.at(CAPE[k + 1]).sub(p0.at(CAPE[k]))), e = elevation(p1.at(CAPE[k + 1]).sub(p1.at(CAPE[k])));
    assert.ok(e <= restE + lift + give + 0.5, `${CAPE[k]}: ${e} <= ${restE} + ${lift + give}`);
  }
  assert.ok(r.cape.clips.slam > 20, 'the slam was lowered');
  assert.ok(p1.at('Cape01').distanceTo(p1.at('Spine02')) - p0.at('Cape01').distanceTo(p0.at('Spine02')) < 1e-5, 'the top stays on the chest');
});

test('a clip changed after the cloak gets the cloak re-keyed from the saved settings', () => {
  const { doc, nodes } = biped(ARM_POINTS, { cape: true });
  clip(doc, nodes, 'slam', SLAM);
  cloakModel(doc, { cape: true, top: 30 });
  // the slam is replaced by one with the arms down and the back straight (as a staff or retarget step would): the old cloak keys are stale
  doc.getRoot().listAnimations()[0].dispose();
  clip(doc, nodes, 'slam', IDLE);
  const r = rebakeCloak(doc, ['slam']);
  assert.deepEqual(r.arms.slam, { L: [0, 0], R: [0, 0] });
  assert.equal(r.cape.slam, 0);
  assert.equal(armLimits(doc).top, 30, 'the settings stay');
  const p = poseAt(doc, 'slam', 1);
  assert.ok(p.at('L_CloakHand').distanceTo(p.at('L_Hand')) < 1e-5, 'the cloak follows the new arm');
  const hasNoCloak = biped(ARM_POINTS).doc;
  assert.deepEqual(rebakeCloak(hasNoCloak, ['slam']), { arms: null, cape: null });
});
