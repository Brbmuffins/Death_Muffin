'use strict';
// Death Muffin dev-agent adapter for the Muffin Core Discord bot. A dumb transport: it forwards @mentions / thread messages / ✅❌ reactions
// in ONE configured channel to the loopback runner and posts whatever the runner asks it to post. All decisions (allow-list, approver
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

function createAdapter({ client, runnerUrl, secret, fetchImpl = fetch, fetchFile = fetch, channelIdOverride = '', log = console.log, pollWaitSec = 25, retryDelays = [1000, 2000, 4000, 8000, 15000] }) {
  let cachedChannel = channelIdOverride || ''; let cachedAt = 0; let stopped = false;
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
  async function channelId() {
    if (channelIdOverride) return channelIdOverride;
    if (Date.now() - cachedAt > 60000) { try { cachedChannel = (await call('/config')).channelId || cachedChannel; cachedAt = Date.now(); } catch { /* keep cached */ } }
    return cachedChannel;
  }
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
  const safeReply = (msg, content) => msg.reply({ content: String(content).slice(0, 1900), allowedMentions: NO_PINGS }).catch((e) => log('[dm-agent] reply failed', e.message));

  async function onMessage(msg) {
    try {
      if (!msg.guild || !msg.author || msg.author.bot) return;
      const ch = msg.channel; const isThread = typeof ch.isThread === 'function' && ch.isThread();
      const parentId = isThread ? ch.parentId : null; const chan = await channelId();
      if (!chan || (isThread ? parentId : ch.id) !== chan) return;
      const mentioned = !!(msg.mentions && msg.mentions.users && msg.mentions.users.has(botId()));   // explicit @bot only, never @everyone
      if (!isThread && !mentioned) return;
      const images = [];
      const text = stripMention(msg.content) + await attachmentText(msg, images);
      const r = await call('/event', { type: 'message', messageId: msg.id, channelId: isThread ? parentId : ch.id, threadId: isThread ? ch.id : null, parentId,
        userId: msg.author.id, username: msg.member && msg.member.displayName || msg.author.username, text, mentioned, ...(images.length ? { images } : {}) });
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
      const emoji = reaction.emoji && reaction.emoji.name; if (emoji !== '✅' && emoji !== '❌') return;
      const m = reaction.message; if (!m.author || m.author.id !== botId()) return;
      const ch = m.channel; if (!(typeof ch.isThread === 'function' && ch.isThread())) return;
      if (ch.parentId !== await channelId()) return;
      const r = await call('/event', { type: 'reaction', messageId: m.id, channelId: ch.parentId, threadId: ch.id, parentId: ch.parentId, userId: user.id, emoji });
      if (r.action === 'remove_reaction') await reaction.users.remove(user.id).catch(() => {});
    } catch (e) { log('[dm-agent] reaction handler error', e.message); }
  }

  // A thread deleted in Discord: tell the runner so it can drop the job's workspace/branch/preview right away.
  async function onThreadDelete(thread) {
    try {
      const chan = await channelId(); if (!thread || !chan || String(thread.parentId) !== String(chan)) return;
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
    return sent;
  }
  async function pollOnce() {
    const { ops } = await call(`/poll?wait=${pollWaitSec}`);
    for (const op of ops || []) {
      if (op.typing) {   // fire-and-forget; the runner never waits for an ack on these
        const t = op.target || {}; await client.channels.fetch(t.threadId || t.channelId).then((ch) => ch.sendTyping()).catch(() => {});
        continue;
      }
      let result; let failed = false; let sent;
      try { sent = await exec(op); result = { messageId: sent.id }; } catch (e) { failed = true; result = { error: e.message }; log('[dm-agent] send failed', e.message); }
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
