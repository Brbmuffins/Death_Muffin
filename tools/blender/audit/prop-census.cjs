// Read-only: placements per prop kind per area (from generateLayout) joined with GLB tri counts (inventory.json).
// node prop-census.cjs <inventory.json>  -> JSON { props:[{id,tris,total,perArea,tall,casterTris}], areas:{area:{tris,casterTris,batches}} }
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
  const inv = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const tri = Object.fromEntries(inv.filter((x) => x.file.startsWith('props/')).map((x) => [x.file.replace('props/', '').replace('.glb', ''), x.tris]));
  const b = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox'] });
  const p = await b.newPage(); await p.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5383/?offline');
  const lay = await p.evaluate(async () => {
    const { generateLayout, PROPS } = await import('/src/content/layout.ts');
    const l = generateLayout(); const m = {};
    for (const pl of l.props) { const k = pl.prop; (m[k] ||= { height: PROPS[pl.prop].height, areas: {} }); m[k].areas[pl.area] = (m[k].areas[pl.area] || 0) + 1; }
    return m;
  });
  const props = [], areas = {};
  for (const [id, v] of Object.entries(lay)) {
    const t = tri[id] ?? null; const total = Object.values(v.areas).reduce((a, b) => a + b, 0); const tall = v.height > 1.5;
    props.push({ id, tris: t, total, tall, worldTris: t ? t * total : null, areas: v.areas });
    for (const [a, c] of Object.entries(v.areas)) { const r = (areas[a] ||= { tris: 0, casterTris: 0, batches: 0, instances: 0 }); r.batches++; r.instances += c; if (t) { r.tris += t * c; if (tall) r.casterTris += t * c; } }
  }
  props.sort((a, b) => (b.worldTris || 0) - (a.worldTris || 0));
  console.log(JSON.stringify({ props, areas }, null, 1)); await b.close();
})();
