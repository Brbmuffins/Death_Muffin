'use strict';
// Team talk (Helix 2026-10-23, runner/lib/addressee.cjs): messages the team says to each other start no turn; they reach the agent with its next turn.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), os = require('os'), path = require('path');
const { IDS, makeWorld, makeDiscord, until } = require('./harness.cjs');
const AD = require('../runner/lib/addressee.cjs');
const BOT = `<@${IDS.BOT}>`;
const WAR = '291020261074010113';
const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
const OWNERS = { War: ['war', 'warbogar', WAR], Helix: ['helix', IDS.HELIX], brb: ['brb', 'brbmuffins', IDS.OWNER] };

// A stand-in for the guessing model: answers "team" when the new message holds TEAM-GUESS, else "bot", and logs every call it gets.
function guesser() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-guess-')), log = path.join(dir, 'calls');
  const file = path.join(dir, 'guess.cjs');
  fs.writeFileSync(file, `#!/usr/bin/env node\nlet p='';process.stdin.on('data',(d)=>{p+=d;}).on('end',()=>{require('fs').appendFileSync(${JSON.stringify(log)},JSON.stringify({args:process.argv.slice(2),p})+'\\n');`
    + `const m=p.split('The new message:')[1]||'';process.stdout.write(JSON.stringify({type:'result',is_error:false,total_cost_usd:0.0018,result:/TEAM-GUESS/.test(m)?'team':'bot'}));});\n`, { mode: 0o755 });
  return { cmd: file, calls: () => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : []) };
}
async function start(over = {}) {
  const g = guesser();
  const w = makeWorld({ jobsOwners: OWNERS, addresseeCmd: g.cmd, ...over });
  w.cfg.projects.deathmuffin.requesters.push(WAR); w.cfg.project.requesters.push(WAR); w.cfg.names[WAR] = 'warbogar';
  const d = makeDiscord(w.runner);
  await d.say(d.main, IDS.HELIX, `${BOT} what does the gate do?`);
  const thread = await until(() => d.world.threads[0], d.ad);
  const job = await until(() => w.runner.jobs()[thread.id], d.ad);
  await until(() => !job.running && texts(thread).length >= 1, d.ad);
  return { w, d, g, thread, job };
}
const idle = (d, job) => until(() => !job.running && job.queue.length === 0, d.ad);

test('signals: who a message names or replies to decides it, at no cost', () => {
  const cfg = { jobsOwners: OWNERS, names: { [IDS.HELIX]: 'Helix', [WAR]: 'warbogar' } };
  const s = (ev, text) => (AD.signal(cfg, { userId: IDS.HELIX, ...ev }, text) || {}).to || null;
  assert.equal(s({ mentioned: true, mentions: [WAR] }, 'you two look'), 'bot', 'the bot mentioned wins');
  assert.equal(s({ replyTo: { bot: true } }, 'yes that one'), 'bot');
  assert.equal(s({}, 'muffin core, show me the gate'), 'bot');
  assert.equal(s({}, 'Muffin: again'), 'bot');
  assert.equal(s({ mentions: [WAR] }, '<@291> look at this'), 'team');
  assert.equal(s({ replyTo: { bot: false, userId: WAR } }, 'agreed'), 'team');
  for (const t of ['war, check this', 'War: yes', '@war clause is still building the runner', 'helix - did you see it', 'brbmuffins?']) assert.equal(s({}, t), 'team', t);
  for (const t of ['war is the theme here', 'muffins are good', 'make it purple', 'warbogar said it was fine yesterday']) assert.equal(s({}, t), null, t);
  assert.ok(!AD.teammateWords(cfg).some((x) => /^\d+$/.test(x)), 'ids are never words');
});

