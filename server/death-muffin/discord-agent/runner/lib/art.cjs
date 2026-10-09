'use strict';
// Approval-gated, credit-capped model generation (Gemini concept -> Tripo model/rig/animations) for the Godot-mode agent.
//
// Trust model:
//  * The sandboxed agent never sees a key and cannot call an API. It only writes SPECS (art-manifest/gemini-jobs/<id>.json,
//    art-manifest/tripo-specs/<id>.json) plus a trigger file (.dm-art-request.json).
//  * This module (runner code, outside the sandbox) validates those specs against allow-lists, prices them, and later, after a human's
//    ✅, runs trusted COPIES of tools/ai/{common,gemini,tripo}.mjs (installed into <toolsDir>/art-tools, never taken from the worktree,
//    which the agent can edit) with the keys in the environment of that one child process only.
//  * What runs is the canonical spec stored at request time, not whatever the worktree holds at approval time.
//  * Budgets (owner-edited file) and the ledger (written here) live outside every repo checkout.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const G = require('./gitops.cjs');
const { addKnownSecrets, redactText } = require('./redact.cjs');

const ID_RE = /^[a-z0-9_]{3,40}$/;
const DEFAULT_COSTS = { generate: 60, rig: 25, anim: 10 };     // floors: the measured Tripo v3 prices (ASSET_PIPELINE.md); history can only raise them
const MAX_ESTIMATE = 400;                                      // one request may never ask for more than this, whatever the budget
const MAX_ANIMS = 10, FACE_MIN = 300, FACE_MAX = 14000;
const GEN_MODELS = ['P1-20260311'];
const TEXTURES = ['standard', 'detailed'];
const RIGS = { biped: 'v1.0-20240301', quadruped: 'v2.5-20260210' };
const BIPED_ANIMS = ['idle', 'walk', 'run', 'slash', 'dig', 'hurt', 'fall', 'cast_a_spell', 'dive', 'chop', 'box_01', 'box_02', 'box_03', 'front_kick_01', 'front_kick_02',
  'hit_to_body_01', 'hit_to_body_02', 'hit_to_head', 'hit_to_side', 'defeat_02', 'defeat_03', 'flee_01', 'flee_02', 'frightened', 'jump', 'lift_heavy', 'shoot', 'agree', 'angry_01'];
const ANIMS = { biped: BIPED_ANIMS.map((a) => `preset:biped:${a}`), quadruped: ['preset:quadruped:walk'] };
const ASPECTS = ['1:1', '3:4', '4:3', '2:3', '3:2', '9:16', '16:9'];
const SPEC_KEYS = ['id', 'input', 'generation', 'rig', 'animations', 'animationMode'];
const JOB_KEYS = ['id', 'prompt', 'out', 'refs', 'aspect', 'size', 'model', 'post'];
const REQUEST_FILE = '.dm-art-request.json';
const MAX_FILE = 64 * 1024, MAX_REF = 8 * 1024 * 1024;
const IMG_MAGIC = [[0x89, 0x50, 0x4e, 0x47], [0xff, 0xd8, 0xff]];   // png, jpeg

const isObj = (x) => x && typeof x === 'object' && !Array.isArray(x);
const onlyKeys = (o, keys, what, errs) => { for (const k of Object.keys(o)) if (!keys.includes(k)) errs.push(`${what}: field "${k}" is not allowed`); };

