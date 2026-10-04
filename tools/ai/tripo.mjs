/**
 * tripo.mjs — Tripo v3 API pipeline (image → low-poly model → rig → retargeted clips).
 *
 * Resumable and spend-safe: every step's task id is recorded in
 * art-src/tripo/<id>/state.json (and mirrored, minus local paths, into
 * art-manifest/tripo/<id>.json). Re-running a spec skips finished steps, so a
 * crash or rerun never pays twice. Nothing is spent without --yes.
 *
 * Usage:
 *   node tools/ai/tripo.mjs balance
 *   node tools/ai/tripo.mjs task <task_id>
 *   node tools/ai/tripo.mjs run art-manifest/tripo-specs/<id>.json [--yes] [--until generate|rig|retarget]
 *
 * Spec: { id, input: "art-src/concepts/<id>.png", generation: { model, face_limit, texture_quality },
 *         rig?: { model, rig_type, spec }, animations?: ["preset:biped:idle", ...],
 *         animationMode?: "batch"|"single", animateInPlace?: boolean (default true) }
 */
import { createWriteStream, existsSync, readFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { ART_SRC, ensureDir, loadKey, MANIFEST_DIR, readJson, redact, ROOT, sha256, sleep, writeJson } from './common.mjs';

const BASE = 'https://openapi.tripo3d.ai/v3';
let KEY = null;
const key = () => (KEY ??= loadKey('TRIPO_API_KEY'));

async function api(method, path, body, isForm = false) {
  for (let attempt = 1; attempt <= 5; attempt++) {
    const res = await fetch(`${BASE}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${key()}`,
        ...(body && !isForm ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? (isForm ? body : JSON.stringify(body)) : undefined,
    });
    const json = await res.json().catch(() => ({}));
    if (res.status === 429) {
      const reset = Number(res.headers.get('X-RateLimit-Reset'));
      const wait = reset ? Math.max(2000, reset * 1000 - Date.now()) : 5000 * attempt;
      console.warn(`  rate limited, waiting ${(wait / 1000).toFixed(0)}s`);
      await sleep(wait);
      continue;
    }
    if (res.status >= 500 && attempt < 5) {
      await sleep(3000 * attempt);
      continue;
    }
    if (!res.ok || json.code !== 0) {
      throw new Error(`${method} ${path} → HTTP ${res.status} code ${json.code}: ${redact(json.message ?? JSON.stringify(json)).slice(0, 300)}`);
    }
    return json.data;
  }
  throw new Error(`${method} ${path}: gave up after retries`);
}

async function upload(path) {
  const buf = readFileSync(path);
  const form = new FormData();
  const type = path.endsWith('.jpg') || path.endsWith('.jpeg') ? 'image/jpeg' : 'image/png';
  form.append('file', new Blob([buf], { type }), basename(path));
  const data = await api('POST', '/files', form, true);
  return { fileToken: data.file_token, hash: sha256(buf) };
}

async function waitTask(taskId, label, timeoutMs = 20 * 60 * 1000) {
  const start = Date.now();
  let last = -1;
  while (Date.now() - start < timeoutMs) {
    const t = await api('GET', `/tasks/${taskId}`);
    if (t.progress !== last) {
      process.stdout.write(`\r  ${label}: ${t.status} ${t.progress ?? 0}%   `);
      last = t.progress;
    }
    if (t.status === 'success') {
      process.stdout.write('\n');
      return t;
    }
    if (['failed', 'cancelled', 'banned', 'expired', 'unknown'].includes(t.status)) {
      process.stdout.write('\n');
      throw new Error(`${label} task ${taskId} ended: ${t.status} ${t.error_msg ?? t.message ?? ''}`);
    }
    await sleep(3000);
  }
  throw new Error(`${label} task ${taskId} timed out (still running — rerun to resume)`);
}

async function download(url, dest) {
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`download failed ${res.status}: ${dest}`);
  await pipeline(Readable.fromWeb(res.body), createWriteStream(dest));
  return dest;
}

class Run {
  constructor(spec) {
    this.spec = spec;
    // ART_SUB (e.g. `fen`) keeps a zone's raw outputs under art-src/<sub>/tripo/ instead of the shared art-src/tripo/.
    this.dir = ensureDir(join(ART_SRC, process.env.ART_SUB ?? '', 'tripo', spec.id));
    this.statePath = join(this.dir, 'state.json');
    this.state = readJson(this.statePath, { id: spec.id, steps: {} });
  }

  save() {
    writeJson(this.statePath, this.state);
    const pub = JSON.parse(JSON.stringify(this.state));
    for (const s of Object.values(pub.steps)) delete s.file;
    writeJson(join(MANIFEST_DIR, 'tripo', `${this.spec.id}.json`), {
      spec: this.spec,
      ...pub,
      totalCredits: Object.values(this.state.steps).reduce((n, s) => n + (s.credits ?? 0), 0),
    });
  }

