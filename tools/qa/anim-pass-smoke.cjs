/**
 * Animation pass smoke (X2/P5). Offline, one Gravecaller in the Hollow Graves:
 *  - every biped and quadruped enemy faces its heading and its planted feet slide < 45% of ground speed (walk-only models
 *    that need more than the playback cap are reported, not failed);
 *  - the hero's run clip matches its movement; heading changes are rate limited;
 *  - a hit flinch is additive (the swing / stride keeps running);
 *  - crowd separation reduces drawn overlaps in a ring of enemies;
 *  - equipped weapon kinds load and screenshot idle + mid-cast;
 *  - perf: __cwDebug.counts() and frame time in a busy fight.
 *   npm run dev -- --host 127.0.0.1 --port 5336 --strictPort
 *   DM_QA_URL='http://127.0.0.1:5336/?offline' DM_PLAYWRIGHT_MODULE=... node tools/qa/anim-pass-smoke.cjs
 * Screenshots/JSON go to DM_QA_ARTIFACT_DIR (default docs/screenshots/anim-pass). DM_QA_NO_SHOTS=1 skips screenshots.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5336/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(__dirname, '../../docs/screenshots/anim-pass');
const SHOTS = !process.env.DM_QA_NO_SHOTS;

// Enemies whose rigs have a Blender recipe: the mesh-contact slip counts only vertices skinned to the recipe's named
// legs (a dragging tail or a swaying head is not a foot), with the floor taken from the planted feet, not one stray toe.
const QUAD_SLUG = { rat: 'skull_rat', cinderhound: 'cinderhound', hound: 'bone_hound' };
function legBones(def) {
  const slug = QUAD_SLUG[def];
  const f = path.join(process.env.DM_QA_RECIPE_DIR || path.join(__dirname, '../blender/recipes'), `${slug}.json`); // DM_QA_RECIPE_DIR: measure an old rig with its old leg bones
  if (!slug || !fs.existsSync(f)) return null;
  const legs = {};
  for (const [k, leg] of Object.entries(JSON.parse(fs.readFileSync(f, 'utf8')).legs)) legs[k] = [...leg.chain, leg.paw].map((n) => n.replace(/\s/g, '_').replace(/[\[\]./:]/g, '')); // three's loader strips these from node names
  return legs;
}
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);

async function openHero(browser, errors) {
  const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('crash', () => log('PAGE CRASH'));
  page.on('framenavigated', (f) => log('nav', f.url()));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `anim_${Date.now() % 1e6}`);
  await page.fill('#cw-email', 'anim@example.invalid');
  await page.fill('#cw-pass', 'TestingAnim1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.goto('graves'); d.unlockAll?.(); d.god(true); d.clear(); d.zoom(0.4); d.advance(0.5); });
  return page;
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const errors = (global.__errors = []);
  let page = await openHero(browser, errors);
  const report = {};

  // --- impact feel: hitstop, visual knockback, death settle (all drawn-only; the sim is never touched) ---
  report.impact = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const { hitstop, FRAME } = await import('/src/graphics/hitstop.ts');
    const { settings } = await import('/src/app/settings.ts');
    const dbg = window.__cwDebug;
    const scene = getRuntime().view;
    const spawn = async (def, dist) => {
      dbg.clear(); scene.player.x = 0; scene.player.z = 0;
      const id = dbg.ring(def, 1, dist)[0];
      const e = dbg.sim().enemies.get(id);
      e.hp = e.maxHp = 100;
      let view;
      for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = scene.views.enemies.get(id); }
      dbg.advance(1.4, false);
      return { id, e, view };
    };
    const out = {};
    settings.reducedMotion = false;

    // Hitstop: a heavy hit freezes the mixer for 2-4 frames; the sim clock keeps running; it is rationed.
    {
      hitstop.reset();
      const { id, e, view } = await spawn('flagellant', 6);
      dbg.freeze(true);
      const sim = dbg.sim();
      dbg.advance(0.3, false);
      sim.damageEnemy(e, 40, 'qa');
      const t0 = sim.time, a0 = view.c.current.time;
      let frozen = 0, steps = 0, c0 = hitstop.count;
      for (let i = 0; i < 12; i++) { const before = view.c.current.time; dbg.advance(1 / 60, false); if (hitstop.scale === 0) frozen++; steps++; void before; }
      out.hitstop = { frozenFrames: frozen, count: hitstop.count - c0, simAdvanced: +(sim.time - t0).toFixed(3), granted: +hitstop.total.toFixed(3) };
      // Light hits never freeze.
      hitstop.reset(); c0 = hitstop.count;
      e.hp = e.maxHp = 100; sim.damageEnemy(e, 3, 'qa'); dbg.advance(0.2, false);
      out.hitstop.lightCount = hitstop.count - c0;
      // A flood of heavy hits is rationed: simulated 10 s of constant heavy hits freezes < 16% of the time.
      hitstop.reset();
      let fr = 0;
      for (let i = 0; i < 600; i++) { hitstop.request(1); hitstop.frame(FRAME); if (hitstop.scale === 0) fr++; }
      out.hitstop.share = +(fr / 600).toFixed(3);
      // Reduced motion switches it off.
      hitstop.reset(); settings.reducedMotion = true; c0 = hitstop.count;
      e.hp = 100; sim.damageEnemy(e, 40, 'qa'); dbg.advance(0.1, false);
      out.hitstop.reducedMotionCount = hitstop.count - c0;
      settings.reducedMotion = false; hitstop.reset();
      dbg.freeze(false);
    }

    // Knockback: the drawn root is shoved away from the hero and relaxes back to the sim position.
    {
      const { id, e, view } = await spawn('risen', 5);
      dbg.freeze(true);
      const sim = dbg.sim();
      dbg.advance(0.2, false);
      const dist = () => Math.hypot(view.c.root.position.x - e.x, view.c.root.position.z - e.z);
      const away = () => (view.c.root.position.x - e.x) * e.x + (view.c.root.position.z - e.z) * e.z;
      const sx = e.x, sz = e.z;
      sim.damageEnemy(e, 40, 'qa');
      let peak = 0, dir = 0;
      for (let i = 0; i < 20; i++) { dbg.advance(1 / 60, false); if (dist() > peak) { peak = dist(); dir = away(); } }
      dbg.advance(1.0, false);
      out.knockback = { peak: +peak.toFixed(2), awayFromHero: dir > 0, settledOffset: +dist().toFixed(3), simMoved: Math.hypot(e.x - sx, e.z - sz) };
      dbg.freeze(false);
    }

    // Death settle: the corpse lands (y eases down a little), its true position never moves.
    {
      const { id, e, view } = await spawn('robber', 5);
      const sim = dbg.sim();
      dbg.freeze(true);
      sim.damageEnemy(e, 1e6, 'qa');
      const ys = [];
      let corpse = null;
      for (let i = 0; i < 420; i++) {
        dbg.advance(1 / 60, false);
        ys.push(+view.c.root.position.y.toFixed(3)); (window.__dp ??= []).push([+view.c.hasLanded(), view.settleT]);
        if (!corpse) corpse = [...sim.corpses.values()][0] ?? null;
      }
      const cv = corpse && scene.views.corpses?.get?.(corpse.id);
      const vv = cv ?? view;
      out.settle = {
        sink: +(Math.max(...ys.slice(0, 10)) - ys[ys.length - 1]).toFixed(3), minY: Math.min(...ys),
        monotonicAfterLanding: ys.slice(-60).every((y, i, a) => i === 0 || y <= a[i - 1] + 1e-6),
        corpseDrawnDelta: corpse ? +Math.hypot(view.c.root.position.x - corpse.x, view.c.root.position.z - corpse.z).toFixed(3) : null,
        hasCorpse: !!corpse,
        finalY: ys[ys.length - 1], landedAt: window.__dp.findIndex((d) => d[0]) / 60,
      };
      void vv;
      dbg.freeze(false);
    }
    return out;
  });
  log('impact', JSON.stringify(report.impact));
  const I = report.impact;
  assert.ok(I.hitstop.frozenFrames >= 2 && I.hitstop.frozenFrames <= 4, `hitstop frames ${I.hitstop.frozenFrames}`);
  assert.equal(I.hitstop.count, 1, 'one freeze per heavy hit');
  assert.ok(I.hitstop.simAdvanced > 0.15, 'sim clock kept running through the freeze');
  assert.equal(I.hitstop.lightCount, 0, 'light hit does not freeze');
  assert.ok(I.hitstop.share < 0.16, `hitstop share ${I.hitstop.share}`);
  assert.equal(I.hitstop.reducedMotionCount, 0, 'no hitstop under reduced motion');
  assert.ok(I.knockback.peak > 0.05 && I.knockback.peak <= 0.6 + 1e-6 && I.knockback.awayFromHero, 'knockback shoves away');
  assert.ok(I.knockback.settledOffset < 0.01 && I.knockback.simMoved === 0, 'knockback relaxes; sim untouched');
  assert.ok(I.settle.hasCorpse && I.settle.sink > 0.02 && I.settle.corpseDrawnDelta < 0.05, 'corpse settles in place');
  if (process.env.DM_QA_IMPACT_ONLY) { await browser.close(); return; }

  // --- enemies: heading and foot slip ---
  const defs = await page.evaluate(async () => {
    const { ENEMIES } = await import('/src/content/enemies.ts');
    const skip = new Set(['niche', 'fen_wisp', 'mire_leech', 'moth', 'bat', 'wraith', 'gargoyle', 'seraph']);
    return Object.keys(ENEMIES).filter((d) => !skip.has(d));
  });
  const only = (process.env.DM_QA_ONLY || '').split(',').filter(Boolean);
  if (only.length) defs.splice(0, defs.length, ...defs.filter((d) => only.includes(d)));
  report.enemies = {};
  for (const def of defs) {
    report.enemies[def] = await page.evaluate(async ([def, legNames]) => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const scene = getRuntime().view;
    const V3 = scene.rig.camera.position.constructor;
    const med = (a) => { a = a.slice().sort((x, y) => x - y); return a[Math.floor(a.length / 2)]; };
    {
      dbg.clear();
      scene.player.x = 0; scene.player.z = 0;
      const id = dbg.ring(def, 1, 12)[0];
      const sim = dbg.sim();
      const e = sim.enemies.get(id);
      if (!e) return 'nospawn';
      e.hp = e.maxHp = 1e9;
      let view;
      for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = scene.views.enemies.get(id); }
      if (!view || !view.c.loaded) { return 'noview'; }
      dbg.advance(1.3, false);
      const feet = [];
      const leaves = [];
      view.c.model.traverse((o) => {
        if (o.name === 'L_Foot' || o.name === 'R_Foot') feet.push(o);
        if (!o.children.length && /Limb|bone_/.test(o.name) && !/Head|Tail/.test(o.name)) leaves.push(o);
      });
      const quad = feet.length !== 2;
      const use = quad ? leaves.map((o) => [o, o.getWorldPosition(new V3()).y]).sort((a, b) => a[1] - b[1]).slice(0, 4).map((a) => a[0]) : feet;
      // Mesh-contact slip: the skinned vertices touching the ground in two successive frames should not move in the world.
      const skinned = [];
      view.c.model.traverse((o) => { if (o.isSkinnedMesh) skinned.push(o); });
      const verts = () => {
        view.c.model.updateMatrixWorld(true);
        // Defensive: advance(.., false) may not render, and getVertexPosition reads skeleton.boneMatrices, which only skeleton.update() refreshes.
        for (const m of skinned) m.skeleton.update();
        const out = [];
        const t = new V3();
        for (const m of skinned) {
          const n = m.geometry.attributes.position.count;
          const a = new Float32Array(n * 3);
          for (let i = 0; i < n; i++) { m.getVertexPosition(i, t); t.applyMatrix4(m.matrixWorld); a[i * 3] = t.x; a[i * 3 + 1] = t.y; a[i * 3 + 2] = t.z; }
          out.push(a);
        }
        return out;
      };
      // Limb mask (dominant joint in the leg set) per skinned mesh vertex, when this rig has a recipe.
      // legMask[m][i] = leg number + 1 of the leg whose bones dominate vertex i (0 = not a leg).
      const legKeys = legNames ? Object.keys(legNames) : [];
      const masks = legNames ? skinned.map((m) => {
        const si = m.geometry.attributes.skinIndex, sw = m.geometry.attributes.skinWeight;
        const mk = new Uint8Array(si.count);
        for (let i = 0; i < si.count; i++) {
          let bk = 0;
          for (let k = 1; k < 4; k++) if (sw.getComponent(i, k) > sw.getComponent(i, bk)) bk = k;
          const nm = m.skeleton.bones[si.getComponent(i, bk)].name;
          mk[i] = legKeys.findIndex((lk) => legNames[lk].includes(nm)) + 1;
        }
        return mk;
      }) : null;
      const meshFrames = [];
      const samples = [];
      let prev = null;
      for (let i = 0; i < 150; i++) {
        dbg.advance(1 / 60, false);
        const ee = sim.enemies.get(id);
        if (!ee) break;
        if (!ee.moving) { prev = null; if (Math.hypot(ee.x, ee.z) < 3.5) break; continue; }
        const fp = use.map((f) => f.getWorldPosition(new V3()));
        const rp = view.c.root.position.clone();
        if (prev) meshFrames.push({ v: verts(), os: !!view.c.oneShot, rootV: Math.hypot(rp.x - prev.rp.x, rp.z - prev.rp.z) * 60 });
        if (prev) samples.push({ rootV: Math.hypot(rp.x - prev.rp.x, rp.z - prev.rp.z) * 60, feet: fp.map((p, k) => ({ y: p.y, v: Math.hypot(p.x - prev.fp[k].x, p.z - prev.fp[k].z) * 60 })), plan: view.c.lastPlan, os: !!view.c.oneShot });
        prev = { fp, rp };
      }
      if (samples.length < 20) { return 'few'; }
      const ground = med(samples.map((s) => s.rootV));
      // Planted-foot speed over a set of samples (the lowest 22% of each foot's height range counts as planted).
      const slipOf = (set) => {
        const slips = [];
        for (let k = 0; k < use.length; k++) {
          const ys = samples.map((s) => s.feet[k].y);
          const lo = Math.min(...ys), hi = Math.max(...ys);
          const st = set.filter((s) => s.feet[k].y <= lo + 0.22 * (hi - lo)).map((s) => s.feet[k].v);
          if (st.length) slips.push(med(st));
        }
        return slips.length ? med(slips) / ground : NaN;
      };
      const loco = samples.filter((s) => !s.os);
      const plan = samples[10].plan;
      const meshSlip = (loco_only) => {
        let ymin0 = Infinity, ymax0 = -Infinity;
        for (const a of meshFrames[0].v) for (let i = 1; i < a.length; i += 3) { ymin0 = Math.min(ymin0, a[i]); ymax0 = Math.max(ymax0, a[i]); }
        const band = (masks ? 0.02 : 0.04) * (ymax0 - ymin0);
        const lowest = (fr) => {
          let lo = Infinity;
          for (let m = 0; m < skinned.length; m++) { const a = fr.v[m]; for (let i = 0; i < a.length / 3; i++) if (!masks || masks[m][i]) lo = Math.min(lo, a[i * 3 + 1]); }
          return lo;
        };
        const los = meshFrames.map(lowest);
        const floor = masks ? [...los].sort((x, y) => x - y)[Math.floor(0.2 * (los.length - 1))] : null;
        const speeds = [];
        for (let f = 1; f < meshFrames.length; f++) {
          if (loco_only && (meshFrames[f].os || meshFrames[f - 1].os)) continue;
          const lo = floor ?? los[f], lo0 = floor ?? los[f - 1];
          for (let m = 0; m < skinned.length; m++) {
            const a = meshFrames[f].v[m], b = meshFrames[f - 1].v[m];
            for (let i = 0; i < a.length; i += 3) {
              if (masks && !masks[m][i / 3]) continue;
              if (a[i + 1] > lo + band || b[i + 1] > lo0 + band) continue;
              speeds.push(Math.hypot(a[i] - b[i], a[i + 2] - b[i + 2]) * 60);
            }
          }
        }
        if (loco_only === 'quartiles') { const t = speeds.slice().sort((x, y) => x - y); return [0.1, 0.25, 0.5, 0.75, 0.9].map((q) => +(t[Math.floor(q * (t.length - 1))] / ground).toFixed(2)); }
        return speeds.length > 20 ? med(speeds) / ground : NaN;
      };
      // slipFeet: per leg, the lowest vertex of that leg while it touches the floor (within 2% of the body's height) in two successive
      // frames, its horizontal speed over the ground speed. Counts one sample per planted leg per frame, so swing frames near the floor
      // and the spread of toes do not dilute it. 0 = planted, 1 = riding the body.
      const feetSlip = () => {
        if (!masks) return null;
        let ymin0 = Infinity, ymax0 = -Infinity;
        for (const a of meshFrames[0].v) for (let i = 1; i < a.length; i += 3) { ymin0 = Math.min(ymin0, a[i]); ymax0 = Math.max(ymax0, a[i]); }
        const band = 0.02 * (ymax0 - ymin0);
        const lowOf = (fr, leg) => { let best = null; for (let m = 0; m < skinned.length; m++) { const a = fr.v[m]; for (let i = 0; i < a.length / 3; i++) if (masks[m][i] === leg + 1 && (!best || a[i * 3 + 1] < best.y)) best = { m, i, y: a[i * 3 + 1] }; } return best; };
        const lows = meshFrames.map((fr) => legKeys.map((_, l) => lowOf(fr, l)));
        const have = lows.flat().filter(Boolean); // a leg with no skinned vertices (the old cinderhound has no foreleg bones) is skipped
        if (!have.length) return null;
        const floor = have.map((b) => b.y).sort((x, y) => x - y)[Math.floor(0.1 * (have.length - 1))];
        const sp = [];
        for (let f = 1; f < meshFrames.length; f++) legKeys.forEach((_, l) => {
          const b = lows[f][l];
          if (!b) return;
          const pv = meshFrames[f - 1].v[b.m];
          if (b.y > floor + band || pv[b.i * 3 + 1] > floor + band) return;
          sp.push(Math.hypot(meshFrames[f].v[b.m][b.i * 3] - pv[b.i * 3], meshFrames[f].v[b.m][b.i * 3 + 2] - pv[b.i * 3 + 2]) * 60);
        });
        return sp.length > 10 ? +(med(sp) / ground).toFixed(2) : null;
      };
      // slip = mesh-contact slip over every moving frame; slipLoco = only frames with no swing / cast one-shot covering the stride; slipBones = the older foot-bone metric (a 22% height window, which counts a robed caster's low swing as planted).
      return { ground: +ground.toFixed(2), slip: +meshSlip(false).toFixed(2), slipLoco: +meshSlip(true).toFixed(2), slipBones: +slipOf(samples).toFixed(2), slipBonesLoco: loco.length > 10 ? +slipOf(loco).toFixed(2) : null, oneShotShare: +(1 - loco.length / samples.length).toFixed(2), slipQuartiles: meshSlip('quartiles'), slipFeet: feetSlip(), clip: plan?.clip, ts: +(plan?.timeScale ?? 0).toFixed(2), capped: (plan?.residual ?? 0) > 0.15, quad };
    }
  }, [def, legBones(def)]);
  }
  if (process.env.DM_QA_ENEMIES_ONLY) {
    for (const [d, v] of Object.entries(report.enemies)) console.log(d.padEnd(16), JSON.stringify(v));
    await browser.close();
    return;
  }
  const bip = Object.entries(report.enemies).filter(([, v]) => typeof v === 'object' && !v.quad && !v.capped);
  assert.ok(bip.length >= 8, 'measured enough biped enemies');
  for (const [def, v] of bip) assert.ok(v.slip < 0.9, `${def} foot slip ratio ${v.slip}`);
  const avg = bip.reduce((s, [, v]) => s + v.slip, 0) / bip.length;
  assert.ok(avg < 0.45, `mean slip ${avg.toFixed(2)}`);
  report.meanBipedSlip = +avg.toFixed(2);
  log('enemy slip mean', report.meanBipedSlip);


  // --- quadruped stride: the bone hound's four foot bones, planted speed along the heading as a share of ground speed.
  // (The mesh/bone metrics above are unreliable on the quadruped rigs; this is the signed measure used to calibrate them.)
  report.houndPlanted = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug; const scene = getRuntime().view; const V3 = scene.rig.camera.position.constructor;
    const med = (a) => { a = a.slice().sort((x, y) => x - y); return a[Math.floor(a.length / 2)]; };
    dbg.clear(); scene.player.x = 0; scene.player.z = 0;
    const id = dbg.ring('hound', 1, 14)[0]; const sim = dbg.sim(); const e = sim.enemies.get(id); e.hp = e.maxHp = 1e9;
    let view; for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = scene.views.enemies.get(id); }
    dbg.advance(1.5, false);
    const bs = ['bone_10', 'bone_11', 'bone_14', 'bone_15'].map((n) => { let f; view.c.model.traverse((o) => { if (o.name === n) f = o; }); return f; });
    const rows = []; let prev = null;
    for (let i = 0; i < 160; i++) {
      dbg.advance(1 / 60, false);
      const ee = sim.enemies.get(id); if (!ee || !ee.moving) { prev = null; continue; }
      const h = view.c.root.rotation.y; const fp = bs.map((b) => b.getWorldPosition(new V3()));
      if (prev) rows.push(fp.map((p, k) => [p.y, ((p.x - prev[k].x) * Math.sin(h) + (p.z - prev[k].z) * Math.cos(h)) * 60]));
      prev = fp;
    }
    const per = bs.map((_, k) => { const ys = rows.map((r) => r[k][0]); const lo = Math.min(...ys), hi = Math.max(...ys); return med(rows.filter((r) => r[k][0] <= lo + 0.25 * (hi - lo)).map((r) => r[k][1])) / e.speed; });
    return { planted: +med(per).toFixed(2), ts: +(view.c.lastPlan?.timeScale ?? 0).toFixed(2) };
  });
  log('hound planted (signed, share of ground speed; 0 = planted)', JSON.stringify(report.houndPlanted));
  assert.ok(Math.abs(report.houndPlanted.planted) < 0.2, `hound feet planted ${report.houndPlanted.planted}`);
  assert.equal(report.enemies.robber.clip, 'run', 'robber runs on its run clip');

  // --- heading: biped toes point along the heading ---
  report.heading = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const scene = getRuntime().view;
    const V3 = scene.rig.camera.position.constructor;
    dbg.clear();
    const id = dbg.ring('robber', 1, 6)[0];
    let view;
    for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = scene.views.enemies.get(id); }
    dbg.freeze(true);
    dbg.advance(2, false);
    const h = view.c.root.rotation.y;
    let A, B;
    view.c.model.traverse((o) => { if (o.name === 'L_Foot') A = o; if (o.name === 'L_ToeBase') B = o; });
    const d = B.getWorldPosition(new V3()).sub(A.getWorldPosition(new V3()));
    return (d.x * Math.sin(h) + d.z * Math.cos(h)) / Math.hypot(d.x, d.z);
  });
  assert.ok(report.heading > 0.9, `robber faces its heading (${report.heading})`);

  // --- hero: run matches movement, turns are rate limited ---
  report.hero = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const v = getRuntime().view;
    dbg.clear();
    v.player.moveTo(v.player.x + 12, v.player.z);
    dbg.advance(0.8, false);
    const plan = v.avatar.c.lastPlan;
    let maxStep = 0, last = v.avatar.c.root.rotation.y;
    v.player.facing = last + 3;
    for (let i = 0; i < 30; i++) { dbg.advance(1 / 60, false); const r = v.avatar.c.root.rotation.y; maxStep = Math.max(maxStep, Math.abs(r - last)); last = r; }
    return { clip: plan?.clip, ts: plan?.timeScale, residual: plan?.residual, maxTurnPerFrame: maxStep };
  });
  assert.equal(report.hero.clip, 'run');
  assert.ok(report.hero.residual < 0.3, 'hero feet near planted');

  // --- additive flinch ---
  report.flinch = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const v = getRuntime().view;
    dbg.clear(); v.player.x = 0; v.player.z = 0;
    const id = dbg.ring('robber', 1, 6)[0];
    let view;
    for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = v.views.enemies.get(id); }
    dbg.advance(1.4, false);
    // Hold the robber still so its locomotion can't change clip (run -> idle on arrival) during the check.
    dbg.freeze(true);
    dbg.advance(0.6, false);
    const c = view.c;
    const before = c.current?.getClip().name;
    c.flinch();
    dbg.advance(0.1);
    return { before, after: c.current?.getClip().name, running: c.flinchAct?.isRunning(), additive: c.flinchAct?.blendMode === 2501 };
  });
  assert.ok(report.flinch.running && report.flinch.additive, 'flinch is additive');
  assert.equal(report.flinch.before, report.flinch.after, 'flinch does not swap the clip');

  // --- crowd: 36 enemies converge on a standing hero; count overlapping pairs (centres closer than 80% of the radii) ---
  await page.evaluate(() => { const dbg = window.__cwDebug; dbg.clear(); dbg.ring('risen', 12, 7); dbg.ring('robber', 12, 9); dbg.ring('penitent', 12, 11); });
  await page.evaluate(async () => { const { getRuntime } = await import('/src/app/GameRuntime.ts'); const v = getRuntime().view; for (let k = 0; k < 60 && [...v.views.enemies.values()].some((x) => !x.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); window.__cwDebug.advance(0.05, false); } });
  const sample = () => page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug; const v = getRuntime().view;
    const items = [...dbg.sim().enemies.values()].map((e) => ({ e, view: v.views.enemies.get(e.id) })).filter((o) => o.view && o.e.state !== 'rising');
    const count = (get) => { let n = 0; for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) { const a = get(items[i]), b = get(items[j]); if (Math.hypot(a[0] - b[0], a[1] - b[1]) < (items[i].e.radius + items[j].e.radius) * 0.8) n++; } return n; };
    return { bodies: items.length, sim: count((o) => [o.e.x, o.e.z]), drawn: count((o) => [o.view.c.root.position.x, o.view.c.root.position.z]) };
  });
  report.crowd = { bodies: 0, simOverlaps: 0, drawnOverlaps: 0, samples: 0 };
  for (let i = 0; i < 16; i++) {
    await page.evaluate(() => window.__cwDebug.advance(0.4, false));
    const c = await sample();
    report.crowd.bodies = Math.max(report.crowd.bodies, c.bodies);
    report.crowd.simOverlaps += c.sim;
    report.crowd.drawnOverlaps += c.drawn;
    report.crowd.samples++;
  }
  log('crowd', JSON.stringify(report.crowd));
  assert.ok(report.crowd.drawnOverlaps <= report.crowd.simOverlaps, 'separation never adds overlaps');
  await page.evaluate(() => window.__cwDebug.advance(0.02));
  if (SHOTS) await page.screenshot({ path: path.join(OUT, 'crowd-ring.png') });

  // --- weapon screenshots ---
  if (SHOTS) {
    await page.close();
    page = await openHero(browser, errors);
    await page.evaluate(() => { const d = window.__cwDebug; d.clear(); d.zoom(0.1); d.advance(2); });
    await page.addStyleTag({ content: '#ui-root { display: none !important; }' });
    const equip = (id) => page.evaluate(async (id) => {
      const { getRuntime } = await import('/src/app/GameRuntime.ts');
      const { equipItem } = await import('/src/net/api.ts');
      const v = getRuntime().view;
      if (!v.inventory.all.some((s) => s.item_id === id)) { v.inventory.add({ item_id: id, quantity: 1 }); await v.inventory.flush(); }
      const s = v.inventory.all.find((x) => x.item_id === id && !x.equipped);
      if (s) v.inventory.replace(await equipItem(v.character.id, s.slot_index, 1));
    }, id);
    for (const [name, ids] of [['staff', ['staff_gold']], ['scythe', ['scythe_gold']], ['wand', ['wand_gold']], ['sickle', ['sickle_gold']], ['wand-grimoire', ['wand_gold', 'grimoire_gold']], ['wand-bell', ['wand_gold', 'mourning_bell_gold']]]) {
      for (const id of ids) await equip(id);
      await page.waitForFunction(async () => { const { getRuntime } = await import('/src/app/GameRuntime.ts'); return [...getRuntime().view.avatar.worn.values()].every((w) => w.obj.userData.model === true); }, null, { timeout: 30000 }).catch(() => {});
      await page.evaluate(() => window.__cwDebug.advance(0.6));
      await page.screenshot({ path: path.join(OUT, `weapon-${name}-idle.png`), clip: { x: 300, y: 150, width: 300, height: 300 } });
      await page.evaluate(() => { const d = window.__cwDebug; d.clear(); d.ring('robber', 1, 4); d.freeze(true); d.advance(0.3, false); });
      await page.evaluate(async () => {
        const { getRuntime } = await import('/src/app/GameRuntime.ts');
        const v = getRuntime().view;
        v.player.cooldowns?.clear?.(); v.player.castUntil = 0;
        const e = [...v.enemiesMap().values()][0];
        v.abilities.cast('bone_needle', { x: e.x, z: e.z, enemyId: e.id }, v.now);
      });
      await page.evaluate(() => window.__cwDebug.advance(0.1));
      await page.screenshot({ path: path.join(OUT, `weapon-${name}-cast.png`), clip: { x: 300, y: 150, width: 300, height: 300 } });
      await page.evaluate(() => { window.__cwDebug.clear(); window.__cwDebug.advance(0.5); });
    }
  }

  // --- perf in a busy fight ---
  report.perf = await page.evaluate(async () => {
    const dbg = window.__cwDebug;
    dbg.clear(); dbg.freeze(false); dbg.zoom(0.4);
    dbg.ring('robber', 14, 9); dbg.ring('risen', 14, 12); dbg.ring('hound', 8, 14);
    dbg.advance(1, false);
    const t0 = performance.now();
    for (let i = 0; i < 120; i++) dbg.advance(1 / 60, false);
    return { counts: dbg.counts(), cpuMsPerStep: +((performance.now() - t0) / 120).toFixed(2) };
  });
  log('perf', JSON.stringify(report.perf));

  assert.deepEqual(errors.filter((e) => !/403|Failed to load resource/.test(e)), [], 'no runtime errors');
  fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 1));
  console.log(JSON.stringify({ meanBipedSlip: report.meanBipedSlip, heading: report.heading, hero: report.hero, flinch: report.flinch, crowd: report.crowd, perf: report.perf }, null, 1));
  await browser.close();
}


main().catch((e) => { console.error(e, global.__errors); process.exit(1); });
