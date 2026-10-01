// Necromancer presentation audit. Report-only: drives the DEV offline build through
// __cwDebug, measures clips numerically and saves close-up screenshots. Usage (dev server on 5301):
//   DM_PLAYWRIGHT_MODULE=... node tools/qa/necro-audit.cjs [clips|gear|thralls|hud|perf|all]
// DM_QA_URL overrides the preview URL; DM_QA_ARTIFACT_DIR the output dir; DM_QA_DISC limits to one discipline.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5301/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(__dirname, '../../docs/screenshots/necro-audit');
fs.mkdirSync(OUT, { recursive: true });
const DISCS = ['Gravecaller', 'Ossuary', 'Mourner', 'Rotweaver'].filter((d) => !process.env.DM_QA_DISC || process.env.DM_QA_DISC === d);
const MODE = process.argv[2] || 'all';
const want = (m) => MODE === 'all' || MODE === m;
const results = {};

async function boot(browser, disc) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  page.on('response', (r) => { if (r.status() >= 400) errors.push('HTTP ' + r.status() + ' ' + r.url()); });
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.addInitScript((quality) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality, tips: false, autoCombat: false })), process.env.DM_QA_QUALITY || 'low');
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `na_${disc.toLowerCase()}_${Date.now() % 100000}`;
  await page.fill('#cw-user', n);
  await page.fill('#cw-email', `${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingNecro1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: disc }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.goto('graves'); d.clear(); d.advance(0.5); });
  return { page, errors };
}

async function shot(page, name, clip) {
  for (let i = 0; i < 4; i++) {
    try { await page.screenshot({ path: path.join(OUT, `${name}.png`), timeout: 30000, ...(clip ? { clip } : {}) }); return; }
    catch (e) { if (i === 3) throw e; await page.waitForTimeout(1500); }
  }
}

/** Screen-space box around the hero, for close crops. */
async function heroBox(page, half = 170) {
  const c = await page.evaluate(() => {
    const d = window.__cwDebug; const p = d.avatar.c.root.position.clone(); p.y = 1.0;
    const v = p.project(d.camera); return { x: (v.x + 1) / 2 * innerWidth, y: (1 - v.y) / 2 * innerHeight };
  });
  const x = Math.max(0, Math.min(1280 - 2 * half, Math.round(c.x - half)));
  const y = Math.max(0, Math.min(800 - 2 * half, Math.round(c.y - half)));
  return { x, y, width: 2 * half, height: 2 * half };
}

/** Numeric clip analysis: samples each clip on the live rig and reports drift, vertical range, pops and tip-vs-hand timing. */
async function analyseClips(page) {
  return page.evaluate(() => {
    const d = window.__cwDebug; const c = d.avatar.c;
    const mixer = c.mixer; const actions = c.actions; const root = c.root;
    const find = (n) => { let b = null; c.model.traverse((o) => { if (!b && o.name === n) b = o; }); return b; };
    const head = find('Head'), hip = find('Hip'), rh = find('R_Hand'), lh = find('L_Hand'), lf = find('L_Foot') || find('L_Ankle'), rf = find('R_Foot') || find('R_Ankle');
    const wp = (o) => { const v = o.getWorldPosition(new c.root.position.constructor()); return v; };
    const rel = (o) => { const v = wp(o); return { x: v.x - root.position.x, y: v.y, z: v.z - root.position.z }; };
    const out = {};
    const names = [...actions.keys()];
    const sample = (a, t) => { a.reset(); a.play(); a.paused = true; a.time = t; a.setEffectiveWeight(1); mixer.update(0); root.updateMatrixWorld(true); };
    for (const a of actions.values()) a.stop();
    // Reference pose: idle frame 0.
    const idle = actions.get('idle'); sample(idle, 0);
    const ref = { head: rel(head), rh: rel(rh), hip: rel(hip) };
    idle.stop();
    for (const name of names) {
      const a = actions.get(name); const dur = a.getClip().duration; const N = 24;
      const rows = [];
      for (let i = 0; i <= N; i++) {
        sample(a, Math.min(dur - 1e-4, (i / N) * dur));
        rows.push({ t: +(i / N * dur).toFixed(3), head: rel(head), hip: rel(hip), rh: rel(rh), lh: rel(lh), lf: lf ? rel(lf) : null, rf: rf ? rel(rf) : null });
      }
      const ys = rows.map((r) => r.head.y), hips = rows.map((r) => r.hip.y);
      const hd = (r) => Math.hypot(r.hip.x - rows[0].hip.x, r.hip.z - rows[0].hip.z);
      const dist = (p, q) => Math.hypot(p.x - q.x, p.y - q.y, p.z - q.z);
      // Hand reach: furthest the right hand travels from the hip, and when (fraction of clip).
      const reach = rows.map((r) => dist(r.rh, r.hip));
      const rmax = Math.max(...reach);
      const tracks = a.getClip().tracks.filter((t) => /^(Root|Hip)\.(position|quaternion)$/.test(t.name)).map((t) => t.name);
      out[name] = {
        dur: +dur.toFixed(2), headY: [+Math.min(...ys).toFixed(2), +Math.max(...ys).toFixed(2)], hipY: [+Math.min(...hips).toFixed(2), +Math.max(...hips).toFixed(2)],
        hipDriftMax: +Math.max(...rows.map(hd)).toFixed(2), hipDriftEnd: +hd(rows[N]).toFixed(2),
        firstVsIdleHead: +dist(rows[0].head, ref.head).toFixed(2), lastVsIdleHead: +dist(rows[N].head, ref.head).toFixed(2),
        handReachMax: +rmax.toFixed(2), handReachAt: +(reach.indexOf(rmax) / N).toFixed(2), handReachIdle: +reach[0].toFixed(2),
        rootTracks: tracks,
      };
      a.stop();
    }
    return out;
  });
}

/** Build a labelled contact sheet from [{label, buf}] screenshots (rendered in a scratch page) and save it as PNG. */
async function sheet(browser, name, cells, cols, cellW, cellH) {
  const page = await browser.newPage({ viewport: { width: cols * cellW, height: Math.ceil(cells.length / cols) * cellH } });
  const html = `<body style="margin:0;background:#111;display:grid;grid-template-columns:repeat(${cols},${cellW}px);font:12px monospace;color:#ddd">` +
    cells.map((c) => `<div style="position:relative;width:${cellW}px;height:${cellH}px;overflow:hidden"><img src="data:image/png;base64,${c.buf.toString('base64')}" style="width:${cellW}px;height:${cellH}px;object-fit:cover"><span style="position:absolute;left:4px;top:2px;background:#000a;padding:1px 3px">${c.label}</span></div>`).join('') + '</body>';
  await page.setContent(html);
  await page.waitForTimeout(400);
  for (let i = 0; i < 4; i++) { try { await page.screenshot({ path: path.join(OUT, `${name}.png`), timeout: 120000 }); break; } catch (e) { if (i === 3) throw e; await page.waitForTimeout(3000); } }
  await page.close();
}

const A = (page, fn, arg) => page.evaluate(fn, arg);

/** Fast 3D-canvas grab (no HUD): render one frame, crop around the hero, return a PNG Buffer. Far cheaper than page.screenshot on SwiftShader. */
async function grab(page, half = 130, advance = 0.001) {
  const b64 = await page.evaluate(([half, adv]) => {
    const d = window.__cwDebug; d.advance(adv, true);
    const cv = document.querySelector('canvas');
    const k = cv.width / innerWidth;
    const p = d.avatar.c.root.position.clone(); p.y = 1.0;
    const v = p.project(d.camera);
    const cx = (v.x + 1) / 2 * innerWidth, cy = (1 - v.y) / 2 * innerHeight;
    const out = document.createElement('canvas'); out.width = out.height = half * 2;
    out.getContext('2d').drawImage(cv, (cx - half) * k, (cy - half) * k, half * 2 * k, half * 2 * k, 0, 0, half * 2, half * 2);
    return out.toDataURL('image/png').split(',')[1];
  }, [half, advance]);
  return Buffer.from(b64, 'base64');
}

/** Freeze one clip at time t (seconds, unscaled) on the live rig and render one frame. */
async function poseAt(page, clipName, t) {
  await page.evaluate(([n, t]) => {
    const d = window.__cwDebug; const c = d.avatar.c;
    for (const a of c.actions.values()) a.stop();
    const a = c.actions.get(n); a.reset(); a.play(); a.paused = true; a.time = t; a.setEffectiveWeight(1);
    c.mixer.update(0);
  }, [clipName, t]);
}

async function clipsPass(page, tag, res, browser) {
  res.clips = await analyseClips(page);
  await page.evaluate(() => { const d = window.__cwDebug; d.zoom(0.4); d.advance(0.2); });
  const cells = [];
  const order = ['idle', 'walk', 'run', 'cast', 'attack', 'hurt', 'hurt2', 'death', 'death2', 'dig'];
  for (const n of order) {
    // Cast/dig/attack play sub-clipped by the game; sample only the played window (cast 1.1 s, dig 1.3 s, attack/hurt 0..1.3).
    const played = { cast: res.clips.cast.dur, dig: res.clips.dig.dur, attack: Math.min(res.clips.attack.dur, 2.0), idle: 3 }[n] ?? res.clips[n].dur;
    for (const f of [0, 0.25, 0.5, 0.75]) {
      await poseAt(page, n, Math.min(res.clips[n].dur - 0.01, f * played));
      cells.push({ label: `${tag} ${n} ${Math.round(f * 100)}%`, buf: await grab(page, 100) });
    }
  }
  await sheet(browser, `clips-${tag}`, cells, 8, 200, 200);
}


const SCENE = `(await import('/src/app/GameRuntime.ts')).getRuntime().view`;

/** Weapons: per-kind props on every discipline in idle / run / cast poses, plus tilt + tip measurements. */
async function gearPass(page, tag, res, browser) {
  await page.evaluate(() => { const d = window.__cwDebug; d.zoom(0.4); d.advance(0.2); });
  const weapons = [['staff_oak', null], ['staff_moon', null], ['sword_copper', null], ['dagger_iron', null], ['mace_gold', null], ['tome_bone', null], ['bow_oak', null], ['scythe_iron', null], ['wand_bone', null], [null, 'shield_steel'], [null, 'tome_bone'], ['staff_oak', 'tome_bone']];
  res.weapons = {};
  const cells = [];
  for (const [main, off] of weapons) {
    const label = [main, off].filter(Boolean).join('+');
    const m = await page.evaluate(([main, off]) => {
      const d = window.__cwDebug; const c = d.avatar.c;
      d.avatar.setEquipment({ main_hand: main ? { item_id: main } : undefined, off_hand: off ? { item_id: off } : undefined });
      const find = (n) => { let b = null; c.model.traverse((o) => { if (!b && o.name === n) b = o; }); return b; };
      const rh = find('R_Hand'), lh = find('L_Hand');
      const worn = d.avatar.worn.get('main_hand')?.obj ?? d.avatar.staff;
      const V = c.root.position.constructor;
      const tilt = (o) => { const q = o.getWorldQuaternion(new (c.root.quaternion.constructor)()); const y = new V(0, 1, 0).applyQuaternion(q); return +(Math.acos(Math.max(-1, Math.min(1, y.y))) * 57.3).toFixed(0); };
      const out = {};
      const sample = (n, t) => { for (const a of c.actions.values()) a.stop(); const a = c.actions.get(n); a.reset(); a.play(); a.paused = true; a.time = t; a.setEffectiveWeight(1); c.mixer.update(0); c.root.updateMatrixWorld(true); d.advance(0.02); };
      // The calibration needs a few animated frames after a swap.
      sample('idle', 0.5); d.advance(0.3);
      for (const [k, n, t] of [['idle', 'idle', 0.5], ['run', 'run', 0.3], ['runB', 'run', 0.9], ['cast', 'cast', 0.46], ['attack', 'attack', 1.2]]) {
        sample(n, t);
        const tip = d.avatar.tip(new V());
        out[k] = { tilt: worn ? tilt(worn) : null, tipY: +tip.y.toFixed(2), tipFwd: +(tip.z - c.root.position.z).toFixed(2), tipRelHand: rh ? +tip.distanceTo(rh.getWorldPosition(new V())).toFixed(2) : null };
      }
      return out;
    }, [main, off]);
    res.weapons[label] = m;
    for (const [k, n, t] of [['idle', 'idle', 0.5], ['run', 'run', 0.3], ['cast', 'cast', 0.46]]) {
      await page.evaluate(([n, t]) => { const d = window.__cwDebug; const c = d.avatar.c; for (const a of c.actions.values()) a.stop(); const a = c.actions.get(n); a.reset(); a.play(); a.paused = true; a.time = t; a.setEffectiveWeight(1); c.mixer.update(0); }, [n, t]);
      cells.push({ label: `${tag} ${label} ${k}`, buf: await grab(page, 100) });
    }
  }
  await sheet(browser, `weapons-${tag}`, cells, 6, 220, 220);
  await page.evaluate(() => window.__cwDebug.avatar.setEquipment({}));

  // Weapon tiers of the staff on one sheet (tint readability).
  const tiers = ['staff_bone', 'staff_copper', 'staff_iron', 'staff_steel', 'staff_gold', 'staff_hell', 'staff_moon'];
  const tc = [];
  for (const id of tiers) {
    await page.evaluate((id) => { const d = window.__cwDebug; d.avatar.setEquipment({ main_hand: { item_id: id } }); d.advance(0.4); }, id);
    await page.evaluate(() => { const d = window.__cwDebug; const c = d.avatar.c; for (const a of c.actions.values()) a.stop(); const a = c.actions.get('idle'); a.reset(); a.play(); a.paused = true; a.time = 0.5; a.setEffectiveWeight(1); c.mixer.update(0); });
    tc.push({ label: `${tag} ${id}`, buf: await grab(page, 100) });
  }
  await sheet(browser, `tiers-${tag}`, tc, 7, 200, 200);
  await page.evaluate(() => window.__cwDebug.avatar.setEquipment({}));

  // Armor: both collections, all five pieces; capes and pets.
  const d1 = { Gravecaller: 'gravecaller', Ossuary: 'ossuary', Mourner: 'mourner', Rotweaver: 'rotweaver' };
  const set = d1[Object.keys(d1).find((k) => k.toLowerCase() === tag)];
  const ac = [];
  for (const [nm, pre] of [['none', null], ['collection1', `set_${set}_`], ['collection2', `set_${set}_ascended_`]]) {
    const items = {};
    if (pre) for (const part of ['head', 'chest', 'hands', 'legs', 'feet']) items[part] = { item_id: pre + part };
    await page.evaluate((items) => { const d = window.__cwDebug; d.avatar.setEquipment({ main_hand: { item_id: 'staff_oak' }, ...items }); d.advance(0.5); }, items);
    for (const [k, n, t] of [['idle', 'idle', 0.5], ['run', 'run', 0.3], ['cast', 'cast', 0.46]]) {
      await page.evaluate(([n, t]) => { const d = window.__cwDebug; const c = d.avatar.c; for (const a of c.actions.values()) a.stop(); const a = c.actions.get(n); a.reset(); a.play(); a.paused = true; a.time = t; a.setEffectiveWeight(1); c.mixer.update(0); }, [n, t]);
      ac.push({ label: `${tag} armor ${nm} ${k}`, buf: await grab(page, 100) });
    }
  }
  await sheet(browser, `armor-${tag}`, ac, 3, 300, 300);
  res.armorHelmMeshes = await page.evaluate(() => { let n = 0; window.__cwDebug.avatar.worn.get('head')?.obj.traverse((o) => { if (o.isMesh) n++; }); return n; });

  const cc = [];
  for (const cape of ['cape_apprentice', 'cape_woodcutting', 'cape_alchemy', 'cape_sexton']) {
    await page.evaluate(async ([cape, S]) => { const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; sc.applyCosmetics({ cape, pet: null }); window.__cwDebug.advance(0.4); }, [cape, SCENE]);
    for (const [k, n, t] of [['idle', 'idle', 0.5], ['run', 'run', 0.3], ['cast', 'cast', 0.46]]) {
      await page.evaluate(([n, t]) => { const d = window.__cwDebug; const c = d.avatar.c; for (const a of c.actions.values()) a.stop(); const a = c.actions.get(n); a.reset(); a.play(); a.paused = true; a.time = t; a.setEffectiveWeight(1); c.mixer.update(0); }, [n, t]);
      cc.push({ label: `${tag} ${cape} ${k}`, buf: await grab(page, 100) });
    }
  }
  await sheet(browser, `capes-${tag}`, cc, 3, 300, 300);
  // Pets: a wee thrall, a bat.
  const pc = [];
  for (const pet of ['pet_wee_thrall', 'pet_tithe_bat', 'pet_drowned_pup']) {
    await page.evaluate(async ([pet, S]) => { const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; sc.applyCosmetics({ cape: null, pet }); window.__cwDebug.advance(1.5); }, [pet, SCENE]);
    pc.push({ label: `${tag} ${pet}`, buf: await grab(page, 140, 0.3) });
  }
  await sheet(browser, `pets-${tag}`, pc, 3, 300, 300);
  await page.evaluate(async (S) => { const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; sc.applyCosmetics({ cape: null, pet: null }); }, SCENE);
}

/** Raise the discipline's legion and look at it next to the hero, idle and in a fight. */
async function thrallPass(page, tag, res, browser) {
  const info = await page.evaluate(async (S) => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug;
    d.zoom(0.55); d.clear(); d.advance(0.2);
    const m = sc.discipline.mods; const sim = d.sim();
    const n = m.thrallCap;
    for (let i = 0; i < n; i++) {
      sim.addCorpse(d.player.x - 4 + i * 1.6, d.player.z - 2, 'normal', 'robber', false, 0, 1, 'graves');
      sim.applyExhume({ t: 'exhume', by: d.self(), x: d.player.x - 4 + i * 1.6, z: d.player.z - 2, r: 2, cap: n, kind: m.thrallKind, hp: 120, damage: 8, attackSpeedMult: m.thrallAttackSpeedMult ?? 1 });
    }
    d.advance(2.5);
    const views = [...sc.views.thralls.values()];
    const box = (o) => { const b = new (o.position.constructor.constructor === Function ? o.position.constructor : Object)(); return b; };
    const V = d.player.constructor;
    const hb = (root) => { let minY = 1e9, maxY = -1e9; root.updateMatrixWorld(true); root.traverse((o) => { if (o.isMesh && !o.isSprite) { o.geometry.computeBoundingBox?.(); const bb = o.geometry.boundingBox; if (bb) { const wb = bb.clone().applyMatrix4(o.matrixWorld); minY = Math.min(minY, wb.min.y); maxY = Math.max(maxY, wb.max.y); } } }); return +(maxY - minY).toFixed(2); };
    return { kind: m.thrallKind, cap: n, count: sim.thralls.size, slug: views[0]?.c.slug, heroH: hb(d.avatar.c.root), thrallH: views[0] ? hb(views[0].c.root) : null, discipline: sc.discipline.id };
  }, SCENE);
  res.thralls = info;
  const cells = [];
  cells.push({ label: `${tag} legion idle`, buf: await grab(page, 170, 0.05) });
  // Fight: 6 robbers around them.
  await page.evaluate(async () => { const d = window.__cwDebug; d.ring('robber', 6, 5); d.advance(1.2); });
  cells.push({ label: `${tag} legion fight 1.2s`, buf: await grab(page, 170, 0.05) });
  await page.evaluate(() => window.__cwDebug.advance(1.5));
  cells.push({ label: `${tag} legion fight 2.7s`, buf: await grab(page, 170, 0.05) });
  await page.evaluate(() => window.__cwDebug.zoom(1));
  cells.push({ label: `${tag} legion at game zoom`, buf: await grab(page, 170, 0.05) });
  await sheet(browser, `thralls-${tag}`, cells, 4, 330, 330);
  // Stride vs ground speed for the thrall's walk/run clip.
  res.thrallStride = await page.evaluate(async (S) => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug;
    const v = [...sc.views.thralls.values()][0]; if (!v) return null;
    const c = v.c; const find = (n) => { let b = null; c.model.traverse((o) => { if (!b && o.name === n) b = o; }); return b; };
    const out = {};
    for (const name of ['walk', 'run', 'attack', 'idle']) {
      const a = c.actions.get(name); if (!a) { out[name] = null; continue; }
      const foot = find('L_Foot') || find('L_Ankle') || find('LeftFoot'); if (!foot) { out[name] = 'nofoot'; continue; }
      for (const x of c.actions.values()) x.stop();
      const dur = a.getClip().duration; const zs = [];
      for (let i = 0; i <= 24; i++) { a.reset(); a.play(); a.paused = true; a.time = Math.min(dur - 1e-3, dur * i / 24); a.setEffectiveWeight(1); c.mixer.update(0); c.root.updateMatrixWorld(true); const w = foot.getWorldPosition(foot.position.clone()); const l = c.root.worldToLocal(w); zs.push(Math.max(Math.abs(l.z), Math.abs(l.x))); }
      const lo = Math.min(...zs), hi = Math.max(...zs);
      out[name] = { dur: +dur.toFixed(2), footTravel: +(hi - lo).toFixed(2), impliedGroundSpeed: +(2 * (hi - lo) / dur).toFixed(2) };
    }
    const t = [...d.sim().thralls.values()][0];
    out.thrallSpeed = t?.speed; out.playbackWalk = 1.3; out.model = c.slug; out.walkScale = c.root.scale.x;
    return out;
  }, SCENE);
}

/** A busy fight with the necro HUD chips visible: real screenshots (HUD is DOM, not canvas). */
async function hudPass(page, tag, res, browser) {
  await page.evaluate(async (S) => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug;
    d.zoom(1); d.clear(); d.advance(0.2); d.souls(3);
    const m = sc.discipline.mods; const sim = d.sim();
    const n = m.thrallCap;
    for (let i = 0; i < n; i++) { const x = d.player.x + (i - n / 2) * 1.4, z = d.player.z + 2; sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, 'graves'); sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap: n, kind: m.thrallKind, hp: 400, damage: 8, attackSpeedMult: m.thrallAttackSpeedMult ?? 1 }); }
    d.advance(1.5);
    for (const e of d.ring('robber', 10, 6)) { const en = sim.enemies.get(e); en.hp = en.maxHp = 1e6; }
    for (const e of d.ring('hound', 10, 8)) { const en = sim.enemies.get(e); en.hp = en.maxHp = 1e6; }
    d.advance(2);
  }, SCENE);
  await shot(page, `hud-busy-${tag}`);
  // Crop of the bottom HUD and the top-left unit frame for legibility.
  res.hud = await page.evaluate(() => {
    const out = {}; for (const sel of ['[data-souls]', '.hud-ward', '[data-ward]', '.hud-thralls', '[data-thralls]', '.hud-hotbar', '.hud-bars']) { const el = document.querySelector(sel); if (el) { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); out[sel] = { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), text: el.textContent.trim().slice(0, 60), font: cs.fontSize, color: cs.color, display: cs.display }; } }
    out.hudChildren = [...document.querySelectorAll('[class*="hud-"]')].map((e) => e.className.toString().split(' ')[0]).filter((v, i, a) => a.indexOf(v) === i).slice(0, 60);
    return out;
  });
}

async function perfPass(page, tag, res) {
  res.perf = await page.evaluate(async (S) => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug;
    d.zoom(1); d.clear(); d.advance(0.3); d.souls(3);
    const m = sc.discipline.mods; const sim = d.sim();
    const n = m.thrallCap;
    for (let i = 0; i < n; i++) { const x = d.player.x + (i - n / 2) * 1.4, z = d.player.z + 2; sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, 'graves'); sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap: n, kind: m.thrallKind, hp: 1e6, damage: 8, attackSpeedMult: 1 }); }
    d.advance(1.5);
    const r0 = (() => { const r = d.perf(60); return { calls: r.calls, triangles: r.triangles, updateMs: +r.updateMs.toFixed(2), simMs: +r.simMs.toFixed(2), skinned: r.skinned, lights: r.lights, programs: r.programs, thralls: sim.thralls.size }; })();
    const defs = ['robber', 'hound', 'penitent', 'rat'];
    const p = d.player;
    for (let i = 0; i < 30; i++) { const e = sim.spawnEnemy(defs[i % defs.length], 'graves', p.x + Math.sin(i) * (4 + (i % 5)), p.z + Math.cos(i) * (4 + (i % 5)), false, false); e.hp = e.maxHp = 1e6; }
    d.advance(1);
    // Fire some rites for a realistic effect load.
    d.aimAtNearest(); d.cast(1); d.advance(0.2); d.cast(3); d.advance(0.2); d.cast(4); d.advance(0.3);
    const r = d.perf(120);
    return { legionOnly: r0, legion30: { calls: r.calls, triangles: r.triangles, updateMs: +r.updateMs.toFixed(2), simMs: +r.simMs.toFixed(2), skinned: r.skinned, lights: r.lights, programs: r.programs, enemies: r.enemies, thralls: r.thralls, sceneTris: r.sceneTris, casters: r.casters, geometries: r.geometries, textures: r.textures } };
  }, SCENE);
}

/** Feel: hurt while running, cast while running, death + respawn, movement-lock sampling. */
async function feelPass(page, tag, res, browser) {
  const step = (n) => page.evaluate((n) => { window.__cwDebug.advance(n / 60, false); }, n);
  // Run east→west along the open floor so walls do not interfere.
  await page.evaluate(() => { const d = window.__cwDebug; d.goto('graves'); d.clear(); d.advance(0.4); });
  await page.keyboard.down('a');
  const run = await page.evaluate(() => {
    const d = window.__cwDebug; const c = d.avatar.c; const out = {};
    d.advance(0.5, false);
    const track = (label, n, fn) => {
      let lx = d.player.x; const rows = [];
      for (let i = 0; i < n; i++) { if (i === 0) fn?.(); d.advance(1 / 60, false); rows.push({ dx: Math.abs(d.player.x - lx), one: c.oneShot?.getClip().name ?? null, cur: c.current?.getClip().name }); lx = d.player.x; }
      const skate = rows.filter((r) => r.dx > 0.02 && r.cur && /^hurt/.test(r.cur)).length;
      const castSlide = rows.filter((r) => r.dx > 0.02 && r.one === 'cast').length;
      const firstRunFrame = rows.findIndex((r) => r.cur === 'run');
      out[label] = { frames: n, movingFramesInHurtClip: skate, movingFramesInCastClip: castSlide, stillFramesBeforeRun: rows.findIndex((r) => r.dx > 0.02), oneShotEndsAtFrame: rows.findIndex((r) => r.one === null), hurtSeconds: +(skate / 60).toFixed(2), firstRunFrame };
    };
    track('hurtWhileRunning', 90, () => c.playOnce('hurt', 1.6));
    track('hurt2WhileRunning', 90, () => { c.oneShot = null; c.playOnce('hurt', 1.6); });
    const id = d.spawn('robber'); const e = d.sim().enemies.get(id); e.speed = 0; e.hp = e.maxHp = 1e6; e.x = d.player.x - 6; e.z = d.player.z - 6; d.advance(0.1, false); d.aimAtNearest(); d.advance(0.1, false);
    track('castWhileRunning', 40, () => { d.aimAtNearest(); d.cast(1); });
    return out;
  });
  await page.keyboard.up('a');
  res.feel = run;
  // Death, corpse pose and respawn.
  const death = await page.evaluate(async (S) => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug; const c = d.avatar.c;
    d.god(false); d.clear(); d.advance(0.2);
    const find = (n) => { let b = null; c.model.traverse((o) => { if (!b && o.name === n) b = o; }); return b; };
    const hip = find('Hip'); const V = c.root.position.constructor;
    const p0 = d.player.x, z0 = d.player.z;
    sc.onHurt(1e7, 'boss', d.player.x + 1, d.player.z);
    const rows = [];
    for (let i = 0; i < 12; i++) { d.advance(0.5, false); const h = hip.getWorldPosition(new V()); rows.push({ t: (i + 1) * 0.5, hipOff: +Math.hypot(h.x - d.player.x, h.z - d.player.z).toFixed(2), hipY: +h.y.toFixed(2), one: c.oneShot?.getClip().name ?? null, cur: c.current?.getClip().name }); }
    const pose = { alive: d.player.alive, dead: sc.deadUntil };
    // Wait for the respawn (4 s) and check the rig afterwards.
    for (let i = 0; i < 10; i++) d.advance(0.5, false);
    d.advance(1.6, false);
    const after = [];
    for (let i = 0; i < 6; i++) { d.advance(0.5, false); const h = hip.getWorldPosition(new V()); after.push({ hipOff: +Math.hypot(h.x - d.player.x, h.z - d.player.z).toFixed(2), hipY: +h.y.toFixed(2), one: c.oneShot?.getClip().name ?? null, cur: c.current?.getClip().name, alive: d.player.alive }); }
    d.god(true);
    return { rows, after, pose };
  }, SCENE);
  res.death = death;
  const cells = [];
  await page.evaluate(() => { const d = window.__cwDebug; d.zoom(0.55); });
}

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    for (const disc of DISCS) {
      const { page, errors } = await boot(browser, disc);
      const tag = disc.toLowerCase();
      results[disc] = {};
      try {
        if (want('clips')) await clipsPass(page, tag, results[disc], browser);
        if (want('gear')) await gearPass(page, tag, results[disc], browser);
        if (want('thralls')) await thrallPass(page, tag, results[disc], browser);
        if (want('hud')) await hudPass(page, tag, results[disc], browser);
        if (want('perf')) await perfPass(page, tag, results[disc], browser);
        if (want('feel')) await feelPass(page, tag, results[disc], browser);
      } finally {
        results[disc].errors = errors.filter((e) => !/favicon|fontsource|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e));
        await page.close();
      }
    }
  } finally { await browser.close(); }
  fs.writeFileSync(path.join(OUT, `results-${MODE}.json`), JSON.stringify(results, null, 1));
  console.log(JSON.stringify(results, null, 1));
}

module.exports = { boot, shot, heroBox, analyseClips, results, OUT };

if (require.main === module) main().catch((e) => { console.error(e); process.exit(1); });
