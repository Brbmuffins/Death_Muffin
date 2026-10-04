/**
 * Ground-effect clarity: a busy Graves fight (our own rotation, optionally two partners casting the same rotation as remote
 * players) measured and photographed at three moments: the cast, the circles settled (2.8 s on), and a hostile slam telegraph
 * landing in the middle of them. Run once per build to get a before / after pair.
 *
 *   npx vite --host 127.0.0.1 --port 5361 --strictPort
 *   flock <slot lock> nice -n 19 env DM_QA_URL='http://127.0.0.1:5361/?offline' DM_QA_TAG=after DM_QA_OUT=/tmp/fxc node tools/qa/fx-clarity.cjs
 *
 * Prints one JSON line per scenario x moment: draw calls the effect layer adds, overdraw layers (src/graphics/fxProbe.ts),
 * screen cover, deepest stack, live decal instances and how many of those are faint / outline-only. Writes <out>/<tag>-<scenario>-<moment>.png
 * (3-D canvas only). Env: DM_QA_SCENARIOS=solo,coop  DM_QA_ZOOM (default 0.6)  DM_QA_QUALITY (default high)
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5361/?offline';
const OUT = process.env.DM_QA_OUT || os.tmpdir();
const TAG = process.env.DM_QA_TAG || 'run';
const SCENARIOS = (process.env.DM_QA_SCENARIOS || 'solo,coop').split(',');
const ZOOM = Number(process.env.DM_QA_ZOOM || 0.6);
fs.mkdirSync(OUT, { recursive: true });
const ROTATION = ['miasma', 'dirge', 'plague_bloom', 'bone_mantle', 'bone_prison', 'black_litany', 'corpse_explosion'];

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  page.setDefaultTimeout(240000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript((q) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, tips: false, autoCombat: false })), process.env.DM_QA_QUALITY || 'high');
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `fxc_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('fxc@example.invalid');
  await page.fill('#cw-pass', 'TestingClarity1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(async () => {
    const d = window.__cwDebug;
    (await import('/src/gameplay/devAccess.ts')).devAccess.active = true;
    const rt = (await import('/src/app/GameRuntime.ts')).getRuntime();
    const P = await import('/src/graphics/fxProbe.ts');
    window.__fc = { d, rt, scene: rt.view, P, ef: rt.view.effects, r: rt.renderer, cam: rt.view.rig.camera };
    rt.stop();
    d.god(true);
    d.unlockAll();
    d.goto('graves');
    d.advance(0.5);
    d.teleport(-12, -4);
    d.advance(2.5);
    rt.renderer.render(rt.view.scene, rt.view.rig.camera);
  });

  for (const scenario of SCENARIOS) {
    await page.evaluate((v) => { window.__fcDump = v; }, process.env.DM_QA_DUMP === '1');
    page.on('console', (m) => { if (m.text().startsWith('DUMP')) console.log(m.text()); });
    const moments = await page.evaluate(async ([scenario, zoom, rotation]) => {
      const { d, rt, scene, P, ef, r, cam } = window.__fc;
      let a = 0x1234abcd;
      Math.random = () => { a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
      const p = d.player;
      const sim = () => d.sim();
      for (const pid of window.__fcPeers || []) { const rr = scene.remotes.get(pid); if (rr) { rr.avatar.dispose(); rr.pet?.dispose(); scene.remotes.delete(pid); } }
      window.__fcPeers = [];
      d.freeze(false);
      const ab = scene.abilities;
      for (const tm of [...ab.timed]) tm.end?.();
      ab.timed.length = 0;
      ab.mantleFx?.kill();
      ab.mantleUntil = 0;
      for (const z of sim().zones.values()) z.until = -1;
      for (const th of [...sim().thralls.values()]) sim().killThrall(th, 'crumbled');
      d.clear();
      d.zoom(zoom);
      p.hp = p.stats.maxHp;
      p.face(p.x, p.z - 5);
      p.runes = {};
      d.forceMods(null);
      p.loadout = { main: null, mainTier: null, off: null, offTier: null, spellMult: 1, needleRangeMult: 1, needlePierce: 0, needleCadenceMult: 1, needleDamageMult: 1, needleWithered: 0, reap: false, exhumeRefund: 0, thrallBonus: 0, riteCooldownMult: 1, bellAllyHeal: 0 };
      d.advance(1.0);
      for (let i = 0; i < 40 && (ef.transientLoad > 0 || ef.additive.active + ef.smoke.active > 0); i++) d.advance(0.25, false);
      const cast = (rite, t) => { p.essence = p.resource.max; p.cooldowns.clear(); p.castUntil = 0; return ab.cast(rite, t, scene.now); };
      // Thralls and a pack of enemies around the hero: a fight, not an empty floor.
      for (let i = 0; i < 5; i++) sim().addCorpse(p.x + Math.sin(i * 1.7) * 1.4, p.z - 3 + Math.cos(i * 1.7) * 1.4, 'normal', 'robber', false, 0, 1, 'graves');
      const mine = () => [...sim().thralls.values()].filter((t) => t.owner === scene.selfId && t.state !== 'dead').length;
      for (let k = 0; k < 14 && mine() < 4; k++) {
        if (!sim().corpses.size) for (let i = 0; i < 3; i++) sim().addCorpse(p.x + Math.sin(i * 1.7) * 1.4, p.z - 3 + Math.cos(i * 1.7) * 1.4, 'normal', 'robber', false, 0, 1, 'graves');
        cast('exhume', { x: p.x, z: p.z - 3 });
        d.advance(0.3);
      }
      d.advance(1.8);
      const foes = [];
      for (let i = 0; i < 8; i++) {
        const e = sim().spawnEnemy('robber', 'graves', p.x + Math.sin(i * 2.4) * 4.5, p.z - 6 + Math.cos(i * 2.4) * 2.5, false, false);
        e.hp = e.maxHp = 1e6; e.speed = 0; e.attackCd = 99; foes.push(e);
      }
      for (let i = 0; i < 40 && (ef.transientLoad > 0 || ef.additive.active + ef.smoke.active > 0); i++) d.advance(0.25, false);
      const target = { x: foes[0].x, z: foes[0].z, enemyId: foes[0].id };
      const callsOf = () => { r.info.autoReset = false; r.info.reset(); r.render(scene.scene, cam); const n = r.info.render.calls; r.info.autoReset = true; return n; };
      const sample = (name) => {
        const c1 = callsOf();
        ef.group.visible = false;
        const c0 = callsOf();
        ef.group.visible = true;
        const f = P.fillStats(r, scene.scene, cam, ef);
        let items = 0, faint = 0, outlined = 0, decalCalls = 0;
        for (const l of ef.decalLayers.values()) { if (l.mesh.visible && l.mesh.count > 0) decalCalls++; } for (const l of ef.decalLayers.values()) for (const it of l.items) { if (it.opacity <= 0.01) continue; items++; if (it.opacity < 0.2) faint++; if ((it.rim ?? 0) > 0.5) outlined++; }
        // Fill of the ground decals alone (particles, Binbun and billboards hidden): the sim's randomness cannot move this much.
        const hide = [];
        const decalMeshes = new Set([...ef.decalLayers.values()].map((l) => l.mesh));
        ef.group.traverse((o) => { if (o !== ef.group && o.visible && (o.isMesh || o.isPoints || o.isSprite) && !decalMeshes.has(o)) { hide.push(o); o.visible = false; } });
        const fd = P.fillStats(r, scene.scene, cam, ef);
        for (const o of hide) o.visible = true;
        if (window.__fcDump) { const rows = []; for (const [k, l] of ef.decalLayers) for (const it of l.items) if (it.opacity > 0.15 && it.sx > 4) rows.push(`${k.slice(0, 5)}|${k.split('|').slice(1).join('|')} r=${(it.sx / 2).toFixed(1)} op=${it.opacity.toFixed(2)} c=${it.color.getHexString()} @${(it.x - p.x).toFixed(1)},${(it.z - p.z).toFixed(1)}`); console.log('DUMP ' + name + ' ' + JSON.stringify(rows)); }
        const png = rt.capture('image/png');
        return { name, calls: c1 - c0, layers: +f.layers.toFixed(3), decalLayersFill: +fd.layers.toFixed(3), cover: +f.covered.toFixed(3), max: f.max, decals: items, decalCalls, faint, outlined, total: c1, png };
      };
      const frames = (s) => { for (let i = 0; i < Math.round(s * 60); i++) d.advance(1 / 60, false); };
      const out = [];
      // Our own rotation, then (coop) the same events replayed as two partners standing either side.
      const peers = ['peerA', 'peerB'];
      const seen = [];
      const he = scene.handleEvent.bind(scene);
      if (scenario === 'coop') {
        peers.forEach((id2, i) => scene.addRemote({ id: id2, characterId: 900 + i, name: id2, classIndex: 2, x: p.x + (i ? 6 : -6), z: p.z - 2, facing: 0, moving: false, hpFrac: 1, gear: {} }));
        window.__fcPeers = peers;
        scene.handleEvent = (ev) => { seen.push(ev); he(ev); };
      }
      for (const rite of rotation) {
        cast(rite, ['bone_prison', 'miasma', 'plague_bloom', 'dirge'].includes(rite) ? { x: p.x, z: p.z - 5 } : target);
        d.advance(0.25, false);
      }
      scene.handleEvent = he;
      if (scenario === 'coop') {
        let k = 0;
        for (const peer of peers) {
          const dx = k ? 7 : -7;
          for (const ev of seen) {
            const c = JSON.parse(JSON.stringify(ev));
            const swap = (o, depth = 0) => {
              if (!o || typeof o !== 'object' || depth > 3) return;
              for (const f of ['by', 'owner', 'caster']) if (o[f] === scene.selfId) o[f] = peer;
              if (typeof o.x === 'number') o.x += dx;
              if (typeof o.tx === 'number') o.tx += dx;
              for (const v of Object.values(o)) swap(v, depth + 1);
            };
            if (c.by !== undefined || c.zone?.owner !== undefined) { swap(c); he(c); }
          }
          k++;
        }
      }
      frames(0.3);
      out.push(sample('cast'));
      frames(2.6);
      out.push(sample('settled'));
      // A hostile slam telegraph lands on the hero: it must read on top of every friendly circle.
      he({ t: 'telegraph', kind: 'slam', id: -1, x: p.x + 3, z: p.z - 3, tx: p.x, tz: p.z, ms: 3000, r: 3.2 });
      he({ t: 'telegraph', kind: 'cone', id: -1, x: p.x - 4, z: p.z + 1, tx: p.x + 2, tz: p.z - 1, ms: 3000 });
      frames(1.2);
      out.push(sample('telegraph'));
      return out;
    }, [scenario, ZOOM, ROTATION]);
    for (const m of moments) {
      fs.writeFileSync(path.join(OUT, `${TAG}-${scenario}-${m.name}.png`), Buffer.from(m.png.split(',')[1], 'base64'));
      const { png, ...rest } = m;
      console.log(JSON.stringify({ tag: TAG, scenario, ...rest }));
    }
  }
  if (errors.length) console.log('PAGE ERRORS', errors.slice(0, 5));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