test('team talk starts no turn and reaches the agent with its next turn; a lone person always reaches the bot', async () => {
  const { w, d, g, thread, job } = await start();
  // a lone person: no signal, nobody else talking -> the bot, without asking the model
  const turns = job.totalTurns;
  await d.say(thread, IDS.HELIX, 'one more thing');
  await until(() => job.totalTurns === turns + 1, d.ad); await idle(d, job);
  const n0 = job.totalTurns;
  // a teammate @-mentioned, a reply to a teammate, a name first: team talk
  await d.say(thread, IDS.OWNER, `<@${WAR}> ASIDE-MARK the gate should glow`);
  const ownerMsg = thread.log[thread.log.length - 1];
  await d.say(thread, WAR, 'ok i will look', [], { replyTo: ownerMsg });
  await d.say(thread, IDS.HELIX, '@war clause is still building the runner');
  await d.ad.pollOnce();
  assert.equal(job.totalTurns, n0, 'no turn for team talk'); assert.equal(job.asides.length, 3);
  assert.deepEqual(job.asides.slice(1).map((a) => a.name), ['warbogar', 'Helix']);
  assert.equal(g.calls().length, 0, 'clear signals never ask the model');
  // while people talk, a message with no signal is guessed: TEAM-GUESS -> team, otherwise -> bot
  await d.say(thread, IDS.HELIX, 'TEAM-GUESS yeah way more purple');
  await d.ad.pollOnce();
  assert.equal(job.totalTurns, n0); assert.equal(job.asides.length, 4); assert.equal(g.calls().length, 1);
  const call = g.calls()[0];
  assert.ok(call.args.includes('--tools') && call.args[call.args.indexOf('--tools') + 1] === '', 'the guess runs with no tools');
  assert.equal(call.args[call.args.indexOf('--model') + 1], 'haiku');
  assert.match(call.p, /<conversation>[\s\S]*ASIDE-MARK[\s\S]*<\/conversation>\nThe new message:\n\[Helix\] TEAM-GUESS/, 'it reads the recent messages');
  // the next message for the bot gets all of it, marked as not said to it, once
  await d.say(thread, IDS.HELIX, 'so what do you think?');
  await until(() => texts(thread).some((t) => /ASIDES-SEEN/.test(t)), d.ad); await idle(d, job);
  assert.equal(job.totalTurns, n0 + 1); assert.deepEqual(job.asides, []);
  assert.equal(g.calls().length, 2, 'that one was guessed too (people are talking) and went to the bot');
  const audit = fs.readFileSync(path.join(w.cfg.stateDir, 'audit.jsonl'), 'utf8');
  for (const how of ['mention', 'reply', 'name', 'guess']) assert.match(audit, new RegExp(`"event":"team-talk"[^\\n]*"how":"${how}"`));
  assert.match(audit, /"event":"addressee"[^\n]*"to":"bot"[^\n]*"how":"guess"/);
  // an @-mention of the bot always reaches it, and commands still work
  await d.say(thread, IDS.OWNER, `${BOT} <@${WAR}> both of you look at this`);
  await until(() => job.totalTurns === n0 + 2, d.ad); await idle(d, job);
});

test('a guess that fails sends the message to the bot; addresseeGuess: false never asks', async () => {
  const { d, g, thread, job } = await start({ addresseeCmd: '/nonexistent/guesser' });
  const n0 = job.totalTurns;
  await d.say(thread, IDS.OWNER, `<@${WAR}> look`);   // team talk: someone else is now talking
  await d.say(thread, IDS.HELIX, 'TEAM-GUESS is this for you?');
  await until(() => job.totalTurns === n0 + 1, d.ad); await idle(d, job);
  assert.equal(g.calls().length, 0);
  const s2 = await start({ addresseeGuess: false });
  const m0 = s2.job.totalTurns;
  await s2.d.say(s2.thread, IDS.OWNER, `<@${WAR}> look`);
  await s2.d.say(s2.thread, IDS.HELIX, 'TEAM-GUESS hmm');
  await until(() => s2.job.totalTurns === m0 + 1, s2.d.ad);
  assert.equal(s2.g.calls().length, 0);
});

test('a discussion post keeps team talk in its conversation log', async () => {
  const g = guesser();
  const w = makeWorld({ jobsOwners: OWNERS, addresseeCmd: g.cmd, jobsChannelId: IDS.JOBS, talkChannelIds: [IDS.TALK] }); const d = makeDiscord(w.runner);
  const { thread } = await d.forumPost(IDS.HELIX, 'Gate lore', 'Why is the gate sealed?', [], d.talk);
  await d.say(thread, IDS.HELIX, `${BOT} thoughts?`);
  const job = w.runner.jobs()[thread.id]; await until(() => !job.running && texts(thread).length, d.ad);
  const n0 = job.totalTurns;
  await d.say(thread, IDS.OWNER, 'helix, ASIDE-MARK the keepers sealed it');
  await d.ad.pollOnce();
  assert.equal(job.totalTurns, n0); assert.ok(job.talkLog.some((m) => /ASIDE-MARK/.test(m.text)));
  await d.say(thread, IDS.HELIX, `${BOT} does that fit?`);
  await until(() => texts(thread).some((t) => /ASIDES-SEEN/.test(t)), d.ad);
});
