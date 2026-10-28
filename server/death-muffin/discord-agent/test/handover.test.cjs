'use strict';
// What a thread keeps outside its workspace, a terminal session's posts, the agent's notes, a discussion's drafts and concept pictures, and the
// handover from a discussion to a job: the brief, its ✅, an update, and the line back when the job ships or is dropped (Helix 2026-10-28).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), path = require('path');
const { IDS, makeWorld, makeDiscord, until, sh } = require('./harness.cjs');
const BOT = `<@${IDS.BOT}>`;

const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
const proposalOf = (thread) => thread.sent.filter((s) => s.payload && s.payload.embeds && s.reactions.length >= 2).pop();
const briefOf = (thread, title) => thread.sent.filter((s) => (s.payload.content || '').startsWith(`📋 **Job brief: ${title}**`) && s.reactions.includes('✅')).pop();
const keepOf = (w, job, ...p) => path.join(w.cfg.stateDir, 'keep', job.id, ...p);
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(300, 7)]);
const imgAtt = (name) => ({ name, contentType: 'image/png', size: PNG.length, url: `https://cdn.discordapp.com/attachments/1/2/${name}` });
const fetchPng = async () => ({ ok: true, status: 200, arrayBuffer: async () => PNG.buffer.slice(PNG.byteOffset, PNG.byteOffset + PNG.length), text: async () => '' });
// a message the bot's account posted that the adapter did not send (a terminal session's), as Discord delivers it
const botPost = (d, chan, content) => {
  const m = { id: String(d.world.nextId++), channel: chan, guild: { id: '1' }, author: { id: IDS.BOT, bot: true }, content, type: 0, system: false, attachments: new Map(), mentions: { users: { has: () => false } } };
  chan.log.push(m); return d.ad.onMessage(m).then(() => m);
};
async function talkPost(d, w, title, text) {
  const { thread } = await d.forumPost(IDS.HELIX, title, text, [], d.talk);
  return thread;
}

test('a terminal session\'s post in a job thread is team talk: kept whole, read with the next turn, never a turn of its own; the adapter\'s own posts are not', async () => {
  const w = makeWorld(); const d = makeDiscord(w.runner, { ownPostWaitMs: 0 });
  await d.say(d.main, IDS.HELIX, `${BOT} where is player speed defined?`);
  const thread = await until(() => d.world.threads[0], d.ad);
  const job = Object.values(w.runner.jobs())[0];
  await until(() => job.status === 'idle' && !job.running && texts(thread).some((t) => /answer is in/.test(t)), d.ad);
  const own = thread.sent[thread.sent.length - 1]; own.author = { id: IDS.BOT, bot: true }; own.type = 0;
  await d.ad.onMessage(own);   // the adapter's own reply comes back from Discord: dropped
  assert.equal((job.asides || []).length, 0);
  const turns = job.totalTurns;
  const long = `ASIDE-MARK the speed lives in client/game/a.gd. ${'x'.repeat(2000)} TAIL-MARK`;
  const m = await botPost(d, thread, long);
  await d.ad.pollOnce();
  assert.equal(job.totalTurns, turns, 'no turn for it');
  assert.equal(job.asides.length, 1); assert.equal(job.asides[0].name, 'Claude (terminal session)');
  const id = m.id.replace(/\D/g, '');
  assert.match(job.asides[0].text, new RegExp(`\\[the whole post: \\.dm-keep/posts/${id}\\.md\\]$`));
  assert.match(fs.readFileSync(path.join(job.worktree, '.dm-keep', 'posts', `${id}.md`), 'utf8'), /TAIL-MARK$/, 'kept whole, in the workspace too');
  await d.say(thread, IDS.HELIX, 'thanks, and the jump height?');
  await until(() => texts(thread).some((t) => /ASIDES-SEEN/.test(t)), d.ad);
  assert.equal(sh(job.worktree, 'status', '--porcelain'), '', 'the keep\'s copies are git-excluded');
  // a thread without a job, or a message the runner itself sent (its id came back with an ack), is ignored
  assert.deepEqual(await w.runner.handleEvent({ type: 'message', botPost: true, messageId: own.id, threadId: thread.id, parentId: IDS.CHAN, channelId: IDS.CHAN, userId: IDS.BOT, text: 'mine' }), { action: 'ignore' });
  assert.equal(job.asides.length, 0, 'the earlier one went with the turn');
});

