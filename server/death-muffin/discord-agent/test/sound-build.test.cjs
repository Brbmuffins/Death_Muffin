// sound-build.mjs: the loudness levelling and the licence row build-sound.sh writes (the sandbox itself is covered by the runner's tests).
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const SCRIPT = path.join(__dirname, '..', 'sound-build.mjs');
const load = () => import(SCRIPT);
const DOC = ['# Audio sources', '', '## Discord agent sounds: `godot/assets/audio/eleven/`', '', 'Intro.', '', '| File | Made | Spec |', '|---|---|---|',
  '| `godot/assets/audio/eleven/old_one.wav` | ElevenLabs Sound Effects, 2026-10-13 | [old_one.json](../audio-manifest/eleven/old_one.json) |', '', 'A note.', '',
  '## Removed', '', '| File | Why |', '|---|---|', '| `x.ogg` | gone |', ''].join('\n');

test('the gain brings a take to -20 LUFS and holds it at the -1.5 dBTP ceiling', async () => {
  const { gainFor } = await load();
  assert.deepStrictEqual(gainFor({ i: -26, tp: -10 }), { gain: 6, limited: false, i: -20, tp: -4 });
  assert.deepStrictEqual(gainFor({ i: -14, tp: -1 }), { gain: -6, limited: false, i: -20, tp: -7 });
  const held = gainFor({ i: -30, tp: -4 });
  assert.strictEqual(held.gain, 2.5); assert.strictEqual(held.limited, true); assert.strictEqual(held.tp, -1.5); assert.strictEqual(held.i, -27.5);
  assert.strictEqual(gainFor({ i: -Infinity, tp: -Infinity }), null, 'silence cannot be measured');
  assert.strictEqual(gainFor({ i: -75, tp: -60 }), null, 'below the -70 LUFS gate');
  assert.strictEqual(gainFor(null), null);
});

test('the loudnorm measurement is read from the JSON block at the end of ffmpeg output', async () => {
  const { parseLoudnorm, gainFor } = await load();
  const out = 'Input #0, mp3...\n[Parsed_loudnorm_0 @ 0x1] \n{\n\t"input_i" : "-23.41",\n\t"input_tp" : "-6.02",\n\t"input_lra" : "1.20"\n}\n';
  assert.deepStrictEqual(parseLoudnorm(out), { i: -23.41, tp: -6.02 });
  assert.strictEqual(gainFor(parseLoudnorm('{\n"input_i" : "-inf",\n"input_tp" : "-inf"\n}')), null, 'a silent take: nothing to level');
  assert.strictEqual(parseLoudnorm('no measurement'), null);
});

test('the row goes after the agent table\'s last row, and a rebuild replaces the sound\'s own row', async () => {
  const { recordRow } = await load();
  const f = 'godot/assets/audio/eleven/new_one.wav';
  const row = `| \`${f}\` | ElevenLabs Sound Effects, take 2, 2026-10-18 | [new_one.json](../audio-manifest/eleven/new_one.json) |`;
  const once = recordRow(DOC, f, row);
  const lines = once.split('\n');
  assert.strictEqual(lines[lines.findIndex((l) => l.includes('old_one.wav')) + 1], row, 'right under the last row of the agent table');
  assert.strictEqual(lines.filter((l) => l.includes('x.ogg')).length, 1, 'the next section is untouched');
  const again = recordRow(once, f, row.replace('take 2', 'take 3'));
  assert.strictEqual(again.split('\n').filter((l) => l.includes('new_one.wav')).length, 1, 'one row per sound');
  assert.match(again, /take 3/);
  assert.throws(() => recordRow('# Audio sources\n', f, row), /no "## Discord agent sounds" section/);
  assert.throws(() => recordRow('## Discord agent sounds\n\nNo table yet.\n', f, row), /has no table/);
});

const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0;

test('a real take: built mono at -20 LUFS, a loud one held at the peak, the row written', { skip: !hasFfmpeg && 'no ffmpeg' }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-sound-build-'));
  try {
    fs.mkdirSync(path.join(dir, 'docs'));
    fs.writeFileSync(path.join(dir, 'docs', 'AUDIO-SOURCES.md'), DOC);
    const take = (id, n, src) => {
      fs.mkdirSync(path.join(dir, 'audio-src', 'eleven', id), { recursive: true });
      execFileSync('ffmpeg', ['-nostdin', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', src, '-ac', '2', '-c:a', 'libmp3lame', '-b:a', '128k', path.join(dir, 'audio-src', 'eleven', id, `v${n}.mp3`)]);
    };
    take('quiet_bell', 2, 'sine=frequency=660:duration=1.5,volume=-28dB');
    const out = execFileSync('node', [SCRIPT, 'quiet_bell', '2', 'sfx'], { cwd: dir, encoding: 'utf8' });
    assert.match(out, /BUILT: godot\/assets\/audio\/eleven\/quiet_bell\.wav/);
    const wav = path.join(dir, 'godot', 'assets', 'audio', 'eleven', 'quiet_bell.wav');
    const probe = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'stream=channels,sample_rate,codec_name', '-of', 'csv=p=0', wav], { encoding: 'utf8' }).trim();
    assert.strictEqual(probe, 'pcm_s16le,44100,1');
    const m = spawnSync('ffmpeg', ['-nostdin', '-hide_banner', '-i', wav, '-af', 'loudnorm=print_format=json', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
    const i = Number(/"input_i" : "(-?[\d.]+)"/.exec(m)[1]);
    assert.ok(Math.abs(i - -20) <= 0.6, `measured ${i} LUFS`);
    const doc = fs.readFileSync(path.join(dir, 'docs', 'AUDIO-SOURCES.md'), 'utf8');
    assert.match(doc, /\| `godot\/assets\/audio\/eleven\/quiet_bell\.wav` \| ElevenLabs Sound Effects, take 2, \d{4}-\d\d-\d\d \| \[quiet_bell\.json\]\(\.\.\/audio-manifest\/eleven\/quiet_bell\.json\) \|/);
    // white noise at full scale has peaks far above its loudness: brought down to the target, never over the ceiling
    take('loud_hiss', 1, 'anoisesrc=color=white:amplitude=1:duration=1.2');
    const loud = execFileSync('node', [SCRIPT, 'loud_hiss', '1', 'sfx'], { cwd: dir, encoding: 'utf8' });
    const peak = Number(/peak (-?[\d.]+) dBTP/.exec(loud)[1]);
    assert.ok(peak <= -1.5 + 0.05, loud);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('a missing licence record stops the build before anything is written', { skip: !hasFfmpeg && 'no ffmpeg' }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-sound-build-'));
  try {
    const r = spawnSync('node', [SCRIPT, 'some_id', '1', 'sfx'], { cwd: dir, encoding: 'utf8' });
    assert.strictEqual(r.status, 1);
    assert.match(r.stderr, /docs\/AUDIO-SOURCES\.md is missing or a symlink/);
    assert.ok(!fs.existsSync(path.join(dir, 'godot')));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
