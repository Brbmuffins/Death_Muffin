'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { loadConfig } = require('./lib/config.cjs');
const { createAudit } = require('./lib/audit.cjs');
const { createAuth } = require('./lib/auth.cjs');
const { redactText, redactDeep } = require('./lib/redact.cjs');
const G = require('./lib/gitops.cjs');
const { runTurn, buildPrompt, readResult } = require('./lib/agent.cjs');
const { parseDiff, classifyDiff, tierLabel, approversFor } = require('./lib/tiers.cjs');
const { planReply } = require('./lib/discordText.cjs');

const TIER_COLOR = { casual: 0x16a34a, gameplay: 0xb45309, sensitive: 0xdc2626 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clip = (s, n) => (String(s).length > n ? String(s).slice(0, n - 1) + '…' : String(s));
const safeName = (n) => String(n || 'file').replace(/[^\w.-]/g, '_');
const SHOT_MAX_BYTES = 8 * 1024 * 1024, SHOTS_PER_POST = 4;
const fmtList = (a, n) => (a.length > n ? a.slice(0, n).join('\n') + `\n… +${a.length - n} more` : a.join('\n'));

function createRunner(cfgIn, opts = {}) {
  const cfg = typeof cfgIn === 'string' ? loadConfig(cfgIn) : cfgIn;
  const now = opts.now || (() => Date.now());
  fs.mkdirSync(cfg.stateDir, { recursive: true });
  const audit = createAudit(path.join(cfg.stateDir, 'audit.jsonl'));
  const auth = createAuth(cfg, now);
  const jobsFile = path.join(cfg.stateDir, 'jobs.json');
  const shipsFile = path.join(cfg.stateDir, 'ships.jsonl');
  const lockFile = path.join(cfg.deployDir, '.deploy.lock');
  fs.mkdirSync(cfg.deployDir, { recursive: true });

  let jobs = {};       // threadId -> job
  try { jobs = JSON.parse(fs.readFileSync(jobsFile, 'utf8')); } catch { /* fresh */ }
  for (const j of Object.values(jobs)) { if (j.status === 'running' || j.status === 'shipping') { j.status = 'idle'; } j.running = false; }
  const save = () => { const t = jobsFile + '.tmp'; fs.writeFileSync(t, JSON.stringify(jobs, null, 1), { mode: 0o600 }); fs.renameSync(t, jobsFile); };
  const pendingNew = new Map();   // eventId -> event awaiting a thread id from the bot
  let shipBusy = false;

  // ---------- outbox (runner -> bot, long-polled) ----------
  const outbox = []; const callbacks = new Map(); let waiters = [];
  function post(target, payload, cb) {
    const p = { ...payload };
    if (p.content) p.content = redactText(p.content);
    if (p.file) p.file = { name: p.file.name, text: redactText(p.file.text) };
    if (p.files) p.files = p.files.map((f) => ({ name: safeName(f.name), b64: f.b64 }));   // binary images: never run through redactText
    if (p.embed) p.embed = redactDeep(p.embed);
    const op = { id: crypto.randomBytes(6).toString('hex'), target: typeof target === 'string' ? { threadId: target } : target, ...p, sentAt: 0, createdAt: now() };
    outbox.push(op); if (cb) callbacks.set(op.id, cb);
    const w = waiters; waiters = []; w.forEach((f) => f());
    return op.id;
  }
  const say = (job, text, extra) => post({ threadId: job.threadId }, { content: clip(text, 1900), ...extra });
  // The agent's own replies can be long: several messages, or a preview plus the full text as reply.md (discordText.cjs).
  const sayLong = (job, text) => { const { chunks, file } = planReply(text); chunks.forEach((c, i) => post({ threadId: job.threadId }, { content: c, ...(file && i === chunks.length - 1 ? { file } : {}) })); };
  // "Muffin Core is typing…" is the normal acknowledgement while a job works. Typing ops are fire-and-forget: handed out once,
  // never retried, and dropped if the bot did not pick them up within a few seconds (Discord shows typing for ~10 s).
  const typing = (job) => post({ threadId: job.threadId }, { typing: true });
  function dueOps() {
    const t = now();
    for (let i = outbox.length - 1; i >= 0; i--) if (outbox[i].typing && (outbox[i].sentAt || t - outbox[i].createdAt > 8000)) outbox.splice(i, 1);
    return outbox.filter((o) => t - o.sentAt > 60000);
  }
  async function poll(waitMs) {
    if (!dueOps().length && waitMs > 0) await new Promise((res) => { const t = setTimeout(res, waitMs); waiters.push(() => { clearTimeout(t); res(); }); });
    const ops = dueOps(); ops.forEach((o) => { o.sentAt = now(); });
    return ops.map(({ sentAt, createdAt, ...o }) => o);
  }
  function ack(id, res) {
    const i = outbox.findIndex((o) => o.id === id); if (i >= 0) outbox.splice(i, 1);
    const cb = callbacks.get(id); callbacks.delete(id); if (cb) { try { cb(res || {}); } catch (e) { console.error('ack cb', e); } }
  }

  // ---------- ships log ----------
  const readShips = () => { try { return fs.readFileSync(shipsFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
  const logShip = (rec) => fs.appendFileSync(shipsFile, JSON.stringify({ ts: new Date(now()).toISOString(), ...rec }) + '\n', { mode: 0o600 });
  const nameOf = (id) => cfg.names[id] || (auth.isOwner(id) ? 'the owner' : `user ${String(id).slice(-4)}`);
  const ownerPing = (target, text) => post(target, { content: `${cfg.ownerIds.map((i) => `<@${i}>`).join(' ')} ${text}`, mentionUsers: cfg.ownerIds });

  // ---------- events from Discord ----------
  function newJob(ev) {
    const id = crypto.randomBytes(3).toString('hex');
    return { id, threadId: null, channelId: ev.channelId, creatorId: String(ev.userId), branch: `discord/${id}`, worktree: null, base: null, sessionId: null,
      model: cfg.defaultModel, status: 'idle', turns: 0, createdAt: new Date(now()).toISOString(), lastActive: now(), queue: [], proposal: null, running: false };
  }
  const inScope = (ev) => (ev.threadId ? String(ev.parentId) === String(cfg.channelId) : String(ev.channelId) === String(cfg.channelId));

  async function handleEvent(ev) {
    if (!cfg.channelId || !inScope(ev)) return { action: 'ignore' };
    if (ev.type === 'reaction') return handleReaction(ev);
    const role = auth.roleOf(ev.userId);
    if (!role) { audit.log('ignored-unlisted', { userId: String(ev.userId), mentioned: !!ev.mentioned }); return { action: 'ignore' }; }
    const text = String(ev.text || '').trim();
    const msg = { userId: String(ev.userId), name: cfg.names[ev.userId] || ev.username || 'someone', role, text, messageId: ev.messageId, ts: now() };

    if (/^!?rollback\b/i.test(text) && (ev.mentioned || ev.threadId)) {
      audit.log('request', { userId: msg.userId, kind: 'rollback' });
      const target = ev.threadId ? { threadId: ev.threadId } : { channelId: ev.channelId, replyTo: ev.messageId };
      doRollback(msg, target).catch((e) => post(target, { content: `Rollback failed to start: ${e.message}` }));
      return { action: 'accepted' };
    }
    const full = auth.isFull(msg.userId);
    if (!auth.rate(`msg:${msg.userId}`, full ? cfg.rateLimit.fullApproverPerHour : cfg.rateLimit.perUserPerHour, 3600e3)) {
      audit.log('rate-limited', { userId: msg.userId });
      return { action: 'reply', text: 'Slow down a little, you have used up this hour\'s requests. Try again later.' };
    }

    if (!ev.threadId) {
      if (!ev.mentioned) return { action: 'ignore' };
      if (!text) return { action: 'reply', text: 'Tell me what you want to look at or change in Death Muffin.' };
      if (!auth.rate(`newjob:${msg.userId}`, full ? cfg.rateLimit.fullApproverNewJobsPerDay : cfg.rateLimit.perUserNewJobsPerDay, 86400e3)) { audit.log('rate-limited', { userId: msg.userId, kind: 'newjob' }); return { action: 'reply', text: 'That is the daily limit of new requests for you. Continue in an existing thread or try tomorrow.' }; }
      const eventId = crypto.randomBytes(5).toString('hex');
      pendingNew.set(eventId, { ev, msg }); setTimeout(() => pendingNew.delete(eventId), 120000).unref();
      audit.log('request', { userId: msg.userId, role, kind: 'new', text });
      return { action: 'create_thread', eventId, threadName: clip(`dm ${text.replace(/\s+/g, ' ').replace(/[^\w .,!?'-]/g, '')}`, 90) };
    }

    const job = jobs[ev.threadId];
    if (!job) return { action: 'ignore' };
    if (!ev.mentioned && cfg.threadReplyRequiresMention) return { action: 'ignore' };
    if (['shipped', 'discarded'].includes(job.status)) return { action: 'reply', text: `This request is closed (${job.status}). Mention me in the channel to start a new one.` };
    audit.log('request', { userId: msg.userId, role, kind: 'thread', job: job.id, text });
    if (text.startsWith('!')) return handleCommand(job, msg, text);
    if (job.turns >= cfg.maxTurnsPerJob) return { action: 'reply', text: 'This thread has hit its turn limit. Start a new request in the channel.' };
    const mm = /\buse\s+(opus|sonnet|haiku)\b/i.exec(text);
    if (mm && auth.canSwitchModel(msg.userId) && cfg.allowedModels.includes(mm[1].toLowerCase())) { job.model = mm[1].toLowerCase(); audit.log('model', { job: job.id, model: job.model, by: msg.userId }); }
    job.queue.push(msg); job.lastActive = now(); save();
    const ahead = running().length;
    pump();
    return { action: 'accepted', queued: job.running || ahead >= cfg.maxConcurrentJobs };
  }

  async function bind({ eventId, threadId, error }) {
    const p = pendingNew.get(eventId); if (!p) return { ok: false };
    pendingNew.delete(eventId);
    if (error || !threadId) { audit.log('thread-failed', { error: error || 'no thread' }); return { ok: false }; }
    const job = newJob(p.ev); job.threadId = String(threadId); jobs[job.threadId] = job;
    try { const w = await G.createWorktree(cfg, job); job.worktree = w.worktree; job.base = w.base; }
    catch (e) { say(job, `I could not set up a workspace: ${e.message}`); job.status = 'discarded'; save(); return { ok: false }; }
    job.queue.push(p.msg); save(); pump();
    return { ok: true, jobId: job.id };
  }

  function handleCommand(job, msg, text) {
    const [cmd, ...rest] = text.slice(1).trim().split(/\s+/); const arg = rest.join(' ').toLowerCase();
    switch ((cmd || '').toLowerCase()) {
      case 'status': return { action: 'reply', text: `Job \`${job.id}\` · ${job.status}${job.running ? ' (working)' : ''} · model ${job.model} · ${job.turns} turn(s) · ${job.queue.length} queued` + (job.proposal ? ` · proposal tier ${job.proposal.tier}` : '') };
      case 'model':
        if (!auth.canSwitchModel(msg.userId)) { audit.log('refused', { userId: msg.userId, kind: 'model' }); return { action: 'reply', text: 'Only full approvers can switch models.' }; }
        if (!cfg.allowedModels.includes(arg)) return { action: 'reply', text: `Models: ${cfg.allowedModels.join(', ')}` };
        job.model = arg; save(); return { action: 'reply', text: `Model set to ${arg} for the next turn.` };
      case 'cancel':
        if (!auth.canDiscard(msg.userId, job, job.proposal && job.proposal.tier)) return { action: 'reply', text: 'Only the person who started this, or the owner, can cancel.' };
        if (job.proc) { job.cancelRequested = true; try { process.kill(-job.proc.pid, 'SIGKILL'); } catch { /* gone */ } return { action: 'reply', text: 'Cancelling the current turn.' }; }
        return { action: 'reply', text: 'Nothing is running.' };
      case 'discard':
        if (!auth.canDiscard(msg.userId, job, job.proposal && job.proposal.tier)) return { action: 'reply', text: 'Only the person who started this, or the owner, can discard.' };
        discard(job, msg.userId).catch((e) => say(job, `Discard failed: ${e.message}`)); return { action: 'accepted' };
      case 'shot':
        if (job.turns >= cfg.maxTurnsPerJob) return { action: 'reply', text: 'This thread has hit its turn limit. Start a new request in the channel.' };
        job.queue.push({ ...msg, text: 'Show me what your current change looks like: write a scenario to .dm-shot.json and run shot.sh, check the images yourself, and keep your reply to one or two lines. If you have not changed anything yet, capture the game as it is now for the thing we have been talking about.' });
        job.lastActive = now(); save(); pump(); return { action: 'accepted' };
      case 'sync':
        job.queue.push({ ...msg, text: '(sync request)', sync: true }); save(); pump(); return { action: 'accepted' };
      default: return { action: 'reply', text: 'Commands: !status, !model <name> (owner), !cancel, !discard, !shot (screenshot of the change), !sync, rollback (approvers).' };
    }
  }

  async function handleReaction(ev) {
    const job = jobs[ev.threadId];
    if (!job || !job.proposal || job.proposal.messageId !== ev.messageId) return { action: 'ignore' };
    const uid = String(ev.userId); const p = job.proposal;
    if (ev.emoji === '✅') {
      audit.log('approve-attempt', { userId: uid, job: job.id, tier: p.tier });
      if (!auth.canApprove(uid, p.tier)) {
        audit.log('approve-refused', { userId: uid, job: job.id, tier: p.tier, why: 'not an approver for this tier' });
        const who = approversFor(p.tier, cfg).map(nameOf).join(' / ');
        if (!job.lastRefusalAt || now() - job.lastRefusalAt > 60000) { job.lastRefusalAt = now(); say(job, `Only ${who} can ship this one (${p.tier} tier).`); }
        return { action: 'remove_reaction' };
      }
      if (job.status !== 'proposed' || !p.testsOk) { audit.log('approve-refused', { userId: uid, job: job.id, why: `status ${job.status}` }); return { action: 'remove_reaction' }; }
      if (!auth.isFull(uid) && auth.shipsToday(uid, readShips()) >= cfg.casualShipsPerDay) {
        audit.log('approve-refused', { userId: uid, job: job.id, why: 'daily cap' });
        say(job, `That is today's limit of ${cfg.casualShipsPerDay} ships for you. The owner can still ship it.`); return { action: 'remove_reaction' };
      }
      if (shipBusy) { say(job, 'Another ship is running. React again when it finishes.'); return { action: 'remove_reaction' }; }
      const curHead = await G.head(job.worktree).catch(() => null);
      if (curHead !== p.head) { audit.log('approve-refused', { userId: uid, job: job.id, why: 'head changed' }); say(job, 'The branch changed after this proposal; wait for the new one.'); return { action: 'remove_reaction' }; }
      audit.log('approved', { userId: uid, job: job.id, tier: p.tier, head: p.head });
      ship(job, uid).catch((e) => { shipBusy = false; say(job, `Ship crashed: ${e.message}`); audit.log('ship-error', { job: job.id, error: e.message }); });
      return { action: 'accepted' };
    }
    if (ev.emoji === '❌') {
      if (!auth.canDiscard(uid, job, p.tier)) return { action: 'remove_reaction' };
      if (job.status === 'shipping') return { action: 'ignore' };
      discard(job, uid).catch((e) => say(job, `Discard failed: ${e.message}`));
      return { action: 'accepted' };
    }
    return { action: 'ignore' };
  }

  async function discard(job, byId) {
    if (job.running) { job.cancelRequested = true; if (job.proc) { try { process.kill(-job.proc.pid, 'SIGKILL'); } catch { /* gone */ } } }
    audit.log('discarded', { job: job.id, userId: String(byId) });
    await G.removeJobArtifacts(cfg, job);
    job.status = 'discarded'; job.queue = []; job.proposal = null; save();
    say(job, `Discarded. Branch \`${job.branch}\` and its workspace are deleted. Nothing went live.`);
  }

  // ---------- scheduler ----------
  const running = () => Object.values(jobs).filter((j) => j.running);
  function pump() {
    while (running().length < cfg.maxConcurrentJobs) {
      const next = Object.values(jobs).filter((j) => !j.running && j.queue.length && ['idle', 'proposed'].includes(j.status)).sort((a, b) => a.queue[0].ts - b.queue[0].ts)[0];
      if (!next) break;
      next.running = true; next.status = 'running';
      processJob(next).catch((e) => { console.error('job crashed', e); say(next, `Something broke on my side: ${clip(e.message, 300)}`); next.running = false; next.status = 'idle'; save(); }).finally(() => { next.running = false; save(); pump(); });
    }
    for (const j of Object.values(jobs)) if (!j.running && j.queue.length && ['idle', 'proposed'].includes(j.status) && !j.queuedNotice) { j.queuedNotice = true; if (j.turns === 0) say(j, 'Queued; I am busy with another request and will start as soon as I can.'); }
  }

  async function agentTurn(job, prompt) {
    job.turns++;
    const r = await runTurn(cfg, job, prompt, { onSpawn: (p) => { job.proc = p; } });
    job.proc = null;
    if (r.sessionId) job.sessionId = r.sessionId;
    fs.mkdirSync(path.join(cfg.stateDir, 'runs'), { recursive: true });
    fs.appendFileSync(path.join(cfg.stateDir, 'runs', `${job.id}.log`), JSON.stringify({ ts: new Date(now()).toISOString(), turn: job.turns, model: job.model, costUsd: r.costUsd, error: r.error, textLen: r.text.length }) + '\n');
    return r;
  }

  async function processJob(job) {
    job.queuedNotice = false;
    const msgs = job.queue.splice(0); save();
    const sync = msgs.some((m) => m.sync);
    const real = msgs.filter((m) => !m.sync);
    let extra = '';
    if (sync) {
      await G.git(cfg.repo, ['fetch', '-q', 'origin']);
      const m = await G.git(job.worktree, ['merge', '--no-edit', 'origin/master'], { allowFail: true });
      if (m.code !== 0) {
        const conflicted = (await G.git(job.worktree, ['diff', '--name-only', '--diff-filter=U'])).out.trim();
        extra = `Master moved and merging it into your branch left conflicts in:\n${conflicted}\nResolve the conflict markers in those files keeping both sides' intent, stage them with agit add <paths>, then finish with agit commit --no-edit. Then run check.sh.`;
        say(job, 'Merging the latest master hit conflicts; asking the agent to resolve them.');
      } else say(job, 'Merged the latest master into this branch cleanly. Re-running checks.');
      job.proposal = null;
    } else if (job.turns === 0) say(job, `On it (${job.model[0].toUpperCase()}${job.model.slice(1)}).`);
    const t0 = now(); let nextUpdate = t0 + 60000;
    typing(job);
    const ticker = setInterval(() => {
      typing(job);
      if (now() >= nextUpdate) { nextUpdate = now() + 5 * 60000; say(job, `Still working… (${Math.max(1, Math.round((now() - t0) / 60000))} min)`); }
    }, 8000); ticker.unref();
    try { await runJob(job, real, extra); } finally { clearInterval(ticker); }
  }
  // ---------- screenshots (<worktree>/.dm-shots/*.png, written by the agent via shot.sh) ----------
  function listShots(job) {
    const dir = path.join(job.worktree || '', '.dm-shots'); let out = [];
    try {
      out = fs.readdirSync(dir).filter((n) => /\.png$/i.test(n)).map((n) => { const st = fs.statSync(path.join(dir, n)); return { name: n, file: path.join(dir, n), size: st.size, mtime: st.mtimeMs }; });
    } catch { return []; }
    return out.sort((a, b) => b.mtime - a.mtime || (a.name < b.name ? -1 : 1));
  }
  const readShot = (s) => { try { return { name: safeName(s.name), b64: fs.readFileSync(s.file).toString('base64') }; } catch { return null; } };
  // New or changed images since the last post go to the thread (once each).
  function postNewShots(job) {
    if (!job.worktree) return;
    job.shotsSeen = job.shotsSeen || {};
    const fresh = listShots(job).filter((s) => job.shotsSeen[s.name] !== `${s.mtime}:${s.size}`);
    if (!fresh.length) return;
    fresh.slice(0, SHOTS_PER_POST).reverse().forEach((s) => {
      job.shotsSeen[s.name] = `${s.mtime}:${s.size}`;
      if (s.size > SHOT_MAX_BYTES) { say(job, `Screenshot ${s.name} is too big to post (${Math.round(s.size / 1048576)} MB).`); return; }
      const f = readShot(s); if (f) post({ threadId: job.threadId }, { content: `📸 ${s.name.replace(/\.png$/i, '')}`, files: [f] });
    });
    for (const s of fresh.slice(SHOTS_PER_POST)) job.shotsSeen[s.name] = `${s.mtime}:${s.size}`;   // beyond the cap: not posted, not retried
    save();
  }
  // Only images taken after the branch's last commit show the change being approved; an older one could show a previous version.
  function proposalShots(job, sinceMs) {
    return listShots(job).filter((s) => s.size <= SHOT_MAX_BYTES && s.mtime >= sinceMs).slice(0, SHOTS_PER_POST).map(readShot).filter(Boolean);
  }

  async function runJob(job, real, extra) {
    let r = null;
    if (real.length || extra) r = await agentTurn(job, buildPrompt(real, extra));
    if (job.cancelRequested) { job.cancelRequested = false; say(job, 'Cancelled.'); job.status = 'idle'; return; }
    if (r && r.error) {
      audit.log('turn-error', { job: job.id, error: r.error });
      say(job, r.timedOut ? `That took longer than ${cfg.turnTimeoutMin} minutes, so I stopped it. Try a smaller step.` : `The agent hit an error: ${clip(redactText(r.error), 300)}`);
      job.status = 'idle'; return;
    }
    if (r && r.text.trim()) sayLong(job, r.text.trim());
    postNewShots(job);
    await afterTurn(job, readResult(job.worktree));
  }

  // Verify -> (fix-up turns) -> propose. Everything here is deterministic runner code, not the model.
  async function verify(job) {
    const wt = job.worktree;
    if (await G.mergeInProgress(wt) || await G.isDirty(wt)) return { ok: false, fixable: true, why: 'There are uncommitted changes (or an unfinished merge). Stage explicit paths with agit add and commit with agit commit -m "<one plain sentence>".' };
    let commits = await G.commitsSince(wt, job.base);
    if (commits.some((c) => /^\s*co-authored-by:/im.test(c.body))) {
      await G.git(wt, ['filter-branch', '-f', '--msg-filter', "sed '/^[Cc]o-[Aa]uthored-[Bb]y:/d'", `${job.base}..HEAD`], { allowFail: true });
      commits = await G.commitsSince(wt, job.base);
    }
    const diff = await G.diffText(wt, job.base);
    if (!diff.trim()) return { ok: true, empty: true };
    const files = parseDiff(diff);
    const cls = classifyDiff(files, cfg);
    if (cls.forbidden.length) return { ok: false, fixable: true, why: `These paths may not be changed by this agent: ${cls.forbidden.join(', ')}. Undo those changes (restore them to the original content) and commit.` };
    const secrets = G.scanDiffForSecrets(diff);
    if (secrets.length) return { ok: false, fixable: true, why: `The secret scan flagged ${secrets.map((s) => s.file).join(', ')}. Remove anything secret-like from the change.` };
    const migrations = G.migrationsFrom(files);
    if (migrations.length && !cfg.allowMigrations) return { ok: false, fixable: false, why: 'This change adds a database migration, which is switched off for this agent.' };
    const t = await (opts.runChecks || runChecks)(job);
    if (!t.ok) return { ok: false, fixable: true, why: `check.sh failed:\n${t.tail}`, tests: t };
    return { ok: true, files, cls, migrations, tests: t, diff, commits };
  }
  async function runChecks(job) {
    const r = await G.run(path.join(cfg.toolsDir, 'check.sh'), [], { cwd: job.worktree, env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8' }, timeoutMs: 25 * 60000 });
    const out = r.out + r.err; const sum = (out.match(/^# (tests|pass|fail) .*$/gm) || []).join(' · ').replace(/# /g, '');
    return { ok: r.code === 0 && !r.timedOut, tail: out.trim().split('\n').slice(-30).join('\n'), summary: sum || (r.code === 0 ? 'typecheck + client + server tests passed' : 'failed') };
  }

  async function afterTurn(job, result) {
    for (let attempt = 0; ; attempt++) {
      const v = await verify(job);
      if (v.ok && v.empty) { job.status = 'idle'; job.proposal = null; return; }
      if (v.ok) return propose(job, v, result);
      audit.log('verify-failed', { job: job.id, why: v.why });
      if (!v.fixable || attempt >= 2) { say(job, `I could not get this into a shippable state: ${clip(v.why, 900)}\nNothing was proposed. Tell me how to proceed or react ❌ / say !discard.`); job.status = 'idle'; return; }
      say(job, `Checks found a problem (${clip(v.why.split('\n')[0], 200)}); asking the agent to fix it.`);
      const r = await agentTurn(job, `The automatic review failed. Fix this, make sure check.sh passes, and commit:\n${v.why}`);
      if (job.cancelRequested) { job.cancelRequested = false; say(job, 'Cancelled.'); job.status = 'idle'; return; }
      if (r.error) { say(job, `The agent hit an error: ${clip(redactText(r.error), 300)}`); job.status = 'idle'; return; }
      postNewShots(job);
      result = readResult(job.worktree) || result;
    }
  }

  async function propose(job, v, result) {
    const head = await G.head(job.worktree);
    try { await (opts.pushBranch || G.pushBranch)(cfg, job); } catch (e) { say(job, `I could not push the branch to GitHub: ${clip(e.message, 300)}`); job.status = 'idle'; return; }
    const tier = v.cls.tier;
    const subjects = v.commits.map((c) => c.subject).reverse();
    const title = clip((result && result.title) || subjects[0] || 'Change', 120);
    const bullets = (Array.isArray(result && result.summary) && result.summary.length ? result.summary : subjects).slice(0, 6).map((b) => `• ${clip(b, 220)}`);
    const warn = G.suspiciousFindings(v.diff).map((w) => clip(w, 150));
    const fileLines = v.files.map((f) => `${f.status === 'add' ? '+' : f.status === 'delete' ? '−' : '~'} ${clip(f.path, 90)}`);
    const url = G.compareUrl(cfg, job.branch);
    const owner = approversFor(tier, cfg).map(nameOf);
    const embed = {
      title: clip(`${tier === 'sensitive' ? '⚠ ' : ''}${title}`, 250), url, color: TIER_COLOR[tier],
      description: bullets.join('\n') + (result && result.risk ? `\n\n**Check:** ${clip(result.risk, 300)}` : ''),
      fields: [
        { name: 'Review tier', value: tierLabel(tier, cfg) + (tier === 'sensitive' ? '\n⚠ touches ' + [...new Set(v.cls.perFile.filter((f) => f.tier === 'sensitive').map((f) => f.path))].slice(0, 4).join(', ') : ''), inline: false },
        { name: `Files (${v.files.length})`, value: '```\n' + fmtList(fileLines, 10) + '\n```', inline: false },
        { name: 'Tests', value: `✅ ${v.tests.summary}`, inline: true },
        { name: 'Migrations', value: v.migrations.length ? v.migrations.map((m) => `\`${m}\``).join('\n') : 'none', inline: true },
        ...(warn.length ? [{ name: 'Heads-up for the reviewer', value: fmtList(warn.map((w) => `• ${w}`), 6), inline: false }] : []),
        { name: 'Exact diff', value: `[${job.branch} on GitHub](${url}) · ${v.commits.length} commit(s)`, inline: false },
      ],
      footer: { text: `✅ ship (${owner.join(' / ')}) · ❌ discard · reply to keep iterating · ${job.id}` },
    };
    for (const f of embed.fields) f.value = clip(f.value, 1024);   // Discord: field value <= 1024 chars (whole embed <= 6000; the caps above keep it well under)
    job.proposal = { messageId: null, head, base: job.base, tier, title, files: v.files.map((f) => f.path), migrations: v.migrations, testsOk: true, createdAt: new Date(now()).toISOString() };
    job.status = 'proposed'; save();
    audit.log('proposal', { job: job.id, tier, head, files: v.files.length, migrations: v.migrations.join(',') });
    const committedAt = Number((await G.git(job.worktree, ['log', '-1', '--format=%ct'], { allowFail: true })).out.trim()) * 1000 || 0;
    const shots = proposalShots(job, committedAt);
    if (shots.length) embed.image = { url: `attachment://${shots[0].name}` };
    post({ threadId: job.threadId }, { embed, ...(shots.length ? { files: shots } : {}), reactions: ['✅', '❌'] }, (res) => { if (res.messageId && job.proposal && job.proposal.head === head) { job.proposal.messageId = String(res.messageId); save(); } });
  }

  // ---------- ship / rollback ----------
  function spawnScript(script, env, onLine) {
    return G.run('bash', [script, ...(env.__ARGS || [])], { env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8', ...env }, timeoutMs: 60 * 60000 });
  }
  async function ship(job, approverId) {
    shipBusy = true; job.status = 'shipping'; save();
    const p = job.proposal; const ownerShips = auth.isOwner(approverId);
    say(job, `Approved by ${nameOf(approverId)}. Shipping: taking the deploy lock, merging onto master, re-testing, deploying. This takes a few minutes.`);
    const env = { REPO: cfg.repo, WT_ROOT: cfg.worktreeRoot, BRANCH: job.branch, JOBID: job.id, EXPECT_HEAD: p.head, LOCK: lockFile, TOOLS: cfg.toolsDir, CONFIG: cfg.__file || path.join(cfg.toolsDir, 'config.json'),
      MAX_TIER: auth.maxTier(approverId) || 'casual', MIGRATIONS: p.migrations.join(' '), DEPLOY_SCRIPT: cfg.deployScript, ...(cfg.deployCmd ? { DEPLOY_CMD: cfg.deployCmd } : {}) };
    let r;
    try { r = await G.run('bash', [path.join(cfg.toolsDir, 'ship.sh')], { env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: 'C.UTF-8', ...env }, timeoutMs: 75 * 60000 }); }
    finally { shipBusy = false; }
    const out = r.out + r.err; const m = /^RESULT: (\S+)\s*(.*)$/m.exec(out); const kind = m ? m[1] : 'crashed'; const detail = m ? m[2] : '';
    audit.log('ship-result', { job: job.id, kind, detail, approver: approverId });
    const tail = clip(out.trim().split('\n').slice(-12).join('\n'), 900);
    if (kind === 'live') {
      const [sha, rb] = detail.split(' ');
      logShip({ type: 'live', jobId: job.id, sha, approverId: String(approverId), approverName: nameOf(approverId), tier: p.tier, title: p.title, rollback: rb && rb !== 'none' ? rb : null });
      job.status = 'shipped'; job.proposal = { ...p, shipSha: sha }; save();
      say(job, `🚀 Live. Release \`${sha}\` is on master and deployed. Thanks, ${nameOf(job.creatorId)}.`);
      if (!ownerShips) ownerPing({ threadId: job.threadId }, `${nameOf(approverId)} shipped **${clip(p.title, 100)}** (${p.tier}) as \`${sha}\`. Diff: ${G.compareUrl(cfg, job.branch)} — to undo: say \`rollback\`.`);
      await G.removeJobArtifacts(cfg, job);
      return;
    }
    const why = {
      conflict: `master moved and this no longer merges cleanly (${detail}). Say !sync and I will merge master in and resolve it, then propose again.`,
      'head-moved': 'the branch changed after the proposal. Wait for the new proposal.',
      gate: `the merged change did not pass the final gate: ${detail}.`,
      'tests-failed': `tests failed on the merged tree:\n${tail}`,
      'master-moved': 'master moved while I was deploying; nothing was pushed. React ✅ again or say !sync.',
      'lock-timeout': 'another deploy held the lock for too long; nothing was changed. React ✅ again later.',
      'deploy-failed': `master was pushed but the deploy script FAILED. The owner should look now.\n${tail}`,
    }[kind] || `unexpected failure (${kind}).\n${tail}`;
    say(job, `❌ Not live: ${why}`);
    if (kind === 'deploy-failed' || kind === 'crashed') ownerPing({ threadId: job.threadId }, `Deploy problem for \`${job.id}\`: ${kind}. Check ${cfg.toolsDir}/state/ship-${job.id}.deploy.log`);
    job.status = ['master-moved', 'lock-timeout'].includes(kind) ? 'proposed' : 'idle';
    if (job.status === 'idle') job.proposal = null;
    save();
  }

  function newestBackup() {
    let ents = []; try { ents = fs.readdirSync(cfg.deployDir); } catch { return null; }
    const c = ents.map((n) => /^backup-pre-release-[0-9a-f]+-(\d{8}T\d{6}Z)$/.exec(n) && { n, stamp: RegExp.$1 }).filter(Boolean)
      .filter((e) => fs.existsSync(path.join(cfg.deployDir, e.n, 'ROLLBACK.sh'))).sort((a, b) => (a.stamp < b.stamp ? 1 : -1));
    return c.length ? path.join(cfg.deployDir, c[0].n, 'ROLLBACK.sh') : null;
  }
  async function doRollback(msg, target) {
    const role = auth.roleOf(msg.userId);
    const refuse = (why) => { audit.log('rollback-refused', { userId: msg.userId, why }); post(target, { content: `Not rolled back: ${why}` }); };
    if (!auth.maxTier(msg.userId)) return refuse('only the owner or an approver can roll back');
    if (shipBusy) return refuse('a ship is running right now');
    const newest = newestBackup(); if (!newest) return refuse('no deploy backup found');
    if (readShips().some((s) => s.type === 'rollback' && s.ok && s.backup === newest)) return refuse('the newest release was already rolled back; nothing newer to undo (ask the owner for anything older)');
    const ships = readShips().filter((s) => s.type === 'live');
    const last = ships[ships.length - 1];
    if (!auth.isFull(msg.userId)) {
      if (!last || last.approverId !== msg.userId) return refuse('you can only roll back your own last ship, and the last ship was not yours');
      if (last.rollback !== newest) return refuse('something newer has been deployed since your ship; ask the owner');
    }
    shipBusy = true;
    post(target, { content: `Rolling back to the state before ${last && last.rollback === newest ? `\`${last.sha}\` (${clip(last.title, 60)})` : 'the newest release'} (${path.basename(path.dirname(newest))}). Taking the deploy lock…` });
    audit.log('rollback-start', { userId: msg.userId, backup: newest });
    let r; try { r = await G.run('bash', [path.join(cfg.toolsDir, 'rollback.sh'), newest], { env: { PATH: process.env.PATH, HOME: process.env.HOME, LOCK: lockFile, ...(cfg.rollbackCmd ? { ROLLBACK_CMD: cfg.rollbackCmd } : {}) }, timeoutMs: 20 * 60000 }); } finally { shipBusy = false; }
    const ok = /RESULT: rolled-back/.test(r.out);
    logShip({ type: 'rollback', approverId: msg.userId, backup: newest, ok });
    audit.log('rollback-result', { userId: msg.userId, ok });
    post(target, { content: ok ? '↩ Rolled back. The live game is back to the previous release. master on GitHub still has the change: the owner should revert it there (or fix forward) so the next deploy does not bring it back.' : `Rollback failed:\n${clip((r.out + r.err).trim().split('\n').slice(-8).join('\n'), 800)}` });
    if (!auth.isOwner(msg.userId)) ownerPing(target, `${nameOf(msg.userId)} ran a rollback (${ok ? 'ok' : 'FAILED'}).`);
  }

  // sweep: abandoned idle threads release their worktree
  async function sweep(staleDays = 7) {
    for (const j of Object.values(jobs)) {
      if (j.running || ['shipped', 'discarded', 'shipping'].includes(j.status)) continue;
      if (now() - j.lastActive > staleDays * 86400e3) { await G.removeJobArtifacts(cfg, j).catch(() => {}); j.status = 'discarded'; say(j, `Closed after ${staleDays} days without activity; the branch and workspace were removed.`); audit.log('swept', { job: j.id }); }
    }
    save();
  }

  pump();
  return { cfg, auth, audit, jobs: () => jobs, handleEvent, bind, poll, ack, pump, sweep, outboxSize: () => outbox.length, readShips, newestBackup, _post: post };
}
module.exports = { createRunner };
