'use strict';
// The sweep never deletes work (Helix 2026-10-28: "i dont like the idea of auto deleting the workspace"): a quiet job holding a change is asked
// "✅ keep, ❌ delete" once per quiet spell and only a ❌ deletes it; a quiet job's workspace with nothing in it goes quietly and comes back.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { IDS, makeWorld, makeDiscord, until, sh } = require('./harness.cjs');
const BOT = `<@${IDS.BOT}>`;

async function request(d, userId, text) {
  await d.say(d.main, userId, `${BOT} ${text}`);
  return until(() => d.world.threads[d.world.threads.length - 1], d.ad);
}
const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
const asks = (thread) => thread.sent.filter((s) => /Keep it\?/.test(s.payload.content || '') && s.reactions.includes('✅') && s.reactions.includes('❌'));
const proposed = (d, thread) => until(() => thread.sent.find((s) => s.payload && s.payload.embeds && s.reactions.length >= 2), d.ad);

test('a quiet job with a change is asked once, pinging its requester; a stranger cannot answer; ✅ keeps it and nothing is asked again until the thread was busy', async () => {
  const w = makeWorld(); const d = makeDiscord(w.runner);
  const thread = await request(d, IDS.HELIX, 'MAKE-CSS make the accent blue');
  await proposed(d, thread); const job = Object.values(w.runner.jobs())[0];
  await until(() => job.status === 'proposed' && !job.running, d.ad);
  await w.runner.sweep(0);
  const ask = await until(() => asks(thread)[0], d.ad);
  assert.ok(ask.payload.content.startsWith(`<@${IDS.HELIX}> `), 'the requester is pinged');
  assert.match(ask.payload.content, /Nothing is deleted without a ❌/);
  assert.equal(job.status, 'proposed'); assert.ok(fs.existsSync(job.worktree), 'the workspace stays');
  await w.runner.sweep(0); assert.equal(asks(thread).length, 1, 'asked once per quiet spell');
  assert.deepEqual(await d.react(ask, IDS.STRANGER, '✅'), [IDS.STRANGER]);
  assert.deepEqual(await d.react(ask, IDS.HELIX, '✅'), []);
  await until(() => texts(thread).some((t) => /^Kept \(Helix\)\. Nothing here is deleted unless/.test(t)), d.ad);
  assert.equal(job.keepAsk.kept.by, IDS.HELIX);
  await d.react(ask, IDS.HELIX, '❌');
  await until(() => texts(thread).some((t) => /^Helix kept it\. Type `!discard`/.test(t)), d.ad);
  await w.runner.sweep(0);
  assert.equal(asks(thread).length, 1); assert.equal(job.status, 'proposed'); assert.ok(fs.existsSync(job.worktree));
});

test('❌ deletes the change like a discard; a question the thread moved past deletes nothing, and the next quiet spell asks again', async () => {
  const w = makeWorld(); const d = makeDiscord(w.runner);
  const thread = await request(d, IDS.HELIX, 'MAKE-CSS make the accent blue');
  await proposed(d, thread); const job = Object.values(w.runner.jobs())[0];
  await until(() => job.status === 'proposed' && !job.running, d.ad);
  await w.runner.sweep(0);
  const old = await until(() => asks(thread)[0], d.ad);
  await d.say(thread, IDS.HELIX, `${BOT} where is player speed defined?`);
  await until(() => !job.running && !job.queue.length && job.lastActive > job.keepAsk.at, d.ad);
  await d.react(old, IDS.HELIX, '❌');
  await until(() => texts(thread).some((t) => /^That question is out of date/.test(t)), d.ad);
  assert.equal(job.status, 'proposed'); assert.ok(fs.existsSync(job.worktree), 'nothing deleted');
  await new Promise((r) => setTimeout(r, 5));
  await w.runner.sweep(0);
  const ask = await until(() => asks(thread)[1], d.ad);
  const branch = job.branch;
  await d.react(ask, IDS.HELIX, '❌');
  await until(() => job.status === 'discarded', d.ad);
  await until(() => texts(thread).some((t) => /^Discarded\. Branch/.test(t)), d.ad);
  assert.equal(job.worktree, null); assert.equal(job.keepAsk, null);
  assert.equal(sh(w.repo, 'ls-remote', 'origin', `refs/heads/${branch}`), '', 'the branch is gone');
});

test('a quiet job with nothing in its workspace loses only the workspace, without a word; the next message builds a fresh one', async () => {
  const w = makeWorld(); const d = makeDiscord(w.runner);
  const thread = await request(d, IDS.OWNER, 'where is player speed defined?');
  const job = await until(() => { const j = Object.values(w.runner.jobs())[0]; return j && j.status === 'idle' && !j.running && j.worktree && j; }, d.ad);
  const wt = job.worktree, sent = thread.sent.length;
  await w.runner.sweep(0);
  assert.equal(job.worktree, null); assert.ok(!fs.existsSync(wt)); assert.equal(job.status, 'idle');
  assert.equal(thread.sent.length, sent, 'nothing said'); assert.equal(asks(thread).length, 0);
  await d.say(thread, IDS.OWNER, `${BOT} and where is it used?`);
  await until(() => job.worktree && fs.existsSync(job.worktree) && !job.running, d.ad);
});
