'use strict';
const { execFile, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const { PATTERNS } = require('./redact.cjs');

function git(cwd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile('git', ['-c', 'core.hooksPath=/dev/null', ...args], {
      cwd, maxBuffer: 64 * 1024 * 1024, timeout: opts.timeout || 300000,
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_EDITOR: 'true' },
    }, (err, stdout, stderr) => {
      if (err && !opts.allowFail) { err.message = `git ${args[0]} failed: ${(stderr || err.message).slice(0, 400)}`; return reject(err); }
      resolve({ code: err ? err.code || 1 : 0, out: String(stdout), err: String(stderr) });
    });
  });
}
const trim = async (p) => (await p).out.trim();

async function createWorktree(cfg, job) {
  await git(cfg.repo, ['fetch', '-q', 'origin']);
  const wt = path.join(cfg.worktreeRoot, `discord-${job.id}`);
  await git(cfg.repo, ['worktree', 'add', '-q', '-b', job.branch, wt, 'origin/master']);
  for (const rel of ['node_modules', 'server/realtime/node_modules']) {
    const src = path.join(cfg.repo, rel);
    if (fs.existsSync(src)) { try { fs.symlinkSync(src, path.join(wt, rel)); } catch { /* exists */ } }
  }
  // keep the agent's result file and the symlinks out of `git status`
  const common = await trim(git(wt, ['rev-parse', '--path-format=absolute', '--git-common-dir']));
  const ex = path.join(common, 'info', 'exclude');
  try { fs.mkdirSync(path.dirname(ex), { recursive: true }); const cur = fs.existsSync(ex) ? fs.readFileSync(ex, 'utf8') : ''; const add = ['.dm-result.json', '.dm-shots/', '.dm-shot.json'].filter((p) => !cur.split('\n').includes(p)); if (add.length) fs.appendFileSync(ex, '\n' + add.join('\n') + '\n'); } catch { /* best effort */ }
  const base = await trim(git(wt, ['rev-parse', 'HEAD']));
  return { worktree: wt, base };
}
async function removeJobArtifacts(cfg, job, { remote = true } = {}) {
  if (job.worktree) await git(cfg.repo, ['worktree', 'remove', '--force', job.worktree], { allowFail: true });
  await git(cfg.repo, ['branch', '-q', '-D', job.branch], { allowFail: true });
  if (remote) await git(cfg.repo, ['push', '-q', 'origin', '--delete', job.branch], { allowFail: true });
  await git(cfg.repo, ['worktree', 'prune'], { allowFail: true });
}
const head = (wt) => trim(git(wt, ['rev-parse', 'HEAD']));
async function diffText(wt, base) { return (await git(wt, ['diff', '-U0', '--no-color', '--no-renames', base, 'HEAD'])).out; }
async function commitsSince(wt, base) { return (await git(wt, ['log', '--format=%H%x1f%s%x1f%B%x1e', `${base}..HEAD`])).out.split('\x1e').map((s) => s.trim()).filter(Boolean).map((r) => { const [sha, subject, body] = r.split('\x1f'); return { sha, subject, body: body || '' }; }); }
async function isDirty(wt) { return (await git(wt, ['status', '--porcelain'])).out.trim().length > 0; }
async function mergeInProgress(wt) { return (await git(wt, ['rev-parse', '-q', '--verify', 'MERGE_HEAD'], { allowFail: true })).code === 0; }

// Secret scan over ADDED lines only (plus a filename check). Returns [{file, why}].
function scanDiffForSecrets(diffTextStr) {
  const hits = []; let file = '';
  for (const line of diffTextStr.split('\n')) {
    if (line.startsWith('diff --git ')) { file = (/ b\/(.*)$/.exec(line) || [])[1] || ''; if (/(^|\/)\.env|\.pem$|\.key$|id_rsa|\.p12$|credentials|secrets?\.(json|ya?ml|txt)$|\.sql\.gz$|\.sqlite3?$/i.test(file)) hits.push({ file, why: 'secret-like filename' }); }
    else if (line.startsWith('+') && !line.startsWith('+++')) {
      const l = line.slice(1);
      if (PATTERNS.some((p) => p.test(l))) hits.push({ file, why: 'secret-like content' });
    }
  }
  const seen = new Set(); return hits.filter((h) => { const k = h.file + h.why; if (seen.has(k)) return false; seen.add(k); return true; });
}
// Non-blocking heads-up for the reviewer: added lines that can reach outside the game.
const SUSPICIOUS = [[/child_process|execSync|spawnSync|\bexec\(/, 'spawns processes'], [/\beval\(|new Function\(/, 'eval'], [/process\.env/, 'reads env'],
  [/https?:\/\/(?!muffindevelopment\.com|localhost|127\.0\.0\.1)[\w.-]+/i, 'external URL'], [/\bsudo\b|\brm\s+-rf\b/, 'sudo/rm -rf'], [/innerHTML\s*=/, 'innerHTML']];
function suspiciousFindings(diffTextStr) {
  const out = new Set(); let file = '';
  for (const line of diffTextStr.split('\n')) {
    if (line.startsWith('diff --git ')) file = (/ b\/(.*)$/.exec(line) || [])[1] || '';
    else if (line.startsWith('+') && !line.startsWith('+++')) for (const [re, why] of SUSPICIOUS) if (re.test(line)) out.add(`${file}: ${why}`);
  }
  return [...out].slice(0, 8);
}
const MIGRATION_RE = /^server\/death-muffin\/backend\/migrations\/([^/]+\.sql)$/;
function migrationsFrom(files) { return files.filter((f) => f.status === 'add' && MIGRATION_RE.test(f.path)).map((f) => MIGRATION_RE.exec(f.path)[1]); }

async function pushBranch(cfg, job) { await git(job.worktree, ['push', '-q', '--force', '-u', 'origin', `${job.branch}:refs/heads/${job.branch}`], { timeout: 180000 }); }
const compareUrl = (cfg, branch) => `https://github.com/${cfg.githubRepo}/compare/master...${branch}`;

// Run a command (no shell), capture combined output, kill the whole process group on timeout.
function run(cmd, args, { cwd, env, input, timeoutMs, maxOut = 8 * 1024 * 1024, onSpawn } = {}) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { cwd, env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    if (onSpawn) onSpawn(p);
    let out = '', err = '', done = false, timedOut = false;
    const kill = () => { try { process.kill(-p.pid, 'SIGKILL'); } catch { try { p.kill('SIGKILL'); } catch { /* gone */ } } };
    const t = timeoutMs ? setTimeout(() => { timedOut = true; kill(); }, timeoutMs) : null;
    p.stdout.on('data', (d) => { if (out.length < maxOut) out += d; });
    p.stderr.on('data', (d) => { if (err.length < maxOut) err += d; });
    p.on('error', (e) => { err += e.message; });
    p.on('close', (code, sig) => { if (done) return; done = true; if (t) clearTimeout(t); resolve({ code, signal: sig, out, err, timedOut }); });
    p.stdin.on('error', () => {});
    p.stdin.end(input || '');
  });
}
module.exports = { git, run, createWorktree, removeJobArtifacts, head, diffText, commitsSince, isDirty, mergeInProgress, scanDiffForSecrets, suspiciousFindings, migrationsFrom, pushBranch, compareUrl, trim };
