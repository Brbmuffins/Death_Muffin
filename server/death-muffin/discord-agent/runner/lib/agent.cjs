'use strict';
const fs = require('fs');
const path = require('path');
const { run } = require('./gitops.cjs');

// The placeholders of the core prompt and the guides (lib/guides.cjs renders both the same way).
function renderText(cfg, job, text) {
  return String(text).replaceAll('__BRANCH__', job.branch).replaceAll('__TOOLS__', cfg.toolsDir).replaceAll('__BASE__', cfg.baseBranch || 'main');
}
function renderCore(cfg, job, text) {
  let sp = renderText(cfg, job, text);
  if (cfg.webAnyHost) {
    sp = sp.replace(/WebFetch on documentation sites only \([^)]*\)\. Use it when/, 'WebFetch on any public web page. Use it for research (how other games handle\na mechanic, bug reports, engine issues, references someone mentions), when someone asks how an engine or library feature works, or');
  }
  return sp;
}
// The installed core, rendered. A turn uses its round's snapshot instead (lib/guides.cjs prepareTurn), passed in as opts.systemPrompt.
function systemPrompt(cfg, job) {
  return renderCore(cfg, job, fs.readFileSync(path.join(cfg.toolsDir, 'PROMPT-godot.md'), 'utf8'));
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
const BASH_LIMIT_MS = String(55 * 60000);
function agentEnv() {
  return { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8', TERM: 'dumb', NO_COLOR: '1',
    CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', BASH_DEFAULT_TIMEOUT_MS: BASH_LIMIT_MS, BASH_MAX_TIMEOUT_MS: BASH_LIMIT_MS };
}
// A discussion post (core.cjs job.talk): the team talks ideas, lore and class kits with the agent, which reads the game but changes nothing.
const TALK_PROMPT = `

## This thread is a discussion post, not a job

You are in one of the team's discussion forums (#classes, #features or #lore), talking with the team. Here you can read the game (Read, Glob,
Grep) and the web, but you cannot change anything: no edits, commits, proposals, models, concept pictures or sounds, and the instructions
above about making and proposing changes and their pictures do not apply. Help the way the team's senior game designer would: answer from the game as it is now
(read the code and data, never guess), brainstorm and flesh out ideas, write lore, sketch class kits, and say plainly when an idea would hurt
the game. Talk like a teammate: short replies unless someone asks for depth, no headings for a one-line answer. When the team wants something
built, tell them to type \`!job\` here (it opens a #jobs post from this discussion) and to mention you in that post.

Messages the team says to each other here do not start a turn; you get them with the next message for you, marked as not said to you.

### Pictures of the live game

When a note in square brackets says a team PC is on, you can show the game as players have it now: screenshots of the LIVE version, on the
offline demo character, rendered by a team PC (never a change, never your workspace). Use it when someone asks to see something or when a
picture settles a question about how something looks; not for every reply. Read \`.dm-guides/screenshots.md\` for the plan's fields (the plan
format; \`before\` does not apply here and you run nothing), then end your reply with the plan in a fenced block marked dm-shot:

\`\`\`dm-shot
{"shots": [{"name": "warren-gate", "view": "game", "area": "graves"}]}
\`\`\`

At most 4 shots. The runner takes the block out of your reply, says in the thread that the pictures are coming (so never promise them
yourself) and posts them when the team PC is done, after a short check of yours has looked at them (it may retake them once). Your workspace is the latest main, which can be a little ahead of the
live game, so plan only for what players already have. Concept pictures (new art ideas) are not made here: they need a #jobs post (\`!job\`).`;
function claudeArgs(cfg, job, { maxTurns, systemPrompt: sp } = {}) {
  // The only programs the agent may run, all in the sandbox: agit, check-godot.sh only with --rerun and the suites it names (the whole check is
  // the runner's, through CI), regen-godot.sh for generated files (B65), the screenshot, model, sound and picture build scripts (pictures: B70) and Blender jobs (B74).
  const bash = [`Bash(${cfg.toolsDir}/agit *)`, `Bash(${cfg.toolsDir}/check-godot.sh --rerun *)`, `Bash(${cfg.toolsDir}/regen-godot.sh)`, `Bash(${cfg.toolsDir}/shot-godot.sh)`, `Bash(${cfg.toolsDir}/shot-godot.sh *)`, `Bash(${cfg.toolsDir}/build-art.sh *)`, `Bash(${cfg.toolsDir}/render-model.sh *)`, `Bash(${cfg.toolsDir}/make-model.sh *)`, `Bash(${cfg.toolsDir}/build-sound.sh *)`, `Bash(${cfg.toolsDir}/build-picture.sh *)`, `Bash(${cfg.toolsDir}/blender-job.sh)`];
  // File tools are scoped to the worktree ("//" = absolute path): a bare "Read" grants every path on the machine (runner secret, /opt),
  // which matters more now that a WebFetch could carry what it read out. WebFetch is limited to documentation hosts (cfg.webDocDomains) unless the owner set cfg.webAnyHost.
  const wt = `/${job.worktree}/**`;
  const web = cfg.webAnyHost ? ['WebSearch', 'WebFetch'] : ['WebSearch', ...(cfg.webDocDomains || []).map((d) => `WebFetch(domain:${d})`)];
  // A discussion post gets read-only tools: no Edit, Write or Bash at all, so nothing can be changed, committed, rendered or bought from there.
  const files = job.talk ? ['Read', 'Glob', 'Grep'] : ['Read', 'Edit', 'Write', 'Glob', 'Grep'];
  const a = ['-p', '--restricted', '--strict-mcp-config', '--permission-mode', 'dontAsk', '--output-format', 'json',
    '--model', job.model, '--append-system-prompt', (sp || systemPrompt(cfg, job)) + (job.talk ? TALK_PROMPT : ''),
    '--tools', [...files, ...(job.talk ? [] : ['Bash']), 'WebSearch', 'WebFetch'].join(','),
    '--allowedTools', ...files.map((t) => `${t}(${wt})`), ...(job.talk ? [] : bash), ...web,
    // No waiting games: Claude Code auto-allows "read-only" commands, so a turn could build its own `until ! pgrep ...; do sleep 5; done`
    // poll loop (2026-10-08: pgrep -f matched the loop itself and job e4388b hung 35 min, blocking every other thread).
    '--disallowedTools', ...NO_WAIT];
  // Step budget per session (cfg.handoffEveryTurns, default 40): a session re-reads its whole conversation on every step, so a long one gets
  // slower and costs roughly steps x context (2026-10-11: one 176-step session was a third of three days' spend). At the limit the runner has
  // the agent write a handoff note and continues in a fresh session (core.cjs agentTurn). 0 = no limit.
  const mt = maxTurns != null ? maxTurns : (cfg.handoffEveryTurns != null ? cfg.handoffEveryTurns : 40);
  if (mt > 0) a.push('--max-turns', String(mt));
  if (job.sessionId) a.push('--resume', job.sessionId);
  return a;
}
function parseClaudeJson(out) {
  const t = out.trim();
  try { return JSON.parse(t); } catch { /* maybe trailing logs */ }
  const i = t.lastIndexOf('\n{'); if (i >= 0) { try { return JSON.parse(t.slice(i + 1)); } catch { /* fallthrough */ } }
  return null;
}
// One turn. cfg.claudeCmd lets tests substitute a fake CLI. systemPrompt: the round's snapshot of the core (else the installed core). Returns { text, sessionId, costUsd, error, timedOut, cancelled, maxTurns }.
// maxTurns: the session stopped at its step budget (not an error; the caller hands off to a fresh session).
async function runTurn(cfg, job, prompt, { onSpawn, maxTurns, systemPrompt: sp } = {}) {
  // Never run without the job's own worktree: with no cwd the session would start wherever the runner lives (its tools, config, secret).
  if (!job.worktree || !fs.existsSync(path.join(job.worktree, '.git'))) return { text: '', sessionId: job.sessionId, error: 'This thread has no workspace right now; send your message again and I will start a fresh one.', timedOut: false };
  const cmd = cfg.claudeCmd || 'claude';
  const env = agentEnv();
  const r = await run(cmd, claudeArgs(cfg, job, { maxTurns, systemPrompt: sp }), { cwd: job.worktree, env, input: prompt, timeoutMs: cfg.turnTimeoutMin * 60000, onSpawn });
  const j = parseClaudeJson(r.out);
  if (!j) return { text: '', sessionId: job.sessionId, error: r.timedOut ? 'timeout' : (r.err || r.out || `exit ${r.code}`).slice(0, 300), timedOut: r.timedOut, signal: r.signal };
  const atLimit = j.subtype === 'error_max_turns';
  return { text: String(j.result || ''), sessionId: j.session_id || job.sessionId, costUsd: j.total_cost_usd, error: j.is_error && !atLimit ? String(j.result || 'error').slice(0, 300) : null, timedOut: r.timedOut, signal: r.signal, maxTurns: atLimit };
}
// The note the agent writes when its session hits the step budget (.dm-handoff.md, removed once read). null = none written.
function readHandoff(wt) {
  const f = path.join(wt, '.dm-handoff.md');
  try { const t = fs.readFileSync(f, 'utf8'); fs.unlinkSync(f); return t.trim() ? t.trim().slice(0, 12000) : null; } catch { return null; }
}
function readResult(wt) {
  const f = path.join(wt, '.dm-result.json');
  try { const j = JSON.parse(fs.readFileSync(f, 'utf8')); fs.unlinkSync(f); return j && typeof j === 'object' ? j : null; } catch { return null; }
}
module.exports = { runTurn, claudeArgs, agentEnv, buildPrompt, wrapRequest, readResult, readHandoff, systemPrompt, renderCore, renderText };
