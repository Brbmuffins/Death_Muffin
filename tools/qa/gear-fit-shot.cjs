/**
 * gear-fit-shot.cjs - contact sheets of worn gear on the nine hero rigs (front / side / back).
 *   DM_QA_URL='http://127.0.0.1:5348/?offline' node tools/qa/gear-fit-shot.cjs <out.png> [--kit full|helm|cape|bare] [--legendary 1]
 *        [--clip idle] [--t 0.0] [--heroes ossuary,gravecaller,...] [--tile 220x400] [--views front,side,back] [--crop head]
 * Builds real NecromancerAvatars (the same setEquipment / setCape path remote players use) in a private scene and canvas, so
 * the world and HUD never interfere. Needs the dev server, Playwright (DM_PLAYWRIGHT_MODULE), Chromium (DM_CHROMIUM_PATH).
 * Run it under `flock .chromium-slot-B.lock nice -n 19`.
 */
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const sharp = require('sharp');
const argv = process.argv.slice(2);
const opt = (k, d) => { const i = argv.indexOf('--' + k); return i < 0 ? d : argv[i + 1]; };
const out = argv.find((a, i) => !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--')));
const kit = opt('kit', 'full'), clip = opt('clip', 'idle'), at = +opt('t', 0), crop = opt('crop', 'body');
const [TW, TH] = opt('tile', crop === 'head' ? '240x240' : '200x380').split('x').map(Number);
const views = opt('views', 'front,side,back').split(',');
const ALL = ['ossuary', 'gravecaller', 'mourner', 'rotweaver', 'knight', 'warden', 'monk', 'witch', 'veil'];
const heroes = opt('heroes', ALL.join(',')).split(',');
const legendary = opt('legendary', '0') === '1';
const SLUG = { ossuary: 'hero_ossuary', gravecaller: 'hero_gravecaller', mourner: 'hero_mourner', rotweaver: 'hero_rotweaver', knight: 'hero_hollow_knight', warden: 'hero_grave_warden', monk: 'hero_bell_monk', witch: 'hero_carrion_witch', veil: 'hero_veilwalker' };
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
  page.on('pageerror', (e) => console.log('pageerror', e.message));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5348/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `gshot_${Date.now() % 1e6}`);
  await page.fill('#cw-email', 'shot@example.invalid');
  await page.fill('#cw-pass', 'TestingAnim1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
  await page.evaluate(() => {
    window.__gs = null;
    Promise.all([import('/src/graphics/Avatars.ts'), import('/src/content/gear.ts'), import(performance.getEntriesByType('resource').map((e) => e.name).find((n) => /\/deps\/three\.js/.test(n)))])
      .then(([a, g, t]) => { window.__gs = { a, g, t }; });
  });
  await page.waitForFunction(() => window.__gs, null, { timeout: 60000 });
  const cfg = { heroes, SLUG, kit, clip, at, views, TW, TH, crop, legendary };
  const data = await page.evaluate(async (cfg) => {
    const { NecromancerAvatar } = window.__gs.a;
    const THREE = window.__gs.t;
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x1a1622);
    scene.add(new THREE.HemisphereLight(0xe6e9ff, 0x6a5a7a, 3.2));
    const key = new THREE.DirectionalLight(0xfff0dd, 2.4); key.position.set(2, 4, 3); scene.add(key);
    const fill = new THREE.DirectionalLight(0x9fb0ff, 1.0); fill.position.set(-3, 2, -3); scene.add(fill);
    const avs = [];
    const LEGSET = { ossuary: 'colossus_mantle', gravecaller: 'legion_unburied', mourner: 'requiem_wraiths', rotweaver: 'plague_choir' };
    cfg.heroes.forEach((h, i) => {
      const av = new NecromancerAvatar(scene, '#a26bff', false, cfg.SLUG[h]);
      av.c.root.position.set(i * 4, 0, 0);
      avs.push(av);
    });
    await new Promise((r) => { const t = setInterval(() => { if (avs.every((a) => a.c.loaded)) { clearInterval(t); r(); } }, 200); });
    cfg.heroes.forEach((h, i) => {
      const av = avs[i];
      const set = cfg.legendary && LEGSET[h] ? `leg_${LEGSET[h]}` : `set_${h}_ascended`;
      const items = {};
      if (cfg.kit === 'full' || cfg.kit === 'helm') {
        items.head = { item_id: `${set}_head`, rarity: cfg.legendary ? 'legendary' : 'epic' };
        items.chest = { item_id: `${set}_chest`, rarity: 'epic' };
        items.hands = { item_id: `${set}_hands`, rarity: 'epic' };
        items.legs = { item_id: `${set}_legs`, rarity: 'epic' };
        items.feet = { item_id: `${set}_feet`, rarity: 'epic' };
      }
      if (cfg.kit === 'full') {
        const necro = ['ossuary', 'gravecaller', 'mourner', 'rotweaver'].includes(h);
        items.main_hand = { item_id: necro ? 'staff_oak' : 'sword_iron', rarity: 'rare' };
        items.off_hand = { item_id: necro ? 'skull_focus_bone' : 'shield_iron', rarity: 'rare' };
      }
      av.setEquipment(items);
      if (cfg.kit === 'full' || cfg.kit === 'cape') av.setCape('cape_apprentice');
      if (/^(death|hurt)/.test(cfg.clip)) av.c.playOnce(cfg.clip); else av.c.setLoop(cfg.clip);
    });
    const tick = () => avs.forEach((a, i) => a.update(1 / 60, i * 4, 0, 0, false, 0));
    for (let k = 0; k < 90; k++) tick();
    if (cfg.at > 0) for (let k = 0; k < cfg.at * 60; k++) tick();
    const cv = document.createElement('canvas');
    cv.width = cfg.TW * cfg.heroes.length; cv.height = cfg.TH * cfg.views.length;
    const r = new THREE.WebGLRenderer({ canvas: cv, antialias: true, preserveDrawingBuffer: true });
    r.setPixelRatio(1); r.setSize(cv.width, cv.height, false); r.setScissorTest(true);
    r.outputColorSpace = THREE.SRGBColorSpace;
    const cam = new THREE.PerspectiveCamera(cfg.crop === 'head' ? 14 : 26, cfg.TW / cfg.TH, 0.1, 50);
    const head = cfg.crop === 'head';
    const calls = [];
    for (let vi = 0; vi < cfg.views.length; vi++) {
      const v = cfg.views[vi];
      for (let i = 0; i < cfg.heroes.length; i++) {
        const cx = i * 4, cy = head ? 1.62 : 1.0, d = head ? 5.2 : 6.8;
        const ang = { front: 0, side: Math.PI / 2, back: Math.PI, q: Math.PI / 4, qb: (3 * Math.PI) / 4 }[v] ?? 0;
        cam.position.set(cx + Math.sin(ang) * d, cy + (head ? 0.25 : 0.7), Math.cos(ang) * d);
        cam.lookAt(cx, cy, 0);
        cam.updateMatrixWorld();
        const x = i * cfg.TW, y = (cfg.views.length - 1 - vi) * cfg.TH;
        avs.forEach((a, j) => { a.c.root.visible = j === i; });
        r.setViewport(x, y, cfg.TW, cfg.TH); r.setScissor(x, y, cfg.TW, cfg.TH);
        r.render(scene, cam);
        calls.push(r.info.render.calls);
      }
    }
    return { url: cv.toDataURL('image/png'), fits: avs.map((a) => a.c.headFit()), calls };
  }, cfg);
  console.log('drawcalls per tile (row-major):', data.calls.join(','), 'sum', data.calls.reduce((a, b) => a + b, 0));
  console.log('headFit', JSON.stringify(Object.fromEntries(heroes.map((h, i) => [h, data.fits[i] && Object.fromEntries(Object.entries(data.fits[i]).map(([k, v]) => [k, +v.toFixed(3)]))]))));
  await sharp(Buffer.from(data.url.split(',')[1], 'base64')).png().toFile(out);
  console.log('wrote', out);
  await browser.close();
})();
