/**
 * enemy-shot.cjs - in-game close-ups of one enemy type walking/running at the hero (offline game, Hollow Graves).
 *   DM_QA_URL='http://127.0.0.1:5346/?offline' node tools/qa/enemy-shot.cjs <def> <out.png> [--frames 6] [--step 0.18] [--size 260] [--radius 7] [--zoom 0.3]
 * Needs the dev server (npm run dev -- --port N), playwright (DM_PLAYWRIGHT_MODULE) and Chromium (DM_CHROMIUM_PATH).
 * Follows the enemy with the camera crop and writes a horizontal strip of N frames `step` seconds apart.
 */
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const sharp = require('sharp');
const argv = process.argv.slice(2);
const opt = (k, d) => { const i = argv.indexOf('--' + k); return i < 0 ? d : argv[i + 1]; };
const [def, out] = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--')));
const N = +opt('frames', 6), step = +opt('step', 0.18), size = +opt('size', 260), radius = +opt('radius', 7), zoom = +opt('zoom', 0.3);
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5346/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `shot_${Date.now() % 1e6}`);
  await page.fill('#cw-email', 'shot@example.invalid');
  await page.fill('#cw-pass', 'TestingAnim1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(([zoom]) => { const d = window.__cwDebug; d.goto('graves'); d.unlockAll?.(); d.god(true); d.clear(); d.zoom(zoom); d.advance(0.5); }, [zoom]);
  const id = await page.evaluate(async ([def, radius]) => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const d = window.__cwDebug, scene = getRuntime().view;
    scene.player.x = 0; scene.player.z = 0;
    const id = d.ring(def, 1, radius)[0];
    const e = d.sim().enemies.get(id); e.hp = e.maxHp = 1e9;
    for (let k = 0; k < 40 && !(scene.views.enemies.get(id)?.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); d.advance(0.05, false); }
    d.advance(1.0, false);
    return id;
  }, [def, radius]);
  const frames = [];
  for (let i = 0; i < N; i++) {
    const p = await page.evaluate(async ([id, step]) => {
      const { getRuntime } = await import('/src/app/GameRuntime.ts');
      const d = window.__cwDebug, s = getRuntime().view;
      d.advance(step);
      const v = s.views.enemies.get(id)?.c.root.position; if (!v) return null;
      const q = s.rig.camera.position.clone().set(v.x, v.y + 0.5, v.z).project(s.rig.camera);
      return { x: (q.x * 0.5 + 0.5) * innerWidth, y: (-q.y * 0.5 + 0.5) * innerHeight };
    }, [id, step]);
    if (!p) break;
    const x = Math.max(0, Math.min(900 - size, Math.round(p.x - size / 2))), y = Math.max(0, Math.min(600 - size, Math.round(p.y - size / 2)));
    frames.push(await page.screenshot({ clip: { x, y, width: size, height: size }, timeout: 90000 }));
  }
  const comps = frames.map((f, i) => ({ input: f, left: i * size, top: 0 }));
  await sharp({ create: { width: size * frames.length, height: size, channels: 3, background: '#16121d' } }).composite(comps).png().toFile(out);
  console.log('wrote', out, frames.length, 'frames');
  await browser.close();
})();
