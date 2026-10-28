'use strict';
// Death Muffin dev-agent adapter for the Muffin Core Discord bot. A dumb transport: it forwards @mentions / thread messages / ✅🧪❌ reactions
// in the configured channels (#death-muffin, #in-game-reports for in-game bug reports, the #jobs forum and the discussion forums) to the loopback
// runner and posts whatever the runner asks it to post, including opening a thread for each new bug report, setting a #jobs post's tags and
// opening a #jobs post from a discussion (!job), and forwards the bot account's posts it did not send (a terminal session's). All decisions (allow-list, approver
// gate, tiers, rate limits) live in the runner; the bot holds no authority and no secret except the shared runner secret.
// Installed to /opt/muffin/discord/dm-agent.js. Env (from /opt/muffin/dm-agent.env): DM_AGENT_SECRET, DM_AGENT_URL, DM_AGENT_CHANNEL_ID (optional override).

const NO_PINGS = { parse: [], repliedUser: false };
// Discord turns a paste over 2000 characters into a message.txt attachment. Text attachments are read (Discord's CDN only, size-capped)
// and handed to the runner as part of the message, which wraps all of it as the person's (untrusted) text.
const TEXT_FILE = /\.(txt|log|md|json|csv|tsv|js|cjs|mjs|ts|css|html|ya?ml|diff|patch|ini|cfg|sql)$/i;
const FILE_MAX_BYTES = 100 * 1024;
const FILES_MAX_CHARS = 60000;
const IMAGE = /\.(png|jpe?g|webp|gif)$/i;
const IMAGE_MAX_BYTES = 8 * 1024 * 1024;
const IMAGES_PER_MESSAGE = 4;
const CDN = /^https:\/\/(cdn\.discordapp\.com|media\.discordapp\.net)\//;

