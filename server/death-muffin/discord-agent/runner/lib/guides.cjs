'use strict';
// The agent's guides (README "Prompt and guides"): PROMPT-godot.md is the core, always loaded; the how-tos for screenshots, short videos,
// pictures, models and sound are guide files the agent Reads when it uses one. The trusted source is the INSTALLED copies
// (<toolsDir>/PROMPT-godot.md and <toolsDir>/guides/), never a worktree. Before every turn:
//   1. the round's snapshot (<stateDir>/guides/<job>/, outside every worktree) holds the rendered core and guides of one installed version;
//      it is made on a round's first turn and made again, core and guides together, when the install changed (a reinstall), when it no
//      longer matches its own hashes, or for a job from before the guides existed (no job.guidesKey); a conversation that carries on is told;
//   2. the turn's system prompt is the snapshot's core, for every call of the turn (step-limit handoffs included);
//   3. the guides are copied into the worktree's .dm-guides/ (git-excluded, in forbiddenPaths), and a missing or edited copy is put back;
//      the exclude entry is added first when the worktree was made by a runner from before the guides.
// gitops.removeJobArtifacts removes the snapshot with the worktree. Nothing is ever copied from a worktree back. An install whose core names a guide that is missing or empty runs no turn.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { renderCore, renderText } = require('./agent.cjs');
const { excludeJobFiles } = require('./gitops.cjs');

const GUIDE_DIR = '.dm-guides';
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const snapDir = (cfg, job) => path.join(cfg.stateDir, 'guides', String(job.id));

// The guides the core names (`.dm-guides/<name>.md`), in order of first mention: the core's index is the one list of guides.
function indexedGuides(core) { return [...new Set([...String(core).matchAll(/\.dm-guides\/([a-z0-9-]+)\.md/g)].map((m) => m[1]))]; }

// The installed core and the guides it names: { core, names, guides: {name: text}, version } or { error }.
function readInstalled(cfg) {
  let core;
  try { core = fs.readFileSync(path.join(cfg.toolsDir, 'PROMPT-godot.md'), 'utf8'); } catch { return { error: 'PROMPT-godot.md is missing' }; }
  const names = indexedGuides(core), guides = {}, missing = [];
  for (const n of names) {
    let t = ''; try { t = fs.readFileSync(path.join(cfg.toolsDir, 'guides', `${n}.md`), 'utf8'); } catch { /* missing */ }
    if (t.trim()) guides[n] = t; else missing.push(`guides/${n}.md`);
  }
  if (missing.length) return { error: `missing or empty: ${missing.join(', ')}` };
  return { core, names, guides, version: sha(JSON.stringify([core, ...names.map((n) => [n, guides[n]])])).slice(0, 16) };
}
// What a snapshot was rendered from: the installed version and everything the placeholders and the web line take.
const keyFor = (cfg, job, version) => sha(JSON.stringify([version, job.branch, cfg.toolsDir, cfg.baseBranch || 'main', !!cfg.webAnyHost])).slice(0, 16);

function writeSnapshot(cfg, job, inst) {
  const dir = snapDir(cfg, job);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const texts = { 'core.md': renderCore(cfg, job, inst.core) };
  for (const n of inst.names) texts[`${n}.md`] = renderText(cfg, job, inst.guides[n]);
  const files = {};
  for (const [f, t] of Object.entries(texts)) { fs.writeFileSync(path.join(dir, f), t, { mode: 0o600 }); files[f] = sha(t); }
  const meta = { version: inst.version, key: keyFor(cfg, job, inst.version), branch: job.branch, round: job.round == null ? 1 : job.round, guides: inst.names, files };
  fs.writeFileSync(path.join(dir, 'snapshot.json'), JSON.stringify(meta, null, 1), { mode: 0o600 });
  return { meta, texts };
}
// What is wrong with a snapshot.json, or null: every field of the shape writeSnapshot writes, and a hash for exactly the core and its guides.
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
function metaProblem(meta) {
  if (!isObject(meta)) return 'is not an object';
  for (const k of ['version', 'key', 'branch']) if (typeof meta[k] !== 'string' || !meta[k]) return `has no ${k}`;
  if (!Array.isArray(meta.guides) || meta.guides.some((n) => typeof n !== 'string' || !/^[a-z0-9-]+$/.test(n)) || new Set(meta.guides).size !== meta.guides.length) return 'has a bad guide list';
  if (!isObject(meta.files)) return 'has no file hashes';
  const want = ['core.md', ...meta.guides.map((n) => `${n}.md`)].sort();
  const have = Object.keys(meta.files).sort();
  if (want.join('\n') !== have.join('\n')) return 'lists other files than its guides';
  if (have.some((f) => typeof meta.files[f] !== 'string' || !/^[0-9a-f]{64}$/.test(meta.files[f]))) return 'has a bad file hash';
  return null;
}
// The round's snapshot: { meta, texts }, { broken: why } (unreadable, incomplete or changed since it was written), or null (none yet).
function readSnapshot(cfg, job) {
  const dir = snapDir(cfg, job);
  if (!fs.existsSync(dir)) return null;
  let meta;
  try { meta = JSON.parse(fs.readFileSync(path.join(dir, 'snapshot.json'), 'utf8')); } catch { return { broken: 'snapshot.json unreadable' }; }
  const why = metaProblem(meta);
  if (why) return { broken: `snapshot.json ${why}` };
  const want = ['core.md', ...meta.guides.map((n) => `${n}.md`)];
  const texts = {};
  for (const f of want) {
    let t; try { t = fs.readFileSync(path.join(dir, f), 'utf8'); } catch { return { broken: `${f} missing` }; }
    if (sha(t) !== meta.files[f]) return { broken: `${f} changed` };
    texts[f] = t;
  }
  return { meta, texts };
}

