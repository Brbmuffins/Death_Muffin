'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), { execFileSync } = require('child_process'), { EventEmitter } = require('events');
const { createRunner } = require('../runner/core.cjs');
const { loadConfig } = require('../runner/lib/config.cjs');
const { createAdapter } = require('../bot/dm-agent.cjs');
const SRC = path.resolve(__dirname, '..');
const IDS = { OWNER: '100000000000000001', HELIX: '142812688358178816', LIMITED: '300000000000000003', STRANGER: '400000000000000004', BOT: '900000000000000009', CHAN: '700000000000000007' };

function sh(cwd, ...a) { return execFileSync('git', ['-c', 'user.name=T', '-c', 'user.email=t@t', ...a], { cwd, stdio: 'pipe' }).toString().trim(); }
// over.godot = true: the same world but for mode 'godot': a `godot-port` branch (the base branch) holding a small godot/ tree, master keeping only the
// publish script (as in the real repo, where publish-godot-client.sh lives on master), a client manifest naming the revision that is "live", fake
// check-godot.sh / publish script, and a deploy hook that only logs.
function makeWorld(over = {}) {
  const godot = !!over.godot; delete over.godot;
  const T = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-e2e-'));
  const origin = path.join(T, 'origin.git'), repo = path.join(T, 'repo'), tools = path.join(T, 'tools'), deploy = path.join(T, 'deploy'), wtRoot = path.join(T, 'wt');
  fs.mkdirSync(wtRoot); fs.mkdirSync(deploy); fs.mkdirSync(path.join(T, 'preview'));
  execFileSync('git', ['init', '-q', '--bare', '-b', 'master', origin]);
  execFileSync('git', ['clone', '-q', origin, repo], { stdio: 'pipe' });
  sh(repo, 'config', 'user.name', 'T'); sh(repo, 'config', 'user.email', 't@t');
  const w = (f, c) => { fs.mkdirSync(path.dirname(path.join(repo, f)), { recursive: true }); fs.writeFileSync(path.join(repo, f), c); };
  w('package.json', '{"name":"x"}'); w('README.md', 'hi'); w('src/ui/ui.css', 'a{color:red}'); w('src/gameplay/a.ts', 'speed=1'); w('server/x.js', 'a=1'); w('server/death-muffin/deploy-release.sh', 'echo ok'); w('server/vps-handoff/necro-progress/necro-rules.cjs', 'SPEED=1');
  sh(repo, 'checkout', '-q', '-b', 'master'); sh(repo, 'add', '-A'); sh(repo, 'commit', '-q', '-m', 'init'); sh(repo, 'push', '-q', 'origin', 'master');
  // optional `mobile` branch on origin (phones). over.mobile = 'clean' | 'conflict' | 'failtests'
  if (over.mobile) {
    sh(repo, 'checkout', '-q', '-b', 'mobile');
    if (over.mobile === 'conflict') w('src/gameplay/a.ts', 'speed=5'); else w('mobile-only.txt', 'touch'); 
    if (over.mobile === 'failtests') w('FAILTESTS', 'x');
    sh(repo, 'add', '-A'); sh(repo, 'commit', '-q', '-m', 'mobile work'); sh(repo, 'push', '-q', 'origin', 'mobile'); sh(repo, 'checkout', '-q', 'master');
    delete over.mobile;
  }
  let liveRev = null;
  if (godot) {
    w('server/death-muffin/publish-godot-client.sh', '#!/usr/bin/env bash\n# stub of the real publisher: records what it was asked to publish, next to itself\necho "published $1 REPO=$REPO" >> "$(dirname "$0")/published.log"\n');
    sh(repo, 'add', '-A'); sh(repo, 'commit', '-q', '-m', 'publish script on master'); sh(repo, 'push', '-q', 'origin', 'master');
    sh(repo, 'checkout', '-q', '-b', 'godot-port');
    w('godot/project.godot', 'config_version=5'); w('godot/README.md', 'godot readme'); w('godot/game/a.gd', 'speed=1'); w('godot/net/dm_api.gd', 'url=1'); w('godot/export_presets.cfg', '[preset.0]');
    w('godot/data/loot/content.json', '{"v":1}');
    sh(repo, 'add', '-A'); sh(repo, 'commit', '-q', '-m', 'godot tree'); sh(repo, 'push', '-q', 'origin', 'godot-port');
    liveRev = sh(repo, 'rev-parse', 'HEAD');
    fs.mkdirSync(path.join(T, 'client')); fs.writeFileSync(path.join(T, 'client', 'manifest.json'), JSON.stringify({ version: 'v1', rev: liveRev.slice(0, 12) }));
  }
  fs.mkdirSync(path.join(tools, 'state'), { recursive: true });
  for (const f of ['ship.sh', 'rollback.sh', 'agit', 'PROMPT.md', 'PROMPT-godot.md']) fs.copyFileSync(path.join(SRC, f), path.join(tools, f));
  fs.symlinkSync(path.join(SRC, 'runner'), path.join(tools, 'runner'));
  fs.writeFileSync(path.join(tools, 'check-godot.sh'), '#!/usr/bin/env bash\n[ -e FAILTESTS ] && { echo "godot boom"; exit 1; }\necho "tests/game run.gd exit=0  12 passed"; echo "GODOT TESTS: 2 suites, 2 passed, 0 failed"\n', { mode: 0o755 });
  // shot-godot.sh stand-in: writes a PNG-ish file; in a base-<id> scratch worktree it writes the BEFORE picture (unless NOBASE exists)
  fs.writeFileSync(path.join(tools, 'shot-godot.sh'), '#!/usr/bin/env bash\n[ -f .dm-shot.json ] || exit 2\nmkdir -p .dm-shots\ncase "$PWD" in */base-*) [ -e "$(dirname "$PWD")/NOBASE" ] && exit 1; echo PNG-before > .dm-shots/a.png;; *) echo PNG-after > .dm-shots/a.png;; esac\n', { mode: 0o755 });
  fs.writeFileSync(path.join(tools, 'check.sh'), '#!/usr/bin/env bash\n[ -e FAILTESTS ] && { echo "boom"; exit 1; }\necho "# tests 3"; echo "# pass 3"; echo "# fail 0"\n', { mode: 0o755 });
  // regen stub: the real generators need the whole game repo; this one derives necro-rules.cjs from src/gameplay/a.ts (upper-cased) and prints the status like the real one
  fs.writeFileSync(path.join(tools, 'regen.sh'), '#!/usr/bin/env bash\nmkdir -p server/vps-handoff/necro-progress\ntr a-z A-Z < src/gameplay/a.ts > server/vps-handoff/necro-progress/necro-rules.cjs\necho "== regenerated"\ngit status --porcelain\n', { mode: 0o755 });
  const backup = path.join(deploy, 'backup-pre-release-abc123456789-20261004T000000Z'); fs.mkdirSync(backup);
  fs.writeFileSync(path.join(backup, 'ROLLBACK.sh'), 'echo rolled-back-ok\n');
  const cfgFile = path.join(tools, 'config.json');
  const raw = { channelId: IDS.CHAN, guildId: '1', ownerIds: [IDS.OWNER], names: { [IDS.HELIX]: 'Helix', [IDS.LIMITED]: 'Limited' },
    projects: { deathmuffin: { requesters: [IDS.HELIX, IDS.LIMITED], approvers: { casual: [IDS.HELIX, IDS.LIMITED], gameplay: [IDS.HELIX], sensitive: [IDS.HELIX] } } },
    repo, worktreeRoot: wtRoot, stateDir: path.join(tools, 'state'), toolsDir: tools, deployDir: deploy,
    claudeCmd: path.join(__dirname, 'fake-claude.cjs'), deployCmd: `n=$(ls ${deploy} | grep -c backup); b=${deploy}/backup-pre-release-aaaaaaaaaa$(printf %02d $n)-$(printf '20261004T%02d0000Z' $n); mkdir -p $b; echo 'echo rolled-back-ok' > $b/ROLLBACK.sh; echo "Rollback: $b/ROLLBACK.sh"; echo deployed "$1"`, turnTimeoutMin: 1, mobileDeployCmd: `echo "$1" >> ${deploy}/mobile-deploys.log`,
    previewRoot: path.join(T, 'preview'), previewUrl: 'https://example.test/death-muffin/preview/',
    previewCmd: 'if [ -e "$DM_PREVIEW_ROOT/../FAIL" ]; then echo "vite exploded"; exit 1; fi; mkdir -p "$DM_PREVIEW_ROOT/$1" && echo "$DM_PREVIEW_TITLE|$DM_PREVIEW_BASE" > "$DM_PREVIEW_ROOT/$1/index.html"',
    ...(godot ? { baseBranch: 'godot-port', mode: 'godot', clientManifest: path.join(T, 'client', 'manifest.json'), deployCmd: `echo deployed "$1" >> ${deploy}/deploys.log`,
      previewCmd: 'if [ -e "$DM_PREVIEW_ROOT/../FAIL" ]; then echo "godot exploded"; exit 1; fi; mkdir -p "$DM_PREVIEW_ROOT/$1" && echo "$DM_PREVIEW_TITLE" > "$DM_PREVIEW_ROOT/$1/DeathMuffin-Preview-$1-win64.zip"' } : {}),
    ...over };
  fs.writeFileSync(cfgFile, JSON.stringify(raw));
  const cfg = loadConfig(cfgFile); cfg.__file = cfgFile;
  const runner = createRunner(cfg);
  return { T, repo, origin, tools, deploy, backup, cfg, runner, sh, liveRev };
}

