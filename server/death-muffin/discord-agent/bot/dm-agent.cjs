'use strict';
// Death Muffin dev-agent adapter for the Muffin Core Discord bot. A dumb transport: it forwards @mentions / thread messages / ✅❌ reactions
// in ONE configured channel to the loopback runner and posts whatever the runner asks it to post. All decisions (allow-list, approver
// gate, tiers, rate limits) live in the runner; the bot holds no authority and no secret except the shared runner secret.
// Installed to /opt/muffin/discord/dm-agent.js. Env (from /opt/muffin/dm-agent.env): DM_AGENT_SECRET, DM_AGENT_URL, DM_AGENT_CHANNEL_ID (optional override).

const NO_PINGS = { parse: [], repliedUser: false };

function createAdapter({ client, runnerUrl, secret, fetchImpl = fetch, channelIdOverride = '', log = console.log, pollWaitSec = 25 }) {
  let cachedChannel = channelIdOverride || ''; let cachedAt = 0; let stopped = false;
  const headers = { 'content-type': 'application/json', 'x-dm-secret': secret };
  async function call(path, body) {
    const res = await fetchImpl(`${runnerUrl}${path}`, { method: body === undefined ? 'GET' : 'POST', headers, body: body === undefined ? undefined : JSON.stringify(body) });
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
  const safeReply = (msg, content) => msg.reply({ content: String(content).slice(0, 1900), allowedMentions: NO_PINGS }).catch((e) => log('[dm-agent] reply failed', e.message));

  async function onMessage(msg) {
    try {
      if (!msg.guild || !msg.author || msg.author.bot) return;
      const ch = msg.channel; const isThread = typeof ch.isThread === 'function' && ch.isThread();
      const parentId = isThread ? ch.parentId : null; const chan = await channelId();
      if (!chan || (isThread ? parentId : ch.id) !== chan) return;
      const mentioned = !!(msg.mentions && msg.mentions.users && msg.mentions.users.has(botId()));   // explicit @bot only, never @everyone
      if (!isThread && !mentioned) return;
      const attachments = [...(msg.attachments ? msg.attachments.values() : [])].map((a) => a.name).filter(Boolean);
      let text = stripMention(msg.content); if (attachments.length) text += `\n[attachments not visible to the agent: ${attachments.join(', ')}]`;
      const r = await call('/event', { type: 'message', messageId: msg.id, channelId: isThread ? parentId : ch.id, threadId: isThread ? ch.id : null, parentId,
        userId: msg.author.id, username: msg.member && msg.member.displayName || msg.author.username, text, mentioned });
      if (r.action === 'reply') return void safeReply(msg, r.text);
      if (r.action === 'accepted') return void (msg.react && msg.react('👀').catch(() => {}));
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

  async function exec(op) {
    const t = op.target || {};
    const ch = await client.channels.fetch(t.threadId || t.channelId);
    const payload = { allowedMentions: op.mentionUsers && op.mentionUsers.length ? { parse: [], users: op.mentionUsers.slice(0, 5) } : NO_PINGS };
    if (op.content) payload.content = String(op.content).slice(0, 1990);
    if (op.embed) payload.embeds = [op.embed];
    if (t.replyTo) payload.reply = { messageReference: t.replyTo, failIfNotExists: false };
    const sent = await ch.send(payload);
    return sent;
  }
  async function pollOnce() {
    const { ops } = await call(`/poll?wait=${pollWaitSec}`);
    for (const op of ops || []) {
      let result; let failed = false; let sent;
      try { sent = await exec(op); result = { messageId: sent.id }; } catch (e) { failed = true; result = { error: e.message }; log('[dm-agent] send failed', e.message); }
      await call('/ack', { id: op.id, result, ok: !failed });       // ack BEFORE reacting so the runner knows the proposal message id first
      if (!failed && sent && op.reactions) for (const r of op.reactions) await sent.react(r).catch(() => {});
    }
  }
  async function loop() {
    while (!stopped) { try { await pollOnce(); } catch (e) { log('[dm-agent] poll error', e.message); await new Promise((r) => setTimeout(r, 5000)); } }
  }
  return { onMessage, onReaction, pollOnce, loop, stop: () => { stopped = true; }, channelId };
}

function attach(client, env = process.env) {
  if (!env.DM_AGENT_SECRET) { console.log('[dm-agent] DM_AGENT_SECRET not set; Death Muffin dev agent disabled'); return null; }
  const ad = createAdapter({ client, runnerUrl: env.DM_AGENT_URL || 'http://127.0.0.1:4321', secret: env.DM_AGENT_SECRET, channelIdOverride: env.DM_AGENT_CHANNEL_ID || '' });
  client.on('messageCreate', (m) => ad.onMessage(m));
  client.on('messageReactionAdd', (r, u) => ad.onReaction(r, u));
  client.once('clientReady', () => { ad.loop(); console.log('[dm-agent] adapter running'); });
  return ad;
}
module.exports = { attach, createAdapter };
