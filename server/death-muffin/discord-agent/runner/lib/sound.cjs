'use strict';
// Sound effects and music from ElevenLabs for the Godot-mode agent. Same trust model as lib/art.cjs, minus the budget gate:
//  * The sandboxed agent never sees the key and cannot call the API. It writes a SPEC (audio-manifest/eleven/<id>.json) and a trigger file
//    (.dm-sound-request.json), then stops.
//  * This module validates the spec against allow-lists and, when the person who asked is in cfg.soundUsers, runs the TRUSTED copy of
//    sound-run.mjs (installed in toolsDir, never taken from the worktree) with the key in that one child's environment.
//  * The owner authorized sound users to spend any amount of the ElevenLabs balance (2026-10-11), so there is no budget or ✅ before a run.
//    Every run is recorded in the ledger (eleven-ledger.json, outside every checkout) with the real cost ElevenLabs reports per call.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const G = require('./gitops.cjs');
const { addKnownSecrets, redactText } = require('./redact.cjs');
const { pathIssue } = require('./art.cjs');

const ID_RE = /^[a-z0-9_]{3,40}$/;
const REQUEST_FILE = '.dm-sound-request.json';
const SPEC_DIR = 'audio-manifest/eleven';
const OUT_DIR = 'audio-src/eleven';
const KINDS = {
  sfx: { keys: ['id', 'kind', 'prompt', 'duration_seconds', 'loop', 'prompt_influence', 'variants'], minS: 0.5, maxS: 30, maxVariants: 4, maxPrompt: 1000 },
  music: { keys: ['id', 'kind', 'prompt', 'duration_seconds', 'variants'], minS: 10, maxS: 180, maxVariants: 2, maxPrompt: 2000 },
};
const MAX_FILE = 16 * 1024;
const isObj = (x) => x && typeof x === 'object' && !Array.isArray(x);

// Returns null (no request), {error} or {id, note}. The file is removed once read.
function readRequest(wt) {
  const f = path.join(wt, REQUEST_FILE);
  let st; try { st = fs.lstatSync(f); } catch { return null; }
  let out;
  if (!st.isFile() || st.size > 4096) out = { error: `${REQUEST_FILE} must be a small regular file` };
  else {
    try {
      const j = JSON.parse(fs.readFileSync(f, 'utf8'));
      if (!isObj(j)) out = { error: `${REQUEST_FILE} must be a JSON object` };
      else if (Object.keys(j).some((k) => !['id', 'note'].includes(k))) out = { error: `${REQUEST_FILE} may only hold "id" and "note"` };
      else if (typeof j.id !== 'string' || !ID_RE.test(j.id)) out = { error: 'id must match [a-z0-9_]{3,40}' };
      else out = { id: j.id, note: typeof j.note === 'string' ? j.note.replace(/[\u0000-\u001f]+/g, ' ').slice(0, 300) : '' };
    } catch { out = { error: `${REQUEST_FILE} is not valid JSON` }; }
  }
  try { fs.unlinkSync(f); } catch { /* gone */ }
  return out;
}

// Returns { ok, errors[], id, spec } where spec is the canonical request that will be sent. Pure given the worktree (tests call it directly).
function validate({ wt, request }) {
  if (!request || request.error) return { ok: false, errors: [request ? request.error : 'no request'] };
  const id = request.id, rel = `${SPEC_DIR}/${id}.json`, errors = [];
  for (const r of ['audio-manifest', SPEC_DIR, rel, 'audio-src', OUT_DIR, `${OUT_DIR}/${id}`]) { const iss = pathIssue(wt, r); if (iss) errors.push(iss); }
  if (errors.length) return { ok: false, errors, id };
  let st; try { st = fs.lstatSync(path.join(wt, rel)); } catch { return { ok: false, errors: [`${rel} does not exist`], id }; }
  if (!st.isFile() || st.size > MAX_FILE) return { ok: false, errors: [`${rel} must be a small regular file`], id };
  let s; try { s = JSON.parse(fs.readFileSync(path.join(wt, rel), 'utf8')); } catch { return { ok: false, errors: [`${rel} is not valid JSON`], id }; }
  if (!isObj(s)) return { ok: false, errors: [`${rel} must be a JSON object`], id };
  const K = KINDS[s.kind];
  if (!K) return { ok: false, errors: [`kind must be ${Object.keys(KINDS).join(' or ')}`], id };
  for (const k of Object.keys(s)) if (!K.keys.includes(k)) errors.push(`field "${k}" is not allowed for ${s.kind}`);
  if (s.id !== id) errors.push(`id must be "${id}"`);
  if (typeof s.prompt !== 'string' || s.prompt.trim().length < 10 || s.prompt.length > K.maxPrompt || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(s.prompt)) errors.push(`prompt must be 10 to ${K.maxPrompt} characters of plain text`);
  if (typeof s.duration_seconds !== 'number' || !isFinite(s.duration_seconds) || s.duration_seconds < K.minS || s.duration_seconds > K.maxS) errors.push(`duration_seconds must be a number ${K.minS} to ${K.maxS}`);
  const variants = s.variants === undefined ? 1 : s.variants;
  if (!Number.isInteger(variants) || variants < 1 || variants > K.maxVariants) errors.push(`variants must be an integer 1 to ${K.maxVariants}`);
  if (s.loop !== undefined && typeof s.loop !== 'boolean') errors.push('loop must be true or false');
  if (s.prompt_influence !== undefined && !(typeof s.prompt_influence === 'number' && s.prompt_influence >= 0 && s.prompt_influence <= 1)) errors.push('prompt_influence must be 0 to 1');
  if (errors.length) return { ok: false, errors: errors.slice(0, 10), id };
  const spec = { id, kind: s.kind, prompt: s.prompt.trim(), duration_seconds: Math.round(s.duration_seconds * 10) / 10, variants,
    ...(s.kind === 'sfx' ? { loop: !!s.loop, prompt_influence: s.prompt_influence === undefined ? 0.4 : s.prompt_influence } : {}) };
  return { ok: true, errors: [], id, spec };
}

