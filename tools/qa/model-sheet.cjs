// Render built GLBs to PNGs + a contact sheet (no game needed).
//   node tools/qa/model-sheet.cjs <outDir> <name=url[:height[:clip]]> ...   e.g. cauldron=models/props/alch_cauldron.glb:1.3
// Needs: playwright-core (DM_PLAYWRIGHT_MODULE), Chromium (DM_CHROMIUM_PATH), sharp (repo dep).
const http = require('http'), fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..', '..');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright-core');
const sharp = require('sharp');
const [out, ...specs] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.glb': 'model/gltf-binary', '.webp': 'image/webp', '.json': 'application/json' };
const srv = http.createServer((q, s) => {
  let p = decodeURIComponent(q.url.split('?')[0]);
  let f = p.startsWith('/node_modules/') ? path.join(root, p) : p === '/' ? path.join(__dirname, 'viewer/model-viewer.html') : path.join(root, 'public', p);
  fs.readFile(f, (e, d) => { if (e) { s.writeHead(404); s.end(); } else { s.writeHead(200, { 'content-type': mime[path.extname(f)] || 'application/octet-stream' }); s.end(d); } });
});
srv.listen(0, '127.0.0.1', async () => {
  const port = srv.address().port;
  const b = await chromium.launch({ executablePath: process.env.DM_CHROMIUM_PATH, args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const pg = await b.newPage({ viewport: { width: 640, height: 640 } });
  pg.on('pageerror', (e) => console.log('pageerror', e.message));
  await pg.goto(`http://127.0.0.1:${port}/`); await pg.waitForFunction('window.ready');
  const files = [];
  for (const sp of specs) {
    const [name, rest] = sp.split('=');
    const [url, h, clip, yaw] = rest.split(':');
    const views = clip ? clip.split(',').map((c) => { const [n, t] = c.split('@'); return [n, t === undefined ? 0.5 : +t]; }) : [[null, 0]];
    for (const [c, t] of views) {
      const info = await pg.evaluate(([u, o]) => window.show(u, o), [url, { height: +(h || 1.5), clip: c, t, yaw: yaw !== undefined ? +yaw : 0.6 }]);
      const f = path.join(out, `${name}${c ? '_' + c + (t !== 0.5 ? '@' + t : '') : ''}.png`);
      await pg.locator('canvas').screenshot({ path: f }); files.push(f);
      console.log(name, JSON.stringify(info));
    }
  }
  await b.close(); srv.close();
  const C = Math.min(+(process.env.DM_COLS || 4), files.length), W = 400, rows = Math.ceil(files.length / C);
  const comps = await Promise.all(files.map(async (f, i) => ({ input: await sharp(f).resize(W, W).toBuffer(), left: (i % C) * W, top: Math.floor(i / C) * W })));
  await sharp({ create: { width: C * W, height: rows * W, channels: 3, background: '#0d0b12' } }).composite(comps).png().toFile(path.join(out, 'sheet.png'));
});
