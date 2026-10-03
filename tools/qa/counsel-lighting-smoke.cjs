const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const artifactDir = process.env.DM_QA_ARTIFACT_DIR || require('node:os').tmpdir();
async function main() {
 const browser = await chromium.launch({headless:true, executablePath:process.env.DM_CHROMIUM_PATH || undefined, args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 try {
  const page = await browser.newPage({viewport:{width:1280,height:800}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>localStorage.setItem('dm_settings_v1',JSON.stringify({quality:'low',tips:true,autoCombat:false,autoGather:false})));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
  await page.getByRole('button',{name:'New to the Covenant? Create an account'}).click();
  await page.fill('#cw-user','counsel_review');await page.fill('#cw-email','counsel@example.invalid');await page.fill('#cw-pass','TestingControls');
  await page.locator('#cw-login-btn').click();await page.locator('.cw-disc').first().click();
  await page.waitForFunction(()=>window.__cwDebug?.avatar.c.loaded);
  const handle=page.getByRole('button',{name:'Move Covenant counsel'});await handle.waitFor();await page.waitForTimeout(350);
  const hero=await page.evaluate(()=>({x:window.__cwDebug.player.x,z:window.__cwDebug.player.z,path:window.__cwDebug.player.hasPath}));
  const initial=await page.locator('.cw-tip:not(.out)').boundingBox();const grip=await handle.boundingBox();
  await page.mouse.move(grip.x+40,grip.y+8);await page.mouse.down();await page.mouse.move(grip.x+360,grip.y+48,{steps:12});await page.mouse.up();
  const moved=await page.locator('.cw-tip:not(.out)').boundingBox();assert.ok(moved.x-initial.x>300);assert.ok(moved.y-initial.y>30);
  await handle.press('ArrowRight');
  const saved=await page.evaluate(()=>JSON.parse(localStorage.getItem('dm_counsel_position_v1')));assert.ok(saved.x>moved.x+9);
  assert.deepEqual(await page.evaluate(()=>({x:window.__cwDebug.player.x,z:window.__cwDebug.player.z,path:window.__cwDebug.player.hasPath})),hero,'Dragging counsel never moves the hero');
  const lighting=await page.evaluate(async()=>{const scene=(await import('/src/app/GameRuntime.ts')).getRuntime().view;const saw=scene.worldView.lightSources.find(s=>s.x===-23.5&&s.z===12.5);return{hemi:scene.hemi.intensity,sky:scene.hemi.color.getHex(),ground:scene.hemi.groundColor.getHex(),moon:scene.moon.intensity,pooledLights:scene.worldView.pointLights.length,saw};});
  assert.equal(lighting.sky,0x4b5864);assert.equal(lighting.ground,0x232820);assert.equal(lighting.hemi,1.12);assert.equal(lighting.moon,2.65);assert.equal(lighting.pooledLights,3);assert.ok(lighting.saw?.lit);
  await page.screenshot({path:path.join(artifactDir,'acre-counsel-moved.png')});
  await page.evaluate(async()=>{const scene=(await import('/src/app/GameRuntime.ts')).getRuntime().view;scene.onboarding.show('station');});
  await page.locator('.cw-tip:not(.out) .title').click();await page.waitForFunction(()=>{const card=document.querySelector('.cw-tip:not(.out)');return card&&card.getAnimations().every(a=>a.playState==='finished');});
  const next=await page.locator('.cw-tip:not(.out)').boundingBox();assert.ok(Math.abs(next.x-saved.x)<1&&Math.abs(next.y-saved.y)<1,'Queued counsel remembers position');
  await page.reload();await page.waitForFunction(()=>window.__cwDebug?.avatar.c.loaded);
  await page.evaluate(async()=>{const scene=(await import('/src/app/GameRuntime.ts')).getRuntime().view;scene.onboarding.reset();scene.onboarding.show('welcome');});
  await handle.waitFor();await page.waitForTimeout(350);
  await page.waitForFunction(()=>document.querySelector('.cw-tip:not(.out)').getAnimations().every(a=>a.playState==='finished'));
  const restored=await page.locator('.cw-tip:not(.out)').boundingBox();assert.ok(Math.abs(restored.x-saved.x)<1&&Math.abs(restored.y-saved.y)<1,'Reload remembers position: '+JSON.stringify({saved,restored}));
  await page.setViewportSize({width:420,height:340});
  await page.waitForFunction(()=>{const r=document.querySelector('.cw-tip:not(.out)').getBoundingClientRect();return r.x>=7&&r.y>=7&&r.right<=window.innerWidth-7&&r.bottom<=window.innerHeight-7;});
  const clamped=await page.locator('.cw-tip:not(.out)').boundingBox();assert.ok(clamped.x>=7&&clamped.y>=7&&clamped.x+clamped.width<=413&&clamped.y+clamped.height<=333,'Resizing keeps counsel on screen');
  await page.setViewportSize({width:1280,height:800});
  await page.getByRole('button',{name:"Don't show tips"}).click();await page.waitForFunction(()=>!document.querySelector('.cw-tip'));
  await page.screenshot({path:path.join(artifactDir,'acre-lighting.png')});
  const combat=await page.evaluate(async()=>{const d=window.__cwDebug;const scene=(await import('/src/app/GameRuntime.ts')).getRuntime().view;d.goto('graves');d.god(true);d.advance(.2,false);return{hemi:scene.hemi.intensity,moon:scene.moon.intensity,lights:d.perf(10).lights};});
  assert.equal(combat.hemi,.95);assert.equal(combat.moon,2.4);assert.equal(combat.lights,12);assert.equal(errors.length,0);
  console.log(JSON.stringify({drag:true,keyboardMove:true,noHeroMovement:true,queueAndReloadPersistence:true,resizeClamping:true,disableTips:true,lighting,sameCombatLightingAndLightCount:combat,browserErrors:errors}));
 } finally {await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