test('notes and images outlive the workspace: a new round gets the thread\'s notes and its earlier images back', async () => {
  const w = makeWorld(); const d = makeDiscord(w.runner, { fetchFile: fetchPng });
  await d.say(d.main, IDS.HELIX, `${BOT} NOTE-WRITE bone or wood?`, [imgAtt('shield.png')]);
  const thread = await until(() => d.world.threads[0], d.ad);
  const job = Object.values(w.runner.jobs())[0];
  await until(() => job.status === 'idle' && !job.running && texts(thread).length, d.ad);
  assert.match(fs.readFileSync(keepOf(w, job, 'notes.md'), 'utf8'), /NOTE-MARK/, 'kept after the turn');
  assert.deepEqual(fs.readdirSync(keepOf(w, job, 'inbox')).map((f) => f.replace(/^\d+-/, '')), ['shield.png']);
  const first = job.worktree;
  await d.say(thread, IDS.HELIX, '!discard'); await until(() => job.status === 'discarded', d.ad);
  assert.ok(!fs.existsSync(first));
  await d.say(thread, IDS.HELIX, 'start over please');
  await until(() => job.round === 2 && texts(thread).some((t) => /NOTES-SEEN/.test(t)), d.ad);
  assert.deepEqual(fs.readdirSync(path.join(job.worktree, '.dm-inbox')).map((f) => f.replace(/^\d+-/, '')), ['shield.png']);
  assert.match(fs.readFileSync(path.join(job.worktree, '.dm-notes.md'), 'utf8'), /NOTE-MARK/);
  // the keep goes with the thread
  await until(() => !job.running, d.ad);
  await w.runner.handleEvent({ type: 'thread-deleted', threadId: thread.id, parentId: IDS.CHAN, channelId: IDS.CHAN });
  await until(() => job.status === 'deleted', d.ad);
  assert.ok(!fs.existsSync(keepOf(w, job)));
});

test('a discussion\'s drafts are posted as files once each, kept, and carried into the job with the whole conversation', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS, talkChannelIds: [IDS.TALK] }); const d = makeDiscord(w.runner);
  const thread = await talkPost(d, w, 'Ossuary bone shield', 'LOG-MARKER-77 a bone shield?');
  await d.say(thread, IDS.HELIX, `${BOT} write the kit up DRAFT-WRITE`);
  const job = w.runner.jobs()[thread.id];
  const draft = await until(() => thread.sent.find((s) => /^📝 Draft: `kit\.md`/.test(s.payload.content || '')), d.ad);
  assert.equal(draft.payload.files[0].name, 'kit.md'); assert.match(String(draft.payload.files[0].attachment), /DRAFT-BODY/);
  assert.match(fs.readFileSync(keepOf(w, job, 'drafts', 'kit.md'), 'utf8'), /DRAFT-BODY/);
  await until(() => !job.running, d.ad);
  let n = texts(thread).length;
  await d.say(thread, IDS.HELIX, 'looks fine');
  await until(() => !job.running && texts(thread).length > n, d.ad);
  assert.equal(thread.sent.filter((s) => /Draft: `kit\.md`/.test(s.payload.content || '')).length, 1, 'an unchanged draft is not posted again');
  await d.say(thread, IDS.HELIX, 'tighten it DRAFT-EDIT and DRAFT-BAD');
  await until(() => thread.sent.some((s) => /^📝 Updated draft: `kit\.md`/.test(s.payload.content || '')), d.ad);
  await until(() => texts(thread).some((t) => /^Not posted: `evil\.sh`\. A draft is a \.md, \.txt, \.json or \.csv file/.test(t)), d.ad);
  await until(() => !job.running, d.ad);
  await d.say(thread, IDS.HELIX, '!job');
  const brief = await until(() => briefOf(thread, 'Bone shield for the Ossuary'), d.ad);
  await d.react(brief, IDS.HELIX, '✅');
  const post = await until(() => (d.world.posts || [])[0], d.ad);
  const nj = await until(() => w.runner.jobs()[post.id], d.ad);
  assert.match(fs.readFileSync(keepOf(w, nj, 'handover', 'drafts', 'kit.md'), 'utf8'), /Bone kit v2/);
  const conv = fs.readFileSync(keepOf(w, nj, 'handover', 'discussion.md'), 'utf8');
  assert.match(conv, /^### .* · \d{4}-\d\d-\d\d \d\d:\d\d UTC\nLOG-MARKER-77 a bone shield\?/, 'from the post\'s first message'); assert.match(conv, /posted the draft kit\.md/);
  assert.match(fs.readFileSync(keepOf(w, nj, 'handover', 'brief.md'), 'utf8'), /^# Bone shield for the Ossuary\n\nConfirmed with ✅ by Helix on \d{4}-\d\d-\d\d, from the discussion "Ossuary bone shield" \(asked by Helix\)\.\n\n\*\*Goal:\*\*/);
  await d.say(post, IDS.HELIX, `${BOT} build it`);
  await until(() => texts(post).some((t) => /HANDOVER-SEEN DISCUSSION-CAME DRAFT-CAME/.test(t)), d.ad);
});

