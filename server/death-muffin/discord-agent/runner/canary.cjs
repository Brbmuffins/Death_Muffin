#!/usr/bin/env node
'use strict';
// The agent's practice run (Helix, 2026-10-19: so the next big change or reinstall cannot break the agent unnoticed). Run it after every
// install-runner.sh and after a test build goes live, before the agent takes requests:   node ~/death-muffin/discord-agent/runner/canary.cjs
// It drives the INSTALLED runner and the LIVE Discord adapter (/opt/muffin/discord/dm-agent.js) through a whole proposal on the real repo, with a
// fake Discord (nothing is posted anywhere) and a stand-in for `claude` that makes one harmless commit (no AI, no cost):
//   installed copies = main · request -> thread -> worktree off main -> the change -> gates -> branch pushed -> proposal (a draft: ✅ 🧪 ❌)
//   · the agent's own check in its sandbox (check-godot.sh --rerun code_load: the shared setup, prep.sh, the sandbox, hygiene, one suite)
//   · 🧪 -> GitHub CI on the branch (every suite) -> "Tests passed" · !discard -> branch, worktree and preview gone. It never ships.
// One line per step ("CANARY <step> ok <s>s" / "CANARY <step> FAILED ..."), then "CANARY PASSED" (exit 0) or "CANARY FAILED: <step>" (exit 1).
// Refuses while the live agent is working or shipping (--force skips that). Options: --config <file>, --adapter <file>, --skip-ci, --keep, and
// --rev <rev> (what the installed copies must match, default origin/main: a trial install of a branch, DEST=<dir> install-runner.sh <rev>).
const fs = require('fs'), os = require('os'), path = require('path'), { EventEmitter } = require('events'), { execFileSync, spawnSync } = require('child_process');
const { createRunner } = require('./core.cjs');
const { loadConfig } = require('./lib/config.cjs');

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const TOOLS = path.resolve(__dirname, '..');
const cfgFile = opt('--config', path.join(TOOLS, 'config.json'));
const adapterFile = opt('--adapter', '/opt/muffin/discord/dm-agent.js');
const skipCi = args.includes('--skip-ci'), keep = args.includes('--keep'), force = args.includes('--force'), REV = opt('--rev', 'origin/main');
const t0 = Date.now(); let stepAt = Date.now();
const line = (s) => process.stdout.write(s + '\n');
const ok = (step, detail = '') => { line(`CANARY ${step} ok ${Math.round((Date.now() - stepAt) / 1000)}s${detail ? ` · ${detail}` : ''}`); stepAt = Date.now(); };
class Failed extends Error { constructor(step, why) { super(why); this.step = step; } }
const fail = (step, why) => { throw new Failed(step, why); };
const git = (cwd, ...a) => execFileSync('git', ['-c', 'core.hooksPath=/dev/null', ...a], { cwd, stdio: 'pipe', encoding: 'utf8' }).trim();

// The files install-runner.sh copies, with where they come from in the repo (installed path -> repo path).
function installedPairs(repo) {
  const SRC = 'server/death-muffin/discord-agent';
  const runner = git(repo, 'ls-tree', '-r', '--name-only', REV, '--', `${SRC}/runner`).split('\n').filter(Boolean).map((f) => [f.slice(SRC.length + 1), f]);
  const scripts = ['ship.sh', 'rollback.sh', 'sandbox-lib.sh', 'check-godot.sh', 'shot-godot.sh', 'preview-godot.sh', 'PROMPT-godot.md', 'agit'].map((f) => [f, `${SRC}/${f}`]);
  return [...runner, ...scripts, ['prep.sh', 'tools/check/prep.sh'], ['ci.sh', 'tools/check/ci.sh']];
}