// ---------- safe reads inside a worktree (no symlinks anywhere on the path) ----------
function pathIssue(wt, rel) {
  const parts = rel.split('/'); let cur = wt;
  for (const p of parts) {
    cur = path.join(cur, p);
    let st; try { st = fs.lstatSync(cur); } catch { return null; }   // does not exist (yet): fine
    if (st.isSymbolicLink()) return `${rel} goes through a symlink`;
  }
  return null;
}
function readSmall(wt, rel, max = MAX_FILE) {
  if (!rel || rel.startsWith('/') || rel.split('/').includes('..')) return { error: `${rel}: bad path` };
  const iss = pathIssue(wt, rel); if (iss) return { error: iss };
  const f = path.join(wt, rel);
  let st; try { st = fs.lstatSync(f); } catch { return { missing: true, error: `${rel} does not exist` }; }
  if (!st.isFile()) return { error: `${rel} is not a regular file` };
  if (st.size > max) return { error: `${rel} is too big (${st.size} bytes, limit ${max})` };
  try { return { text: fs.readFileSync(f, 'utf8') }; } catch (e) { return { error: `${rel}: ${e.message}` }; }
}
function parseJson(r, rel) {
  if (r.error) return { error: r.error };
  try { return { value: JSON.parse(r.text) }; } catch { return { error: `${rel} is not valid JSON` }; }
}
function imageOk(wt, rel) {
  const iss = pathIssue(wt, rel); if (iss) return iss;
  const f = path.join(wt, rel); let st; try { st = fs.lstatSync(f); } catch { return `${rel} does not exist`; }
  if (!st.isFile() || st.size > MAX_REF || st.size < 8) return `${rel} is not a usable image`;
  const fd = fs.openSync(f, 'r'); const b = Buffer.alloc(4); try { fs.readSync(fd, b, 0, 4, 0); } finally { fs.closeSync(fd); }
  return IMG_MAGIC.some((m) => m.every((x, i) => b[i] === x)) ? null : `${rel} is not a PNG or JPEG`;
}

// ---------- the request file ----------
// Returns null (no request), {error} or {id, note}. The file is removed once read (like .dm-result.json).
function readRequest(wt) {
  const f = path.join(wt, REQUEST_FILE);
  let st; try { st = fs.lstatSync(f); } catch { return null; }
  let out;
  if (!st.isFile() || st.size > 4096) out = { error: `${REQUEST_FILE} must be a small regular file` };
  else {
    try {
      const j = JSON.parse(fs.readFileSync(f, 'utf8')); const errs = [];
      if (!isObj(j)) errs.push(`${REQUEST_FILE} must be a JSON object`);
      else { onlyKeys(j, ['id', 'note'], REQUEST_FILE, errs); if (typeof j.id !== 'string' || !ID_RE.test(j.id)) errs.push('id must match [a-z0-9_]{3,40}'); }
      out = errs.length ? { error: errs.join('; ') } : { id: j.id, note: typeof j.note === 'string' ? j.note.replace(/[\u0000-\u001f]+/g, ' ').slice(0, 300) : '' };
    } catch { out = { error: `${REQUEST_FILE} is not valid JSON` }; }
  }
  try { fs.unlinkSync(f); } catch { /* gone */ }
  return out;
}

