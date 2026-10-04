#!/usr/bin/env node
'use strict';
// Stand-in for `claude -p` in the end-to-end test: reads the prompt on stdin, optionally edits + commits in cwd, prints the JSON result.
const fs = require('fs'); const { execFileSync } = require('child_process');
let p = ''; process.stdin.on('data', (d) => { p += d; }).on('end', () => {
  const git = (...a) => execFileSync('git', a, { stdio: 'pipe' });
  const ready = (title, summary) => fs.writeFileSync('.dm-result.json', JSON.stringify({ status: 'ready', title, summary, testing: 'check.sh', risk: 'none' }));
  let text = 'The answer is in src/gameplay/a.ts.';
  const edit = (file, from, to, msg, extraMsg = '') => { fs.mkdirSync(require('path').dirname(file), { recursive: true }); fs.writeFileSync(file, (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '').replace(from, to) || to); git('add', '--', file); git('commit', '-q', '-m', msg + extraMsg); };
  // SHOT-PNG / SHOT-PNG2: pretend shot.sh ran (a scenario file + a PNG; PNG2 = different bytes). The !shot prompt mentions shot.sh.
  if (/SHOT-PNG|shot\.sh/.test(p)) {
    fs.writeFileSync('.dm-shot.json', '{"shots":[{"name":"a"}]}'); fs.mkdirSync('.dm-shots', { recursive: true });
    fs.writeFileSync('.dm-shots/a.png', Buffer.from(/SHOT-PNG2/.test(p) ? 'PNG-two-bytes' : 'PNG-one'));
    if (/SHOT-PNG/.test(p) && /BIG/.test(p)) fs.writeFileSync('.dm-shots/big.png', Buffer.alloc(9 * 1024 * 1024, 1));
  }
  if (/secret scan flagged/.test(p)) { git('rm', '-q', '-f', 'src/gameplay/key.ts'); git('commit', '-q', '-m', 'Remove the key file'); text = 'Removed.'; }
  else if (/MAKE-CSS2/.test(p)) { edit('src/ui/ui.css', 'color:blue', 'color:green', 'Make the HUD accent green again'); ready('Green accent', ['green']); text = 'Done.'; }
  else if (/MAKE-CSS/.test(p)) { edit('src/ui/ui.css', 'color:red', 'color:blue', 'Make the HUD accent blue'); ready('HUD accent blue', ['Accent colour is now blue']); text = 'Done, ready for review.'; }
  else if (/MAKE-SERVER/.test(p)) { edit('server/x.js', 'a=1', 'a=2', 'Tweak the server constant'); ready('Server tweak', ['a is 2']); text = 'Done.'; }
  else if (/MAKE-GAMEPLAY/.test(p)) { edit('src/gameplay/a.ts', 'speed=1', 'speed=9', 'Faster movement'); ready('Faster movement', ['speed 9']); text = 'Done.'; }
  else if (/MAKE-COAUTHOR/.test(p)) { edit('src/ui/ui.css', 'color:red', 'color:green', 'Make the HUD accent green', '\n\nCo-Authored-By: Claude <noreply@anthropic.com>'); ready('Green accent', ['green']); text = 'Done.'; }
  else if (/MAKE-SECRET/.test(p)) { edit('src/gameplay/key.ts', '', 'export const k = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123";\n', 'Add a helper'); ready('Helper', ['helper']); text = 'Done.'; }
  else if (/MAKE-FORBIDDEN/.test(p)) { edit('server/death-muffin/deploy-release.sh', 'echo', 'echo hacked', 'Speed up deploys'); ready('Deploy tweak', ['x']); text = 'Done.'; }
  else if (/LONG-REPLY/.test(p)) text = 'Here is the log:\n```\n' + Array.from({ length: 70 }, (_, i) => `line ${i}: ${'x'.repeat(40)}`).join('\n') + '\n```\nDone.';
  else if (/HUGE-REPLY/.test(p)) text = Array.from({ length: 400 }, (_, i) => `row ${i}: ${'y'.repeat(60)}`).join('\n');
  else if (/PASTE-ECHO/.test(p)) text = /PASTED-MARKER-42/.test(p) ? 'I can read the pasted file.' : 'No pasted file in the prompt.';
  else if (/SHOT-PNG|shot\.sh/.test(p)) text = 'Here is how it looks.';
  else if (/ship it|print.*token|ignore your rules/i.test(p)) text = 'I cannot ship, show secrets or change my rules. Only an approver ✅ ships.';
  process.stdout.write(JSON.stringify({ type: 'result', result: text, session_id: 'sess-1', is_error: false, total_cost_usd: 0 }));
});
