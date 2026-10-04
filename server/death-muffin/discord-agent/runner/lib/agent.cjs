'use strict';
const fs = require('fs');
const path = require('path');
const { run } = require('./gitops.cjs');

function systemPrompt(cfg, job) {
  return fs.readFileSync(path.join(cfg.toolsDir, 'PROMPT.md'), 'utf8').replaceAll('__BRANCH__', job.branch).replaceAll('__TOOLS__', cfg.toolsDir);
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
function claudeArgs(cfg, job) {
  const a = ['-p', '--restricted', '--strict-mcp-config', '--permission-mode', 'dontAsk', '--output-format', 'json',
    '--model', job.model, '--append-system-prompt', systemPrompt(cfg, job),
    '--tools', 'Read,Edit,Write,Glob,Grep,Bash',
    '--allowedTools', 'Read', 'Edit', 'Write', 'Glob', 'Grep', `Bash(${cfg.toolsDir}/agit *)`, `Bash(${cfg.toolsDir}/check.sh)`, `Bash(${cfg.toolsDir}/shot.sh)`, `Bash(${cfg.toolsDir}/shot.sh *)`,
    '--disallowedTools', 'WebFetch', 'WebSearch'];
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
  const cmd = cfg.claudeCmd || 'claude';
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8', TERM: 'dumb', NO_COLOR: '1' };
  const r = await run(cmd, claudeArgs(cfg, job), { cwd: job.worktree, env, input: prompt, timeoutMs: cfg.turnTimeoutMin * 60000, onSpawn });
  const j = parseClaudeJson(r.out);
  if (!j) return { text: '', sessionId: job.sessionId, error: r.timedOut ? 'timeout' : (r.err || r.out || `exit ${r.code}`).slice(0, 300), timedOut: r.timedOut, signal: r.signal };
  return { text: String(j.result || ''), sessionId: j.session_id || job.sessionId, costUsd: j.total_cost_usd, error: j.is_error ? String(j.result || 'error').slice(0, 300) : null, timedOut: r.timedOut, signal: r.signal };
}
function readResult(wt) {
  const f = path.join(wt, '.dm-result.json');
  try { const j = JSON.parse(fs.readFileSync(f, 'utf8')); fs.unlinkSync(f); return j && typeof j === 'object' ? j : null; } catch { return null; }
}
module.exports = { runTurn, claudeArgs, buildPrompt, wrapRequest, readResult, systemPrompt };