test('a reply corrects the brief before the ✅; only the newest brief opens the job; a reply not in the format opens nothing', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS, talkChannelIds: [IDS.TALK] }); const d = makeDiscord(w.runner);
  const thread = await talkPost(d, w, 'Shields', 'a shield for the ossuary');
  await d.say(thread, IDS.HELIX, '!job BRIEF-BAD');
  await until(() => texts(thread).some((t) => t === 'I could not write that up as a job brief. Try `!job` again.'), d.ad);
  const job = w.runner.jobs()[thread.id]; await until(() => !job.running, d.ad);
  await d.say(thread, IDS.HELIX, '!job');
  const first = await until(() => briefOf(thread, 'Bone shield for the Ossuary'), d.ad);
  await until(() => !job.running, d.ad);
  await d.say(thread, IDS.HELIX, 'BRIEF-FIX make it blue');
  const fixed = await until(() => briefOf(thread, 'Blue bone shield for the Ossuary'), d.ad);
  assert.match(fixed.payload.content, /BRIEF-FIXED/);
  await d.react(first, IDS.HELIX, '✅'); await d.ad.pollOnce();
  assert.equal((d.world.posts || []).length, 0, 'the replaced brief\'s ✅ does nothing');
  await d.react(fixed, IDS.HELIX, '✅');
  const post = await until(() => (d.world.posts || [])[0], d.ad);
  assert.equal(post.name, 'Blue bone shield for the Ossuary');
  await d.react(fixed, IDS.LIMITED, '✅'); await d.ad.pollOnce();
  assert.equal(d.world.posts.length, 1, 'a second ✅ opens nothing more');
});

test('one discussion, one job: !job again sends an update into the job; !job new opens another; the discussion hears when a job ships or is dropped', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS, talkChannelIds: [IDS.TALK] }); const d = makeDiscord(w.runner);
  const thread = await talkPost(d, w, 'Ossuary bone shield', 'a bone shield');
  await d.say(thread, IDS.HELIX, '!job');
  await d.react(await until(() => briefOf(thread, 'Bone shield for the Ossuary'), d.ad), IDS.HELIX, '✅');
  const post = await until(() => (d.world.posts || [])[0], d.ad);
  const talk = w.runner.jobs()[thread.id]; await until(() => !talk.running && texts(thread).some((t) => /^Made it a job/.test(t)), d.ad);
  // the job builds it: the proposal says how it measures against the brief
  await d.say(post, IDS.HELIX, `${BOT} GD-DOC readme BRIEF-CHECK`);
  const p = await until(() => proposalOf(post), d.ad);
  assert.deepEqual(p.payload.embeds[0].fields[0], { name: 'Brief', value: '4 of 5 done; not yet: the door glow', inline: false });
  // the update: same brief format, into the job thread, read with its next turn
  await d.say(thread, IDS.HELIX, '!job');
  const upd = await until(() => thread.sent.find((s) => /^📋 \*\*Job brief:/.test(s.payload.content || '') && new RegExp(`sends it to <#${post.id}> as an update`).test(s.payload.content) && s.reactions.includes('✅')), d.ad);
  assert.match(upd.payload.content, /UPDATE-BRIEF/);
  await d.react(upd, IDS.HELIX, '✅');
  await until(() => texts(post).some((t) => t.startsWith(`📋 **Update from <#${thread.id}>**, confirmed by Helix: Bone shield for the Ossuary`)), d.ad);
  await until(() => texts(thread).some((t) => t.startsWith(`Sent the update to <#${post.id}>`)), d.ad);
  assert.equal(d.world.posts.length, 1);
  const job = w.runner.jobs()[post.id];
  assert.match(fs.readFileSync(keepOf(w, job, 'handover', 'brief.md'), 'utf8'), /UPDATE-BRIEF/, 'the update replaced the brief');
  await d.say(post, IDS.HELIX, `${BOT} pick up the update`);
  await until(() => texts(post).some((t) => /UPDATE-SEEN/.test(t)), d.ad);
  await until(() => job.status === 'proposed' && !job.running, d.ad);
  // ship it: the discussion hears, once
  await d.react(proposalOf(post), IDS.HELIX, '✅');
  await until(() => job.status === 'shipped', d.ad);
  const sha = String(job.proposal.shipSha).slice(0, 7);
  await until(() => texts(thread).some((t) => t === `✅ The job from this discussion shipped: <#${post.id}> (\`${sha}\`).`), d.ad);
  // the job shipped: !job opens a new one now, and so does !job new
  await until(() => !talk.running, d.ad);
  await d.say(thread, IDS.HELIX, '!job new');
  const again = await until(() => { const b = briefOf(thread, 'Bone shield for the Ossuary'); return b !== upd && /opens it as a #jobs post\./.test(b.payload.content) && b; }, d.ad);
  await d.react(again, IDS.HELIX, '✅');
  const second = await until(() => d.world.posts[1], d.ad);
  assert.equal(talk.handoverTo, second.id);
  // a job that is dropped says so too
  const j2 = w.runner.jobs()[second.id];
  await d.say(second, IDS.HELIX, `${BOT} where is the readme?`);
  await until(() => j2.worktree && !j2.running, d.ad);
  assert.equal(j2.proposal, null);
  await d.say(second, IDS.HELIX, '!discard');
  await until(() => texts(thread).some((t) => t === `The job from this discussion was dropped for now: <#${second.id}>. It can be picked up there again.`), d.ad);
  assert.equal(texts(thread).filter((t) => /The job from this discussion shipped/.test(t)).length, 1);
});

