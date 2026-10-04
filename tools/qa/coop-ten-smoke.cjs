const path=require('node:path');
const artifactDir=process.env.DM_QA_ARTIFACT_DIR || require('node:os').tmpdir();
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {io}=require('socket.io-client');
const {chromium}=require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function main(){
 const browser=await chromium.launch({headless:true,executablePath:process.env.DM_CHROMIUM_PATH || undefined,args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const peers=[];
 try{
  const page=await browser.newPage({viewport:{width:1280,height:800}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>localStorage.setItem('dm_settings_v1',JSON.stringify({quality:'low',tips:false,autoCombat:false})));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5201/?offline&coop');await page.getByRole('button',{name:'New to the Covenant? Create an account'}).click();
  await page.fill('#cw-user','coop_host');await page.fill('#cw-email','test@example.invalid');await page.fill('#cw-pass','TestingControls');await page.locator('#cw-login-btn').click();await page.locator('.cw-disc').first().click();
  await page.waitForFunction(()=>window.__cwDebug?.avatar.c.loaded&&window.__cwDebug.net().connected);
  // Parties are explicit now: the host makes one and the nine socket peers join its code.
  await page.evaluate(()=>window.__cwDebug.party.create());
  await page.waitForFunction(()=>window.__cwDebug.party.code()&&window.__cwDebug.net().connected);
  const instance=await page.evaluate(()=>window.__cwDebug.net().instance);
  await page.evaluate(()=>{const d=window.__cwDebug;d.god(true);d.goto('graves');d.clear();d.sim().waveTimers.set('graves',Infinity);d.ring('robber',40,6);d.freeze();for(const e of d.sim().enemies.values())e.hp=e.maxHp=1e8;d.advance(.5,false);});
  await wait(1500);
  const solo=await page.evaluate(()=>{const d=window.__cwDebug;d.perf(120);return d.perf(240);});
  const join=async i=>{
   const socket=io(process.env.DM_QA_REALTIME || 'http://127.0.0.1:5291',{auth:{token:'offline:peer'+i},transports:['websocket'],reconnection:false});peers.push(socket);
   await new Promise((resolve,reject)=>{socket.once('connect',resolve);socket.once('connect_error',reject);setTimeout(()=>reject(new Error('Connect timed out')),10000);});
   return await new Promise(resolve=>socket.emit('world:join',{instance,characterId:i+100,classIndex:i%4+1,x:(i%3)*2-2,z:-12},resolve));
  };
  const results=[];for(let i=1;i<=9;i++){const result=await join(i);assert.equal(result.success,true);results.push(result);}
  const over=await join(10);assert.equal(over.success,false);assert.match(over.error,/10 players/);peers[9].disconnect();
  await page.waitForFunction(()=>window.__cwDebug.counts().remotes===9);
  await page.waitForFunction(()=>document.querySelectorAll('[data-party] .hud-member').length===10);
  assert.equal(await page.locator('[data-party] .hud-member').count(),10);
  peers[0].emit('chat:send','Ten-player co-op check');await page.getByText('Ten-player co-op check',{exact:false}).waitFor();
  const node=await page.evaluate(()=>{const d=window.__cwDebug;const n=d.nodes('acre').find(n=>n.type==='coffin_oak');d.sim().nodes.get(n.id).remaining=1;return n;});
  peers[0].emit('player:move',{x:node.x+1,z:node.z,facing:0,moving:false,hpFrac:1});await wait(250);
  await page.evaluate(()=>window.__cwDebug.advance(.2,false));peers[0].emit('world:intent',{t:'gather',nodeId:node.id,successes:1});
  await page.waitForFunction(id=>window.__cwDebug.sim().nodes.get(id).remaining===0,node.id);
  peers[0].emit('player:move',{x:2,z:-12,facing:0,moving:false,hpFrac:1});await wait(250);
  await page.evaluate(()=>window.__cwDebug.advance(.2,false));
  const enemy=await page.evaluate(()=>{const e=[...window.__cwDebug.sim().enemies.values()][0];return{id:e.id,hp:e.hp};});
  peers[0].emit('world:intent',{t:'hit',ids:[enemy.id],dmg:5});await page.waitForFunction(({id,hp})=>window.__cwDebug.sim().enemies.get(id).hp<hp,enemy);
  await wait(1500);const ten=await page.evaluate(()=>{const d=window.__cwDebug;d.perf(120);return[d.perf(240),d.perf(240),d.perf(240)];});
  assert.ok(ten.every(p=>p.updateMs<16.7));
  const bound=await page.locator('[data-party]').boundingBox();assert.ok(bound.height<=581,'Ten player list stays clear of the bottom HUD');
  await page.screenshot({path:path.join(artifactDir,'ten-player-world.png')});
  const migrated=new Promise(resolve=>peers[0].once('room:host',resolve));await page.close();const migration=await Promise.race([migrated,wait(10000).then(()=>null)]);assert.equal(migration?.hostId,peers[0].id);assert.ok(migration.snapshot);
  assert.equal(errors.length,0);
  const evidence={tenPlayersInOneWorld:true,eleventhRejected:true,tenVisiblePartyMembers:true,chatDelivered:true,sharedNodeDepletion:true,guestCombatIntent:true,hostMigration:true,solo,ten,browserErrors:errors};
  fs.writeFileSync(path.join(artifactDir,'ten-player-performance.json'),JSON.stringify(evidence,null,2));console.log(JSON.stringify(evidence));
 }finally{for(const peer of peers)peer.disconnect();await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
