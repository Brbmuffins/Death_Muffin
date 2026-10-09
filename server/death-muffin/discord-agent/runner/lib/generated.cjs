'use strict';
// Derived ("generated") files: server bundles built from src/, and the loot doc.
// They sit under server/** (sensitive), so by path alone any data change would escalate.
// Instead they are treated as tier-neutral ONLY when they are exactly what the generators produce from the committed sources.
// That is proven here by deterministic code: re-run regen.sh (same sandbox as check.sh) in a scratch worktree of the commit and
// require a clean `git status` for every generated file the change touches. The model never decides this.
const fs = require('fs');
const path = require('path');
const { run } = require('./gitops.cjs');

const GENERATED = [
  'server/vps-handoff/necro-progress/necro-rules.cjs',
  ...['gathering', 'garden', 'cosmetic', 'labor', 'contract', 'salvage', 'affix', 'authority', 'kill', 'vault', 'legion', 'gold-sink', 'rune', 'loadout']
    .map((n) => `server/death-muffin/backend/gathering/${n}-rules.cjs`),
  'docs/LOOT-TABLES.md',
];
// Files that are edited in place by a generator rather than fully produced: reset to the BASE version (not deleted) before regen,
// so hand edits outside the generated regions cannot ride along as "derived".
const PATCHED = [];

const git = (cwd, args, o) => run('git', ['-c', 'core.hooksPath=/dev/null', ...args], { cwd, timeoutMs: 120000, env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8' }, ...o });

// -> { derived: [paths verified as exactly regenerated], mismatched: [paths that differ], error?: string }
async function verifyGenerated({ toolsDir, repo, scratchRoot, base, head, changedPaths }) {
  const cand = changedPaths.filter((p) => GENERATED.includes(p));
  if (!cand.length) return { derived: [], mismatched: [] };
  const sw = path.join(scratchRoot, `gen-${process.pid}-${Date.now().toString(36)}`);
  try {
    const add = await git(repo, ['worktree', 'add', '-q', '--detach', sw, head]);
    if (add.code !== 0) return { derived: [], mismatched: cand, error: `scratch worktree failed: ${add.err.slice(0, 200)}` };
    for (const rel of ['node_modules']) {
      const src = path.join(repo, rel);
      if (fs.existsSync(src)) { try { fs.symlinkSync(src, path.join(sw, rel)); } catch { /* exists */ } }
    }
    for (const p of cand) {
      const f = path.join(sw, p);
      if (PATCHED.includes(p)) {
        const b = await git(repo, ['show', `${base}:${p}`]);
        if (b.code !== 0) return { derived: [], mismatched: [p], error: `no base version of ${p}` };
        fs.writeFileSync(f, b.out);
      } else fs.rmSync(f, { force: true });
    }
    const r = await run(path.join(toolsDir, 'regen.sh'), [], { cwd: sw, env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8' }, timeoutMs: 10 * 60000 });
    if (r.code !== 0 || r.timedOut) return { derived: [], mismatched: cand, error: `regen.sh failed: ${(r.out + r.err).trim().split('\n').slice(-5).join(' | ').slice(0, 300)}` };
    const st = await git(sw, ['--no-optional-locks', 'status', '--porcelain', '--', ...cand]);
    const bad = new Set(st.out.split('\n').filter(Boolean).map((l) => l.slice(3).replace(/^"|"$/g, '')));
    return { derived: cand.filter((p) => !bad.has(p)), mismatched: cand.filter((p) => bad.has(p)) };
  } finally {
    await git(repo, ['worktree', 'remove', '--force', sw]);
    fs.rmSync(sw, { recursive: true, force: true });
    await git(repo, ['worktree', 'prune']);
  }
}
const describeMismatch = (m) => `These generated files are not what the generators produce from the committed sources: ${m.mismatched.join(', ')}${m.error ? ` (${m.error})` : ''}. Run regen.sh and commit exactly its output; do not edit generated files by hand.`;
module.exports = { GENERATED, PATCHED, verifyGenerated, describeMismatch };
