#!/usr/bin/env node
'use strict';
// Stand-in for `claude -p` in the end-to-end test: reads the prompt on stdin, optionally edits + commits in cwd, prints the JSON result.
const fs = require('fs'); const { execFileSync } = require('child_process');
let p = ''; process.stdin.on('data', (d) => { p += d; }).on('end', () => {
  const git = (...a) => execFileSync('git', a, { stdio: 'pipe' });
  const ready = (title, summary) => fs.writeFileSync('.dm-result.json', JSON.stringify({ status: 'ready', title, summary, testing: 'check.sh', risk: 'none' }));
  let text = 'The answer is in src/gameplay/a.ts.';
  if (/SLOW-TURN/.test(p)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000); // a turn still running when someone reacts ❌
  const edit = (file, from, to, msg, extraMsg = '') => { fs.mkdirSync(require('path').dirname(file), { recursive: true }); fs.writeFileSync(file, (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '').replace(from, to) || to); git('add', '--', file); git('commit', '-q', '-m', msg + extraMsg); };
  // SHOT-PNG / SHOT-PNG2: pretend shot.sh ran (a scenario file + a PNG; PNG2 = different bytes). The !shot prompt mentions shot.sh.
  const rules = 'server/vps-handoff/necro-progress/necro-rules.cjs';
  const wr = (f, c) => { fs.mkdirSync(require('path').dirname(f), { recursive: true }); fs.writeFileSync(f, c); };
  // godot mode (base branch godot-port): GD-GAMEPLAY = godot/game/a.gd (GD-SHOT in the same request also leaves a shot plan + picture), GD-NET = sensitive net code, GD-DOC = readme, GD-PRESET = a forbidden path
  if (/GD-GAMEPLAY/.test(p)) { edit('godot/game/a.gd', 'speed=1', 'speed=9', 'Faster movement'); ready('Faster movement', ['speed 9']); text = 'Done.'; }
  else if (/GD-NET/.test(p)) { edit('godot/net/dm_api.gd', 'url=1', 'url=2', 'Change the api url'); ready('Api url', ['url 2']); text = 'Done.'; }
  else if (/GD-DOC/.test(p)) { edit('godot/README.md', 'godot readme', 'godot readme v2', 'Clarify the Godot readme'); ready('Readme', ['readme']); text = 'Done.'; }
  else if (/GD-PRESET/.test(p)) { edit('godot/export_presets.cfg', '[preset.0]', '[preset.0]\nx=1', 'Tweak the export'); ready('Export', ['x']); text = 'Done.'; }
  else if (/not what the generators produce/.test(p)) { wr(rules, 'SPEED=9\n'); git('add', '--', rules); try { git('commit', '-q', '-m', 'Regenerate the server rules'); } catch { /* nothing to commit */ } text = 'Regenerated.'; }
  else if (/MAKE-DATA-HAND/.test(p)) { wr('src/gameplay/a.ts', 'speed=9\n'); wr(rules, 'SPEED=9 // hand edit\n'); git('add', '--', 'src/gameplay/a.ts', rules); git('commit', '-q', '-m', 'Faster movement'); ready('Faster', ['speed 9']); text = 'Done.'; }
  else if (/MAKE-DATA-FORBIDDEN/.test(p)) { wr('src/gameplay/a.ts', 'speed=9\n'); wr('server/realtime/deploy-realtime.sh', 'echo evil\n'); git('add', '--', 'src/gameplay/a.ts', 'server/realtime/deploy-realtime.sh'); git('commit', '-q', '-m', 'Faster movement'); ready('Faster', ['speed 9']); text = 'Done.'; }
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
  else if (/HUGE-REPLY/.test(p)) text = Array.from({ length: 400 }, (_, i) => `row ${i}: ${'y'.repeat(60)}`).join('\n');
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
  if (/previous change shipped/.test(p)) text += ' ROUND-NOTE-SEEN';
  if (/different version of the game/.test(p)) text += ' MODE-NOTE-SEEN';
  if (process.argv.includes('--resume')) text += ' RESUMED';
  process.stdout.write(JSON.stringify({ type: 'result', result: text, session_id: 'sess-1', is_error: false, total_cost_usd: 0 }));
});
