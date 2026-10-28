'use strict';
// 3D model tries (Pixal3D on a team PC, free): the request file's validation, the runner's gates and the whole flow through the fake Discord layer, and the real
// model-run.sh against a fake model-gen.sh. NOTHING here reaches a team PC or ComfyUI: the run script in the flow is a stand-in (test/fake-art/model-run.sh).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), os = require('os'), path = require('path'), crypto = require('crypto');
const { spawnSync } = require('child_process');
const A = require('../runner/lib/art.cjs');
const { IDS, makeWorld, makeDiscord, until } = require('./harness.cjs');
const BOT = `<@${IDS.BOT}>`;
const SRC = path.resolve(__dirname, '..');

// ---------- the request file and its validation ----------
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const PNG = (tag) => Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from(tag)]);
const ids = (n, p = 'hound') => Array.from({ length: n }, (_, i) => `${p}_${String.fromCharCode(97 + i)}`);

test('readRequest(MODEL_FILE): 1 to MAX_MODELS ids, no repeats, a clipped note, and the trigger file is always removed', () => {
  const wt = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-mdl-'));
  try {
    const f = path.join(wt, A.MODEL_FILE);
    const rq = (o) => { fs.writeFileSync(f, typeof o === 'string' ? o : JSON.stringify(o)); const r = A.readRequest(wt, A.MODEL_FILE, A.MAX_MODELS); assert.equal(fs.existsSync(f), false, 'the trigger file is gone'); return r; };
    assert.equal(A.readRequest(wt, A.MODEL_FILE, A.MAX_MODELS), null, 'no file, no request');
    assert.deepEqual(rq({ ids: ids(A.MAX_MODELS) }).ids, ids(A.MAX_MODELS));
    assert.deepEqual(rq({ id: 'bone_hound' }).ids, ['bone_hound']);
    assert.match(rq({ ids: ids(A.MAX_MODELS + 1) }).error, new RegExp(`1 to ${A.MAX_MODELS}`));
    assert.match(rq({ ids: [] }).error, new RegExp(`1 to ${A.MAX_MODELS}`));
    assert.match(rq({ ids: ['bone_hound', 'bone_hound'] }).error, /must not repeat/);
    for (const bad of ['Bone_Hound', 'ab', '../x/y', 'a'.repeat(41), 'bone hound']) assert.match(rq({ ids: [bad] }).error, /each id must match/, bad);
    assert.match(rq({ ids: ['bone_hound'], budget: 5 }).error, /budget/);
    assert.match(rq('{not json').error, /not valid JSON/);
    assert.equal(rq({ ids: ['bone_hound'], note: 'x'.repeat(900) }).note.length, 300);
    assert.equal(rq({ ids: ['bone_hound'], note: 'a\nb' }).note, 'a b');
  } finally { fs.rmSync(wt, { recursive: true, force: true }); }
});

