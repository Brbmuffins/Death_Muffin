'use strict';
// The #jobs forum (Helix 2026-10-21): an @-mention in a post makes that post the job's thread; the runner sets the post's tags, never its title.
const test = require('node:test');
const assert = require('node:assert/strict');
const { IDS, makeWorld, makeDiscord, until } = require('./harness.cjs');
const BOT = `<@${IDS.BOT}>`;

const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
const tagsOf = (d, thread) => (thread.appliedTags || []).map((id) => d.jobs.availableTags.find((t) => t.id === id).name).sort();
const proposalOf = (thread) => thread.sent.find((s) => s.payload && s.payload.embeds && s.reactions.length >= 2);

test('#jobs: the team talks without the bot; an @-mention takes the job with the post as context, tags it and keeps its title', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS }); const d = makeDiscord(w.runner);
  const { thread } = await d.forumPost(IDS.HELIX, 'Tooltip overlaps the bag', 'The tooltip LOG-MARKER-77 covers the bag slots', ['War', 'To do']);
  await d.say(thread, IDS.HELIX, 'War can you look at this?'); await d.ad.pollOnce();
  assert.equal(Object.keys(w.runner.jobs()).length, 0, 'no mention, no job'); assert.equal(thread.sent.length, 0);
  await d.say(thread, IDS.STRANGER, `${BOT} take this`);
  assert.equal(Object.keys(w.runner.jobs()).length, 0, 'someone not on the team cannot start one');

  await d.say(thread, IDS.HELIX, `${BOT} take this`);
  const job = w.runner.jobs()[thread.id]; assert.ok(job && job.forumPost, 'the post is the job thread');
  await until(() => texts(thread).some((t) => /Saw LOG-MARKER-77/.test(t)), d.ad);   // the post's opening message reached the agent
  assert.equal(job.creatorId, IDS.HELIX); assert.equal(job.round, 1); assert.equal(d.world.threads.length, 0, 'no new thread opened');
  await until(() => !job.running && tagsOf(d, thread).includes('Doing'), d.ad);
  assert.deepEqual(tagsOf(d, thread), ['Doing', 'Muffin Core', 'War'], 'To do comes off, the owner tag stays');
  assert.equal(thread.renames, undefined, 'the post keeps the title its author gave it');

  // an open job post is never archived by the runner, whatever its age
  job.lastActive = job.seenAt = Date.now() - 3 * 86400e3; assert.equal(w.runner.archiveQuiet(), 0);
  await d.say(thread, IDS.HELIX, '!discard');
  await until(() => job.status === 'discarded' && tagsOf(d, thread).includes('To do'), d.ad);
  assert.deepEqual(tagsOf(d, thread), ['Muffin Core', 'To do', 'War'], 'a discarded job is open again');
  job.lastActive = job.seenAt = Date.now() - 3 * 86400e3; assert.equal(w.runner.archiveQuiet(), 0);

  // with nothing open, the team talks without the bot again; a mention starts a fresh round
  await d.say(thread, IDS.HELIX, 'ok War, yours'); await d.ad.pollOnce();
  assert.equal(job.round, 1); assert.equal(job.worktree, null);
  await d.say(thread, IDS.HELIX, `${BOT} try again`);
  await until(() => job.round === 2 && !job.running && tagsOf(d, thread).includes('Doing'), d.ad);
});

test('#jobs: a mention in the opening message proposes in the post; ✅ ships it, tags it Done and archives it once quiet', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS }); const d = makeDiscord(w.runner);
  const { thread } = await d.forumPost(IDS.HELIX, 'Readme wording', `${BOT} GD-DOC readme`, ['Helix']);
  const job = w.runner.jobs()[thread.id]; assert.ok(job);
  const p = await until(() => proposalOf(thread), d.ad);
  assert.deepEqual(await d.react(p, IDS.HELIX, '✅'), [], 'the ✅ in a #jobs post is accepted');
  await until(() => job.status === 'shipped' && tagsOf(d, thread).includes('Done'), d.ad);
  assert.deepEqual(tagsOf(d, thread), ['Done', 'Helix', 'Muffin Core']);
  job.lastActive = job.seenAt = Date.now() - 2 * 3600e3; (job.history || []).forEach((h) => { h.at = new Date(job.lastActive).toISOString(); });
  assert.equal(w.runner.archiveQuiet(), 1);
  await until(() => thread.archived, d.ad);
});