// ---------- what the BASE branch already holds (never taken from the agent's worktree) ----------
async function baseInfo(cfg, job) {
  const info = { rootPngs: new Set(), existing: new Set(), history: { ...DEFAULT_COSTS } };
  const ref = job.base || `origin/${cfg.baseBranch || 'master'}`;
  const ls = async (args) => { const r = await G.git(cfg.repo, ['ls-tree', ...args], { allowFail: true }); return r.code === 0 ? r.out.split('\n').filter(Boolean) : []; };
  for (const n of await ls(['--name-only', ref])) if (/^[A-Za-z0-9_-]+\.png$/.test(n)) info.rootPngs.add(n);
  for (const n of await ls(['--name-only', ref, 'art-manifest/tripo-specs/'])) { const m = /([a-z0-9_]+)\.json$/.exec(n); if (m) info.existing.add(m[1]); }
  for (const n of await ls(['--name-only', ref, 'godot/assets/slice/models/'])) { const m = /models\/([a-z0-9_]+)$/.exec(n); if (m && m[1] !== 'props') info.existing.add(m[1]); }
  for (const n of await ls(['--name-only', ref, 'godot/assets/slice/models/props/'])) { const m = /props\/([a-z0-9_]+)\.glb$/.exec(n); if (m) info.existing.add(`prop_${m[1]}`), info.existing.add(m[1]); }
  info.history = await loadCostHistory(cfg, ref);
  return info;
}
// Highest credits ever charged per step type in the committed manifests (art-manifest/tripo/*.json): generate, rig, one animation clip.
async function loadCostHistory(cfg, ref) {
  const h = { ...DEFAULT_COSTS };
  try {
    const r = await G.git(cfg.repo, ['ls-tree', '-r', '--name-only', ref, 'art-manifest/tripo/'], { allowFail: true });
    const files = r.out.split('\n').filter((f) => /^art-manifest\/tripo\/[a-z0-9_]+\.json$/.test(f));
    if (!files.length) return h;
    const cat = await G.run('git', ['cat-file', '--batch'], { cwd: cfg.repo, input: files.map((f) => `${ref}:${f}`).join('\n') + '\n', timeoutMs: 60000, env: { PATH: process.env.PATH, HOME: process.env.HOME } });
    const buf = Buffer.from(cat.out, 'utf8'); let pos = 0;
    while (pos < buf.length) {
      const nl = buf.indexOf(10, pos); if (nl < 0) break;
      const head = buf.slice(pos, nl).toString(); const m = /^[0-9a-f]+ blob (\d+)$/.exec(head);
      if (!m) { pos = nl + 1; continue; }
      const size = Number(m[1]); const body = buf.slice(nl + 1, nl + 1 + size).toString(); pos = nl + 1 + size + 1;
      try {
        for (const [name, s] of Object.entries(JSON.parse(body).steps || {})) {
          if (!s || typeof s.credits !== 'number' || !isFinite(s.credits) || s.credits < 0) continue;
          const key = name === 'generate' ? 'generate' : name === 'rig' ? 'rig' : name.startsWith('anim_') ? 'anim' : null;
          if (key) h[key] = Math.max(h[key], Math.min(s.credits, 500));
        }
      } catch { /* skip a bad manifest */ }
    }
  } catch { /* defaults */ }
  return h;
}