// ---- a fake Discord for the live adapter (the shape discord.js gives it) ----
class Chan extends EventEmitter {
  constructor(world, id, o = {}) { super(); this.world = world; this.id = id; this.sent = []; this.thread = !!o.thread; this.parentId = o.parentId || null; world.chans.set(id, this); }
  isThread() { return this.thread; }
  async setName(n) { this.name = n; return this; }
  async setArchived(a) { this.archived = a; return this; }
  async sendTyping() {}
  async send(p) { const m = new Msg(this.world, this, this.world.botId, p.content || '', true); m.payload = p; this.sent.push(m); return m; }
}
class Msg {
  constructor(world, channel, authorId, content, bot = false) {
    this.world = world; this.id = String(world.nextId++); this.channel = channel; this.guild = { id: world.guildId }; this.author = bot ? { id: world.botId, bot: true } : { id: authorId, bot: false, username: 'canary' };
    this.content = content; this.reactions = []; this.attachments = new Map(); this.replies = [];
    this.mentions = { users: { has: (id) => this.content.includes(`<@${id}>`) } };
  }
  async reply(p) { this.replies.push(p); return p; }
  async react(e) { this.reactions.push(e); }
  async startThread({ name }) { const t = new Chan(this.world, 'canary-' + this.id, { thread: true, parentId: this.channel.id }); t.name = name; this.world.threads.push(t); return t; }
}