test('validateModels: only a concept the runner made and posted, unchanged, and nothing odd in art-src', () => {
  const wt = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-mdl-'));
  try {
    const put = (id, tag) => { fs.mkdirSync(path.join(wt, 'art-src/concepts'), { recursive: true }); const b = PNG(tag); fs.writeFileSync(path.join(wt, `art-src/concepts/${id}.png`), b); return sha(b); };
    const concepts = { bone_hound: { sha: put('bone_hound', 'a'), at: 1 }, prop_lamp: { sha: put('prop_lamp', 'b'), at: 1 }, icon_reap: { sha: put('icon_reap', 'c'), at: 1, kind: 'ability_icon' } };
    const v = (idList, c = concepts) => A.validateModels({ wt, request: { ids: idList }, concepts: c });
    const ok = v(['bone_hound', 'prop_lamp']); assert.equal(ok.ok, true, ok.errors.join(' | ')); assert.deepEqual(ok.items, [{ id: 'bone_hound' }, { id: 'prop_lamp' }]);
    // an id that already has a model is fine (the tries just make a new one)
    fs.mkdirSync(path.join(wt, 'art-manifest/comfy'), { recursive: true }); fs.writeFileSync(path.join(wt, 'art-manifest/comfy/bone_hound.json'), '{}');
    assert.equal(v(['bone_hound']).ok, true);
    // a picture the agent put there itself is not a runner-made concept
    put('self_made', 'z');
    const own = v(['self_made']); assert.equal(own.ok, false); assert.match(own.errors.join(), /no concept picture for "self_made" was made and posted in this thread: ask for the concept first/);
    const none = v(['never_made']); assert.equal(none.ok, false); assert.match(none.errors.join(), /never_made/);
    assert.match(v(['bone_hound', 'never_made']).errors.join(), /^never_made: no concept picture/, 'with several ids each problem names its id');
    // a concept that changed after people saw it
    fs.writeFileSync(path.join(wt, 'art-src/concepts/prop_lamp.png'), PNG('edited'));
    const ch = v(['prop_lamp']); assert.equal(ch.ok, false); assert.match(ch.errors.join(), /is not the picture people saw \(it changed\).*do not edit art-src\/concepts\//);
    // a picture concept (an icon) is built with build-picture.sh, not turned into a model
    assert.match(v(['icon_reap']).errors.join(), /picture concept/);
    // the picture is a symlink / is gone
    const victim = path.join(wt, 'victim.png'); fs.writeFileSync(victim, PNG('v'));
    fs.rmSync(path.join(wt, 'art-src/concepts/bone_hound.png')); fs.symlinkSync(victim, path.join(wt, 'art-src/concepts/bone_hound.png'));
    assert.equal(v(['bone_hound']).ok, false);
    fs.rmSync(path.join(wt, 'art-src/concepts/bone_hound.png'));
    assert.equal(v(['bone_hound']).ok, false);
    // art-src/comfy/<id> must not hold a symlink (the runner writes the tries there)
    concepts.bone_hound.sha = put('bone_hound', 'a2'); fs.mkdirSync(path.join(wt, 'art-src/comfy/bone_hound'), { recursive: true });
    assert.equal(v(['bone_hound']).ok, true);
    fs.symlinkSync(victim, path.join(wt, 'art-src/comfy/bone_hound/try.glb'));
    assert.match(v(['bone_hound']).errors.join(), /holds a symlink/);
    fs.rmSync(path.join(wt, 'art-src/comfy/bone_hound'), { recursive: true }); fs.rmSync(path.join(wt, 'art-src/comfy'), { recursive: true });
    fs.symlinkSync(os.tmpdir(), path.join(wt, 'art-src/comfy'));
    assert.equal(v(['bone_hound']).ok, false, 'art-src/comfy as a symlink is refused');
    assert.equal(A.validateModels({ wt, request: { error: 'bad file' }, concepts }).ok, false);
  } finally { fs.rmSync(wt, { recursive: true, force: true }); }
});

// ---------- the flow ----------
const calls = (w) => { try { return fs.readFileSync(path.join(w.artDir, 'calls.log'), 'utf8').split('\n').filter(Boolean); } catch { return []; } };
const modelCalls = (w) => calls(w).filter((c) => /^model-run /.test(c));
const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
const audits = (w, event) => fs.readFileSync(path.join(w.cfg.stateDir, 'audit.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((e) => e.event === event);
const ledger = (w) => { try { return JSON.parse(fs.readFileSync(w.ledgerFile, 'utf8')).entries; } catch { return []; } };
const flag = (w, name, on = true) => (on ? fs.writeFileSync(path.join(w.artDir, name), String(on === true ? 1 : on)) : fs.rmSync(path.join(w.artDir, name), { force: true }));
const worldOf = (budgets = { [IDS.HELIX]: 1000 }) => { const w = makeWorld({ godot: true }); fs.writeFileSync(w.budgetFile, JSON.stringify(budgets)); return { w, d: makeDiscord(w.runner) }; };
async function ask(d, userId, text) { await d.say(d.main, userId, `${BOT} ${text}`); return until(() => d.world.threads[d.world.threads.length - 1], d.ad); }
// a thread with concepts already made and posted (the runner pins each picture's hash)
async function conceptThread(d, idList, userId = IDS.HELIX) {
  const thread = await ask(d, userId, `GD-CONCEPT ids=${idList.join(',')}`);
  await until(() => thread.sent.find((s) => /Concept art/.test(s.payload.content || '')), d.ad);
  return { thread };
}
const jobOf = (w) => Object.values(w.runner.jobs())[0];
const idle = (job, d) => until(() => !job.running && job.status === 'idle' && !job.queue.length, d.ad);
const readyCount = (thread) => texts(thread).filter((t) => /3D tries are ready/.test(t)).length;

test('flow: a valid request makes the tries one id at a time, spends nothing, and the agent hears exactly what arrived', async () => {
  const { w, d } = worldOf(); const want = ['bone_hound', 'prop_bone_lamp'];
  const { thread } = await conceptThread(d, want); const job = jobOf(w);
  const conceptsBefore = want.map((id) => fs.readFileSync(path.join(job.worktree, `art-src/concepts/${id}.png`)));
  await d.say(thread, IDS.HELIX, `make them in 3D GD-MODEL ids=${want.join(',')}`);
  await until(() => readyCount(thread) === 1, d.ad); await idle(job, d);
  const said = texts(thread);
  assert.ok(said.some((t) => /Making 3D tries of "bone_hound", "prop_bone_lamp" on a team PC/.test(t) && /a bone hound for the crypt/.test(t)), 'people hear what is being made, with the agent\'s note');
  assert.ok(said.some((t) => new RegExp(`3D tries are ready: "bone_hound" \\(\\d+ tries\\), "prop_bone_lamp" \\(\\d+ tries\\)`).test(t)));
  const mc = modelCalls(w); assert.equal(mc.length, want.length); assert.deepEqual(mc.map((c) => c.split(' ')[1]), want, 'in the order asked, one at a time');
  for (const c of mc) { assert.ok(c.includes(`gen=${path.join(w.cfg.toolsDir, 'model-gen.sh')}`), 'the trusted installed model-gen.sh, never one from the worktree'); assert.ok(c.includes(`workflow=${path.join(w.cfg.toolsDir, 'image-to-model.json')}`)); }
  assert.equal(fs.existsSync(path.join(job.worktree, A.MODEL_FILE)), false, 'the trigger file is cleaned');
  want.forEach((id, i) => assert.ok(fs.readFileSync(path.join(job.worktree, `art-src/concepts/${id}.png`)).equals(conceptsBefore[i]), 'the picture people saw is what the tries came from'));
  assert.equal(job.modelCount, want.length); assert.equal(job.status, 'idle'); assert.equal(job.running, false);
  // the agent's next turn: the queued runner message names every try file and the run details, and says what to do next
  const prompt = await until(() => { try { return fs.readFileSync(path.join(job.worktree, '.fake-model-prompt'), 'utf8'); } catch { return null; } }, d.ad);
  for (const id of want) {
    const tries = JSON.parse(fs.readFileSync(path.join(job.worktree, `art-src/comfy/${id}/tries.json`), 'utf8')); assert.ok(tries.length > 0);
    for (const t of tries) assert.ok(prompt.includes(`art-src/comfy/${id}/${t.file}`), `${t.file} named for ${id}`);
    assert.ok(prompt.includes(`(run details: art-src/comfy/${id}/tries.json)`));
  }
  assert.match(prompt, /The runner made 3D tries on a team PC \(Pixal3D, free\)/);
  assert.ok(prompt.includes(`${w.cfg.toolsDir}/render-model.sh`) && prompt.includes(`${w.cfg.toolsDir}/make-model.sh`) && prompt.includes(`${w.cfg.toolsDir}/build-art.sh`));
  assert.match(prompt, /art-src\/ is git-ignored: do not commit it/);
  assert.ok(texts(thread).some((t) => /Looked at the tries\./.test(t)), 'the agent answered the runner message');
  // free: no credits, no Tripo; audited
  assert.deepEqual(ledger(w), []); assert.equal(calls(w).filter((c) => /^tripo/.test(c)).length, 0);
  assert.deepEqual(audits(w, 'model-start').map((e) => e.ids), [want]);
  assert.equal(audits(w, 'model-result').length, 1); assert.deepEqual(audits(w, 'model-result')[0].failed, []);
  assert.equal(audits(w, 'model-refused').length + audits(w, 'model-invalid').length, 0);
});

test('flow: an id with no concept posted in this thread is refused (the agent is told; nothing runs, whatever the file says)', async () => {
  const { w, d } = worldOf();
  // the agent that fixes nothing: told once (a second turn), then there is nothing to do
  const t1 = await ask(d, IDS.HELIX, 'GD-MODEL ids=never_made'); const j1 = jobOf(w);
  await until(() => audits(w, 'model-invalid').length === 1 && j1.turns === 2, d.ad); await idle(j1, d);
  assert.equal(modelCalls(w).length, 0);
  assert.match(audits(w, 'model-invalid')[0].errors, /no concept picture for "never_made"/);
  assert.ok(!texts(t1).some((x) => /still has problems/.test(x)), 'an agent that stops asking is not nagged about it');
  // the agent that insists: three tries, then people are told why
  const t2 = await ask(d, IDS.HELIX, 'GD-MODEL-STUBBORN ids=never_made');
  await until(() => texts(t2).some((x) => /The 3D model request still has problems, so nothing was generated/.test(x)), d.ad);
  assert.match(texts(t2).join('\n'), /no concept picture for "never_made" was made and posted in this thread/);
  assert.equal(modelCalls(w).length, 0); assert.equal(audits(w, 'model-start').length, 0);
  assert.equal(audits(w, 'model-invalid').length, 1 + 3, 'the stubborn request was read three times');
  assert.equal(fs.existsSync(path.join(Object.values(w.runner.jobs()).at(-1).worktree, A.MODEL_FILE)), false);
});

test('flow: a concept that changed after it was shown is refused, a picture put there by the agent is not a concept', async () => {
  const { w, d } = worldOf();
  const { thread } = await conceptThread(d, ['bone_hound']); const job = jobOf(w);
  fs.writeFileSync(path.join(job.worktree, 'art-src/concepts/bone_hound.png'), PNG('swapped'));
  await d.say(thread, IDS.HELIX, 'GD-MODEL-STUBBORN ids=bone_hound');
  await until(() => texts(thread).some((x) => /The 3D model request still has problems/.test(x)), d.ad);
  assert.match(texts(thread).join('\n'), /is not the picture people saw \(it changed\): do not edit art-src\/concepts\//);
  assert.equal(modelCalls(w).length, 0);
  fs.mkdirSync(path.join(job.worktree, 'art-src/concepts'), { recursive: true }); fs.writeFileSync(path.join(job.worktree, 'art-src/concepts/own_picture.png'), PNG('mine'));
  await d.say(thread, IDS.HELIX, 'GD-MODEL-STUBBORN ids=own_picture');
  await until(() => texts(thread).filter((x) => /The 3D model request still has problems/.test(x)).length === 2, d.ad);
  assert.match(texts(thread).join('\n'), /no concept picture for "own_picture" was made and posted in this thread/);
  assert.equal(modelCalls(w).length, 0);
});

test('flow: more than MAX_MODELS ids is refused whole; the trigger file is cleaned', async () => {
  const { w, d } = worldOf(); const many = ids(A.MAX_MODELS + 1);
  const { thread } = await conceptThread(d, many.slice(0, 3)); const job = jobOf(w);
  await d.say(thread, IDS.HELIX, `GD-MODEL-STUBBORN ids=${many.join(',')}`);
  await until(() => texts(thread).some((x) => /The 3D model request still has problems/.test(x)), d.ad);
  assert.match(texts(thread).join('\n'), new RegExp(`ids must be a list of 1 to ${A.MAX_MODELS} ids`));
  assert.equal(modelCalls(w).length, 0); assert.equal(job.modelCount || 0, 0);
  assert.equal(fs.existsSync(path.join(job.worktree, A.MODEL_FILE)), false);
});

test('flow: the budget gate (a model budget or an owner), nothing runs for a refusal', async () => {
  const { w, d } = worldOf({ [IDS.HELIX]: 1000 });
  const { thread } = await conceptThread(d, ['bone_hound']); const job = jobOf(w);
  await d.say(thread, IDS.LIMITED, 'GD-MODEL ids=bone_hound');
  await until(() => texts(thread).some((x) => /Limited has no model-generation budget, so I will not make 3D tries/.test(x)), d.ad); await idle(job, d);
  assert.equal(modelCalls(w).length, 0); assert.equal(job.modelCount || 0, 0); assert.equal(job.status, 'idle');
  assert.deepEqual(audits(w, 'model-refused').map((e) => [e.userId, e.why]), [[IDS.LIMITED, 'no budget']]);
  assert.equal(fs.existsSync(path.join(job.worktree, A.MODEL_FILE)), false);
  // the owner needs no budget of their own
  await d.say(thread, IDS.OWNER, 'GD-MODEL ids=bone_hound');
  await until(() => readyCount(thread) === 1, d.ad); await idle(job, d);
  assert.equal(modelCalls(w).length, 1); assert.equal(audits(w, 'model-refused').length, 1);
});

test('flow: the per-round cap counts models made, refuses what would pass it, and says the cap', async () => {
  const { w, d } = worldOf(); const pool = ids(A.MAX_CONCEPTS, 'cap');
  const { thread } = await conceptThread(d, pool); const job = jobOf(w);
  let cap = null, made = 0;
  for (const id of pool) {
    const before = readyCount(thread), refusals = audits(w, 'model-refused').length;
    await d.say(thread, IDS.HELIX, `GD-MODEL ids=${id}`);
    await until(() => readyCount(thread) > before || audits(w, 'model-refused').length > refusals, d.ad); await idle(job, d);
    if (audits(w, 'model-refused').length > refusals) { cap = Number(/pass (\d+) 3D models in this round \((\d+) made so far\)/.exec(texts(thread).join('\n'))[1]); break; }
    made++;
  }
  assert.ok(cap, `the round has a cap below ${pool.length} models (a refusal came)`);
  assert.equal(made, cap, 'every model up to the cap ran, the next one was refused'); assert.equal(job.modelCount, cap); assert.equal(modelCalls(w).length, cap);
  assert.match(texts(thread).join('\n'), new RegExp(`\\(${cap} made so far\\)\\. Pick from the tries already posted`));
  assert.deepEqual(audits(w, 'model-refused').map((e) => e.why), ['round cap']);
  // a request that would pass the cap together is refused whole, not cut
  await d.say(thread, IDS.HELIX, `GD-MODEL ids=${pool[0]},${pool[1]}`);
  await until(() => audits(w, 'model-refused').length === 2, d.ad); await idle(job, d);
  assert.equal(modelCalls(w).length, cap);
});

test('flow: a run that makes nothing says so, spends nothing and does not send the agent after tries that are not there', async () => {
  const { w, d } = worldOf();
  const { thread } = await conceptThread(d, ['bone_hound']); const job = jobOf(w);
  flag(w, 'model-fail');
  await d.say(thread, IDS.HELIX, 'GD-MODEL ids=bone_hound');
  await until(() => texts(thread).some((x) => /No 3D try came back: "bone_hound" \(the team PC made no model\)/.test(x)), d.ad); await idle(job, d);
  assert.match(texts(thread).join('\n'), /no team PC runs model jobs/, 'the tail of the run is shown');
  assert.equal(readyCount(thread), 0); assert.ok(!fs.existsSync(path.join(job.worktree, '.fake-model-prompt')));
  assert.deepEqual(audits(w, 'model-result')[0].failed, ['"bone_hound" (the team PC made no model)']);
  flag(w, 'model-fail', false); flag(w, 'model-tries', '1');
  await d.say(thread, IDS.HELIX, 'GD-MODEL ids=bone_hound');
  await until(() => texts(thread).some((x) => /3D tries are ready: "bone_hound" \(1 try\)/.test(x)), d.ad); await idle(job, d);
});

test('flow: !cancel between ids stops before the next one', async () => {
  const { w, d } = worldOf(); const two = ['bone_hound', 'bone_golem'];
  const { thread } = await conceptThread(d, two); const job = jobOf(w);
  flag(w, 'model-hold');   // the stand-in waits while this file exists, like a team PC still working
  try {
    await d.say(thread, IDS.HELIX, `GD-MODEL ids=${two.join(',')}`);
    await until(() => modelCalls(w).length === 1 && job.proc, d.ad);
    assert.equal(job.running, true, 'the job is working for the whole run, so !cancel reaches it');
    const r = await d.say(thread, IDS.HELIX, '!cancel'); assert.match(r.replies[0].content, /^Cancelling the current step/);
    await until(() => texts(thread).some((x) => /^Stopped\. \d+ model\(s\) had tries made\./.test(x)), d.ad); await idle(job, d);
    assert.equal(modelCalls(w).length, 1, 'the second id never started'); assert.equal(readyCount(thread), 0);
    assert.equal(job.cancelRequested, false); assert.equal(job.running, false);
  } finally { flag(w, 'model-hold', false); }
});

test('flow: !discard while the tries are being made stops before the next id and then discards the thread', async () => {
  const { w, d } = worldOf(); const two = ['bone_hound', 'bone_golem'];
  const { thread } = await conceptThread(d, two); const job = jobOf(w);
  flag(w, 'model-hold');
  try {
    await d.say(thread, IDS.HELIX, `GD-MODEL ids=${two.join(',')}`);
    await until(() => modelCalls(w).length === 1 && job.proc, d.ad);
    await d.say(thread, IDS.HELIX, '!discard');
    await until(() => job.status === 'discarded', d.ad);
    assert.equal(modelCalls(w).length, 1, 'the second id never started'); assert.equal(readyCount(thread), 0); assert.equal(job.running, false);
    assert.equal(job.queue.length, 0, 'nothing is queued for the agent after a discard');
  } finally { flag(w, 'model-hold', false); }
});

// ---------- model-run.sh itself, against a fake model-gen.sh ----------
const RUN = path.join(SRC, 'model-run.sh');
// The fake gen takes the real one's arguments (--runs F --wait N OUT/ PIC), writes the first FAKE_ARRIVE (default all) runs' <label>.glb and a job log, and prints
// the lines the real one prints. FAKE_MODE: "ok" | "timeout" | "nothing"; every call is logged with its arguments next to it.
const FAKE_GEN = `#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd); echo "$*" >> "$d/gen.calls"
runs=; wait=; while [ $# -gt 2 ]; do case "$1" in --runs) runs=$2; shift 2;; --wait) wait=$2; shift 2;; *) break;; esac; done
out=$1; pic=$2; echo "$wait" > "$d/gen.wait"; cp "$runs" "$d/gen.runs.json"; [ -f "$pic" ] || { echo "model gen: no picture $pic" >&2; exit 2; }
case "\${FAKE_MODE:-ok}" in
  timeout) echo "model gen: job fake1234 queued, 3 run(s)"; echo "model gen: the team PC did not finish in time (job fake1234 cancelled)" >&2; exit 1;;
  nothing) echo "model gen: job fake1234 queued"; echo "model gen: the job finished without models" >&2; exit 1;;
esac
python3 - "$runs" "$out" "\${FAKE_ARRIVE:-99}" <<'PY'
import json, os, sys
runs, out, n = json.load(open(sys.argv[1])), sys.argv[2], int(sys.argv[3])
log = os.path.join(out, "fake1234.log"); open(log, "w").write("12:00:00 job fake1234, 3D models, %d run(s)\\n12:00:01 workflow: ComfyUI 9.8.7, template fake_template (templates 1.2.3); made by x.\\n12:00:02 team app 4.5.6 started\\n" % len(runs))
print("model gen: job fake1234 queued, %d run(s): %s" % (len(runs), ", ".join(r["label"] for r in runs)))
print("model gen: " + log)
for r in runs[:n]:
    open(os.path.join(out, r["label"] + ".glb"), "w").write("glb " + r["label"]); print("model gen: " + os.path.join(out, r["label"] + ".glb"))
PY
exit 0
`;
function shellWorld(id = 'bone_hound') {
  const T = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-mrun-')); const wt = path.join(T, 'wt'); fs.mkdirSync(path.join(wt, 'art-src/concepts'), { recursive: true });
  fs.writeFileSync(path.join(wt, `art-src/concepts/${id}.png`), PNG('pic')); fs.writeFileSync(path.join(T, 'gen.sh'), FAKE_GEN, { mode: 0o755 });
  const run = (idArg, env = {}) => { const r = spawnSync('bash', [RUN, idArg], { cwd: wt, encoding: 'utf8', env: { ...process.env, DM_MODEL_GEN: path.join(T, 'gen.sh'), ...env } }); return { ...r, out: r.stdout + r.stderr, result: (/^RESULT: (\S+)$/m.exec(r.stdout) || [])[1] }; };
  return { T, wt, run, tries: (i = id) => JSON.parse(fs.readFileSync(path.join(wt, `art-src/comfy/${i}/tries.json`), 'utf8')) };
}

test('model-run.sh: three tries (seeds 0 to 2, Pixal3D settings), a tries.json that is the record "run" block per try, RESULT: ok', () => {
  const s = shellWorld();
  try {
    const r = s.run('bone_hound'); assert.equal(r.status, 0, r.out); assert.equal(r.result, 'ok');
    const sent = JSON.parse(fs.readFileSync(path.join(s.T, 'gen.runs.json'), 'utf8'));
    assert.equal(sent.length, 3); assert.deepEqual(sent.map((x) => x.seed), [0, 1, 2]);
    for (const x of sent) { assert.equal(x.model, 'pixal3d'); assert.equal(x.image, 'bone_hound.png'); assert.match(x.label, /^[a-z0-9][a-z0-9-]{0,23}$/, 'a team-app label'); assert.ok(x.faces > 0 && x.texture > 0 && x.settings.detail > 0 && x.settings.grid > 0); }
    assert.equal(new Set(sent.map((x) => x.label)).size, 3);
    assert.match(fs.readFileSync(path.join(s.T, 'gen.calls'), 'utf8'), /--wait \d+ art-src\/comfy\/bone_hound\/ art-src\/concepts\/bone_hound\.png/);
    assert.ok(Number(fs.readFileSync(path.join(s.T, 'gen.wait'), 'utf8')) > 0, 'model-gen.sh cancels its own team job at its own deadline');
    const t = s.tries(); assert.equal(t.length, 3);
    t.forEach((x, i) => {
      assert.deepEqual(Object.keys(x).sort(), ['comfyui', 'date', 'faces', 'file', 'job', 'label', 'model', 'pc', 'seed', 'settings', 'teamApp', 'template', 'texture'].sort());
      assert.equal(x.seed, i); assert.equal(x.label, sent[i].label); assert.equal(x.file, `${x.label}.glb`); assert.deepEqual(x.settings, sent[i].settings);
      assert.equal(x.comfyui, '9.8.7'); assert.equal(x.template, 'fake_template (templates 1.2.3)'); assert.equal(x.teamApp, '4.5.6'); assert.equal(x.pc, null); assert.equal(x.job, 'fake1234');
      assert.match(x.date, /^\d{4}-\d{2}-\d{2}$/); assert.ok(fs.existsSync(path.join(s.wt, 'art-src/comfy/bone_hound', x.file)));
    });
  } finally { fs.rmSync(s.T, { recursive: true, force: true }); }
});

test('model-run.sh: tries.json lists only the tries that arrived, a new request starts from nothing, long ids get a team-app label', () => {
  const s = shellWorld('prop_a_long_name_for_a_bone_candelabra');   // 38 chars: the label must still fit the team app's 24
  try {
    let r = s.run('prop_a_long_name_for_a_bone_candelabra', { FAKE_ARRIVE: '2' }); assert.equal(r.status, 0, r.out); assert.equal(r.result, 'ok');
    const first = s.tries('prop_a_long_name_for_a_bone_candelabra'); assert.equal(first.length, 2); assert.deepEqual(first.map((x) => x.seed), [0, 1]);
    for (const x of first) assert.match(x.label, /^[a-z0-9][a-z0-9-]{0,23}$/);
    const out = path.join(s.wt, 'art-src/comfy/prop_a_long_name_for_a_bone_candelabra');
    r = s.run('prop_a_long_name_for_a_bone_candelabra', { FAKE_ARRIVE: '1' }); assert.equal(r.result, 'ok');
    assert.equal(s.tries('prop_a_long_name_for_a_bone_candelabra').length, 1);
    assert.deepEqual(fs.readdirSync(out).filter((f) => f.endsWith('.glb')), [first[0].file], 'the earlier tries of these labels are gone, not left to be mistaken for new ones');
  } finally { fs.rmSync(s.T, { recursive: true, force: true }); }
});

test('model-run.sh: RESULT words and exit codes for every way it ends (and a failure leaves no tries.json behind)', () => {
  const s = shellWorld();
  try {
    assert.equal(s.run('bone_hound').result, 'ok');
    let r = s.run('bone_hound', { FAKE_MODE: 'timeout' }); assert.equal(r.result, 'timeout'); assert.equal(r.status, 3); assert.equal(fs.existsSync(path.join(s.wt, 'art-src/comfy/bone_hound/tries.json')), false, 'the earlier request\'s tries.json is not left');
    r = s.run('bone_hound', { FAKE_MODE: 'nothing' }); assert.equal(r.result, 'failed'); assert.equal(r.status, 5);
    r = s.run('bone_hound', { FAKE_ARRIVE: '0' }); assert.equal(r.result, 'failed', 'a run that exits 0 but made no model is a failure');
    for (const bad of ['Bone_Hound', '../etc', 'ab', '']) { r = s.run(bad); assert.equal(r.result, 'bad-id', bad); assert.equal(r.status, 2); }
    r = s.run('no_such_picture'); assert.equal(r.result, 'no-concept'); assert.equal(r.status, 2);
    fs.symlinkSync(path.join(s.T, 'gen.sh'), path.join(s.wt, 'art-src/concepts/linked_one.png'));
    assert.equal(s.run('linked_one').result, 'no-concept', 'a symlinked picture is not used');
    r = s.run('bone_hound', { DM_MODEL_GEN: path.join(s.T, 'missing.sh') }); assert.equal(r.result, 'no-tools'); assert.equal(r.status, 2);
    r = s.run('bone_hound', { DM_MODEL_GEN: '' }); assert.equal(r.result, 'no-tools');
    assert.equal(fs.existsSync(path.join(s.wt, 'art-src/comfy/no_such_picture')), false, 'a refused id leaves nothing in art-src/comfy');
  } finally { fs.rmSync(s.T, { recursive: true, force: true }); }
});

test('model-run.sh with the real model-gen.sh: no backend means a failure with the reason, not a crash, and no secret in the output', () => {
  const s = shellWorld(); const secret = path.join(s.T, 'secret'); fs.writeFileSync(secret, 'TESTSECRET-never-printed\n', { mode: 0o600 });
  try {
    const r = s.run('bone_hound', { DM_MODEL_GEN: path.join(SRC, '..', 'model-gen.sh'), DM_TEAM_API: 'http://127.0.0.1:1', DM_TEAM_SECRET_FILE: secret, DM_MODEL_WAIT_MIN: '1' });
    assert.equal(r.result, 'failed', r.out); assert.equal(r.status, 5);
    assert.match(r.out, /model gen:/); assert.ok(!r.out.includes('TESTSECRET-never-printed'));
    assert.equal(fs.existsSync(path.join(s.wt, 'art-src/comfy/bone_hound/tries.json')), false);
  } finally { fs.rmSync(s.T, { recursive: true, force: true }); }
});
