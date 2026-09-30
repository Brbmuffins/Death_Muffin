/**
 * retarget-clips.mjs — extra retarget jobs onto an EXISTING rig task (no re-rig), with a hard budget.
 *
 *   node tools/ai/retarget-clips.mjs <hero> <preset> [preset…] [--accept] [--yes]
 *
 * Candidates download to art-src/necro-anim/<hero>/cand_<preset>.glb for measuring
 * (tools/measure-clips.mjs). With --accept the file lands at art-src/tripo/<hero>/anim_<preset>.glb,
 * where tools/build-characters.mjs picks it up. Every job is recorded in art-manifest/necro-anim-jobs.json
 * (task id, preset, credits) and the total is capped at BUDGET credits. Nothing is spent without --yes.
 */
import { copyFileSync, createWriteStream, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { ART_SRC, ensureDir, loadKey, MANIFEST_DIR, readJson, redact, sha256, sleep, writeJson } from './common.mjs';

const BASE = 'https://openapi.tripo3d.ai/v3';
const BUDGET = 260;
const COST = 10;
const JOBS = join(MANIFEST_DIR, 'necro-anim-jobs.json');
const key = loadKey('TRIPO_API_KEY');

async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: `Bearer ${key}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json.code !== 0) throw new Error(`${method} ${path} -> ${res.status}: ${redact(json.message ?? '')}`);
  return json.data;
}

const args = process.argv.slice(2);
const flags = args.filter((a) => a.startsWith('--'));
const [hero, ...presets] = args.filter((a) => !a.startsWith('--'));
const accept = flags.includes('--accept');
const yes = flags.includes('--yes');
const state = readJson(join(ART_SRC, 'tripo', hero, 'state.json'));
if (!state?.steps?.rig?.taskId) throw new Error(`${hero}: no rig task in state.json`);
const log = readJson(JOBS, { budget: BUDGET, jobs: [] });
const spent = log.jobs.reduce((n, j) => n + (j.credits ?? COST), 0);
const todo = presets.filter((p) => !log.jobs.some((j) => j.hero === hero && j.preset === p && j.status === 'success'));
console.log(`${hero}: rig ${state.steps.rig.taskId}; spent so far ${spent}/${BUDGET}; ${todo.length} new job(s) = ${todo.length * COST}`);
if (spent + todo.length * COST > BUDGET) throw new Error('over budget, refusing');
if (!yes) { console.log('dry run (add --yes)'); process.exit(0); }

for (const preset of todo) {
  const body = { input: state.steps.rig.taskId, out_format: 'glb', bake_animation: true, export_with_geometry: true, animate_in_place: true, animation: `preset:biped:${preset}` };
  const { task_id } = await api('POST', '/animations/retarget', body);
  const job = { hero, preset, taskId: task_id, rigTaskId: state.steps.rig.taskId, status: 'created', createdAt: new Date().toISOString() };
  log.jobs.push(job);
  writeJson(JOBS, log);
  let t;
  for (;;) {
    t = await api('GET', `/tasks/${task_id}`);
    if (t.status === 'success') break;
    if (['failed', 'cancelled', 'banned', 'expired', 'unknown'].includes(t.status)) { job.status = t.status; job.credits = 0; break; }
    await sleep(3000);
  }
  if (t.status === 'success') {
    const dir = ensureDir(join(ART_SRC, 'necro-anim', hero));
    const file = join(dir, `cand_${preset}.glb`);
    const res = await fetch(t.output.model_url);
    await pipeline(Readable.fromWeb(res.body), createWriteStream(file));
    job.status = 'success';
    job.credits = t.credits_consumed ?? t.consumed_credit ?? COST;
    job.fileHash = sha256(readFileSync(file));
    if (accept) copyFileSync(file, join(ART_SRC, 'tripo', hero, `anim_${preset}.glb`));
  }
  writeJson(JOBS, log);
  console.log(`  ${preset}: ${job.status} (${job.credits} cr) ${task_id}`);
}
const bal = await api('GET', '/account/balance');
console.log('balance', bal.balance);
