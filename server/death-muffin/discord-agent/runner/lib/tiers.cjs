'use strict';
const { matches, matchesAny } = require('./glob.cjs');

const RANK = { casual: 0, gameplay: 1, sensitive: 2 };

// Parse `git diff -U0 --no-color --no-renames` into [{ path, status: 'add'|'delete'|'modify', binary, hunks: [{removed, added}] }].
function parseDiff(text) {
  const files = []; let cur = null; let hunk = null;
  for (const line of text.split('\n')) {
    if (line.startsWith('diff --git ')) {
      const m = /^diff --git a\/(.*) b\/(.*)$/.exec(line);
      cur = { path: m ? m[2] : line.slice(11), status: 'modify', binary: false, hunks: [] }; files.push(cur); hunk = null;
    } else if (!cur) continue;
    else if (line.startsWith('new file mode')) cur.status = 'add';
    else if (line.startsWith('deleted file mode')) cur.status = 'delete';
    else if (line.startsWith('Binary files') || line.startsWith('GIT binary patch')) cur.binary = true;
    else if (line.startsWith('@@')) { hunk = { removed: [], added: [] }; cur.hunks.push(hunk); }
    else if (hunk && line.startsWith('-') && !line.startsWith('---')) hunk.removed.push(line.slice(1));
    else if (hunk && line.startsWith('+') && !line.startsWith('+++')) hunk.added.push(line.slice(1));
  }
  return files;
}

// casual: documents and patch notes, any content; never a binary file or a change of mode only
function classifyFile(file, cfg) {
  const t = cfg.tiers;
  if (matchesAny(t.sensitive, file.path)) return 'sensitive';
  if (matchesAny(t.casual || [], file.path) && !file.binary && !(file.hunks.length === 0 && file.status === 'modify')) return 'casual';
  if (matchesAny(t.gameplay, file.path)) return 'gameplay';
  return 'sensitive';
}

// -> { tier, perFile: [{path, tier}], forbidden: [paths] }. The diff's tier is its strictest file's; an empty diff has nothing to judge -> sensitive.
function classifyDiff(diffText, cfg) {
  const files = Array.isArray(diffText) ? diffText : parseDiff(diffText);
  const perFile = files.map((f) => ({ path: f.path, tier: classifyFile(f, cfg) }));
  let tier = 'casual';
  for (const f of perFile) if (RANK[f.tier] > RANK[tier]) tier = f.tier;
  if (!perFile.length) tier = 'sensitive';   // nothing to judge -> never casual
  const forbidden = files.filter((f) => matchesAny(cfg.forbiddenPaths || [], f.path)).map((f) => f.path);
  return { tier, perFile, forbidden };
}

// Who may ✅ a proposal of this tier (per-project config; the owner is always included by loadConfig).
function approversFor(tier, cfg) { return [...(cfg.project.approvers[tier] || [])]; }
function tierLabel(tier, cfg) {
  const nm = (id) => (cfg.ownerIds.includes(id) ? 'owner' : (cfg.names && cfg.names[id]) || `user ${String(id).slice(-4)}`);
  const who = [...new Set(approversFor(tier, cfg).map(nm))].sort((a, b) => (a === 'owner') - (b === 'owner'));
  const head = { casual: 'Casual', gameplay: 'Gameplay', sensitive: '⚠ Sensitive' }[tier];
  return `${head} — ${who.join(' or ')} can ✅`;
}
module.exports = { parseDiff, classifyDiff, classifyFile, approversFor, tierLabel, RANK };