async function main() {
  const live = loadConfig(cfgFile);
  if (live.mode !== 'godot') fail('config', `the agent is in ${live.mode} mode, not godot`);
  const repo = live.repo;
  git(repo, 'fetch', '-q', 'origin');
  // 1. installed copies = main (a stale install is what a promotion leaves behind)
  const stale = installedPairs(repo).filter(([inst, src]) => {
    let want; try { want = execFileSync('git', ['-C', repo, 'show', `${REV}:${src}`]); } catch { return false; }
    try { return !fs.readFileSync(path.join(TOOLS, inst)).equals(want); } catch { return true; }
  }).map(([inst]) => inst);
  if (stale.length) fail('installed', `differs from ${REV}: ${stale.slice(0, 8).join(', ')}${stale.length > 8 ? ` and ${stale.length - 8} more` : ''}. Reinstall: bash server/death-muffin/discord-agent/install-runner.sh ${REV}`);
  ok('installed', `runner and scripts match ${REV} ${git(repo, 'rev-parse', '--short', REV)}`);
  // 2. the live agent is idle (a practice run beside a real job would share the job slots' CPU, and never beside a ship)
  // (by its processes: jobs.json is only written when a job changes, so after a restart it can still say "running" for a job that is idle)
  if (!force) {
    const busy = new Set();
    for (const pid of fs.readdirSync('/proc').filter((x) => /^\d+$/.test(x))) {
      let cwd = ''; try { cwd = fs.readlinkSync(`/proc/${pid}/cwd`); } catch { continue; }
      const m = cwd.startsWith(live.worktreeRoot + '/') && /^(discord|ship|base|basecheck|preview)-([^/]+)/.exec(cwd.slice(live.worktreeRoot.length + 1));
      if (m) busy.add(m[0]);
    }
    if (fs.existsSync(path.join(live.stateDir, 'ship-active'))) busy.add('a ship');
    if (busy.size) fail('idle', `the live agent is working (${[...busy].join(', ')}); try again when it is idle, or --force`);
  }
  ok('idle');

  // A runner of its own: the installed code and config, its own state folder, no team PCs, and a stand-in for claude.
  const T = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-canary-'));
  const stamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15);
  const fake = path.join(T, 'fake-claude.cjs');
  fs.writeFileSync(fake, `#!/usr/bin/env node
'use strict';
// canary stand-in for claude -p: the practice request gets one harmless commit (a comment in a test file); anything else changes nothing
const fs = require('fs'), { execFileSync } = require('child_process');
let p = ''; process.stdin.on('data', (d) => { p += d; }).on('end', () => {
  let text = 'Nothing to do.';
  if (/CANARY-PRACTICE/.test(p)) {
    const f = 'client/tests/code_load.gd';
    fs.appendFileSync(f, '# practice run ${stamp} of the Discord agent (runner/canary.cjs); never shipped\\n');
    execFileSync('git', ['-c', 'core.hooksPath=/dev/null', 'add', '--', f]);
    execFileSync('git', ['-c', 'core.hooksPath=/dev/null', 'commit', '-q', '-m', 'Practice run of the Discord agent (never shipped)']);
    fs.writeFileSync('.dm-result.json', JSON.stringify({ status: 'ready', title: 'Practice run', summary: ['A comment in a test file, to prove the agent end to end'], testing: 'canary', risk: 'none' }));
    text = 'Practice change made.';
  }
  process.stdout.write(JSON.stringify({ type: 'result', result: text, session_id: 'canary', is_error: false, total_cost_usd: 0 }));
});
`, { mode: 0o755 });
  const cf = path.join(T, 'config.json');
  const raw = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
  fs.writeFileSync(cf, JSON.stringify({ ...raw, stateDir: path.join(T, 'state'), toolsDir: TOOLS, claudeCmd: fake, teamApi: '', bugChannelId: '', previewOnProposal: false }));
  fs.mkdirSync(path.join(T, 'state'), { recursive: true });
  const cfg = loadConfig(cf); cfg.__file = cf;
  const runner = createRunner(cfg);
  const { createAdapter } = require(adapterFile);
  const world = { chans: new Map(), threads: [], nextId: 1, botId: '900000000000000009', guildId: String(cfg.guildId || '1') };
  const client = new EventEmitter(); client.user = { id: world.botId }; client.channels = { fetch: async (id) => world.chans.get(String(id)) };
  const chan = new Chan(world, String(cfg.channelId));
  const fetchImpl = async (url, init = {}) => {
    const u = new URL(url); const body = init.body ? JSON.parse(init.body) : undefined; let out;
    if (u.pathname === '/config') out = { channelId: cfg.channelId, bugChannelId: '' };
    else if (u.pathname === '/poll') out = { ops: await runner.poll(0) };
    else if (u.pathname === '/event') out = await runner.handleEvent(body);
    else if (u.pathname === '/bind') out = await runner.bind(body);
    else if (u.pathname === '/ack') { runner.ack(body.id, body.result); out = { ok: true }; }
    return { ok: true, status: 200, json: async () => JSON.parse(JSON.stringify(out || {})) };
  };
  const ad = createAdapter({ client, runnerUrl: 'http://canary', secret: 'canary', fetchImpl, pollWaitSec: 0, log: () => {} });
  const owner = String(cfg.ownerIds[0]);
  const until = async (step, fn, ms) => {
    const end = Date.now() + ms;
    while (Date.now() < end) { await ad.pollOnce(); const v = await fn(); if (v) return v; await new Promise((r) => setTimeout(r, 250)); }
    fail(step, `nothing after ${Math.round(ms / 60000)} min`);
  };
  const texts = (th) => th.sent.map((s) => (s.payload && s.payload.content) || '').filter(Boolean);
  let job = null, thread = null;
  const said = () => (thread ? texts(thread).slice(-4).join(' | ') : '');
  try {
    // 3. a request opens a thread and a workspace, and a proposal comes back
    await ad.onMessage(new Msg(world, chan, owner, `<@${world.botId}> CANARY-PRACTICE practice run ${stamp}`));
    thread = await until('thread', () => world.threads[0], 60000);
    const proposal = () => thread.sent.find((s) => s.payload && s.payload.embeds && s.reactions.length >= 2);
    const p = await until('proposal', () => proposal() || (texts(thread).some((t) => /could not|Something broke|error/i.test(t)) && fail('proposal', said())), 15 * 60000);
    job = Object.values(runner.jobs()).find((j) => j.threadId === thread.id);
    const tests = (p.payload.embeds[0].fields.find((f) => f.name === 'Tests') || {}).value || '';
    const want = cfg.drafts ? ['✅', '🧪', '❌'] : ['✅', '❌'];
    if (want.join() !== p.reactions.join()) fail('proposal', `reactions ${p.reactions.join(' ')}, expected ${want.join(' ')}`);
    const pushed = git(repo, 'ls-remote', 'origin', `refs/heads/${job.branch}`).split(/\s/)[0];
    if (pushed !== job.proposal.head) fail('proposal', `the branch on GitHub is ${pushed || 'missing'}, not the proposal's ${job.proposal.head}`);
    ok('proposal', `${job.branch} · tier ${job.proposal.tier} · ${tests.split('\n')[0]}`);
    // 4. the agent's own check in its sandbox, as the agent runs it (the shared setup from the cache, hygiene, one suite)
    const r = spawnSync('bash', [path.join(TOOLS, 'check-godot.sh'), '--rerun', 'code_load'], { cwd: job.worktree, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8' }, timeout: 40 * 60000 });
    const sum = ((r.stdout || '').match(/^GODOT TESTS: .*$/gm) || []).pop() || '';
    if (r.status !== 0) fail('sandbox-check', `${sum || 'no summary'}\n${String((r.stdout || '') + (r.stderr || '')).trim().split('\n').slice(-12).join('\n')}`);
    ok('sandbox-check', sum.replace(/^GODOT TESTS: /, ''));
    // 5. 🧪: every test on GitHub CI, nothing shipped
    if (skipCi) line('CANARY ci skipped (--skip-ci)');
    else if (!cfg.ciGate) line('CANARY ci skipped (the CI gate is off in config.json)');
    else {
      if (!cfg.drafts) line('CANARY ci (drafts are off: the proposal already waited for CI)');
      else {
        const pm = proposal(); let refused = false;
        await ad.onReaction({ emoji: { name: '🧪' }, message: pm, partial: false, users: { remove: async () => { refused = true; } } }, { id: owner, bot: false });
        // the adapter passes 🧪 on only since 2026-10-19: an older /opt/muffin/discord/dm-agent.js drops it silently
        await until('ci', () => (refused ? fail('ci', `the runner refused 🧪: ${said()}`) : texts(thread).some((t) => /🧪 Testing this change/.test(t))), 60000)
          .catch((e) => { throw e.step === 'ci' && !refused ? new Failed('ci', `🧪 never reached the runner: is ${adapterFile} current? (install-bot.sh, then restart muffin-discord)`) : e; });
        await until('ci', () => (texts(thread).some((t) => /🧪 Tests passed/.test(t)) ? true : texts(thread).some((t) => /tests failed|Not this change|could not get this|Something broke/i.test(t)) ? fail('ci', said()) : false), 45 * 60000);
      }
      ok('ci', (texts(thread).find((t) => /🧪 Tests passed/.test(t)) || job.proposal.tested || '').replace(/\s+/g, ' ').slice(0, 200));
    }
  } finally {
    // 6. !discard: everything the run made is removed (unless --keep)
    if (job && !keep) {
      await ad.onMessage(new Msg(world, thread, owner, '!discard'));
      await until('discard', () => job.status === 'discarded' && !job.running, 5 * 60000).catch((e) => { line(`CANARY discard FAILED ${e.message}`); });
      const left = [git(repo, 'ls-remote', 'origin', `refs/heads/${job.branch}`), fs.existsSync(path.join(cfg.worktreeRoot, path.basename(job.worktree || 'none'))) ? 'worktree' : ''].filter(Boolean);
      if (left.length) line(`CANARY discard FAILED left behind: ${left.join(', ')}`); else ok('discard', `${job.branch} and its workspace removed`);
    } else if (job) line(`CANARY kept ${job.branch} at ${job.worktree} (--keep): discard it by hand`);
    if (!keep) fs.rmSync(T, { recursive: true, force: true });
  }
}

main().then(() => { line(`CANARY PASSED in ${Math.round((Date.now() - t0) / 1000)}s`); process.exit(0); })
  .catch((e) => { line(`CANARY ${e.step || 'crashed'} FAILED ${String(e.message || e).slice(0, 1500)}`); line(`CANARY FAILED: ${e.step || 'crashed'}`); process.exit(1); });
