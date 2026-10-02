/**
 * clip-strip.cjs — orthographic side-view frame strip of one clip of a GLB, rendered in Chromium (three.js).
 *
 *   node tools/qa/clip-strip.cjs <out.png> <file.glb|public-url> <clip> [--frames 8] [--facing -z|+z|+x|-x]
 *        [--speed 1.2 [--abs]] [--skeleton] [--cell 300] [--time-scale 1] [--from 0 --to 1] [--label text]
 *
 * Every cell is the same clip phase on a ground with fixed tick marks. With --speed (model units per second at the
 * model's own scale; body-heights per second unless --abs says model units) the body is also carried forward at that ground speed, so a planted foot stays on its tick mark
 * and a sliding foot visibly drifts. Without it the body stays in place (a stand-in for the engine, which moves it).
 * `--facing` is the direction the model's nose points in its glTF file; it is turned to screen-right.
 * Needs playwright (DM_PLAYWRIGHT_MODULE) and Chromium (DM_CHROMIUM_PATH), like model-sheet.cjs.
 */
const http = require('http'), fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..', '..');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const sharp = require('sharp');

const argv = process.argv.slice(2);
const pos = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--') && !['--skeleton'].includes(argv[i - 1])));
const opt = (k, d) => { const i = argv.indexOf('--' + k); return i < 0 ? d : argv[i + 1]; };
const [out, file, clip] = pos;
const frames = +opt('frames', 8), cell = +opt('cell', 300), facing = opt('facing', '-z');
const speed = opt('speed', null) === null ? null : +opt('speed', 0), skeleton = argv.includes('--skeleton');
const absSpeed = argv.includes('--abs'), from = +opt('from', 0), to = +opt('to', 1), tscale = +opt('time-scale', 1), label = opt('label', '');
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.glb': 'model/gltf-binary', '.webp': 'image/webp', '.json': 'application/json' };
const abs = path.isAbsolute(file) ? file : path.resolve(file);
const srv = http.createServer((q, s) => {
  const p = decodeURIComponent(q.url.split('?')[0]);
  let f;
  if (p === '/') { s.writeHead(200, { 'content-type': 'text/html' }); s.end(PAGE); return; }
  if (p === '/model.glb') f = fs.existsSync(abs) ? abs : path.join(root, 'public', file);
  else if (p.startsWith('/node_modules/')) f = path.join(root, p);
  else f = path.join(root, 'public', p);
  fs.readFile(f, (e, d) => { if (e) { s.writeHead(404); s.end(); } else { s.writeHead(200, { 'content-type': mime[path.extname(f)] || 'application/octet-stream' }); s.end(d); } });
});
const PAGE = `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:#16121d}</style>
<script type="importmap">{"imports":{"three":"/node_modules/three/build/three.module.js","three/addons/":"/node_modules/three/examples/jsm/"}}</script>
<script type="module">
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
const r = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
r.outputColorSpace = THREE.SRGBColorSpace; r.toneMapping = THREE.ACESFilmicToneMapping; r.toneMappingExposure = 2.0;
document.body.appendChild(r.domElement);
const scene = new THREE.Scene(); scene.background = new THREE.Color(0x1a1620);
scene.add(new THREE.HemisphereLight(0xb8b0d0, 0x2a2018, 1.5));
const sun = new THREE.DirectionalLight(0xfff0d8, 2.2); sun.position.set(2, 5, 6); scene.add(sun);
let g, o, mixer, action, skel, ticks = new THREE.Group(); scene.add(ticks);
window.setup = async (cfg) => {
  g = await new GLTFLoader().loadAsync('/model.glb');
  o = g.scene; scene.add(o);
  const yaw = { '+x': 0, '-x': Math.PI, '-z': -Math.PI / 2, '+z': Math.PI / 2 }[cfg.facing];
  o.rotation.y = yaw; o.updateMatrixWorld(true);
  let box = new THREE.Box3().setFromObject(o); o.position.y -= box.min.y; o.updateMatrixWorld(true);
  window.__h = box.max.y - box.min.y; window.__ext = Math.max(box.max.x - box.min.x, box.max.z - box.min.z, window.__h); window.__cx = (box.max.x + box.min.x) / 2;
  const a = g.animations.find((x) => x.name === cfg.clip) || g.animations[0];
  mixer = new THREE.AnimationMixer(o); action = mixer.clipAction(a); action.play();
  window.__dur = a.duration;
  if (cfg.skeleton) { o.traverse((c) => { if (c.isSkinnedMesh) c.material.opacity = 0.35, c.material.transparent = true; }); skel = new THREE.SkeletonHelper(o); skel.material.depthTest = false; skel.material.linewidth = 2; scene.add(skel); }
  r.setSize(cfg.cell, cfg.cell);
  const world = window.__ext * 1.3;
  const cam = new THREE.OrthographicCamera(-world / 2, world / 2, world * 0.8, -world * 0.2, 0.1, 100);
  window.__cam = cam; window.__world = world;
  const lm = new THREE.LineBasicMaterial({ color: 0x777788 });
  for (let i = -20; i <= 20; i++) { const x = i * window.__h * 0.25; ticks.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(x, -0.01, 0), new THREE.Vector3(x, -world * 0.04, 0)]), lm)); }
  ticks.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(-50, 0, 0), new THREE.Vector3(50, 0, 0)]), new THREE.LineBasicMaterial({ color: 0x555566 })));
  return { height: window.__h, dur: window.__dur };
};
window.frame = (t, x) => {
  mixer.setTime(t); o.position.x = x; o.updateMatrixWorld(true); o.traverse((c) => { if (c.isSkinnedMesh) c.skeleton.update(); });
  const cx = x + window.__cx; window.__cam.position.set(cx, 0, 20); window.__cam.lookAt(cx, 0, 0);
  window.__cam.updateProjectionMatrix(); r.render(scene, window.__cam);
};
window.ready = true;
</script>`;
srv.listen(0, '127.0.0.1', async () => {
  const port = srv.address().port;
  const b = await chromium.launch({ executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const pg = await b.newPage({ viewport: { width: cell, height: cell } });
  pg.on('pageerror', (e) => console.log('pageerror', e.message));
  await pg.goto(`http://127.0.0.1:${port}/`); await pg.waitForFunction('window.ready');
  const info = await pg.evaluate((c) => window.setup(c), { clip, facing, skeleton, cell });
  const cells = [];
  const dur = info.dur;
  // Carry the body at `speed` (in body-heights per second when given as e.g. 0.9) across one loop of the clip.
  const spanT = (to - from) * dur;
  for (let f = 0; f < frames; f++) {
    const u = from + ((to - from) * f) / frames;
    const t = u * dur;
    const x = speed === null ? 0 : (absSpeed ? speed : speed * info.height) * ((t - from * dur) / tscale);
    if (speed !== null) await pg.evaluate((cx) => { window.__cfx = 0; }, x);
    await pg.evaluate(([tt, xx]) => window.frame(tt, xx), [t, x]);
    cells.push(await pg.locator('canvas').screenshot());
  }
  await b.close(); srv.close();
  const H = 22;
  const text = (s, x) => `<text x="${x}" y="15" fill="#ccc" font-size="13" font-family="monospace">${s}</text>`;
  const comps = cells.map((buf, i) => ({ input: buf, left: i * cell, top: H }));
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${cell * frames}" height="${H}">` + (label ? text(label, 6) : '') +
    Array.from({ length: frames }, (_, i) => text((((from + ((to - from) * i) / frames) * dur)).toFixed(2) + 's', i * cell + cell - 60)).join('') + '</svg>';
  comps.push({ input: Buffer.from(svg), left: 0, top: 0 });
  await sharp({ create: { width: cell * frames, height: cell + H, channels: 3, background: '#16121d' } }).composite(comps).png().toFile(out);
  console.log('wrote', out, JSON.stringify(info), speed === null ? 'in place' : `carried at ${speed} body-heights/s`);
});
