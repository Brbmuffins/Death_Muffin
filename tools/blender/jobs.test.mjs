// Blender jobs without Blender: the kinds list, job validation, the model rows and the merge back into a shipped model (merge.mjs), on
// made-up models. Blender itself is exercised by running a job (docs/BLENDER-PIPELINE.md "Jobs").
//   node --test tools/blender/jobs.test.mjs      (CI: "Blender jobs")
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Document } from '@gltf-transform/core';
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
