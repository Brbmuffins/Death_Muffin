const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const artifactDir=process.env.DM_QA_ARTIFACT_DIR || require('node:os').tmpdir();
const {chromium}=require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
if(!process.env.DM_QA_OWNER_USER || !process.env.DM_QA_OWNER_PASSWORD) throw new Error('Set DM_QA_OWNER_USER and DM_QA_OWNER_PASSWORD for existing-account verification.');
async function domainCheck() {
 const site='https://muffindevelopment.com/death-muffin/';
 const username='dm_domain_probe_'+Date.now();
 const backend=process.env.DM_QA_BACKEND || '/home/ubuntu/death-muffin/backend';
 const env=require(backend+'/node_modules/dotenv').parse(fs.readFileSync(backend+'/.env'));
 const mysql=require(backend+'/node_modules/mysql2/promise');
 const db=await mysql.createConnection({host:env.DB_HOST,user:env.DB_USER,password:env.DB_PASS,database:env.DB_NAME});
 const browser=await chromium.launch({headless:true,executablePath:process.env.DM_CHROMIUM_PATH || undefined,args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const errors=[],failed=[];
 try {
  const context=await browser.newContext({viewport:{width:1280,height:800}});
  const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
  // Verify the supplied owner's login without launching or saving their character.
  await page.route(site+'play/**',route=>route.fulfill({status:200,contentType:'text/html',body:'<html><body>Login destination verified</body></html>'}));
  await page.goto(site,{waitUntil:'networkidle'});
  await page.fill('#email',process.env.DM_QA_OWNER_USER);await page.fill('#password',process.env.DM_QA_OWNER_PASSWORD);await page.click('.enter-button');
  await page.waitForURL(site+'play/');
  const ownerToken=await page.evaluate(()=>sessionStorage.getItem('dm_jwt'));assert.ok(ownerToken);
  const owner=await context.request.get(site+'api/character',{headers:{Authorization:'Bearer '+ownerToken}});
  assert.equal(owner.status(),200,'Existing owner character remains available');
  await context.close();
  const qa=await browser.newContext({viewport:{width:1280,height:800}});
  await qa.addInitScript(()=>localStorage.setItem('dm_settings_v1',JSON.stringify({quality:'low',tips:false})));
  const game=await qa.newPage();game.on('pageerror',e=>errors.push(e.message));
  game.on('response',r=>{if(r.url().startsWith(site)&&r.status()>=400)failed.push({status:r.status(),url:r.url()});});
  let joinResolve;const joined=new Promise(resolve=>joinResolve=resolve);
  game.on('response',async r=>{if(r.url().includes('/rt/socket.io/')&&r.request().method()==='GET'){try{if((await r.text()).includes('"success":true'))joinResolve(true);}catch{}}});
  const wsUrls=[];game.on('websocket',ws=>{wsUrls.push(ws.url());ws.on('framereceived',frame=>{if(String(frame.payload).includes('"success":true'))joinResolve(true);});});
  const registered=await qa.request.post(site+'api/register',{data:{username,email:username+'@example.invalid',password:'DomainProbe-'+Date.now()}});
  assert.equal(registered.status(),201);const {token}=await registered.json();
  await game.goto(site);await game.evaluate(token=>sessionStorage.setItem('dm_jwt',token),token);
  await game.goto(site+'play/');await game.locator('.cw-disc').first().click();
  await game.locator('.hud').waitFor({timeout:30000});
  const connected=await Promise.race([joined,new Promise(resolve=>setTimeout(()=>resolve(false),20000))]);
  assert.ok(connected,'Authenticated co-op joins the world on the new domain');
  assert.ok(wsUrls.length&&wsUrls.every(url=>url.startsWith('wss://muffindevelopment.com/death-muffin/rt/socket.io/')));
  await game.locator('[data-slot="1"]').hover();
  const spellCard=game.getByRole('tooltip',{name:'Spell details'});await spellCard.waitFor();
  assert.match(await spellCard.innerText(),/Fracture/);await game.keyboard.press('Escape');
  assert.equal(await spellCard.isVisible(),false);
  assert.match(await game.locator('[data-mapframe] canvas').getAttribute('aria-label'),/Click unlocked ground/);
  await game.getByRole('button',{name:'Auto combat',exact:true}).waitFor();
  assert.equal(await game.getByRole('button',{name:'Auto combat',exact:true}).getAttribute('aria-pressed'),'true');
  await game.keyboard.press('g');
  await game.waitForFunction(()=>document.querySelector('.hud-auto')?.getAttribute('aria-pressed')==='false');
  await game.getByRole('button',{name:'Settings',exact:true}).click();
  await game.getByRole('button',{name:'Change class',exact:true}).click();
  await game.getByRole('button',{name:'Gravecaller',exact:true}).click();
  await game.getByRole('dialog',{name:'Change class',exact:true}).waitFor({state:'hidden',timeout:30000});
  await game.locator('.hud').waitFor();
  await game.screenshot({path:path.join(artifactDir,'muffindevelopment-game.png')});
  const charResponse=await qa.request.get(site+'api/character',{headers:{Authorization:'Bearer '+token}});
  assert.equal(charResponse.status(),200);const character=await charResponse.json();assert.equal(character.class_index,2);
  const progress=await qa.request.get(site+'api/api/necro-progress/'+character.id,{headers:{Authorization:'Bearer '+token}});assert.equal(progress.status(),200);
  const health=await qa.request.get(site+'api/health');assert.equal(health.status(),200);
  const leaders=await qa.request.get(site+'api/leaderboard');assert.equal(leaders.status(),200);assert.ok(Array.isArray((await leaders.json()).players));
  await game.goto(site+'leaderboard.html',{waitUntil:'networkidle'});assert.ok(await game.locator('#leaderboard-rows').count());
  if(process.argv.includes('--gather-check')) {
   const headers={Authorization:'Bearer '+token};
   const gather=await qa.request.post(site+'api/api/gather',{headers,data:{characterId:character.id,nodeType:'coffin_oak',actions:5}});
   assert.equal(gather.status(),200,await gather.text());const reward=(await gather.json()).data;assert.equal(reward.accepted,5);
   const skills=await qa.request.get(site+'api/api/professions/'+character.id,{headers});assert.equal(skills.status(),200);
   assert.deepEqual((await skills.json()).data.find(s=>s.profession_id==='woodcutting'),reward.skills[0]);
   const bag=await qa.request.get(site+'api/api/inventory/'+character.id,{headers});assert.equal(bag.status(),200);
   for(const item of reward.items)assert.ok((await bag.json()).data.some(s=>s.item_id===item.itemId&&s.quantity>=item.qty));
   const locked=await qa.request.post(site+'api/api/gather',{headers,data:{characterId:character.id,nodeType:'bone_elder',actions:1}});assert.equal(locked.status(),400);
   const other=await qa.request.post(site+'api/api/gather',{headers,data:{characterId:character.id+1000000,nodeType:'coffin_oak',actions:1}});assert.equal(other.status(),403);
   await game.goto(site+'play/');await game.locator('.hud').waitFor({timeout:30000});
   await game.keyboard.press('p');await game.getByRole('dialog').waitFor();
   assert.match(await game.getByRole('dialog').innerText(),/Woodcutting/);
   await game.screenshot({path:path.join(artifactDir,'live-professions.png')});
   console.log(JSON.stringify({liveGathering:true,accepted:reward.accepted,successes:reward.successes,skillPersistence:true,inventoryPersistence:true,levelGate:true,ownershipCheck:true,skillsPanel:true}));
   if(process.argv.includes('--afk-check')){
    const quantity=rows=>rows.filter(s=>s.item_id==='log_oak').reduce((n,s)=>n+s.quantity,0);
    const before=quantity((await bag.json()).data);
    await game.getByRole('button',{name:'Start AFK Woodcutting',exact:true}).click();
    await game.waitForFunction(()=>document.querySelector('[data-afk-status]')?.textContent.startsWith('AFK ·'));
    await game.getByRole('button',{name:'Close skills',exact:true}).click();
    await game.evaluate(()=>Object.defineProperty(document,'hidden',{configurable:true,get:()=>true}));
    let earned=0;const deadline=Date.now()+60000;
    while(Date.now()<deadline){
     await new Promise(resolve=>setTimeout(resolve,1500));
     const saved=await qa.request.get(site+'api/api/inventory/'+character.id,{headers});assert.equal(saved.status(),200);
     earned=quantity((await saved.json()).data)-before;if(earned>0)break;
    }
    assert.ok(earned>0,'AFK saves materials while the game is in a background tab');console.log(JSON.stringify({liveAfkBackgroundSaved:true,earned}));
    await game.evaluate(()=>Object.defineProperty(document,'hidden',{configurable:true,get:()=>false}));
    await game.keyboard.press('p');await game.getByRole('button',{name:'Pause AFK',exact:true}).click();
    await game.waitForFunction(()=>document.querySelector('[data-afk-status]')?.textContent==='AFK paused');
    await game.getByRole('button',{name:'Start AFK Woodcutting',exact:true}).click();
    await game.waitForFunction(()=>document.querySelector('[data-afk-status]')?.textContent.startsWith('AFK ·'));
    await game.reload();await game.locator('.hud').waitFor({timeout:30000});await game.keyboard.press('p');
    assert.equal(await game.locator('[data-afk-status]').innerText(),'Paused','Reload ends AFK; it never resumes offline work');
    await game.screenshot({path:path.join(artifactDir,'live-afk.png')});
    console.log(JSON.stringify({liveAfkControls:true,backgroundAfkSavedLogs:earned,pauseWorks:true,reloadEndsSession:true}));
   }
  }
  for(const url of ['https://playcrossworlds.com/death-muffin/play/?test=1','http://playcrossworlds.com/death-muffin/']) {
   const response=await qa.request.get(url,{maxRedirects:0});assert.equal(response.status(),308);
   assert.equal(response.headers().location,url.replace(/^https?:\/\/playcrossworlds.com/,'https://muffindevelopment.com'));
  }
  for(const url of ['https://muffindevelopment.com/','https://playcrossworlds.com/','https://playcrossworlds.com/play/'])assert.equal((await qa.request.get(url)).status(),200);
  const http=await qa.request.get('http://muffindevelopment.com/death-muffin/',{maxRedirects:0});assert.equal(http.status(),301);assert.equal(http.headers().location,site);
  assert.equal(errors.length,0);assert.equal(failed.filter(r=>r.status!==404||!r.url.endsWith('/api/character')).length,0);
  console.log(JSON.stringify({ownerLogin:true,existingCharacterAvailable:true,newAccountRegistration:true,gameRendered:true,authenticatedCoopOnNewDomain:true,progressAvailable:true,liveClassSwitch:true,richSpellHover:true,minimapNavigationAvailable:true,autoCombatToggle:true,leaderboard:true,oldLinksRedirect:true,otherSitesAvailable:true,browserErrors:errors}));
 } finally {
  await browser.close();
  assert.match(username,/^dm_domain_probe_\d+$/);
  const [[account]]=await db.execute('SELECT id FROM accounts WHERE username=?',[username]);
  if(account){
   await db.beginTransaction();
   const [characters]=await db.execute('SELECT id FROM characters WHERE account_id=?',[account.id]);
   for(const character of characters){
    for(const table of ['character_combat_stats','character_gear','character_quest_objectives','character_quests','character_talents','combat_sessions','gold_transactions','hero_mastery','inventory','item_instance','professions','character_necro_progress',...(process.argv.includes('--gather-check')?['gather_ledger']:[])])await db.query('DELETE FROM ?? WHERE character_id=?',[table,character.id]);
    await db.execute('DELETE FROM characters WHERE id=? AND account_id=?',[character.id,account.id]);
   }
   await db.execute('DELETE FROM accounts WHERE id=? AND username=?',[account.id,username]);await db.commit();
  }
  await db.end();console.log('Temporary domain test account removed.');
 }
}
domainCheck().catch(e=>{console.error(e.message);process.exitCode=1;});