  /** Create-or-resume one task step. `create` returns the POST body+path. */
  async step(name, create, { outFile, allowFail = false } = {}) {
    const st = (this.state.steps[name] ??= {});
    if (st.status === 'success' && (!outFile || existsSync(join(this.dir, outFile)))) {
      console.log(`  ${name}: done (${st.taskId})`);
      return st;
    }
    if (!st.taskId || st.status === 'failed') {
      const { path, body } = await create();
      const data = await api('POST', path, body);
      Object.assign(st, { taskId: data.task_id, status: 'created', request: body, createdAt: new Date().toISOString() });
      this.save();
    }
    try {
      const t = await waitTask(st.taskId, name);
      st.status = 'success';
      st.credits = t.credits_consumed ?? t.consumed_credit ?? null;
      st.output = t.output;
      if (outFile && t.output?.model_url) {
        const f = join(this.dir, outFile);
        await download(t.output.model_url, f);
        st.file = f;
        st.fileHash = sha256(readFileSync(f));
      }
      if (t.output?.rendered_image_url && !existsSync(join(this.dir, `${name}-preview.png`))) {
        await download(t.output.rendered_image_url, join(this.dir, `${name}-preview.png`)).catch(() => {});
      }
    } catch (err) {
      if (/ended: failed|ended: banned/.test(err.message)) st.status = 'failed';
      st.error = err.message;
      this.save();
      if (allowFail) return st;
      throw err;
    }
    this.save();
    return st;
  }

  async go(until) {
    const s = this.spec;
    console.log(`\n== ${s.id}`);
    // 1. upload concept
    const up = (this.state.steps.upload ??= {});
    if (!up.fileToken) {
      const inputPath = join(ROOT, s.input);
      if (!existsSync(inputPath)) throw new Error(`concept image missing: ${s.input}`);
      Object.assign(up, await upload(inputPath), { status: 'success', input: s.input });
      this.save();
      console.log('  upload: ok');
    }
    // 2. image → model
    const gen = await this.step('generate', async () => ({
      path: '/generation/image-to-model',
      body: {
        input: up.fileToken,
        texture: true,
        pbr: true,
        ...s.generation,
      },
    }), { outFile: 'model.glb' });
    if (until === 'generate' || !s.rig) return;

    // 3. rig check + rig
    const check = await this.step('rigCheck', async () => ({
      path: '/animations/rig-check',
      body: { input: gen.taskId },
    }));
    if (check.output && check.output.riggable === false) {
      throw new Error(`${s.id}: not riggable (${JSON.stringify(check.output)}) — adjust concept pose`);
    }
    const rig = await this.step('rig', async () => ({
      path: '/animations/rig',
      body: { input: gen.taskId, out_format: 'glb', spec: 'tripo', ...s.rig },
    }), { outFile: 'rig.glb' });
    if (until === 'rig' || !s.animations?.length) return;

    // 4. retarget — one batch GLB, or one GLB per clip
    const common = { input: rig.taskId, out_format: 'glb', bake_animation: true, export_with_geometry: true,
      // 2026-10-02 A/B (docs/TRIPO-ANIMATE-IN-PLACE.md): on v1.0 biped GLB retargets this flag changes nothing (byte-identical
      // output) and does not corrupt the bake. Kept true for continuity; spec.animateInPlace:false sends false. The game strips
      // root travel at runtime either way (graphics/inPlaceAnimation.ts).
      animate_in_place: s.animateInPlace ?? true };
    if ((s.animationMode ?? 'single') === 'batch') {
      // The API caps a batch at 5 presets ("animations size must be <= 5").
      for (let i = 0, n = 1; i < s.animations.length; i += 5, n++) {
        const chunk = s.animations.slice(i, i + 5);
        await this.step(`retarget_${n}`, async () => ({
          path: '/animations/retarget',
          body: chunk.length === 1 ? { ...common, animation: chunk[0] } : { ...common, animations: chunk },
        }), { outFile: `anims_${n}.glb` });
      }
    } else {
      for (const anim of s.animations) {
        const clip = anim.split(':').pop();
        await this.step(`anim_${clip}`, async () => ({
          path: '/animations/retarget',
          body: { ...common, animation: anim },
        }), { outFile: `anim_${clip}.glb`, allowFail: true });
      }
    }
  }
}

async function main() {
  const [cmd, arg, ...rest] = process.argv.slice(2);
  if (cmd === 'balance') {
    console.log(await api('GET', '/account/balance'));
    return;
  }
  if (cmd === 'task') {
    console.log(JSON.stringify(await api('GET', `/tasks/${arg}`), null, 2));
    return;
  }
  if (cmd === 'run') {
    const spec = readJson(join(ROOT, arg));
    if (!spec) throw new Error(`spec not found: ${arg}`);
    const untilIdx = rest.indexOf('--until');
    const until = untilIdx >= 0 ? rest[untilIdx + 1] : undefined;
    if (!rest.includes('--yes')) {
      const n = spec.animations?.length ?? 0;
      console.log(`Plan for ${spec.id}: upload → image-to-model (${spec.generation?.model}, ≤${spec.generation?.face_limit} faces)` +
        (spec.rig ? ` → rig-check → rig (${spec.rig.rig_type})` : '') +
        (n ? ` → ${n} animation(s) [${spec.animationMode ?? 'single'}]` : '') +
        `\nNothing spent. Re-run with --yes to execute.`);
      return;
    }
    const before = await api('GET', '/account/balance');
    await new Run(spec).go(until);
    const after = await api('GET', '/account/balance');
    console.log(`credits: ${before.balance} → ${after.balance} (spent ${(before.balance - after.balance).toFixed(2)}, frozen ${after.frozen})`);
    return;
  }
  console.error('usage: tripo.mjs balance | task <id> | run <spec.json> [--yes] [--until step]');
  process.exit(1);
}

main().catch((e) => {
  console.error('\n' + redact(e.message ?? e));
  process.exit(1);
});