// Put the snapshot's guides in <worktree>/.dm-guides/ exactly (never through a symlink); returns the guide files that were there but different.
function syncWorktree(wt, snap) {
  const dir = path.join(wt, GUIDE_DIR);
  let st = null; try { st = fs.lstatSync(dir); } catch { /* none */ }
  if (st && !st.isDirectory()) fs.rmSync(dir, { force: true });
  fs.mkdirSync(dir, { recursive: true });
  const want = new Set(snap.meta.guides.map((n) => `${n}.md`));
  const changed = [];
  for (const f of fs.readdirSync(dir)) if (!want.has(f)) { fs.rmSync(path.join(dir, f), { recursive: true, force: true }); changed.push(f); }
  for (const f of want) {
    const p = path.join(dir, f);
    let cur = null; try { const s = fs.lstatSync(p); if (s.isFile()) cur = fs.readFileSync(p, 'utf8'); else { fs.rmSync(p, { recursive: true, force: true }); cur = ''; } } catch { /* missing */ }
    if (cur === snap.texts[f]) continue;
    if (cur !== null) changed.push(f);
    fs.writeFileSync(p, snap.texts[f]);
  }
  return changed;
}

const NOTE_NEW = '(The runner\'s instructions changed since this conversation started: the how-tos for screenshots, short videos, pictures, models and ' +
  'sound are now guides in .dm-guides/, listed in your instructions. Read the one you need before you use it; do not rely on older text earlier in this conversation.)';
const NOTE_UPDATED = '(The runner\'s instructions, the guides in .dm-guides/ included, were updated since your last turn. Read again any guide you use; do not rely on an earlier copy.)';
const NOTE_RESTORED = (files) => `(.dm-guides/ had been changed (${files.join(', ')}); the runner put its own copies back. Never edit, add or delete files there.)`;

// Before a turn: -> { systemPrompt, note } or { error } (the turn must not run). No worktree: {} (runTurn reports that itself).
function prepareTurn(cfg, job, { audit } = {}) {
  const log = (e, f) => { if (audit) audit.log(e, { job: job.id, ...f }); };
  if (!job.worktree || !fs.existsSync(path.join(job.worktree, '.git'))) return {};
  const inst = readInstalled(cfg);
  if (inst.error) {
    log('guides-install-broken', { why: inst.error });
    return { error: `My instructions on the server are incomplete (${inst.error}), so I did not start. An admin needs to reinstall the agent (install-runner.sh); nothing was changed.` };
  }
  const notes = [];
  let snap = readSnapshot(cfg, job), fresh = false;
  // a snapshot is only for the install it was made from: its guides must be the ones the installed core names, in the same order
  if (snap && !snap.broken && snap.meta.key === keyFor(cfg, job, inst.version) && snap.meta.guides.join(',') !== inst.names.join(',')) snap = { broken: 'guide list differs from the install' };
  if (!snap || snap.broken || snap.meta.key !== keyFor(cfg, job, inst.version)) {
    const why = !snap ? 'none' : snap.broken ? `broken: ${snap.broken}` : snap.meta.branch !== job.branch ? 'new round' : 'install changed';
    snap = writeSnapshot(cfg, job, inst); fresh = true;
    log('guides-snapshot', { round: snap.meta.round, version: inst.version, why });
    // a conversation that carries on is told what changed under it: nothing when only a broken snapshot was remade the same
    if (job.sessionId && why !== 'new round') { if (!job.guidesKey) notes.push(NOTE_NEW); else if (job.guidesKey !== snap.meta.key) notes.push(NOTE_UPDATED); }
  }
  job.guidesKey = snap.meta.key;   // kept in jobs.json: which rendered version this job's conversation last saw
  // a worktree made before the guides existed has no exclude entry for them: the copies would show as untracked and fail the proposal's check
  let common = null;
  try { common = String(execFileSync('git', ['-C', job.worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { stdio: ['ignore', 'pipe', 'ignore'] })).trim(); } catch { /* not a repository */ }
  if (!common) return { error: 'I could not read this thread\'s workspace (its git folder), so I did not start. Send your message again and I will try once more; nothing was changed.' };
  const added = excludeJobFiles(common, [`${GUIDE_DIR}/`]);
  if (added.length) log('guides-excluded', { files: added.join(', ') });
  // copies that differ from a snapshot made this turn are simply older ones; from the snapshot in use they were changed in the worktree
  const changed = syncWorktree(job.worktree, snap);
  if (changed.length && !fresh) { log('guides-restored', { files: changed.join(', ') }); notes.push(NOTE_RESTORED(changed)); }
  return { systemPrompt: snap.texts['core.md'], note: notes.join('\n') };
}

module.exports = { GUIDE_DIR, indexedGuides, readInstalled, readSnapshot, prepareTurn, snapDir };