function createAdapter({ client, runnerUrl, secret, fetchImpl = fetch, fetchFile = fetch, channelIdOverride = '', log = console.log, pollWaitSec = 25, retryDelays = [1000, 2000, 4000, 8000, 15000], ownPostWaitMs = 8000 }) {
  let cachedChannel = channelIdOverride || ''; let cachedBugChannel = ''; let cachedJobs = ''; let cachedTalk = []; let cachedAt = 0; let stopped = false;
  const headers = { 'content-type': 'application/json', 'x-dm-secret': secret };
  // Messages, reactions and thread events are retried for ~30 s when the runner is unreachable (it restarts in a couple of seconds after an
  // update), so nothing someone types during a restart is lost. Only connection failures retry; an HTTP error answer is final.
  async function call(path, body) {
    const once = () => fetchImpl(`${runnerUrl}${path}`, { method: body === undefined ? 'GET' : 'POST', headers, body: body === undefined ? undefined : JSON.stringify(body) });
    let res;
    for (let i = 0; ; i++) {
      try { res = await once(); break; }
      catch (e) { if (!(path === '/event' || path === '/bind') || i >= retryDelays.length) throw e; await new Promise((r) => setTimeout(r, retryDelays[i])); }
    }
    if (!res.ok) throw new Error(`runner ${path} -> ${res.status}`);
    return res.json();
  }
  async function refresh() {
    if (Date.now() - cachedAt <= 60000) return;
    try { const c = await call('/config'); cachedChannel = channelIdOverride || c.channelId || cachedChannel; cachedBugChannel = c.bugChannelId || ''; cachedJobs = c.jobsChannelId || ''; cachedTalk = (c.talkChannelIds || []).map(String); cachedAt = Date.now(); } catch { /* keep cached */ }
  }
  async function channelId() { await refresh(); return channelIdOverride || cachedChannel; }
  // The channels the runner serves: the main one and (optional) the bug-report one, the #jobs forum and the discussion forums.
  async function ours(id) { await refresh(); return !!id && [channelIdOverride || cachedChannel, cachedBugChannel, cachedJobs, ...cachedTalk].some((c) => c && String(c) === String(id)); }
  const botId = () => client.user && client.user.id;
  const stripMention = (t) => String(t || '').replace(new RegExp(`<@!?${botId()}>`, 'g'), '').trim();
  // Returns the text to append; image attachments (Discord CDN only, <= 8 MB, <= 4 per message) are pushed onto `images` as { name, b64 }.
  async function attachmentText(msg, images = []) {
    const out = []; const skipped = []; let budget = FILES_MAX_CHARS;
    for (const a of msg.attachments ? msg.attachments.values() : []) {
      const name = String(a.name || 'file');
      if (IMAGE.test(name) || /^image\/(png|jpe?g|webp|gif)\b/i.test(String(a.contentType || ''))) {
        if (!CDN.test(String(a.url || ''))) { skipped.push(`${name} (not hosted on Discord)`); continue; }
        if (a.size > IMAGE_MAX_BYTES) { skipped.push(`${name} (image over 8 MB)`); continue; }
        if (images.length >= IMAGES_PER_MESSAGE) { skipped.push(`${name} (only ${IMAGES_PER_MESSAGE} images per message)`); continue; }
        try {
          const res = await fetchFile(a.url); if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const buf = Buffer.from(await res.arrayBuffer());
          if (buf.length > IMAGE_MAX_BYTES) { skipped.push(`${name} (image over 8 MB)`); continue; }
          images.push({ name, b64: buf.toString('base64') });
        } catch (e) { log('[dm-agent] image read failed', e.message); skipped.push(`${name} (could not be downloaded)`); }
        continue;
      }
      const isText = TEXT_FILE.test(name) || /^text\//.test(String(a.contentType || ''));
      if (!isText || !CDN.test(String(a.url || ''))) { skipped.push(name); continue; }
      if (a.size > FILE_MAX_BYTES || budget <= 0) { skipped.push(`${name} (too large to read)`); continue; }
      try {
        const res = await fetchFile(a.url); if (!res.ok) throw new Error(`HTTP ${res.status}`);
        let t = await res.text(); const cut = t.length > budget; t = t.slice(0, budget); budget -= t.length;
        out.push(`[attached file ${name}${cut ? ', cut short' : ''}]\n${t}\n[end of ${name}]`);
      } catch (e) { log('[dm-agent] attachment read failed', e.message); skipped.push(`${name} (could not be read)`); }
    }
    return (out.length ? `\n\n${out.join('\n\n')}` : '') + (skipped.length ? `\n[attachments not visible to the agent: ${skipped.join(', ')}]` : '');
  }
  const safeReply = (msg, content) => msg.reply({ content: String(content).slice(0, 1900), allowedMentions: NO_PINGS }).then((m) => remember(m && m.id)).catch((e) => log('[dm-agent] reply failed', e.message));
  // The ids of the messages this adapter sent. The bot's other messages in a thread of ours are a terminal session posting with the bot's account
  // (Helix 2026-10-28): forwarded as botPost after a short wait, because Discord can deliver a message before send() has returned its id.
  const own = new Set();
  const remember = (id) => { if (!id) return; own.add(String(id)); if (own.size > 1000) own.delete(own.values().next().value); };
  async function onOwnPost(msg) {
    const ch = msg.channel;
    if (msg.system || ![0, 19].includes(msg.type) || !(typeof ch.isThread === 'function' && ch.isThread()) || !await ours(ch.parentId)) return;   // plain messages and replies only
    await new Promise((r) => setTimeout(r, ownPostWaitMs));
    if (own.has(String(msg.id))) return;
    const images = [];
    const text = String(msg.content || '').trim() + await attachmentText(msg, images);
    if (!text.trim() && !images.length) return;
    await call('/event', { type: 'message', botPost: true, messageId: msg.id, channelId: ch.parentId, threadId: ch.id, parentId: ch.parentId, userId: msg.author.id,
      username: 'Claude (terminal session)', text, mentioned: false, mentions: [], ...(images.length ? { images } : {}) });
  }

  async function onMessage(msg) {
    try {
      if (!msg.guild || !msg.author) return;
      if (msg.author.bot) return void (msg.author.id === botId() && await onOwnPost(msg));
      const ch = msg.channel; const isThread = typeof ch.isThread === 'function' && ch.isThread();
      const parentId = isThread ? ch.parentId : null;
      if (!await ours(isThread ? parentId : ch.id)) return;
      const mentioned = !!(!!(msg.mentions && msg.mentions.users && msg.mentions.users.has(botId())) || (!!msg.guild?.members?.me?.roles?.botRole && !!msg.mentions?.roles?.has?.(msg.guild.members.me.roles.botRole.id)));   // @bot or the bot's own managed role (same name in the @ menu), never @everyone
      if (!isThread && !mentioned) return;
      const images = [];
      const text = stripMention(msg.content) + await attachmentText(msg, images);
      // Who it is said to (the runner decides): the other people named in it, and whose message it replies to. A reply's own ping is not in
      // the text, so only real <@id> mentions count as naming someone.
      const mentions = [...new Set([...String(msg.content || '').matchAll(/<@!?(\d+)>/g)].map((m) => m[1]).filter((id) => id !== botId()))].slice(0, 10);
      let replyTo;
      if (msg.reference && msg.reference.messageId && typeof msg.fetchReference === 'function') {
        const ref = await msg.fetchReference().catch(() => null);
        if (ref && ref.author) replyTo = { bot: ref.author.id === botId(), userId: String(ref.author.id) };
      }
      // A forum post (#jobs or a discussion forum): an @-mention (or !job) carries the post's title, its opening message and its last 50 messages
      // before this one (the runner uses them only when this brings the bot into the post).
      let post;
      const forum = isThread && [cachedJobs, ...cachedTalk].some((c) => c && String(c) === String(parentId));
      if (forum && (mentioned || /^!job\b/i.test(stripMention(msg.content)))) {
        post = { title: String(ch.name || '') };
        if (msg.id !== ch.id) {
          const first = typeof ch.fetchStarterMessage === 'function' ? await ch.fetchStarterMessage().catch(() => null) : null;
          if (first && first.content) post.text = stripMention(first.content).slice(0, 4000);
        }
        const recent = ch.messages && typeof ch.messages.fetch === 'function' ? await ch.messages.fetch({ limit: 50, before: msg.id }).catch(() => null) : null;
        if (recent) post.history = [...recent.values()].reverse().filter((m) => m.content).map((m) => ({ name: (m.member && m.member.displayName) || (m.author && m.author.username) || 'someone',
          text: stripMention(m.content).slice(0, 1500), bot: !!(m.author && m.author.id === botId()) }));
      }
      const r = await call('/event', { type: 'message', messageId: msg.id, channelId: isThread ? parentId : ch.id, threadId: isThread ? ch.id : null, parentId,
        userId: msg.author.id, username: msg.member && msg.member.displayName || msg.author.username, text, mentioned, mentions, ...(replyTo ? { replyTo } : {}), ...(images.length ? { images } : {}), ...(post ? { post } : {}) });
      if (r.action === 'reply') return void safeReply(msg, r.text);
      // The runner shows "typing…" while it works; a reaction only marks a message that has to wait its turn.
      if (r.action === 'accepted') return void (r.queued && msg.react && msg.react('⏳').catch(() => {}));
      if (r.action === 'create_thread') {
        let thread;
        try { thread = await msg.startThread({ name: r.threadName || 'Death Muffin request', autoArchiveDuration: 1440 }); }
        catch (e) { log('[dm-agent] thread failed', e.message); await call('/bind', { eventId: r.eventId, error: e.message }); return void safeReply(msg, 'I could not open a thread for this (missing permission?).'); }
        await call('/bind', { eventId: r.eventId, threadId: thread.id });
      }
    } catch (e) { log('[dm-agent] message handler error', e.message); }
  }

  async function onReaction(reaction, user) {
    try {
      if (!user || user.bot) return;
      if (reaction.partial) await reaction.fetch();
      if (reaction.message.partial) await reaction.message.fetch();
      const emoji = reaction.emoji && reaction.emoji.name; if (!['✅', '🧪', '❌'].includes(emoji)) return;
      const m = reaction.message; if (!m.author || m.author.id !== botId()) return;
      const ch = m.channel; if (!(typeof ch.isThread === 'function' && ch.isThread())) return;
      if (!await ours(ch.parentId)) return;
      const r = await call('/event', { type: 'reaction', messageId: m.id, channelId: ch.parentId, threadId: ch.id, parentId: ch.parentId, userId: user.id, emoji });
      if (r.action === 'remove_reaction') await reaction.users.remove(user.id).catch(() => {});
    } catch (e) { log('[dm-agent] reaction handler error', e.message); }
  }

  // A thread deleted in Discord: tell the runner so it can drop the job's workspace/branch/preview right away.
  async function onThreadDelete(thread) {
    try {
      if (!thread || !await ours(thread.parentId)) return;
      await call('/event', { type: 'thread-deleted', threadId: thread.id, parentId: thread.parentId, channelId: thread.parentId });
    } catch (e) { log('[dm-agent] thread delete handler error', e.message); }
  }

  async function exec(op) {
    const t = op.target || {};
    const ch = await client.channels.fetch(t.threadId || t.channelId);
    const payload = { allowedMentions: op.mentionUsers && op.mentionUsers.length ? { parse: [], users: op.mentionUsers.slice(0, 5) } : NO_PINGS };
    if (op.content) payload.content = String(op.content).slice(0, 1990);
    if (op.embed) payload.embeds = [op.embed];
    if (op.file && op.file.text) payload.files = [{ attachment: Buffer.from(String(op.file.text), 'utf8'), name: String(op.file.name || 'reply.md').replace(/[^\w.-]/g, '_') }];
    if (Array.isArray(op.files)) {   // images from the runner (base64): up to 4, names sanitized
      const imgs = op.files.slice(0, 4).filter((f) => f && f.b64).map((f) => ({ attachment: Buffer.from(String(f.b64), 'base64'), name: String(f.name || 'image.png').replace(/[^\w.-]/g, '_') }));
      payload.files = (payload.files || []).concat(imgs);
    }
    if (t.replyTo) payload.reply = { messageReference: t.replyTo, failIfNotExists: false };
    const sent = await ch.send(payload);
    remember(sent && sent.id);
    return sent;
  }
  // Renaming a thread the bot started itself: Discord lets a thread's owner edit its name, so no extra permission is normally needed.
  // Manage Threads is only needed for threads someone else started. discord.js's `manageable` (Manage Threads) is deliberately not checked.
  // An archived thread is skipped (editing it needs Manage Threads and would not reopen it); every failure is logged and swallowed.
  async function renameThread(threadId, name) {
    try {
      const ch = await client.channels.fetch(String(threadId));
      if (!ch || typeof ch.isThread !== 'function' || !ch.isThread()) return;
      if (ch.archived) { log('[dm-agent] rename skipped, thread archived'); return; }
      const n = String(name || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 100);
      if (n && n !== ch.name) await ch.setName(n, 'Death Muffin dev agent: issue title');
    } catch (e) { log('[dm-agent] rename failed', e.message); }
  }
  // Archiving a finished job's thread (the runner decides when). The bot started the thread; if Discord refuses, give the bot Manage Threads
  // in the channel. An already archived or missing thread is skipped; failures are logged, and the op is acked either way.
  async function archiveThread(threadId) {
    try {
      const ch = await client.channels.fetch(String(threadId));
      if (!ch || typeof ch.isThread !== 'function' || !ch.isThread() || ch.archived) return;
      await ch.setArchived(true, 'Death Muffin dev agent: finished, archived to keep the channel tidy');
    } catch (e) { log('[dm-agent] archive failed', e.message); }
  }
  // A #jobs post's tags (the runner names them): `remove` comes off, `add` goes on, every other tag (War, Helix, ...) stays; names match the
  // forum's tags ignoring case, and a name the forum lacks is skipped. Discord allows 5 tags a post, so the added ones are kept first. Editing
  // another person's post needs Manage Threads; an archived post is skipped. Failures are logged and swallowed.
  async function setTags({ threadId, add = [], remove = [] }) {
    try {
      const ch = await client.channels.fetch(String(threadId));
      if (!ch || typeof ch.isThread !== 'function' || !ch.isThread() || ch.archived) return;
      const forum = ch.parent || await client.channels.fetch(String(ch.parentId));
      const byName = new Map(((forum && forum.availableTags) || []).map((t) => [String(t.name).toLowerCase(), String(t.id)]));
      const ids = (names) => names.map((n) => byName.get(String(n).toLowerCase())).filter(Boolean);
      const drop = new Set([...ids(remove), ...ids(add)]);
      const next = [...new Set([...ids(add), ...(ch.appliedTags || []).map(String).filter((id) => !drop.has(id))])].slice(0, 5);
      const cur = (ch.appliedTags || []).map(String);
      if (next.length !== cur.length || next.some((id) => !cur.includes(id))) await ch.setAppliedTags(next, 'Death Muffin dev agent: job status');
    } catch (e) { log('[dm-agent] tags failed', e.message); }
  }
  // A new #jobs post from a discussion (!job): opened with the runner's text and tags (by name; one the forum lacks is skipped), pinging nobody.
  async function openPost({ channelId, name, content, tags = [] }) {
    const forum = await client.channels.fetch(String(channelId));
    const byName = new Map(((forum && forum.availableTags) || []).map((t) => [String(t.name).toLowerCase(), t]));
    const applied = tags.map((n) => byName.get(String(n).toLowerCase())).filter(Boolean).slice(0, 5);
    const t = await forum.threads.create({ name: String(name || 'Job').slice(0, 100), message: { content: String(content || '').slice(0, 1990), allowedMentions: NO_PINGS },
      appliedTags: applied.map((x) => String(x.id)), reason: 'Death Muffin dev agent: !job from a discussion' });
    remember(t.id);   // a forum post's opening message has the post's id
    return { threadId: t.id, tags: applied.map((x) => String(x.name)) };
  }
  async function pollOnce() {
    const { ops } = await call(`/poll?wait=${pollWaitSec}`);
    for (const op of ops || []) {
      if (op.typing) {   // fire-and-forget; the runner never waits for an ack on these
        const t = op.target || {}; await client.channels.fetch(t.threadId || t.channelId).then((ch) => ch.sendTyping()).catch(() => {});
        continue;
      }
      if (op.rename) {   // fire-and-forget: a thread can only be renamed ~2 times per 10 min, the runner paces them. Never awaited: a rename
        // held by Discord's rate limit blocked every op behind it (2026-10-12: a proposal appeared 4.5 min late after a runner restart
        // forgot the pacing). discord.js keeps same-thread renames in order; renameThread logs and swallows its own failures.
        const r = op.rename; renameThread(r.threadId, r.name); continue;
      }
      if (op.archive) { await archiveThread(op.archive.threadId); await call('/ack', { id: op.id, result: {}, ok: true }); continue; }
      if (op.tags) { await setTags(op.tags); await call('/ack', { id: op.id, result: {}, ok: true }); continue; }
      if (op.forumPost) {
        let result; let ok = true;
        try { result = await openPost(op.forumPost); } catch (e) { ok = false; result = { error: e.message }; log('[dm-agent] job post failed', e.message); }
        await call('/ack', { id: op.id, result, ok }); continue;
      }
      let result; let failed = false; let sent;
      try { sent = await exec(op); result = { messageId: sent.id }; } catch (e) { failed = true; result = { error: e.message }; log('[dm-agent] send failed', e.message); }
      if (!failed && op.newThread) {   // a new bug report: the post opens its own thread (the runner records it from the ack)
        try { const t = await sent.startThread({ name: String(op.newThread.name || 'Bug report').slice(0, 100), autoArchiveDuration: op.newThread.autoArchiveMin || 4320 }); result.threadId = t.id; }
        catch (e) { failed = true; result.error = e.message; log('[dm-agent] report thread failed', e.message); }
      }
      await call('/ack', { id: op.id, result, ok: !failed });       // ack BEFORE reacting so the runner knows the proposal message id first
      if (!failed && sent && op.reactions) for (const r of op.reactions) await sent.react(r).catch(() => {});
    }
  }
  async function loop() {
    while (!stopped) { try { await pollOnce(); } catch (e) { log('[dm-agent] poll error', e.message); await new Promise((r) => setTimeout(r, 5000)); } }
  }
  return { onMessage, onReaction, onThreadDelete, pollOnce, loop, stop: () => { stopped = true; }, channelId };
}

function attach(client, env = process.env) {
  if (!env.DM_AGENT_SECRET) { console.log('[dm-agent] DM_AGENT_SECRET not set; Death Muffin dev agent disabled'); return null; }
  const ad = createAdapter({ client, runnerUrl: env.DM_AGENT_URL || 'http://127.0.0.1:4321', secret: env.DM_AGENT_SECRET, channelIdOverride: env.DM_AGENT_CHANNEL_ID || '' });
  client.on('messageCreate', (m) => ad.onMessage(m));
  client.on('messageReactionAdd', (r, u) => ad.onReaction(r, u));
  client.on('threadDelete', (t) => ad.onThreadDelete(t));
  client.once('clientReady', () => { ad.loop(); console.log('[dm-agent] adapter running'); });
  return ad;
}
module.exports = { attach, createAdapter };