// ---- fake Discord layer ----
class Chan extends EventEmitter {
  constructor(world, id, opts = {}) { super(); this.world = world; this.id = id; this.sent = []; this.thread = !!opts.thread; this.parentId = opts.parentId || null; world.chans.set(id, this); }
  isThread() { return this.thread; }
  async sendTyping() { this.typing = (this.typing || 0) + 1; }
  async send(p) { const m = new Msg(this.world, this, IDS.BOT, p.content || '', true); m.payload = p; this.sent.push(m); return m; }
}
class Msg {
  constructor(world, channel, authorId, content, bot = false) {
    this.world = world; this.id = String(world.nextId++); this.channel = channel; this.guild = { id: '1' }; this.author = { id: authorId, bot: false, username: 'u' + authorId.slice(-3) };
    if (bot) this.author = { id: IDS.BOT, bot: true }; this.content = content; this.reactions = []; this.attachments = new Map(); this.replies = [];
    this.mentions = { users: { has: (id) => this.content.includes(`<@${id}>`) || this.content.includes(`<@!${id}>`) } };
  }
  async reply(p) { this.replies.push(p); return p; }
  async react(e) { this.reactions.push(e); }
  async startThread({ name }) { const t = new Chan(this.world, 'T' + this.id, { thread: true, parentId: this.channel.id }); t.name = name; this.world.threads.push(t); return t; }
}
function makeDiscord(runner, over = {}) {
  const world = { chans: new Map(), threads: [], nextId: 1000 };
  const client = new EventEmitter(); client.user = { id: IDS.BOT };
  client.channels = { fetch: async (id) => world.chans.get(id) };
  const main = new Chan(world, IDS.CHAN);
  const fetchImpl = async (url, init = {}) => {
    const u = new URL(url); const body = init.body ? JSON.parse(init.body) : undefined; let out;
    if (u.pathname === '/config') out = { channelId: runner.cfg.channelId };
    else if (u.pathname === '/poll') out = { ops: await runner.poll(0) };
    else if (u.pathname === '/event') out = await runner.handleEvent(body);
    else if (u.pathname === '/bind') out = await runner.bind(body);
    else if (u.pathname === '/ack') { runner.ack(body.id, body.result); out = { ok: true }; }
    return { ok: true, status: 200, json: async () => JSON.parse(JSON.stringify(out)) };
  };
  const ad = createAdapter({ client, runnerUrl: 'http://x', secret: 's', fetchImpl, pollWaitSec: 0, log: () => {}, ...over });
  const say = (chan, userId, content, attachments = []) => { const m = new Msg(world, chan, userId, content); attachments.forEach((a, i) => m.attachments.set(String(i), a)); return ad.onMessage(m).then(() => m); };
  const react = async (msg, userId, emoji) => { const removed = []; const reaction = { emoji: { name: emoji }, message: msg, partial: false, users: { remove: async (id) => { removed.push(id); } } }; await ad.onReaction(reaction, { id: userId, bot: false }); return removed; };
  return { world, client, main, ad, say, react };
}
async function until(fn, ad, ms = 30000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { await ad.pollOnce(); const v = fn(); if (v) return v; await new Promise((r) => setTimeout(r, 40)); }
  throw new Error('timeout waiting for condition');
}
module.exports = { IDS, makeWorld, makeDiscord, until, sh };
