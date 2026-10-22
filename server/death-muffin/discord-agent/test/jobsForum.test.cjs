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
  await d.say(thread, IDS.HELIX, 'discard this');
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
