// Stand-in for tools/ai/tripo.mjs: a fake account balance in state.json next to this tool, costs from the spec (60 + 25 rig + 10 per clip).
// Resumable like the real one: credits already paid for an id (paid.json) are not charged again. Switches: files next to this tool.
//   fail-after-generate : spend 60, then fail      leak-key : print the key into the output (the runner must redact it)      slow : take 1.5 s
import fs from 'node:fs'; import path from 'node:path';
const here = path.dirname(new URL(import.meta.url).pathname), base = path.join(here, '..', '..');
const sf = path.join(base, 'state.json'), pf = path.join(base, 'paid.json');
const rd = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return d; } };
const log = (s) => fs.appendFileSync(path.join(base, 'calls.log'), s + '\n');
if (process.env.TRIPO_API_KEY !== 'tsk_FakeTripoKeyForTestsOnly000000000000') { console.error('FAKE tripo: wrong or missing key'); process.exit(7); }
const [cmd, arg, ...rest] = process.argv.slice(2);
const st = rd(sf, { balance: 0 });
if (cmd === 'balance') { if (fs.existsSync(path.join(base, 'balance-fail'))) { console.error('HTTP 500'); process.exit(1); } console.log(`{ balance: ${st.balance}, frozen: 0 }`); process.exit(0); }
if (cmd !== 'run' || !rest.includes('--yes')) { console.error('usage'); process.exit(1); }
const spec = JSON.parse(fs.readFileSync(path.join(process.env.DM_ART_ROOT, arg), 'utf8'));
log(`tripo run ${spec.id} anims=${(spec.animations || []).length} rig=${spec.rig ? spec.rig.rig_type : 'none'} root=${process.env.DM_ART_ROOT}`);
if (fs.existsSync(path.join(base, 'slow'))) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500);
const paid = rd(pf, {}); const total = 60 + (spec.rig ? 25 : 0) + 10 * (spec.animations || []).length;
const charge = (n) => { st.balance -= n; paid[spec.id] = (paid[spec.id] || 0) + n; fs.writeFileSync(sf, JSON.stringify(st)); fs.writeFileSync(pf, JSON.stringify(paid)); };
if (process.env.TRIPO_API_KEY && fs.existsSync(path.join(base, 'leak-key'))) console.log('debug: key=' + process.env.TRIPO_API_KEY);
const dir = path.join(process.env.DM_ART_ROOT, 'art-src', 'tripo', spec.id); fs.mkdirSync(dir, { recursive: true });
if (!(paid[spec.id] >= 60)) charge(60);
if (fs.existsSync(path.join(base, 'fail-after-generate'))) { console.error('generate ok; rig task ended: failed'); process.exit(1); }
if (paid[spec.id] < total) charge(total - paid[spec.id]);
fs.writeFileSync(path.join(dir, 'model.glb'), 'glb'); fs.writeFileSync(path.join(dir, 'generate-preview.png'), Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.from('preview')]));
fs.mkdirSync(path.join(process.env.DM_ART_ROOT, 'art-manifest', 'tripo'), { recursive: true });
fs.writeFileSync(path.join(process.env.DM_ART_ROOT, 'art-manifest', 'tripo', `${spec.id}.json`), JSON.stringify({ spec, totalCredits: paid[spec.id] }));
console.log(`credits: x → y (spent ${paid[spec.id]})`);