// ---------- validation ----------
// Returns { ok, errors[], id, kind, spec, gemini, estimate: { total, parts: [{label, credits}] } }. Pure given its inputs (tests call it directly).
function validate({ wt, request, info }) {
  const errors = []; const id = request && request.id;
  if (!request || request.error) return { ok: false, errors: [request ? request.error : 'no request'] };
  const gRel = `art-manifest/gemini-jobs/${id}.json`, tRel = `art-manifest/tripo-specs/${id}.json`;
  const gj = parseJson(readSmall(wt, gRel), gRel), tj = parseJson(readSmall(wt, tRel), tRel);
  if (gj.error) errors.push(gj.error); if (tj.error) errors.push(tj.error);
  if (errors.length) return { ok: false, errors, id };
  if (info.existing.has(id)) errors.push(`id "${id}" is already used by an existing model; pick a new id`);

  // -- tripo spec
  const t = tj.value; let spec = null;
  if (!isObj(t)) errors.push(`${tRel} must be a JSON object`);
  else {
    onlyKeys(t, SPEC_KEYS, tRel, errors);
    if (t.id !== id) errors.push(`${tRel}: id must be "${id}"`);
    if (t.input !== `art-src/concepts/${id}.png`) errors.push(`${tRel}: input must be "art-src/concepts/${id}.png"`);
    const g = t.generation; let gen = null;
    if (!isObj(g)) errors.push(`${tRel}: generation is required`);
    else {
      onlyKeys(g, ['model', 'face_limit', 'texture_quality'], 'generation', errors);
      if (!GEN_MODELS.includes(g.model)) errors.push(`generation.model must be one of ${GEN_MODELS.join(', ')}`);
      if (!Number.isInteger(g.face_limit) || g.face_limit < FACE_MIN || g.face_limit > FACE_MAX) errors.push(`generation.face_limit must be an integer ${FACE_MIN} to ${FACE_MAX}`);
      if (!TEXTURES.includes(g.texture_quality)) errors.push(`generation.texture_quality must be ${TEXTURES.join(' or ')}`);
      gen = { model: g.model, face_limit: g.face_limit, texture_quality: g.texture_quality };
    }
    let rig = null, anims = [];
    if (t.rig !== undefined) {
      if (!isObj(t.rig)) errors.push('rig must be an object');
      else {
        onlyKeys(t.rig, ['model', 'rig_type'], 'rig', errors);
        if (!RIGS[t.rig.rig_type]) errors.push(`rig.rig_type must be ${Object.keys(RIGS).join(' or ')}`);
        else if (t.rig.model !== RIGS[t.rig.rig_type]) errors.push(`rig.model for ${t.rig.rig_type} must be ${RIGS[t.rig.rig_type]}`);
        else rig = { model: t.rig.model, rig_type: t.rig.rig_type };
      }
    }
    if (t.animations !== undefined) {
      if (!Array.isArray(t.animations)) errors.push('animations must be a list');
      else if (!rig) errors.push('animations need a valid rig');
      else {
        if (t.animations.length > MAX_ANIMS) errors.push(`at most ${MAX_ANIMS} animations`);
        if (new Set(t.animations).size !== t.animations.length) errors.push('animations must not repeat');
        for (const a of t.animations) if (typeof a !== 'string' || !ANIMS[rig.rig_type].includes(a)) errors.push(`animation ${JSON.stringify(String(a)).slice(0, 60)} is not an allowed ${rig.rig_type} preset`);
        anims = t.animations.slice(0, MAX_ANIMS);
      }
    }
    if (t.animationMode !== undefined && t.animationMode !== 'single') errors.push('animationMode must be "single"');
    if (rig && id.startsWith('prop_')) errors.push('ids starting with prop_ are static props: remove the rig');
    if (!rig && !id.startsWith('prop_')) errors.push('a model without a rig is a static prop and its id must start with prop_');
    if (gen) spec = { id, input: `art-src/concepts/${id}.png`, generation: gen, ...(rig ? { rig, animations: anims, animationMode: 'single' } : {}) };
  }

  // -- gemini job (a one-element list, like the other files in gemini-jobs/)
  const gv = gj.value; const job = Array.isArray(gv) ? gv[0] : gv; let gem = null;
  if (Array.isArray(gv) && gv.length !== 1) errors.push(`${gRel} must hold exactly one job`);
  else if (!isObj(job)) errors.push(`${gRel} must hold one job object`);
  else {
    onlyKeys(job, JOB_KEYS, gRel, errors);
    if (job.id !== `concept_${id}`) errors.push(`${gRel}: job id must be "concept_${id}"`);
    if (job.out !== `art-src/concepts/${id}.png`) errors.push(`${gRel}: out must be "art-src/concepts/${id}.png"`);
    if (typeof job.prompt !== 'string' || job.prompt.length < 20 || job.prompt.length > 4000 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(job.prompt)) errors.push('prompt must be 20 to 4000 characters of plain text');
    if (job.aspect !== undefined && !ASPECTS.includes(job.aspect)) errors.push(`aspect must be one of ${ASPECTS.join(', ')}`);
    if (job.size !== undefined && job.size !== '1K') errors.push('size must be "1K" when given');
    if (job.model !== undefined && job.model !== 'gemini-3.1-flash-image') errors.push('model must be gemini-3.1-flash-image when given');
    let refs = [];
    if (job.refs !== undefined) {
      if (!Array.isArray(job.refs) || job.refs.length > 3) errors.push('refs must be a list of at most 3 images');
      else for (const r of job.refs) {
        if (typeof r !== 'string') { errors.push('a ref is not a string'); continue; }
        if (info.rootPngs.has(r)) { refs.push(r); continue; }       // a reference sheet that is committed on the base branch
        if (/^art-src\/concepts\/[a-z0-9_]+\.png$/.test(r)) { const bad = imageOk(wt, r); if (bad) errors.push(`ref ${bad}`); else refs.push(r); continue; }
        errors.push(`ref "${String(r).slice(0, 80)}" is not allowed (art-src/concepts/<name>.png or a reference sheet committed at the repo root)`);
      }
    }
    let post;
    if (job.post !== undefined) {
      if (!isObj(job.post)) errors.push('post must be an object');
      else {
        onlyKeys(job.post, ['resize', 'format'], 'post', errors);
        if (job.post.format !== undefined && job.post.format !== 'png') errors.push('post.format must be "png"');
        if (job.post.resize !== undefined && !(Array.isArray(job.post.resize) && job.post.resize.length === 2 && job.post.resize.every((n) => Number.isInteger(n) && n >= 256 && n <= 2048))) errors.push('post.resize must be [w, h], each 256 to 2048');
        post = { ...(job.post.resize ? { resize: job.post.resize } : {}), ...(job.post.format ? { format: 'png' } : {}) };
      }
    }
    gem = { id: `concept_${id}`, prompt: job.prompt, out: `art-src/concepts/${id}.png`, aspect: job.aspect || '1:1', ...(refs.length ? { refs } : {}), ...(post && Object.keys(post).length ? { post } : {}) };
  }

  // -- places the tools will write must not be symlinks (a symlink would send a write outside the worktree)
  for (const rel of ['art-src', 'art-src/concepts', `art-src/concepts/${id}.png`, 'art-src/gemini', `art-src/gemini/concept_${id}.png`, 'art-src/tripo', `art-src/tripo/${id}`,
    'art-manifest', 'art-manifest/images.json', 'art-manifest/tripo', `art-manifest/tripo/${id}.json`, 'art-manifest/gemini-jobs', 'art-manifest/tripo-specs', gRel, tRel]) {
    const iss = pathIssue(wt, rel); if (iss) errors.push(iss);
  }
  const dir = path.join(wt, 'art-src', 'tripo', id);
  try { const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { if (e.isSymbolicLink()) errors.push(`art-src/tripo/${id} holds a symlink`); else if (e.isDirectory()) walk(path.join(d, e.name)); } }; walk(dir); } catch { /* none yet */ }

  if (errors.length || !spec || !gem) return { ok: false, errors: [...new Set(errors)].slice(0, 12), id };
  const est = estimate(spec, info.history);
  if (est.total > MAX_ESTIMATE) return { ok: false, errors: [`estimated ${est.total} credits is above the ${MAX_ESTIMATE} per-request ceiling; ask for fewer animations`], id };
  return { ok: true, errors: [], id, kind: spec.rig ? 'character' : 'prop', spec, gemini: gem, estimate: est };
}

