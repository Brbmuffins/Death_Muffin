// tools/assets/check-models.mjs: reading a GLB, sorting models into kinds, and the rules (npm run test:server).
import test from 'node:test';
import assert from 'node:assert';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { BUILDINGS, HERO_CLIPS, RULES, check, kindOf, readGlb, staffClips } from './check-models.mjs';

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'check-models.mjs');
const BIPED = ['Hips', 'Spine', 'Head', 'L_Arm', 'R_Arm'];

// A GLB with only its JSON chunk: enough for the checker, which reads counts, never vertex data.
function glb({ tris = 100, materials = 1, joints = [], clips = [], unindexed = 0 }) {
  const json = {
    asset: { version: '2.0' },
    accessors: [{ count: tris * 3 }, { count: unindexed * 3 }],
    meshes: [{ primitives: [{ indices: 0, attributes: { POSITION: 1 } }, ...(unindexed ? [{ attributes: { POSITION: 1 } }] : [])] }],
    materials: Array.from({ length: materials }, (_, i) => ({ name: `m${i}` })),
    nodes: joints.map((name) => ({ name })),
    skins: joints.length ? [{ joints: joints.map((_, i) => i) }] : [],
    animations: clips.map((name) => ({ name })),
  };
  let j = Buffer.from(JSON.stringify(json));
  j = Buffer.concat([j, Buffer.alloc((4 - (j.length % 4)) % 4, 0x20)]);
  const h = Buffer.alloc(20);
  h.write('glTF', 0, 'latin1');
  h.writeUInt32LE(2, 4);
  h.writeUInt32LE(20 + j.length, 8);
  h.writeUInt32LE(j.length, 12);
  h.writeUInt32LE(0x4e4f534a, 16);
  return Buffer.concat([h, j]);
}

test('a GLB is read for triangles, materials, skeleton and clips', () => {
  const m = readGlb(glb({ tris: 1200, materials: 2, joints: BIPED, clips: ['idle', 'run'], unindexed: 10 }));
  assert.deepStrictEqual(m, { tris: 1210, materials: 2, joints: BIPED, clips: ['idle', 'run'] });
  assert.throws(() => readGlb(Buffer.from('not a model at all')), /not a binary glTF/);
});

test('models sort into heroes, crowd creatures, characters, gear and props', () => {
  const crowd = new Set(['bone_rat']);
  assert.strictEqual(kindOf('client/assets/slice/models/hero_mourner/character.glb', crowd).kind, 'hero');
  assert.strictEqual(kindOf('client/assets/slice/models/bone_rat/character.glb', crowd).kind, 'crowd');
  assert.strictEqual(kindOf('client/assets/slice/models/prelate/character.glb', crowd).kind, 'character');
  assert.strictEqual(kindOf('client/assets/slice/models/props/necro_wpn_bone_staff.glb', crowd).kind, 'gear');
  assert.strictEqual(kindOf('client/assets/slice/models/props/necro_helm_cowl.glb', crowd).kind, 'gear');
  assert.strictEqual(kindOf('client/assets/slice/models/props/gear_soul_lantern.glb', crowd).kind, 'gear');
  assert.strictEqual(kindOf('client/assets/slice/models/props/shroud_moth.glb', crowd).kind, 'prop');
  for (const b of BUILDINGS) assert.strictEqual(kindOf(`client/assets/slice/models/props/${b}.glb`, crowd).kind, 'building');
});

test('a building may be heavier than a prop', () => {
  const big = readGlb(glb({ tris: RULES.prop.cap + 1 }));
  assert.ok(RULES.building.cap > RULES.prop.cap);
  assert.deepStrictEqual(check('x.glb', big, 'building', BIPED).errors, []);
  assert.match(check('x.glb', big, 'prop', BIPED).errors[0], /over the prop cap/);
});

test('the rules: caps and materials fail, a target is a warning, gear has no skeleton', () => {
  const gear = (o) => check('x.glb', readGlb(glb(o)), 'gear', BIPED);
  assert.deepStrictEqual(gear({ tris: 3400 }), { errors: [], warnings: [] });
  assert.match(gear({ tris: 3800 }).warnings[0], /over the gear target of 3500/);
  assert.match(gear({ tris: 4100 }).errors[0], /over the gear cap of 4000/);
  assert.match(gear({ tris: 3000, materials: 2 }).errors[0], /2 materials/);
  assert.match(gear({ tris: 3000, joints: ['Bone'] }).errors[0], /has a skeleton/);
  assert.deepStrictEqual(check('x.glb', readGlb(glb({ tris: 9000 })), 'crowd', BIPED), { errors: [], warnings: [] }, 'crowd creatures are the baker\'s');
});

