'use strict';
const fs = require('fs');
const path = require('path');
const { run } = require('./gitops.cjs');

function systemPrompt(cfg, job) {
  const promptFile = cfg.mode === 'godot' ? 'PROMPT-godot.md' : 'PROMPT.md';
  let sp = fs.readFileSync(path.join(cfg.toolsDir, promptFile), 'utf8').replaceAll('__BRANCH__', job.branch).replaceAll('__TOOLS__', cfg.toolsDir);
  if (cfg.webAnyHost) {
    sp = sp.replace(/WebFetch on documentation sites only \([^)]*\)\. Use it when/, 'WebFetch on any public web page. Use it for research (how other games handle\na mechanic, bug reports, engine issues, references someone mentions), when someone asks how an engine or library feature works, or');
  }
  return sp;
}
// Quote person text so it cannot close its own wrapper; label the role from CONFIG (never from the message).
function wrapRequest(m) {
  const safe = String(m.text || '').replace(/<\/?request[^>]*>/gi, '[request]');
  const name = String(m.name || 'someone').replace(/[^\w .-]/g, '').slice(0, 40);
  return `<request from="${name}" role="${m.role}">\n${safe}\n</request>`;
}
function buildPrompt(messages, extra) {
  return [...(extra ? [extra] : []), ...messages.map(wrapRequest)].join('\n\n');
}
const NO_WAIT = ['Bash(sleep *)', 'Bash(pgrep *)', 'Bash(pkill *)', 'Bash(ps *)', 'Bash(watch *)', 'Bash(timeout *)', 'Bash(wait *)'];
// The check scripts take 10-20 min. Claude Code's Bash tool stops a foreground command at 2 min (10 max) and pushes long ones into the
// background, which is how the agent ended up polling for check-godot.sh. Background tasks off + a Bash limit just above the scripts' own
// 40-minute hard limit, so the one allowed call simply blocks until the checks finish.
const BASH_LIMIT_MS = String(42 * 60000);
function agentEnv() {
  return { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8', TERM: 'dumb', NO_COLOR: '1',
    CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', BASH_DEFAULT_TIMEOUT_MS: BASH_LIMIT_MS, BASH_MAX_TIMEOUT_MS: BASH_LIMIT_MS };
}
function claudeArgs(cfg, job) {
  // The only programs the agent may run: agit, and the mode's own check script (+ regen.sh on the web side only: Godot mode has no
  // generated server bundles to rebuild; shot.sh on the web side, shot-godot.sh on the Godot side).
  const bash = cfg.mode === 'godot'
    ? [`Bash(${cfg.toolsDir}/agit *)`, `Bash(${cfg.toolsDir}/check-godot.sh)`, `Bash(${cfg.toolsDir}/shot-godot.sh)`, `Bash(${cfg.toolsDir}/shot-godot.sh *)`, `Bash(${cfg.toolsDir}/build-art.sh *)`]
    : [`Bash(${cfg.toolsDir}/agit *)`, `Bash(${cfg.toolsDir}/check.sh)`, `Bash(${cfg.toolsDir}/regen.sh)`, `Bash(${cfg.toolsDir}/shot.sh)`, `Bash(${cfg.toolsDir}/shot.sh *)`];
  // File tools are scoped to the worktree ("//" = absolute path): a bare "Read" grants every path on the machine (runner secret, /opt),
  // which matters more now that a WebFetch could carry what it read out. WebFetch is limited to documentation hosts (cfg.webDocDomains) unless the owner set cfg.webAnyHost.
  const wt = `/${job.worktree}/**`;
  const web = cfg.webAnyHost ? ['WebSearch', 'WebFetch'] : ['WebSearch', ...(cfg.webDocDomains || []).map((d) => `WebFetch(domain:${d})`)];
  const a = ['-p', '--restricted', '--strict-mcp-config', '--permission-mode', 'dontAsk', '--output-format', 'json',
    '--model', job.model, '--append-system-prompt', systemPrompt(cfg, job),
    '--tools', 'Read,Edit,Write,Glob,Grep,Bash,WebSearch,WebFetch',
    '--allowedTools', ...['Read', 'Edit', 'Write', 'Glob', 'Grep'].map((t) => `${t}(${wt})`), ...bash, ...web,
    // No waiting games: Claude Code auto-allows "read-only" commands, so a turn could build its own `until ! pgrep ...; do sleep 5; done`
    // poll loop (2026-10-08: pgrep -f matched the loop itself and job e4388b hung 35 min, blocking every other thread).
    '--disallowedTools', ...NO_WAIT];
  if (job.sessionId) a.push('--resume', job.sessionId);
  return a;
}
function parseClaudeJson(out) {
  const t = out.trim();
  try { return JSON.parse(t); } catch { /* maybe trailing logs */ }
  const i = t.lastIndexOf('\n{'); if (i >= 0) { try { return JSON.parse(t.slice(i + 1)); } catch { /* fallthrough */ } }
  return null;
}
// One turn. cfg.claudeCmd lets tests substitute a fake CLI. Returns { text, sessionId, costUsd, error, timedOut, cancelled }.
async function runTurn(cfg, job, prompt, { onSpawn } = {}) {
  // Never run without the job's own worktree: with no cwd the session would start wherever the runner lives (its tools, config, secret).
  if (!job.worktree || !fs.existsSync(path.join(job.worktree, '.git'))) return { text: '', sessionId: job.sessionId, error: 'This thread has no workspace right now; send your message again and I will start a fresh one.', timedOut: false };
  const cmd = cfg.claudeCmd || 'claude';
  const env = agentEnv();
  const r = await run(cmd, claudeArgs(cfg, job), { cwd: job.worktree, env, input: prompt, timeoutMs: cfg.turnTimeoutMin * 60000, onSpawn });
  const j = parseClaudeJson(r.out);
  if (!j) return { text: '', sessionId: job.sessionId, error: r.timedOut ? 'timeout' : (r.err || r.out || `exit ${r.code}`).slice(0, 300), timedOut: r.timedOut, signal: r.signal };
  return { text: String(j.result || ''), sessionId: j.session_id || job.sessionId, costUsd: j.total_cost_usd, error: j.is_error ? String(j.result || 'error').slice(0, 300) : null, timedOut: r.timedOut, signal: r.signal };
}
function readResult(wt) {
  const f = path.join(wt, '.dm-result.json');
  try { const j = JSON.parse(fs.readFileSync(f, 'utf8')); fs.unlinkSync(f); return j && typeof j === 'object' ? j : null; } catch { return null; }
}
module.exports = { runTurn, claudeArgs, agentEnv, buildPrompt, wrapRequest, readResult, systemPrompt };