// Conservative price: the highest credits ever seen per step type (never below the measured floor). rig-check is free.
function estimate(spec, history = DEFAULT_COSTS) {
  const c = { generate: Math.max(DEFAULT_COSTS.generate, history.generate || 0), rig: Math.max(DEFAULT_COSTS.rig, history.rig || 0), anim: Math.max(DEFAULT_COSTS.anim, history.anim || 0) };
  const parts = [{ label: 'image to model', credits: c.generate }];
  if (spec.rig) parts.push({ label: 'rig', credits: c.rig });
  const n = (spec.animations || []).length; if (n) parts.push({ label: `${n} animation${n === 1 ? '' : 's'} x ${c.anim}`, credits: n * c.anim });
  return { total: parts.reduce((a, p) => a + p.credits, 0), parts };
}

function describe(v) {
  const s = v.spec; const bits = [`Concept image (Gemini) -> 3D model (Tripo, up to ${s.generation.face_limit} faces, ${s.generation.texture_quality} textures)`];
  if (s.rig) bits.push(`rig (${s.rig.rig_type})`);
  if (s.animations && s.animations.length) bits.push(`${s.animations.length} animation${s.animations.length === 1 ? '' : 's'}: ${s.animations.map((a) => a.split(':').pop()).join(', ')}`);
  return bits.join(' -> ');
}