test('concept pictures in a discussion: made and posted there, nothing built; !job carries them into the job\'s workspace', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS, talkChannelIds: [IDS.TALK] }); fs.writeFileSync(w.budgetFile, JSON.stringify({ [IDS.HELIX]: 1000 }));
  const d = makeDiscord(w.runner);
  const thread = await talkPost(d, w, 'Reaper icons', 'new icons?');
  await d.say(thread, IDS.HELIX, `${BOT} show me GD-PICTURE ids=icon_reaper_reap`);
  const posted = await until(() => thread.sent.find((s) => /Concept art/.test(s.payload.content || '')), d.ad);
  assert.match(posted.payload.content, /Nothing is in the game\. Reply with what to change, keep or drop; `!job` carries the pictures into the job\.$/);
  const talk = w.runner.jobs()[thread.id];
  await until(() => talk.status === 'idle' && !talk.running, d.ad);
  assert.ok(talk.concepts.icon_reaper_reap);
  await d.say(thread, IDS.HELIX, '!job');
  await d.react(await until(() => briefOf(thread, 'Bone shield for the Ossuary'), d.ad), IDS.HELIX, '✅');
  const post = await until(() => (d.world.posts || [])[0], d.ad);
  const job = await until(() => w.runner.jobs()[post.id], d.ad);
  assert.equal(job.concepts.icon_reaper_reap.sha, talk.concepts.icon_reaper_reap.sha);
  await d.say(post, IDS.HELIX, `${BOT} CONCEPTS-BACK?`);
  await until(() => texts(post).some((t) => /CONCEPTS-BACK-SEEN/.test(t)), d.ad);
  assert.ok(fs.existsSync(path.join(job.worktree, 'art-src', 'concepts', 'icon_reaper_reap.png')));
});

test('a thread\'s kept files are never part of a change: the notes, drafts, attachments and kept discussion are forbidden paths', () => {
  const { DEFAULTS } = require('../runner/lib/config.cjs');
  const { classifyDiff } = require('../runner/lib/tiers.cjs');
  const files = ['.dm-keep/handover/discussion.md', '.dm-drafts/kit.md', '.dm-inbox/shot.png', '.dm-notes.md'];
  const diff = files.map((f) => `diff --git a/${f} b/${f}\n--- /dev/null\n+++ b/${f}\n@@ -0,0 +1 @@\n+x\n`).join('');
  assert.deepEqual(classifyDiff(diff, DEFAULTS).forbidden, files);
});
