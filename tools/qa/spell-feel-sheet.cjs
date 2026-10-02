/**
 * Contact sheets for docs/NECRO-SPELL-FEEL.md: one PNG per rite with the BEFORE frames on the left and AFTER on the right.
 *   DM_QA_OUT=docs/screenshots/spell-feel node tools/qa/spell-feel-sheet.cjs [beforeTag afterTag]
 * Reads <tag>-<rite>-<n>.png written by spell-feel-smoke.cjs, writes sheet-<rite>.jpg. Delete the per-frame PNGs afterwards if the repo should stay small (the sheets carry both sides).
 */
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const OUT = path.resolve(process.env.DM_QA_OUT || 'docs/screenshots/spell-feel');
const [A = 'before', B = 'after'] = process.argv.slice(2);
const W = 352;

(async () => {
  const files = fs.readdirSync(OUT);
  const rites = [...new Set(files.filter((f) => f.startsWith(`${A}-`) && f.endsWith('.png')).map((f) => f.slice(A.length + 1).replace(/-\d+\.png$/, '')))];
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: W * 4 + 30, height: 260 } });
  for (const r of rites) {
    const col = (tag) => files.filter((f) => f.startsWith(`${tag}-${r}-`) && f.endsWith('.png')).sort().map((f) => `<img src="file://${path.join(OUT, f)}" width="${W}">`).join('');
    const html = `<body style="margin:0;background:#0b0810;color:#cbbf9f;font:12px sans-serif"><div style="display:flex;gap:10px;padding:4px"><div><b>${A}</b><div style="display:flex">${col(A)}</div></div><div><b>${B}</b><div style="display:flex">${col(B)}</div></div></div>`;
    const tmp = path.join(require('node:os').tmpdir(), `sheet-${r}.html`);
    fs.writeFileSync(tmp, html);
    await page.goto(`file://${tmp}`);
    await page.screenshot({ path: path.join(OUT, `sheet-${r}.jpg`), type: 'jpeg', quality: 82, fullPage: true });
  }
  await browser.close();
  console.log('sheets', rites.length);
})();