// ---------- keys (read by the runner when it spends; only ever put in one child's environment) ----------
function parseKeyFile(text) {
  const out = {};
  for (const line of String(text).split(/\r?\n/)) { const i = line.indexOf('='); if (i > 0) { const k = line.slice(0, i).trim(); const v = line.slice(i + 1).trim(); if (v) out[k] = v; } }
  return out;
}

function paths(cfg) {
  const td = cfg.toolsDir;
  return {
    tools: cfg.artToolsDir || path.join(td, 'art-tools'),
    script: cfg.artRunScript || path.join(td, 'art-run.sh'),
    lock: cfg.artLockFile || path.join(td, 'state', 'tripo.lock'),
    keys: cfg.artKeysFile || path.join(cfg.repo, '.ai-keys.local'),
    budget: cfg.artBudgetFile || path.join(td, 'tripo-budget.json'),
    ledger: cfg.artLedgerFile || path.join(td, 'tripo-ledger.json'),
  };
}

// ---------- budgets + ledger ----------
function createStore(cfg, now = () => Date.now()) {
  const P = paths(cfg);
  const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return d; } };
  const budgetOf = (uid) => { const b = readJson(P.budget, {}); const v = isObj(b) ? b[String(uid)] : 0; return typeof v === 'number' && isFinite(v) && v > 0 ? v : 0; };
  const load = () => { const l = readJson(P.ledger, null); return l && Array.isArray(l.entries) ? l : { version: 1, entries: [] }; };
  const save = (l) => { fs.mkdirSync(path.dirname(P.ledger), { recursive: true }); const t = `${P.ledger}.tmp.${process.pid}`; fs.writeFileSync(t, JSON.stringify(l, null, 1) + '\n', { mode: 0o600 }); fs.renameSync(t, P.ledger); };
  const spentBy = (uid) => load().entries.filter((e) => String(e.userId) === String(uid)).reduce((n, e) => n + (Number(e.credits) > 0 ? Number(e.credits) : 0), 0);
  const remaining = (uid) => Math.max(0, budgetOf(uid) - spentBy(uid));
  // A 'started' entry is written BEFORE anything is spent, so a crash leaves a trace that reconcile() can close.
  function begin(fields) { const l = load(); const e = { id: crypto.randomBytes(5).toString('hex'), ts: new Date(now()).toISOString(), status: 'started', credits: 0, ...fields }; l.entries.push(e); save(l); return e.id; }
  function finish(entryId, fields) { const l = load(); const e = l.entries.find((x) => x.id === entryId); if (!e) return null; Object.assign(e, fields, { finishedAt: new Date(now()).toISOString() }); save(l); return e; }
  const open = () => load().entries.filter((e) => e.status === 'started');
  return { paths: P, budgetOf, spentBy, remaining, begin, finish, open, entries: () => load().entries };
}

