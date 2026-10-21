#!/usr/bin/env node
// Writes a context baseline (tools/context/README.md): the rule text sizes and inventory check of this checkout, and the usage of two
// windows from the transcripts on this machine, tokens only (no dollars, no paths outside the repo).
//
//   node tools/context/make-baseline.mjs <out.json> --label <rev> --window <since>..<until> --agent-window <since>..<until> [--dir <projects dir>]

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { sizes, checkRules } from './measure.mjs';
import { collect, report } from './usage.mjs';

const argv = process.argv.slice(2);
const out = argv[0];
const opt = (name) => { const i = argv.indexOf(name); return i > 0 ? argv[i + 1] : null; };
const range = (r) => { const m = /^(\d{4}-\d{2}-\d{2})\.\.(\d{4}-\d{2}-\d{2})$/.exec(r || ''); if (!m) { console.error(`expected <since>..<until>, got ${r}`); process.exit(2); } return { since: m[1], until: m[2] }; };
if (!out || !opt('--label')) { console.error('usage: make-baseline.mjs <out.json> --label <rev> --window <since>..<until> --agent-window <since>..<until>'); process.exit(2); }
const dir = opt('--dir') || path.join(os.homedir(), '.claude', 'projects');
const everyone = range(opt('--window'));
const agent = range(opt('--agent-window'));
const usage = (w, who) => { const r = report(collect({ dir, ...w, who }), { top: 15, tokensOnly: true }); delete r.generated; r.window = { ...w, ends: 'UTC dates, both included', counted: 'calls and tool results by their own timestamps' }; return r; };

const baseline = {
  about: `Context baseline before any change to how rules are loaded (tools/context/README.md). static: measure.mjs at ${opt('--label')}. usage: usage.mjs --tokens-only over the Claude Code transcripts on the VPS; "everyone" = every audience ${everyone.since}..${everyone.until}, "agent" = the Discord agent ${agent.since}..${agent.until}. Remade by: node tools/context/make-baseline.mjs ${out} --label ${opt('--label')} --window ${everyone.since}..${everyone.until} --agent-window ${agent.since}..${agent.until}`,
  static: { sizes: sizes(), rules: checkRules() },
  usage: { everyone: usage(everyone, 'all'), agent: usage(agent, 'agent') },
};
fs.writeFileSync(out, JSON.stringify(baseline, null, 1) + '\n');
console.log(`wrote ${out}`);
