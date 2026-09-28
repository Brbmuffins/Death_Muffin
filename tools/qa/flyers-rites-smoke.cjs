/**
 * Flying pack + Grimoire expansion + Bone Mantle smoke (offline preview, High quality so Binbun renders).
 *   npm run dev -- --host 127.0.0.1 --port 5199 --strictPort
 *   node tools/qa/flyers-rites-smoke.cjs
 * Screenshots go to DM_QA_ARTIFACT_DIR (default: the system temp dir). Fails on page errors, a flyer
 * model that did not load, or a rite that did not cast.
 */
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const OUT = process.env.DM_QA_ARTIFACT_DIR || os.tmpdir();

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  const models = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  page.on('response', (r) => r.url().endsWith('.glb') && models.push([r.url().split('/').pop(), r.status()]));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `flyqa_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('flyqa@example.invalid');
  await page.fill('#cw-pass', 'TestingFlyers1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
  const shot = async (name) => page.screenshot({ path: path.join(OUT, `qa-${name}.png`) });

  // --- Flyers: one of each around the hero, then a gargoyle mid-dive.
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.god(true);
    d.goto('graves');
    d.advance(0.5);
    d.clear();
    const p = d.player;
    const ids = ['gargoyle', 'moth', 'bat', 'seraph'].map((def, i) => {
      const e = d.sim().spawnEnemy(def, 'graves', p.x + Math.sin(i * 1.57 + 0.4) * 3.2, p.z + Math.cos(i * 1.57 + 0.4) * 3.2, false, false);
      e.attackCd = 99;
      return e;
    });
    d.freeze(true);
    d.zoom(0.55);
    d.advance(2.5);
    return ids.length;
  });
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.__cwDebug.advance(0.6));
  await shot('flyers');
  const flapped = await page.evaluate(() => window.__cwDebug.sim().enemies.size);
  assert.ok(flapped >= 4, 'flyers spawned');
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.freeze(false);
    d.clear();
    const p = d.player;
    const g = d.sim().spawnEnemy('gargoyle', 'graves', p.x + 6, p.z + 1, false, false);
    g.attackCd = 0;
    d.advance(0.55);
  });
  await shot('gargoyle-dive');

  // --- Rites: Bone Mantle on a pile of corpses, then the four new rites on a pack.
  const casts = await page.evaluate(async () => {
    const d = window.__cwDebug;
    const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
    d.clear();
    d.unlockAll();
    // Every rite, as the dev account has it (runtime overlay only, never saved).
    (await import('/src/gameplay/devAccess.ts')).devAccess.active = true;
    d.freeze(true);
    const p = d.player;
    const out = {};
    const pack = (n, r, def = 'robber') => {
      const list = [];
      for (let i = 0; i < n; i++) {
        const e = d.sim().spawnEnemy(def, 'graves', p.x + 5 + Math.sin(i * 2.4) * r, p.z + Math.cos(i * 2.4) * r, false, false);
        e.hp = e.maxHp = 5000;
        list.push(e);
      }
      return list;
    };
    const cast = (id, t) => {
      p.essence = p.resource.max;
      p.cooldowns.clear();
      p.castUntil = 0;
      return scene.abilities.cast(id, t, scene.now);
    };
    for (let i = 0; i < 4; i++) d.sim().addCorpse(p.x + Math.sin(i) * 2, p.z + Math.cos(i) * 2, 'normal', 'robber', false, 0, 1, 'graves');
    out.mantle = cast('bone_mantle', { x: p.x, z: p.z });
    d.advance(0.5);
    return out;
  });
  await page.waitForTimeout(600);
  await page.evaluate(() => window.__cwDebug.advance(0.3));
  await shot('bone-mantle');
  for (const [id, wait] of [['bone_prison', 0.25], ['grave_hands', 0.7], ['bone_storm', 0.9], ['soul_siphon', 0.8]]) {
    const r = await page.evaluate(async ([rite, wait]) => {
      const d = window.__cwDebug;
      const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
      d.clear();
      const p = d.player;
      const list = [];
      for (let i = 0; i < 5; i++) {
        const e = d.sim().spawnEnemy(rite === 'soul_siphon' ? 'golem' : 'robber', 'graves', p.x + 5 + Math.sin(i * 2.4) * 1.2, p.z + Math.cos(i * 2.4) * 1.2, false, false);
        e.hp = e.maxHp = 5000;
        list.push(e);
        if (rite === 'soul_siphon') break;
      }
      for (let i = 0; i < 3; i++) d.sim().addCorpse(p.x + 5 + i * 0.6, p.z - 0.5, 'normal', 'robber', false, 0, 1, 'graves');
      p.essence = p.resource.max;
      p.cooldowns.clear();
      p.castUntil = 0;
      const t = { x: list[0].x, z: list[0].z, enemyId: list[0].id };
      const res = scene.abilities.cast(rite, t, scene.now);
      d.advance(wait);
      return { res, hp: list.map((e) => Math.round(e.hp)), root: list.map((e) => e.rootT ?? 0) };
    }, [id, wait]);
    await page.waitForTimeout(400);
    await page.evaluate(() => window.__cwDebug.advance(0.05));
    await shot(id.replace('_', '-'));
    assert.equal(r.res, 'ok', `${id} cast`);
    console.log(id, JSON.stringify(r));
  }
  assert.equal(casts.mantle, 'ok', 'bone mantle cast');

  // --- Perf: 36 enemies, the old roster vs the flying pack (CPU update, draw calls, triangles).
  const perf = await page.evaluate(() => {
    const d = window.__cwDebug;
    d.freeze(false);
    const run = (defs) => {
      d.clear();
      d.advance(0.2);
      const p = d.player;
      for (let i = 0; i < 36; i++) {
        const e = d.sim().spawnEnemy(defs[i % defs.length], 'graves', p.x + Math.sin(i) * (4 + (i % 5)), p.z + Math.cos(i) * (4 + (i % 5)), false, false);
        e.hp = e.maxHp = 1e6;
      }
      d.advance(1);
      const r = d.perf(120);
      return { calls: r.calls, triangles: r.triangles, updateMs: +r.updateMs.toFixed(3), programs: r.programs };
    };
    return { ground: run(['robber', 'hound', 'penitent', 'rat']), flyers: run(['gargoyle', 'moth', 'bat', 'seraph']) };
  });
  console.log('perf', JSON.stringify(perf));
  const flyerModels = models.filter(([f]) => /gargoyle|seraph|shroud_moth|tithe_bat|mantle_|grave_hand/.test(f) || f === 'character.glb');
  console.log('models', JSON.stringify(models.filter(([f]) => /shroud|tithe|mantle|grave_hand/.test(f))));
  assert.ok(flyerModels.every(([, s]) => s === 200 || s === 304), 'a model failed to load');
  assert.deepEqual(errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e)), [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
