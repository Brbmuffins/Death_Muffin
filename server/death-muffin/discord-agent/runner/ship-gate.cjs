'use strict';
// Called by ship.sh on the MERGED tree, under the deploy lock: re-derive the tier from what will actually go live and refuse if it
// exceeds what the approver may ship (or touches forbidden paths). Usage: ship-gate.cjs <config.json> <ship-worktree> <old-master-sha> <max-tier>
const { execFileSync } = require('child_process');
const { loadConfig } = require('./lib/config.cjs');
const { classifyDiff, RANK } = require('./lib/tiers.cjs');
const { scanDiffForSecrets } = require('./lib/gitops.cjs');
const [, , cfgFile, wt, oldMaster, maxTier] = process.argv;
const cfg = loadConfig(cfgFile);
const diff = execFileSync('git', ['diff', '-U0', '--no-color', '--no-renames', oldMaster, 'HEAD'], { cwd: wt, maxBuffer: 256 * 1024 * 1024 }).toString();
const c = classifyDiff(diff, cfg);
const secrets = scanDiffForSecrets(diff);
if (c.forbidden.length) { console.log(`GATE: forbidden paths: ${c.forbidden.join(', ')}`); process.exit(10); }
if (secrets.length) { console.log(`GATE: secret scan hit: ${secrets.map((s) => s.file).join(', ')}`); process.exit(11); }
if (RANK[c.tier] > RANK[maxTier]) { console.log(`GATE: change is ${c.tier}-tier but this approver may only ship ${maxTier}`); process.exit(12); }
console.log(`GATE: ok (${c.tier})`);
