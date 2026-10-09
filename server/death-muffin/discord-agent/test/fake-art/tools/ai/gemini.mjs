// Stand-in for tools/ai/gemini.mjs: writes a tiny PNG where the job says. NO network. Behaviour switches are files next to this tool.
import fs from 'node:fs'; import path from 'node:path';
const here = path.dirname(new URL(import.meta.url).pathname), base = path.join(here, '..', '..');
const log = (s) => fs.appendFileSync(path.join(base, 'calls.log'), s + '\n');
const root = process.env.DM_ART_ROOT;
if (process.env.GEMINI_API_KEY !== 'AIzaFakeGeminiKeyForTestsOnly000000000000') { console.error('FAKE gemini: wrong or missing key'); process.exit(7); }
log(`gemini cwd=${process.cwd() === root ? 'root' : 'other'}`);
if (fs.existsSync(path.join(base, 'gemini-fail'))) { console.log('FAILED: no image: SAFETY'); process.exit(0); }   // the real tool prints FAILED and exits 0
const jobs = JSON.parse(fs.readFileSync(path.join(root, process.argv[2]), 'utf8'));
for (const j of jobs) {
  const out = path.join(root, j.out); if (fs.existsSync(out)) { console.log(`skip ${j.id} (exists)`); continue; }
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from('fake concept for ' + j.id)]));
  console.log(`gen  ${j.id} … ok`);
}
