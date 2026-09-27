const path=require('node:path');
const artifactDir=process.env.DM_QA_ARTIFACT_DIR || require('node:os').tmpdir();
const assert=require('node:assert/strict');
const {chromium}=require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
async function main(){
 const browser=await chromium.launch({headless:true,executablePath:process.env.DM_CHROMIUM_PATH || undefined,args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 try{
  const page=await browser.newPage({viewport:{width:1280,height:800}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>localStorage.setItem('dm_settings_v1',JSON.stringify({quality:'low',tips:false,autoCombat:false,autoGather:false})));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');await page.getByRole('button',{name:'New to the Covenant? Create an account'}).click();
  await page.fill('#cw-user','afk_review');await page.fill('#cw-email','test@example.invalid');await page.fill('#cw-pass','TestingControls');await page.locator('#cw-login-btn').click();await page.locator('.cw-disc').first().click();
  await page.waitForFunction(()=>window.__cwDebug?.avatar.c.loaded);
  await page.evaluate(async()=>{const g=(await import('/src/app/GameRuntime.ts')).getRuntime().view.gathering;const stop=g.stop.bind(g);window.__afkStops=[];g.stop=(reason,message)=>{if(g.afk)window.__afkStops.push({reason,message});return stop(reason,message);};});
  await page.keyboard.press('p');await page.getByRole('button',{name:'Start AFK Woodcutting',exact:true}).click();
  await page.waitForFunction(()=>window.__cwDebug.gathering().afk);
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});window.__afkHiddenAt=Date.now();});
  try { await page.waitForFunction(()=>window.__cwDebug.inventory.all.some(s=>s.item_id==='log_oak'&&s.quantity>0),{},{timeout:60000}); }
  catch(error){console.error(await page.evaluate(()=>({gather:window.__cwDebug.gathering(),bag:window.__cwDebug.inventory.all,stops:window.__afkStops,store:localStorage.getItem('cw_offline_db_v1'),hidden:document.hidden})));throw error;}
  const saved=await page.evaluate(async()=>{const r=(await import('/src/app/GameRuntime.ts')).getRuntime();return {running:r.view.gathering.afk,status:r.view.gathering.status,bag:window.__cwDebug.inventory.all.map(s=>({item:s.item_id,qty:s.quantity})),skills:window.__cwDebug.gathering().skills,elapsed:Date.now()-window.__afkHiddenAt};});
  assert.ok(saved.running);assert.ok(saved.skills.some(s=>s.profession_id==='woodcutting'&&(s.skill_xp>0||s.skill_level>1)));
  const noRender=await page.evaluate(async()=>{const r=(await import('/src/app/GameRuntime.ts')).getRuntime();const before=r.renderer.info.render.frame;await new Promise(resolve=>setTimeout(resolve,2200));return r.renderer.info.render.frame===before;});assert.ok(noRender);
  await page.evaluate(()=>Object.defineProperty(document,'hidden',{configurable:true,get:()=>false}));
  await page.getByRole('button',{name:'Pause AFK',exact:true}).click();
  assert.equal(await page.evaluate(async()=>(await import('/src/app/GameRuntime.ts')).getRuntime().view.gathering.afk),false);
  await page.getByRole('button',{name:'Start AFK Woodcutting',exact:true}).click();
  await page.waitForFunction(()=>window.__cwDebug.gathering().afk);
  await page.evaluate(()=>{const d=window.__cwDebug;const template=d.inventory.all[0];d.inventory.replace(Array.from({length:24},(_,i)=>({...template,id:i+1,slot_index:i,item_id:'staff_oak',quantity:1,equipped:0})));d.advance(.3,false);});
  await page.waitForFunction(()=>!window.__cwDebug.gathering().afk);
  const full=await page.evaluate(async()=>(await import('/src/app/GameRuntime.ts')).getRuntime().view.gathering.status);assert.ok(/Bag full/.test(full),JSON.stringify({full,stops:await page.evaluate(()=>window.__afkStops)}));
  await page.screenshot({path:path.join(artifactDir,'afk-skills.png')});
  assert.equal(errors.length,0);console.log(JSON.stringify({afkControls:true,worksWithAutoDisabled:true,skillsPanelKeepsWorking:true,hiddenTabEarnsSavedItemsAndXp:saved,noHiddenRendering:noRender,pauseResume:true,bagFullStops:true,browserErrors:errors}));
 }finally{await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
