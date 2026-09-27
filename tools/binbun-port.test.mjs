import assert from 'node:assert/strict';
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { curveSamples, parseGodotText } from './binbun-port.mjs';

const ROOT = process.cwd();

async function filesBelow(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesBelow(file));
    else files.push(file);
  }
  return files;
}

test('Godot text parser keeps typed values and multiline dictionaries', () => {
  const parsed = parseGodotText(`
[gd_scene load_steps=2 format=3]
[sub_resource type="Animation" id="Animation_test"]
resource_name = "oneshot"
tracks/0/keys = {
"times": PackedFloat32Array(0, 0.5, 1),
"values": [Color(1, 0.5, 0, 1), true, SubResource("Curve_test")]
}
`);
  assert.equal(parsed.sections.length, 2);
  const animation = parsed.sections[1];
  assert.equal(animation.properties.resource_name, 'oneshot');
  assert.deepEqual(animation.properties['tracks/0/keys'].times, { $type: 'PackedFloat32Array', args: [0, 0.5, 1] });
  assert.equal(animation.properties['tracks/0/keys'].values[0].$type, 'Color');
});

test('curve sampler follows Godot cubic Bezier tangents', () => {
  const samples = curveSamples({ properties: {
    _data: [
      { $type: 'Vector2', args: [0, 0] }, 0, 3, 0, 0,
      { $type: 'Vector2', args: [1, 1] }, 0, 0, 0, 0,
    ],
  } }, 3);
  assert.equal(samples[0], 0);
  assert.ok(samples[1] > 0.75 && samples[1] < 0.9);
  assert.equal(samples[2], 1);
});

test('generated selection is complete and every referenced portable asset exists', async () => {
  const selection = JSON.parse(await readFile(path.join(ROOT, 'art-manifest', 'binbun-effects.json'), 'utf8'));
  const outputRoot = path.join(ROOT, 'public', 'fx', 'binbun');
  const index = JSON.parse(await readFile(path.join(outputRoot, 'index.json'), 'utf8'));
  assert.deepEqual(index.effects.map((effect) => effect.id), selection.effects.map((effect) => effect.id));
  const actual = (await filesBelow(outputRoot)).map((file) => path.relative(ROOT, file).replaceAll('\\', '/')).sort();
  assert.deepEqual(actual, [...index.files, 'public/fx/binbun/index.json'].sort());
  for (const effect of index.effects) {
    const bundleFile = path.join(ROOT, 'public', 'fx', 'binbun', effect.file);
    const bundle = JSON.parse(await readFile(bundleFile, 'utf8'));
    assert.equal(bundle.id, effect.id);
    assert.ok(bundle.documents[bundle.root]);
    for (const asset of Object.values(bundle.assets)) {
      if (asset.output) await stat(path.join(ROOT, 'public', 'fx', 'binbun', asset.output));
    }
    for (const document of Object.values(bundle.documents)) {
      for (const section of document.sections) {
        if (section.bakedTexture) await stat(path.join(ROOT, 'public', 'fx', 'binbun', section.bakedTexture));
      }
    }
  }
});