test('a hero body needs the shared skeleton and its combat clips', () => {
  const hero = (o) => check('x.glb', readGlb(glb({ tris: 11000, joints: BIPED, clips: [...HERO_CLIPS, 'death2', 'dig', 'hurt2'], ...o })), 'hero', BIPED);
  assert.deepStrictEqual(hero({}), { errors: [], warnings: [] });
  assert.match(hero({ joints: BIPED.slice(0, 4) }).errors[0], /not the shared biped/);
  // a cloak's bones (tools/blender/cloak.mjs) are the hero's own, on the reference or not
  assert.deepStrictEqual(hero({ joints: [...BIPED, 'L_CloakUpperarm', 'R_CloakHand', 'Cape01', 'Cape02'] }).errors, []);
  assert.deepStrictEqual(check('x.glb', readGlb(glb({ tris: 11000, joints: BIPED, clips: [...HERO_CLIPS, 'death2', 'dig', 'hurt2'] })), 'hero', [...BIPED, 'Cape01']).errors, []);
  assert.match(hero({ joints: [...BIPED.slice(0, 4), 'L_CloakUpperarm'] }).errors[0], /not the shared biped/);
  assert.match(hero({ clips: HERO_CLIPS.filter((c) => c !== 'slam' && c !== 'summon') }).errors[0], /missing the clips slam, summon/);
  const noExtras = hero({ clips: HERO_CLIPS });
  assert.deepStrictEqual(noExtras.errors, []);
  assert.match(noExtras.warnings[0], /missing the extra clips death2, dig, hurt2/);
  assert.match(hero({ tris: 21000 }).errors[0], /over the hero cap of 20000/);
});

test('a hero the staff recipe names keeps its re-baked clips', () => {
  const recipe = { heroes: ['hero_mourner'], clips: { run: {}, flick: {} } };
  assert.deepStrictEqual(staffClips('hero_mourner', recipe), ['run_staff', 'flick_staff']);
  assert.deepStrictEqual(staffClips('hero_leg_plague_choir', recipe), [], 'a body the recipe does not name needs none');
  const clips = [...HERO_CLIPS, 'death2', 'dig', 'hurt2'];
  const hero = (extra) => check('x.glb', readGlb(glb({ tris: 11000, joints: BIPED, clips: [...clips, ...extra] })), 'hero', BIPED, staffClips('hero_mourner', recipe));
  assert.deepStrictEqual(hero(['run_staff', 'flick_staff']).errors, []);
  assert.match(hero(['run_staff']).errors[0], /missing the staff clips flick_staff/);
});

test('the game holds a staff the way its staff clips were baked for', () => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
  const recipe = JSON.parse(readFileSync(path.join(root, 'tools/blender/recipes/staff.json'), 'utf8'));
  const props = readFileSync(path.join(root, 'client/game/dm_gear_props.gd'), 'utf8');
  const lean = (kind) => Number((props.match(new RegExp(`"${kind}": \\{"lean": (-?[\\d.]+)`)) || [])[1]);
  assert.strictEqual(lean('staff_fist'), recipe.lean, 'HOLDS.staff_fist is the recipe lean (the grip the clips are re-baked for)');
  assert.strictEqual(lean('staff'), recipe.gameLean, 'HOLDS.staff is the recipe gameLean (the grip the original clips are read with)');
});

test('the command fails on a broken model and passes a good one', () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'dm-check-models-'));
  try {
    mkdirSync(path.join(dir, 'props'));
    const bad = path.join(dir, 'props', 'necro_wpn_test.glb');
    const good = path.join(dir, 'props', 'necro_helm_test.glb');
    writeFileSync(bad, glb({ tris: 5000, materials: 2 }));
    writeFileSync(good, glb({ tris: 3000 }));
    const r = spawnSync('node', [SCRIPT, bad, good], { encoding: 'utf8' });
    assert.strictEqual(r.status, 1, r.stdout);
    assert.match(r.stdout, /MODEL FAIL .*necro_wpn_test\.glb: 5000 triangles, over the gear cap of 4000/);
    assert.match(r.stdout, /MODEL FAIL .*necro_wpn_test\.glb: 2 materials/);
    assert.match(r.stdout, /models: 2 checked, 1 failing, 0 over target/);
    assert.strictEqual(spawnSync('node', [SCRIPT, good], { encoding: 'utf8' }).status, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
