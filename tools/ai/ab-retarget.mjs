/**
 * ab-retarget.mjs — one-off A/B: retarget presets onto an existing rig task with a chosen animate_in_place / format,
 * log every task to art-manifest/tripo/ab-animate-in-place-2026-10-02.json. Hard budget cap. Nothing spent without --yes.
 *
 *   node tools/ai/ab-retarget.mjs <rigTaskId> <preset> <glb|fbx> <inplace:0|1> <outfile> [--yes]
 */
import { createWriteStream } from 'node:fs';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { ART_SRC, ensureDir, loadKey, MANIFEST_DIR, readJson, redact, sleep, writeJson } from './common.mjs';

const BASE = 'https://openapi.tripo3d.ai/v3';
const BUDGET = 40;
const LOG = join(MANIFEST_DIR, 'tripo', 'ab-animate-in-place-2026-10-02.json');
const [rig, preset, fmt, inplace, outName, ...flags] = process.argv.slice(2);
const key = loadKey('TRIPO_API_KEY');

async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { Authorization: `Bearer ${key}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json.code !== 0) throw new Error(`${method} ${path} HTTP ${res.status}: ${redact(json.message ?? JSON.stringify(json)).slice(0, 300)}`);
  return json.data;
}

const log = readJson(LOG, { purpose: 'A/B: animate_in_place on vs off, hero_gravecaller rig', budget: BUDGET, tasks: [] });
const spent = log.tasks.reduce((n, t) => n + (t.credits ?? 10), 0);
const body = { input: rig, out_format: fmt, animation: `preset:biped:${preset}`, export_with_geometry: true, animate_in_place: inplace === '1' };
if (fmt === 'glb') body.bake_animation = true;
console.log(JSON.stringify(body), `spent so far ${spent}/${BUDGET}`);
if (!flags.includes('--yes')) { console.log('dry run'); process.exit(0); }
if (spent + 10 > BUDGET) throw new Error('budget cap');
const bal0 = (await api('GET', '/account/balance')).balance;
const { task_id } = await api('POST', '/animations/retarget', body);
const rec = { taskId: task_id, rigTask: rig, params: body, out: outName, createdAt: new Date().toISOString(), credits: null };
log.tasks.push(rec); writeJson(LOG, log);
for (;;) {
  const t = await api('GET', `/tasks/${task_id}`);
  if (t.status === 'success') {
    rec.status = 'success'; rec.credits = t.credits_consumed ?? t.consumed_credit ?? null;
    const url = t.output?.model_url ?? t.output?.model ?? Object.values(t.output ?? {}).find((v) => typeof v === 'string' && /^https/.test(v));
    const dest = join(ensureDir(join(ART_SRC, 'tripo-ab')), outName);
    const r = await fetch(url);
    await pipeline(Readable.fromWeb(r.body), createWriteStream(dest));
    rec.outputKeys = Object.keys(t.output ?? {});
    break;
  }
  if (['failed', 'cancelled', 'banned', 'expired', 'unknown'].includes(t.status)) { rec.status = t.status; rec.error = redact(t.error_msg ?? ''); break; }
  await sleep(3000);
}
const bal1 = (await api('GET', '/account/balance')).balance;
rec.balanceBefore = bal0; rec.balanceAfter = bal1; rec.balanceDelta = +(bal0 - bal1).toFixed(2);
if (rec.credits == null) rec.credits = rec.balanceDelta;
writeJson(LOG, log);
console.log(rec.status, 'credits', rec.credits);
