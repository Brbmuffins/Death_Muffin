const assert = require('node:assert/strict');
const path = require('node:path');
const os = require('node:os');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false, autoGather: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', 'tool_review');
    await page.fill('#cw-email', 'tool_review@example.invalid');
    await page.fill('#cw-pass', 'TestingControls');
    await page.locator('#cw-login-btn').click();
    const chosenClass = process.env.DM_QA_CLASS;
    await (chosenClass ? page.locator('.cw-disc').filter({ hasText: chosenClass }) : page.locator('.cw-disc').first()).click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded);
    await page.evaluate(async () => { window.__gatherView = (await import('/src/app/GameRuntime.ts')).getRuntime().view; });
    if (chosenClass) await page.waitForFunction(() => window.__gatherView.avatar.classGear.length > 0);
    await page.keyboard.press('p');

    for (const [skill, label] of [
      ['woodcutting', 'Woodcutting'], ['mining', 'Mining'], ['fishing', 'Fishing'], ['gravedigging', 'Gravedigging'],
    ].filter(([id]) => !process.env.DM_QA_SKILL || id === process.env.DM_QA_SKILL)) {
      await page.getByRole('button', { name: `Start AFK ${label}`, exact: true }).click();
      await page.waitForFunction(id => {
        const view = window.__gatherView;
        return view.gathering.afk && view.avatar.gatheringTools.get(id)?.visible &&
          view.nodeViews.selectedRing.visible &&
          (view.avatar.staff ? !view.avatar.staff.visible : view.avatar.classGear.every(obj => !obj.visible));
      }, skill, { timeout: 15000 });
      const state = await page.evaluate(id => {
        const view = window.__gatherView;
        const ring = view.nodeViews.selectedRing;
        ring.geometry.computeBoundingBox();
        const size = new ring.geometry.boundingBox.constructor().setFromObject(view.avatar.gatheringTools.get(id))
          .getSize(ring.position.clone());
        return { skill: id, modelMeshes: view.avatar.gatheringTools.get(id).children.length, size: size.toArray(),
          selected: view.nodeViews.selectedRing.visible, otherToolsVisible: [...view.avatar.gatheringTools]
            .filter(([name, obj]) => name !== id && obj.visible).length };
      }, skill);
      assert.ok(state.modelMeshes > 0, `${skill} model has geometry`);
      assert.ok(Math.max(...state.size) > 0.5 && Math.max(...state.size) < 2.4,
        `${skill} has a readable hand-held size: ${state.size}`);
      assert.equal(state.otherToolsVisible, 0, 'Only one gathering tool is visible');
      await page.waitForFunction(() => window.__gatherView.gathering.working, null, { timeout: 30000 });
      await page.locator('[role="dialog"][aria-label="Skills"]').evaluate(el => { el.style.visibility = 'hidden'; });
      await page.screenshot({ path: path.join(process.env.DM_QA_ARTIFACT_DIR || os.tmpdir(), `gather-${skill}.png`) });
      await page.locator('[role="dialog"][aria-label="Skills"]').evaluate(el => { el.style.visibility = ''; });
      await page.getByRole('button', { name: 'Pause AFK', exact: true }).click();
      const stopped = await page.evaluate(() => {
        const view = window.__gatherView;
        return { active: view.gathering.afk, selected: view.nodeViews.selectedRing.visible,
          gearRestored: view.avatar.staff ? view.avatar.staff.visible : view.avatar.classGear.every(obj => obj.visible),
          visibleTools: [...view.avatar.gatheringTools.values()].filter(obj => obj.visible).length };
      });
      assert.deepEqual(stopped, { active: false, selected: false, gearRestored: true, visibleTools: 0 });
      console.log(JSON.stringify(state));
    }
    assert.deepEqual(errors, [], 'No browser runtime errors');
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
