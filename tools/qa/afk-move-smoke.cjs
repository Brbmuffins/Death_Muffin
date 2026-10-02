const assert=require('node:assert/strict');
const {chromium}=require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const {SWIFTSHADER_ARGS,watchErrors,preloadModules}=require('./lib/qa-common.cjs');
// Moving away (minimap click, WASD) during AFK woodcutting must end the gather and clear its status.
async function main(){
 const browser=await chromium.launch({headless:true,executablePath:process.env.DM_CHROMIUM_PATH || undefined,args:SWIFTSHADER_ARGS});
 try{
  const page=await browser.newPage({viewport:{width:1280,height:800}});const {errors}=watchErrors(page);
  await page.addInitScript(()=>localStorage.setItem('dm_settings_v1',JSON.stringify({quality:'low',tips:false,autoCombat:false,autoGather:false})));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5362/?offline');await page.getByRole('button',{name:'New to the Covenant? Create an account'}).click();
  await page.fill('#cw-user','afk_move');await page.fill('#cw-email','test@example.invalid');await page.fill('#cw-pass','TestingControls');await page.locator('#cw-login-btn').click();await page.locator('.cw-disc').first().click();
  await page.waitForFunction(()=>window.__cwDebug?.avatar.c.loaded,null,{timeout:90000});
  await preloadModules(page,{loot:'/src/gameplay/loot.ts'});
  const startAfk=async()=>{await page.keyboard.press('p');await page.getByRole('button',{name:'Start AFK Woodcutting',exact:true}).click();await page.waitForFunction(()=>window.__cwDebug.gathering().afk);
   await page.waitForFunction(()=>{window.__cwDebug.advance(.2,false);return window.__cwDebug.gathering().working;},null,{timeout:30000,polling:300});await page.keyboard.press('Escape');};
  // 1. minimap click
  await startAfk();
  const cutting=await page.evaluate(()=>window.__cwDebug.gathering().status);assert.ok(/Working/.test(cutting),cutting);
  const moved=await page.evaluate(()=>{const v=window.__qaMods.runtime.getRuntime().view;const p=v.player;return v.navigateFromMinimap(p.x+8,p.z+1);});
  const g1=await page.evaluate(()=>{window.__cwDebug.advance(.3,false);return window.__cwDebug.gathering();});
  assert.ok(moved,'minimap navigation accepted');assert.equal(g1.afk,false);assert.equal(g1.node,null);assert.ok(!/Working|Walking/.test(g1.status),g1.status);
  // 2. WASD
  await page.evaluate(()=>window.__cwDebug.advance(3,false));
  await startAfk();
  await page.keyboard.down('d');await page.evaluate(()=>window.__cwDebug.advance(.5,false));await page.keyboard.up('d');
  const g2=await page.evaluate(()=>window.__cwDebug.gathering());assert.equal(g2.afk,false);assert.equal(g2.node,null);
  console.log(JSON.stringify({minimapStops:true,wasdStops:true,status:g1.status,errors}));assert.equal(errors.length,0);
 }finally{await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