test('a discussion post: a mention brings it in with the post so far; then it answers every message; !pause keeps what is said for !resume', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS, talkChannelIds: [IDS.TALK] }); const d = makeDiscord(w.runner);
  const { thread } = await d.forumPost(IDS.HELIX, 'Ossuary bone shield', 'What if the Ossuary had a bone shield?', [], d.talk);
  await d.say(thread, IDS.OWNER, 'I like it, LOG-MARKER-77 maybe'); await d.ad.pollOnce();
  assert.equal(Object.keys(w.runner.jobs()).length, 0, 'no mention, the bot stays out');
  await d.say(thread, IDS.HELIX, `${BOT} thoughts?`);
  const job = w.runner.jobs()[thread.id]; assert.ok(job && job.talk);
  await until(() => texts(thread).some((t) => /Saw LOG-MARKER-77/.test(t)), d.ad);   // the messages before the mention reached it
  await until(() => !job.running, d.ad);
  let n = texts(thread).length;
  await d.say(thread, IDS.HELIX, 'what does the ossuary do right now?');   // no mention needed any more
  await until(() => !job.running && texts(thread).length > n, d.ad);
  assert.equal(thread.renames, undefined); assert.deepEqual(thread.appliedTags, [], 'a discussion post is never renamed or tagged');

  const p = await d.say(thread, IDS.HELIX, '!pause'); assert.match(p.replies[0].content, /^Paused\./);
  n = texts(thread).length; const turns = job.totalTurns;
  await d.say(thread, IDS.OWNER, 'between us: LOG-MARKER-77 is the plan');
  await d.say(thread, IDS.HELIX, `${BOT} you there?`);   // a mention does not bring it back
  await d.say(thread, IDS.HELIX, 'pause');                // nor does a plain word act as a command
  await d.ad.pollOnce();
  assert.equal(job.totalTurns, turns); assert.equal(texts(thread).length, n); assert.equal(job.pausedMsgs.length, 3);
  await d.say(thread, IDS.HELIX, '!resume');
  await until(() => texts(thread).some((t) => /Caught up on LOG-MARKER-77/.test(t)), d.ad);
  assert.equal(job.paused, null);

  const disc = await d.say(thread, IDS.HELIX, '!discard'); assert.match(disc.replies[0].content, /nothing to discard in a discussion post/);
  job.lastActive = job.seenAt = Date.now() - 3 * 86400e3; assert.equal(w.runner.archiveQuiet(), 0, 'a discussion post is never archived');
  // after talkIdleHours the workspace goes quietly; the next message starts a fresh one that still knows the conversation
  await until(() => !job.running, d.ad); await w.runner.sweep();
  assert.equal(job.worktree, null); assert.equal(job.status, 'idle');
  await d.say(thread, IDS.HELIX, 'and the cooldown?');
  await until(() => job.worktree && !job.running && texts(thread).filter((t) => /Saw LOG-MARKER-77/.test(t)).length >= 2, d.ad);
});

test('!job for War in a discussion post opens a #jobs post tagged To do and War, links it, and a mention there starts the job', async () => {
  const w = makeWorld({ jobsChannelId: IDS.JOBS, talkChannelIds: [IDS.TALK], jobsOwners: { War: ['war', 'warbogar'], Helix: ['helix'] } });
  const d = makeDiscord(w.runner);
  const { thread } = await d.forumPost(IDS.HELIX, 'Ossuary bone shield', 'LOG-MARKER-77 bone shield idea', [], d.talk);
  const who = await d.say(thread, IDS.HELIX, '!job for nobody');   // !job alone brings the bot in too
  assert.match(who.replies[0].content, /do not know who "nobody" is/);
  await d.say(thread, IDS.HELIX, '!job for warbogar');
  const post = await until(() => (d.world.posts || [])[0], d.ad);
  assert.equal(post.parentId, IDS.JOBS); assert.equal(post.name, 'Bone shield for the Ossuary');
  assert.match(post.starter.content, /LOG-MARKER-77 was decided/, 'written from the discussion');
  assert.match(post.starter.content, new RegExp(`from <#${thread.id}>, asked by Helix$`));
  assert.deepEqual(post.starter.payload.allowedMentions, { parse: [], repliedUser: false });
  assert.deepEqual(tagsOf(d, post), ['To do', 'War']);
  await until(() => texts(thread).some((t) => t.startsWith(`Made it a job: <#${post.id}> (tagged To do, War).`)), d.ad);
  assert.ok(!texts(thread).some((t) => /^JOB TITLE/.test(t)), 'the write-up is not also said in the discussion');
  // the new post is a #jobs post like any other: the bot stays out until someone mentions it there
  await d.say(post, IDS.HELIX, 'War this one is yours'); assert.equal(w.runner.jobs()[post.id], undefined);
  await d.say(post, IDS.HELIX, `${BOT} go`);
  const job = w.runner.jobs()[post.id]; assert.ok(job && job.forumPost && !job.talk);
  await until(() => texts(post).some((t) => /Saw LOG-MARKER-77/.test(t)), d.ad);
  const elsewhere = await d.say(post, IDS.HELIX, '!job'); assert.match(elsewhere.replies[0].content, /works in the discussion forums/);
});

test('a discussion post\'s agent gets read-only tools and the discussion instructions; a job\'s agent keeps its full set', () => {
  const { claudeArgs } = require('../runner/lib/agent.cjs');
  const args = (extra) => {
    const a = claudeArgs({ toolsDir: '/t', webAnyHost: true }, { worktree: '/w', branch: 'b', model: 'sonnet', ...extra }, { systemPrompt: 'CORE' });
    return { tools: a[a.indexOf('--tools') + 1], allowed: a.slice(a.indexOf('--allowedTools') + 1, a.indexOf('--disallowedTools')), sp: a[a.indexOf('--append-system-prompt') + 1] };
  };
  const talk = args({ talk: true }), work = args({});
  assert.equal(talk.tools, 'Read,Glob,Grep,WebSearch,WebFetch');
  assert.ok(!talk.allowed.some((t) => /^(Edit|Write|Bash)/.test(t)), talk.allowed.join(' '));
  assert.match(talk.sp, /^CORE[\s\S]*This thread is a discussion post, not a job/);
  assert.equal(work.tools, 'Read,Edit,Write,Glob,Grep,Bash,WebSearch,WebFetch'); assert.equal(work.sp, 'CORE');
  assert.ok(work.allowed.some((t) => /^Bash\(/.test(t)));
});
