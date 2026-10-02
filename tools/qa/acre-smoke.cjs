const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { SWIFTSHADER_ARGS, watchErrors } = require('./lib/qa-common.cjs');
const artifactDir = process.env.DM_QA_ARTIFACT_DIR || require('node:os').tmpdir();
async function main() {
 const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: SWIFTSHADER_ARGS });
 try {
  for (const quality of ['low', 'high']) {
   const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
   const { errors } = watchErrors(page); // ignores @fontsource 403s (node_modules symlinked outside the Vite root)
   await page.addInitScript(q => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, tips: false, autoCombat: false, autoGather: false })), quality);
   await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
   await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
   await page.fill('#cw-user', 'acre_'+quality); await page.fill('#cw-email', 'acre_'+quality+'@example.invalid'); await page.fill('#cw-pass', 'TestingControls');
   await page.locator('#cw-login-btn').click(); await page.locator('.cw-disc').first().click();
   await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded);
   await page.screenshot({ path: path.join(artifactDir, 'acre-starter-'+quality+'.png') });
   for (const type of ['coffin_oak', 'grave_pauper']) {
    await page.evaluate(async () => { const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view; scene.teleportTo(-26, 20); });
    const point = await page.evaluate(type => {
     const d = window.__cwDebug;
     const n = d.nodes('acre').filter(n => n.type === type).sort((a,b) => Math.hypot(a.x+26,a.z-20)-Math.hypot(b.x+26,b.z-20))[0];
     return d.hoverNode(n.id);
    }, type);
    assert.ok(point[0] > 0 && point[0] < 1280 && point[1] > 0 && point[1] < 640, 'Starter '+type+' is visible above bottom controls: '+JSON.stringify(point));
    await page.mouse.move(...point); await page.mouse.click(...point);
    await page.waitForFunction(type => window.__cwDebug.gathering().status.includes(type === 'coffin_oak' ? 'Coffin-Oak' : "Pauper's Grave"), type);
    await page.evaluate(() => window.__cwDebug.advance(3, true));
    const card = await page.locator('[data-nodetip]').boundingBox();
    if (card) assert.ok(card.width <= 276 && card.height <= 160 && card.x >= 0 && card.y >= 0, 'Gather card stays compact');
    await page.screenshot({ path: path.join(artifactDir, 'acre-'+type+'-'+quality+'.png') });
   }
   const markers = await page.evaluate(async () => {
    const runtime = (await import('/src/app/GameRuntime.ts')).getRuntime();
    const groups = runtime.view.nodeViews.group.children.filter(g => g.children[0]?.isInstancedMesh);
    runtime.view.nodeViews.update(30);
    return groups.every(g => g.scale.x === 1 && g.scale.z === 1);
   });
   assert.ok(markers, 'Fishing animation leaves node positions anchored');
   assert.equal(errors.length, 0, JSON.stringify(errors));
   console.log(JSON.stringify({ quality, beginnerTreeClickable: true, beginnerGraveClickable: true, compactGatherCard: true, fixedFishingPositions: markers, browserErrors: errors }));
   await page.close();
  }
 } finally { await browser.close(); }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