function describe(spec) {
  const v = spec.variants > 1 ? `${spec.variants} takes` : '1 take';
  return spec.kind === 'music' ? `Music, ${spec.duration_seconds} s, instrumental, ${v}` : `Sound effect, ${spec.duration_seconds} s${spec.loop ? ', seamless loop' : ''}, ${v}`;
}

function paths(cfg) {
  const td = cfg.toolsDir;
  return {
    script: cfg.soundRunScript || path.join(td, 'sound-run.mjs'),
    key: cfg.soundKeyFile || '/home/ubuntu/death-muffin/private/elevenlabs-api-key',
    ledger: cfg.soundLedgerFile || path.join(td, 'eleven-ledger.json'),
  };
}

function createSound(cfg, { now = () => Date.now() } = {}) {
  const P = paths(cfg);
  const users = new Set((cfg.soundUsers || []).map(String));
  const allowed = (uid) => users.has(String(uid));
  const loadKey = () => {
    let k; try { k = fs.readFileSync(P.key, 'utf8').trim(); } catch { throw new Error('the ElevenLabs key file is missing'); }
    if (!k.startsWith('sk_')) throw new Error('the ElevenLabs key file does not hold a secret key');
    addKnownSecrets([k]);
    return k;
  };
  const readLedger = () => { try { const l = JSON.parse(fs.readFileSync(P.ledger, 'utf8')); return Array.isArray(l.entries) ? l : { version: 1, entries: [] }; } catch { return { version: 1, entries: [] }; } };
  const record = (entry) => {
    const l = readLedger(); l.entries.push({ id: crypto.randomBytes(5).toString('hex'), ts: new Date(now()).toISOString(), ...entry });
    fs.mkdirSync(path.dirname(P.ledger), { recursive: true });
    const t = `${P.ledger}.tmp.${process.pid}`; fs.writeFileSync(t, JSON.stringify(l, null, 1) + '\n', { mode: 0o600 }); fs.renameSync(t, P.ledger);
  };
  const spentBy = (uid) => readLedger().entries.filter((e) => String(e.userId) === String(uid)).reduce((n, e) => n + (Number(e.credits) > 0 ? Number(e.credits) : 0), 0);
  // Runs sound-run.mjs in the worktree. Returns { result, credits, files: [rel...], tail }.
  async function run(wt, spec, { onSpawn } = {}) {
    const key = loadKey();
    const r = await G.run(process.execPath, [P.script], { cwd: wt, onSpawn, timeoutMs: (spec.kind === 'music' ? 12 : 5) * 60000 * spec.variants,
      env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8', ELEVENLABS_API_KEY: key, DM_SOUND_SPEC: JSON.stringify(spec), ...(cfg.soundApiBase ? { DM_ELEVEN_BASE: cfg.soundApiBase } : {}) } });
    const out = r.out + r.err;
    const credits = [...out.matchAll(/^COST: (\d+(?:\.\d+)?)$/gm)].reduce((n, m) => n + Number(m[1]), 0);
    const files = [...out.matchAll(/^FILE: (audio-src\/eleven\/[a-z0-9_]+\/v\d\.mp3)$/gm)].map((m) => m[1]);
    const res = /^RESULT: (\S+)/m.exec(out);
    return { result: res ? res[1] : (r.timedOut ? 'timeout' : 'crashed'), credits, files, tail: redactText(out.trim().split('\n').filter((l) => !/^(COST|FILE): /.test(l)).slice(-6).join('\n')) };
  }
  return { paths: P, allowed, users: () => [...users], run, record, spentBy, entries: () => readLedger().entries };
}

module.exports = { ID_RE, REQUEST_FILE, SPEC_DIR, OUT_DIR, KINDS, readRequest, validate, describe, paths, createSound };
