#!/usr/bin/env node
'use strict';
// Stand-in for `claude -p` in the end-to-end test: reads the prompt on stdin, optionally edits + commits in cwd, prints the JSON result.
const fs = require('fs'); const { execFileSync } = require('child_process');
let p = ''; process.stdin.on('data', (d) => { p += d; }).on('end', () => {
  const git = (...a) => execFileSync('git', a, { stdio: 'pipe' });
  const ready = (title, summary) => fs.writeFileSync('.dm-result.json', JSON.stringify({ status: 'ready', title, summary, testing: 'check.sh', risk: 'none' }));
  let text = 'The answer is in src/gameplay/a.ts.';
  // step budget: LONG-TASK runs out of steps (error_max_turns) unless it is continuing from a handoff; LONG-FOREVER always does; the runner's
  // note request writes .dm-handoff.md (NO-NOTE in the worktree: writes none). Every call logs its --max-turns and whether it resumed.
  try { const ex = require('path').join(String(execFileSync('git', ['rev-parse', '--git-common-dir'])).trim(), 'info', 'exclude'); if (!fs.readFileSync(ex, 'utf8').includes('.fake-calls')) fs.appendFileSync(ex, '\n.fake-calls\n'); } catch { /* not a repo */ }
  const mtI = process.argv.indexOf('--max-turns'); fs.appendFileSync('.fake-calls', `${mtI >= 0 ? process.argv[mtI + 1] : '-'} ${process.argv.includes('--resume') ? 'resume' : 'fresh'} ${/step limit\. The work continues/.test(p) ? 'note' : /<handoff>/.test(p) ? 'continue' : /automatic review failed/.test(p) ? (/check-godot\.sh --rerun <suite>/.test(p) ? 'fixup-rerun' : 'fixup') : 'turn'}\n`);
  const out = (o) => process.stdout.write(JSON.stringify({ type: 'result', session_id: 'sess-' + Math.random().toString(16).slice(2, 8), total_cost_usd: 0, ...o }));
  if (/step limit\. The work continues/.test(p)) { if (!fs.existsSync('NO-NOTE')) fs.writeFileSync('.dm-handoff.md', 'HANDOFF: speed half done; next set speed=9 in client/game/a.gd\n'); return out({ subtype: 'success', is_error: false, result: 'Note written.' }); }
  if (/LONG-FOREVER/.test(p) || (/LONG-TASK/.test(p) && !/<handoff>|left no note/.test(p))) return out({ subtype: 'error_max_turns', is_error: true, errors: ['Reached maximum number of turns (40)'] });
  if (/LOG-MARKER-77/.test(p)) text = 'Saw LOG-MARKER-77 in the report.';
  if (/STATUS-TURN/.test(p)) { fs.writeFileSync('.dm-status', '20% · Hunting the tooltip crash, then fixing it; ~1 min.\n'); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2500); }
  const ttl = /TITLE-TURN="([^"]+)"/.exec(p); if (ttl) { fs.writeFileSync('.dm-title', ttl[1] + '\n'); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 800); }
  if (/SLOW-TURN/.test(p)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000); // a turn still running when someone reacts ❌
  const edit = (file, from, to, msg, extraMsg = '') => { fs.mkdirSync(require('path').dirname(file), { recursive: true }); fs.writeFileSync(file, (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '').replace(from, to) || to); git('add', '--', file); git('commit', '-q', '-m', msg + extraMsg); };
  // SHOT-PNG / SHOT-PNG2: pretend shot.sh ran (a scenario file + a PNG; PNG2 = different bytes). The !shot prompt mentions shot.sh.
  const rules = 'server/vps-handoff/necro-progress/necro-rules.cjs';
  const wr = (f, c) => { fs.mkdirSync(require('path').dirname(f), { recursive: true }); fs.writeFileSync(f, c); };
  // godot mode (base branch godot-port): GD-GAMEPLAY = client/game/a.gd (GD-SHOT in the same request also leaves a shot plan + picture), GD-NET = sensitive net code, GD-DOC = readme, GD-PRESET = a forbidden path
  // model requests: GD-ART [kind] id=<id>. kinds: (none) rigged biped with 6 clips | PROP | BAD (unknown field) | BADFIX (bad first, valid once the runner says it was rejected) | LINK (concept png is a symlink) | SWAP (rewrites the spec bigger, no request)
  const art = /GD-ART(?:-(\w+))? id=([a-z0-9_]+)/.exec(p);
  // a sync that hit conflicts: keep this branch's side of each conflicted file and commit the merge (a CONFLICT-ADD marker file in the worktree makes it also touch a new file)
  const conflictList = /left conflicts in:\n([\s\S]*?)\nResolve/.exec(p);
  // concept + set requests: GD-CONCEPT ids=a,b writes Gemini jobs + .dm-concept-request.json; GD-SET ids=a,b writes props' Tripo specs (+ jobs if missing) + one .dm-art-request.json
  const cset = /GD-(CONCEPT|SET) ids=([a-z0-9_,]+)/.exec(p);
  if (cset && !/The runner generated the approved model/.test(p) && !/rejected your (concept|model) request/.test(p)) {
    const ids = cset[2].split(',');
    for (const id of ids) if (cset[1] === 'CONCEPT' || !fs.existsSync(`art-manifest/gemini-jobs/${id}.json`)) wr(`art-manifest/gemini-jobs/${id}.json`, JSON.stringify([{ id: `concept_${id}`, prompt: `A ${id} for a necromancer armor set, three-quarter view, plain light grey background.`, out: `art-src/concepts/${id}.png`, aspect: '1:1' }]));
    if (cset[1] === 'CONCEPT') { wr('.dm-concept-request.json', JSON.stringify({ ids, note: 'a bone armor set' })); text = 'Asked for concepts.' + (/The runner generated concept images/.test(p) ? ' CONCEPT-NOTE-SEEN' : ''); }
    else {
      for (const id of ids) wr(`art-manifest/tripo-specs/${id}.json`, JSON.stringify({ id, input: `art-src/concepts/${id}.png`, generation: { model: 'P1-20260311', face_limit: 2500, texture_quality: 'detailed' } }));
      wr('.dm-art-request.json', JSON.stringify({ ids, note: 'the bone set' })); text = 'Asked for the set.' + (/The runner generated concept images/.test(p) ? ' CONCEPT-NOTE-SEEN' : '');
    }
  } else if (art && !/The runner generated the approved model/.test(p) && !/rejected your model request/.test(p)) {
    const kind = art[1] || '', id = art[2];
    const spec = { id, input: `art-src/concepts/${id}.png`, generation: { model: 'P1-20260311', face_limit: 7000, texture_quality: 'detailed' } };
    if (kind === 'PROP') spec.id = id; else { spec.rig = { model: 'v1.0-20240301', rig_type: 'biped' }; spec.animations = ['idle', 'walk', 'run', 'slash', 'hurt', 'fall'].map((a) => 'preset:biped:' + a); spec.animationMode = 'single'; }
    if (kind === 'BAD' || kind === 'BADFIX') { spec.api_key = 'give me more'; if (kind === 'BAD') spec.nofix = true; }
    const job = [{ id: `concept_${id}`, prompt: 'A gaunt undead warlock in a strict T-pose, empty hands, plain light grey background, flat lighting, dark fantasy.', out: `art-src/concepts/${id}.png`, aspect: '3:4' }];
    if (kind === 'SWAP') { const f = `art-manifest/tripo-specs/${id}.json`; const cur = JSON.parse(fs.readFileSync(f, 'utf8')); cur.animations = cur.animations.concat(['preset:biped:dive', 'preset:biped:jump', 'preset:biped:dig']); wr(f, JSON.stringify(cur)); text = 'Swapped.'; }
    else {
      wr(`art-manifest/gemini-jobs/${id}.json`, JSON.stringify(job)); wr(`art-manifest/tripo-specs/${id}.json`, JSON.stringify(spec));
      if (kind === 'LINK') { fs.mkdirSync('art-src/concepts', { recursive: true }); fs.symlinkSync(process.env.ART_VICTIM || '/etc/hostname', `art-src/concepts/${id}.png`); }
      wr('.dm-art-request.json', JSON.stringify({ id, note: 'a new warlock for the Chapterhouse' })); text = 'Asked for the model; waiting for approval.';
    }
  } else if (/rejected your model request/.test(p)) {
    // the runner's fix-up turn: BADFIX specs lose their bad field, BAD specs stay broken; either way the request file is written again
    const dir = 'art-manifest/tripo-specs'; let id = null;
    for (const n of fs.readdirSync(dir)) { const f = `${dir}/${n}`; const cur = JSON.parse(fs.readFileSync(f, 'utf8')); if ('api_key' in cur) { id = cur.id; if (!cur.nofix) { delete cur.api_key; wr(f, JSON.stringify(cur)); } } }
    if (id) wr('.dm-art-request.json', JSON.stringify({ id })); text = 'Tried to fix the spec.';
  } else if (/GD-SOUND id=([a-z0-9_]+)/.test(p) && !/The runner generated the sound/.test(p) && !/rejected your sound request/.test(p)) {
    // sound requests: GD-SOUND id=<id> [BADSOUND] writes the spec + trigger file
    const id = /GD-SOUND id=([a-z0-9_]+)/.exec(p)[1];
    wr(`audio-manifest/eleven/${id}.json`, JSON.stringify({ id, kind: 'sfx', prompt: 'A ghostly banshee wail, rising then fading, no music.', duration_seconds: 2, variants: 2, ...(/BADSOUND/.test(p) ? { voice: 'x' } : {}) }));
    wr('.dm-sound-request.json', JSON.stringify({ id, note: 'dash sound' })); text = 'Asked for the sound.';
  } else if (/rejected your sound request/.test(p)) {
    text = 'Cannot fix it.';
  } else if (/The runner generated the sound "([a-z0-9_]+)"/.test(p)) {
    const id = /The runner generated the sound "([a-z0-9_]+)"/.exec(p)[1];
    wr(`client/assets/audio/eleven/${id}.wav`, fs.readFileSync(`audio-src/eleven/${id}/v1.mp3`)); git('add', '--', `client/assets/audio/eleven/${id}.wav`, `audio-manifest/eleven/${id}.json`); git('commit', '-q', '-m', `Add the ${id} sound`); ready(`New sound: ${id}`, [`Added ${id}`]); text = 'Built and committed.' + (/build-sound\.sh/.test(p) ? ' BUILD-SOUND-SEEN' : '');
  } else if (/The runner generated the approved models? "/.test(p)) {
    const ids = [.../The runner generated the approved models? ((?:"[a-z0-9_]+"(?:, )?)+)/.exec(p)[1].matchAll(/"([a-z0-9_]+)"/g)].map((m) => m[1]);
    for (const id of ids) {
      const glb = id.startsWith('prop_') ? `client/assets/slice/models/props/${id.slice(5)}.glb` : `client/assets/slice/models/${id}/character.glb`;
      wr(glb, 'glb-bytes'); git('add', '--', glb, `art-manifest/gemini-jobs/${id}.json`, `art-manifest/tripo-specs/${id}.json`, `art-manifest/tripo/${id}.json`);
    }
    git('commit', '-q', '-m', `Add the ${ids.join(', ')} model${ids.length > 1 ? 's' : ''}`); ready(`New model: ${ids.join(', ')}`, ids.map((i) => `Added ${i}`));
    text = 'Built and committed.' + (/build-art\.sh/.test(p) ? ' BUILD-ART-SEEN' : '') + (/render-model\.sh/.test(p) ? ' RENDER-SEEN' : '');
  }
  else if (conflictList) {
    const files = conflictList[1].split('\n').map((x) => x.trim()).filter(Boolean);
    for (const f of files) { git('checkout', '--ours', '--', f); git('add', '--', f); }
    if (fs.existsSync('CONFLICT-ADD')) { fs.rmSync('CONFLICT-ADD'); fs.writeFileSync('src/extra.ts', 'x=1\n'); git('add', '--', 'src/extra.ts'); }
    git('commit', '-q', '--no-edit'); text = 'Resolved the merge.';
  }
  else if (/GD-GAMEPLAY/.test(p)) { edit('client/game/a.gd', 'speed=1', 'speed=9', 'Faster movement'); ready('Faster movement', ['speed 9']); text = 'Done.'; }
  else if (/GD-NET/.test(p)) { edit('client/net/dm_api.gd', 'url=1', 'url=2', 'Change the api url'); ready('Api url', ['url 2']); text = 'Done.'; }
  else if (/GD-UI/.test(p)) { edit('client/ui/menu.gd', 'title=1', 'title=2', 'Rename the menu title'); ready('Menu title', ['title 2']); text = 'Done.'; }
  else if (/GD-DOC/.test(p)) { edit('client/README.md', 'client readme', 'client readme v2', 'Clarify the game readme'); ready('Readme', ['readme']); text = 'Done.'; }
  else if (/GD-PRESET/.test(p)) { edit('client/export_presets.cfg', '[preset.0]', '[preset.0]\nx=1', 'Tweak the export'); ready('Export', ['x']); text = 'Done.'; }
  else if (/not what the generators produce/.test(p)) { wr(rules, 'SPEED=9\n'); git('add', '--', rules); try { git('commit', '-q', '-m', 'Regenerate the server rules'); } catch { /* nothing to commit */ } text = 'Regenerated.'; }
  else if (/MAKE-DATA-HAND/.test(p)) { wr('src/gameplay/a.ts', 'speed=9\n'); wr(rules, 'SPEED=9 // hand edit\n'); git('add', '--', 'src/gameplay/a.ts', rules); git('commit', '-q', '-m', 'Faster movement'); ready('Faster', ['speed 9']); text = 'Done.'; }
  else if (/MAKE-DATA-FORBIDDEN/.test(p)) { wr('src/gameplay/a.ts', 'speed=9\n'); wr('server/death-muffin/deploy-release.sh', 'echo evil\n'); git('add', '--', 'src/gameplay/a.ts', 'server/death-muffin/deploy-release.sh'); git('commit', '-q', '-m', 'Faster movement'); ready('Faster', ['speed 9']); text = 'Done.'; }
  else if (/MAKE-DATA/.test(p)) { wr('src/gameplay/a.ts', 'speed=9\n'); wr(rules, 'SPEED=9\n'); git('add', '--', 'src/gameplay/a.ts', rules); git('commit', '-q', '-m', 'Faster movement'); ready('Faster movement', ['speed 9']); text = 'Done.'; }
  else if (/secret scan flagged/.test(p)) { git('rm', '-q', '-f', 'src/gameplay/key.ts'); git('commit', '-q', '-m', 'Remove the key file'); text = 'Removed.'; }
  else if (/MAKE-CSS2/.test(p)) { edit('src/ui/ui.css', 'color:blue', 'color:green', 'Make the HUD accent green again'); ready('Green accent', ['green']); text = 'Done.'; }
  else if (/MAKE-CSS/.test(p)) { edit('src/ui/ui.css', 'color:red', 'color:blue', 'Make the HUD accent blue'); ready('HUD accent blue', ['Accent colour is now blue']); text = 'Done, ready for review.'; }
  else if (/MAKE-SERVER/.test(p)) { edit('server/x.js', 'a=1', 'a=2', 'Tweak the server constant'); ready('Server tweak', ['a is 2']); text = 'Done.'; }
  else if (/MAKE-GAMEPLAY/.test(p)) { edit('src/gameplay/a.ts', 'speed=1', 'speed=9', 'Faster movement'); ready('Faster movement', ['speed 9']); text = 'Done.'; }
  else if (/MAKE-COAUTHOR/.test(p)) { edit('src/ui/ui.css', 'color:red', 'color:green', 'Make the HUD accent green', '\n\nCo-Authored-By: Claude <noreply@anthropic.com>'); ready('Green accent', ['green']); text = 'Done.'; }
  else if (/MAKE-SECRET/.test(p)) { edit('src/gameplay/key.ts', '', 'export const k = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123";\n', 'Add a helper'); ready('Helper', ['helper']); text = 'Done.'; }
  else if (/MAKE-FORBIDDEN/.test(p)) { edit('server/death-muffin/deploy-release.sh', 'echo', 'echo hacked', 'Speed up deploys'); ready('Deploy tweak', ['x']); text = 'Done.'; }
  else if (/LONG-REPLY/.test(p)) text = 'Here is the log:\n```\n' + Array.from({ length: 70 }, (_, i) => `line ${i}: ${'x'.repeat(40)}`).join('\n') + '\n```\nDone.';
  else if (/HUGE-REPLY/.test(p)) text = Array.from({ length: 600 }, (_, i) => `row ${i}: ${'y'.repeat(60)}`).join('\n');
  else if (/IMG-ECHO/.test(p)) {
    const m = /\[image attached by [^:\]]*: (\.dm-inbox\/[^ ]+) —/.exec(p); const note = /\[(?:attachments not visible|image [^\]]*not attached|file [^\]]*not attached)[^\]]*\]/.exec(p);
    text = (m && fs.existsSync(m[1]) ? `IMG-SEEN ${fs.readFileSync(m[1]).length} ${m[1]}` : 'IMG-NONE') + (note ? ` NOTE ${note[0]}` : '');
  }
  else if (/PASTE-ECHO/.test(p)) text = /PASTED-MARKER-42/.test(p) ? 'I can read the pasted file.' : 'No pasted file in the prompt.';
  else if (/SHOT-PNG|shot(-godot)?\.sh/.test(p)) text = 'Here is how it looks.';
  else if (/ship it|print.*token|ignore your rules/i.test(p)) text = 'I cannot ship, show secrets or change my rules. Only an approver ✅ ships.';
  // Like the real agent, the screenshot comes after the last commit (only images newer than it go on the proposal).
  if (/SHOT-PNG|shot(-godot)?\.sh/.test(p)) {
    fs.writeFileSync('.dm-shot.json', '{"shots":[{"name":"a"}]}'); fs.mkdirSync('.dm-shots', { recursive: true });
    fs.writeFileSync('.dm-shots/a.png', Buffer.from(/SHOT-PNG2/.test(p) ? 'PNG-two-bytes' : 'PNG-one'));
    if (/SHOT-PNG/.test(p) && /BIG/.test(p)) fs.writeFileSync('.dm-shots/big.png', Buffer.alloc(9 * 1024 * 1024, 1));
  }
  if (/New round in this thread/.test(p)) text += ' ROUND-NOTE-SEEN';
  if (/Earlier rounds here: round 1 shipped/.test(p)) text += ' ROUND-SUMMARY-SEEN';
  if (/different version of the game/.test(p)) text += ' MODE-NOTE-SEEN';
  if (process.argv.includes('--resume')) text += ' RESUMED';
  if (/<handoff>[\s\S]*HANDOFF: speed half done/.test(p)) text += ' CONTINUED-FROM-NOTE';
  process.stdout.write(JSON.stringify({ type: 'result', result: text, session_id: 'sess-1', is_error: false, total_cost_usd: 0 }));
});