// ---------- running ----------
function createArt(cfg, { audit, now = () => Date.now() } = {}) {
  const P = paths(cfg); const store = createStore(cfg, now);
  const loadKeys = () => {
    let t; try { t = fs.readFileSync(P.keys, 'utf8'); } catch { throw new Error('the art key file is missing'); }
    const k = parseKeyFile(t);
    if (!k.TRIPO_API_KEY || !k.GEMINI_API_KEY) throw new Error('the art key file does not hold both keys');
    addKnownSecrets([k.TRIPO_API_KEY, k.GEMINI_API_KEY]);
    return { TRIPO_API_KEY: k.TRIPO_API_KEY, GEMINI_API_KEY: k.GEMINI_API_KEY };
  };
  const baseEnv = () => ({ PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8' });
  const parseBalance = (out) => { const m = /balance:\s*(-?\d+(?:\.\d+)?)/.exec(String(out)); return m ? Number(m[1]) : null; };
  // Live Tripo balance (free call). null when it cannot be read.
  async function balance() {
    try {
      const r = await G.run('node', [path.join(P.tools, 'tools', 'ai', 'tripo.mjs'), 'balance'], { cwd: P.tools, env: { ...baseEnv(), ...loadKeys(), DM_ART_ROOT: P.tools }, timeoutMs: 60000 });
      return r.code === 0 ? parseBalance(r.out) : null;
    } catch { return null; }
  }
  // Runs art-run.sh in the worktree (flock inside, one run at a time). Returns { credits, before, after, result, tail, timedOut, code }.
  async function run(wt, id, { onSpawn } = {}) {
    const keys = loadKeys();
    const r = await G.run('bash', [P.script, id], { cwd: wt, onSpawn, timeoutMs: 75 * 60000,
      env: { ...baseEnv(), ...keys, DM_ART_TOOLS: P.tools, DM_ART_LOCK: P.lock, ...(cfg.artLockWaitSec ? { DM_ART_LOCK_WAIT: String(cfg.artLockWaitSec) } : {}) } });
    const out = r.out + r.err;
    const num = (name) => { const m = new RegExp(`^${name}: (\\S+)$`, 'm').exec(out); return m && isFinite(Number(m[1])) ? Number(m[1]) : null; };
    const before = num('BALANCE_BEFORE'); let after = num('BALANCE_AFTER');
    if (after == null && before != null) after = await balance();   // killed (timeout / cancel): the script's own exit trap never ran
    const res = /^RESULT: (\S+)\s*(.*)$/m.exec(out);
    let credits = before != null && after != null ? Math.max(0, +(before - after).toFixed(2)) : null;
    if (credits === null) {
      // balance unreadable: fall back to what tripo.mjs itself recorded in the manifest for this run
      try { const m = JSON.parse(fs.readFileSync(path.join(wt, 'art-manifest', 'tripo', `${id}.json`), 'utf8')); if (typeof m.totalCredits === 'number') credits = m.totalCredits; } catch { /* none */ }
    }
    const safeTail = redactText(out.trim().split('\n').filter((l) => !/^BALANCE_/.test(l)).slice(-8).join('\n'));
    return { credits, before, after, result: res ? res[1] : (r.timedOut ? 'timeout' : 'crashed'), detail: res ? res[2] : '', tail: safeTail, timedOut: !!r.timedOut, code: r.code };
  }
  // Called at startup: runs that were 'started' but never finished (the runner died mid-run) are closed from the balance delta.
  async function reconcile() {
    const open = store.open(); if (!open.length) return 0;
    const bal = await balance();
    for (const e of open) {
      const delta = bal != null && typeof e.balanceBefore === 'number' ? Math.max(0, +(e.balanceBefore - bal).toFixed(2)) : null;
      const credits = delta != null ? Math.min(delta, e.estimate || delta) : (e.estimate || 0);   // unknown: charge the estimate (conservative)
      store.finish(e.id, { status: 'interrupted', credits, balanceAfter: bal, note: delta != null ? 'runner restarted mid-run; charged from the balance delta' : 'runner restarted mid-run; balance unreadable, charged the estimate' });
      if (audit) audit.log('art-reconciled', { entry: e.id, credits });
    }
    return open.length;
  }
  return { store, paths: P, loadKeys, balance, run, reconcile, parseBalance };
}

module.exports = { ID_RE, DEFAULT_COSTS, MAX_ESTIMATE, MAX_ANIMS, REQUEST_FILE, ANIMS, RIGS, readRequest, baseInfo, loadCostHistory, validate, estimate, describe, parseKeyFile, paths, createStore, createArt, pathIssue };
