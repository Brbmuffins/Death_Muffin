// The records of models made from a ComfyUI run (art-manifest/comfy/<id>.json) and the steps make.mjs does on them, without Blender: every
// record checks out, every step kind has its script, and a record that breaks a rule is refused (made from a recorded one). Blender itself is
// exercised by building a model (ASSET_PIPELINE.md "Image to model").
//   node --test tools/blender/make.test.mjs      (CI: "Blender jobs")
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { KINDS, RIG_SCRIPT, validateRecord } from './make.mjs';

const DIR = new URL('../../art-manifest/comfy/', import.meta.url);
const COMFY = new URL('./comfy/', import.meta.url);
const records = readdirSync(DIR).filter((f) => f.endsWith('.json')).map((f) => [f.slice(0, -5), JSON.parse(readFileSync(new URL(f, DIR), 'utf8'))]);
const TYPES = ['int', 'number', 'bool', 'enum', 'vec', 'boxes', 'map'];
const copy = (x) => JSON.parse(JSON.stringify(x));

test('every recorded model checks out', () => {
  assert.ok(records.length > 0, 'no records in art-manifest/comfy');
  for (const [id, rec] of records) assert.deepEqual(validateRecord(rec, id), [], `art-manifest/comfy/${id}.json`);
});

test('every step kind has its script and known parameter types', () => {
  for (const [name, kind] of Object.entries(KINDS)) {
    const scripts = name === 'rig' ? KINDS.rig.params.body.values.map((b) => RIG_SCRIPT[b]) : [kind.script];
    for (const s of scripts) assert.ok(s && existsSync(join(COMFY.pathname, s)), `${name}: no script ${s}`);
    for (const [p, spec] of Object.entries(kind.params)) {
      assert.ok(TYPES.includes(spec.type), `${name}.${p}: unknown type ${spec.type}`);
      if (spec.type === 'map') for (const [f, fs] of Object.entries(spec.fields)) assert.ok(TYPES.includes(fs.type), `${name}.${p}.${f}: unknown type ${fs.type}`);
    }
  }
});

test('a record that breaks a rule is refused', () => {
  const [id, base] = records.find(([, r]) => r.frame && r.steps.some((s) => s.kind === 'place')) ?? records[0];
  const bad = (change, why) => {
    const rec = copy(base);
    change(rec);
    assert.ok(validateRecord(rec, id).length > 0, why);
  };
  bad((r) => { r.extra = 1; }, 'an unknown field');
  bad((r) => { r.id = `${id}_x`; }, 'an id that is not the file name');
  bad((r) => { r.game = r.run.file; }, 'the game file over the run');
  bad((r) => { r.steps = r.steps.filter((s) => s.kind !== 'finish'); }, 'no finish');
  bad((r) => { r.steps.push(copy(r.steps.find((s) => s.kind === 'finish'))); }, 'two finishes');
  bad((r) => { r.steps.unshift({ kind: 'rig', body: 'quad' }); }, 'a rig before the last step');
  bad((r) => { delete r.frame; }, 'a place without a frame');
  bad((r) => { r.steps.find((s) => s.kind === 'finish').triangles = KINDS.finish.params.triangles.max + 1; }, 'triangles over the kind\'s range');
  bad((r) => { r.steps.find((s) => s.kind === 'finish').texture = 333; }, 'a texture size the kind does not list');
  bad((r) => { r.steps[0].kind = 'paint'; }, 'an unknown kind');
});
