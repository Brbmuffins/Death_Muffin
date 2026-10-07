'use strict';
// Called by ship.sh on the MERGED tree, under the deploy lock: re-derive the tier from what will actually go live and refuse if it
// exceeds what the approver may ship (or touches forbidden paths). Usage: ship-gate.cjs <config.json> <ship-worktree> <old-base-sha> <max-tier>
const { execFileSync } = require('child_process');
const { loadConfig } = require('./lib/config.cjs');
const { classifyDiff, RANK } = require('./lib/tiers.cjs');
const { scanDiffForSecrets } = require('./lib/gitops.cjs');
const { verifyGenerated } = require('./lib/generated.cjs');
const { parseDiff } = require('./lib/tiers.cjs');
const [, , cfgFile, wt, oldMaster, maxTier] = process.argv;
const cfg = loadConfig(cfgFile);
const diff = execFileSync('git', ['diff', '-U0', '--no-color', '--no-renames', oldMaster, 'HEAD'], { cwd: wt, maxBuffer: 256 * 1024 * 1024 }).toString();
(async () => {
const files = parseDiff(diff);
// Generated files count as derived (tier-neutral) only if a fresh sandboxed regeneration reproduces them exactly.
const g = cfg.mode === 'godot' ? { derived: [], mismatched: [] } : await verifyGenerated({   // godot mode has no tier-neutral generated files (same rule as the runner's verify)
   toolsDir: cfg.toolsDir, repo: cfg.repo, scratchRoot: cfg.worktreeRoot, base: oldMaster, head: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: wt }).toString().trim(), changedPaths: files.map((f) => f.path) });
if (g.mismatched.length) { console.log(`GATE: generated files do not match a fresh regeneration: ${g.mismatched.join(', ')}${g.error ? ` (${g.error})` : ''}`); process.exit(13); }
const c = classifyDiff(files, cfg, g.derived);
const secrets = scanDiffForSecrets(diff);
if (c.forbidden.length) { console.log(`GATE: forbidden paths: ${c.forbidden.join(', ')}`); process.exit(10); }
if (secrets.length) { console.log(`GATE: secret scan hit: ${secrets.map((s) => s.file).join(', ')}`); process.exit(11); }
if (RANK[c.tier] > RANK[maxTier]) { console.log(`GATE: change is ${c.tier}-tier but this approver may only ship ${maxTier}`); process.exit(12); }
console.log(`GATE: ok (${c.tier})`);
})().catch((e) => { console.log(`GATE: error ${e.message}`); process.exit(14); });
