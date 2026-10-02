/**
 * Necromancer spell-feel smoke (docs/NECRO-SPELL-FEEL.md): casts every necromancer rite on a staged pack, takes a
 * cropped screenshot of each, fails on page errors, then measures a busy Graves fight (ring of 40 + a legion).
 *
 *   npm run dev -- --host 127.0.0.1 --port 5331 --strictPort
 *   DM_QA_URL=http://127.0.0.1:5331/?offline DM_QA_TAG=after DM_QA_QUALITY=high node tools/qa/spell-feel-smoke.cjs
 *
 * Env: DM_QA_TAG (screenshot prefix, default "run"), DM_QA_OUT (dir, default os.tmpdir()), DM_QA_QUALITY (high|low),
 *      DM_QA_REDUCED=1 (Settings -> reduced motion), DM_QA_DISC (discipline card text, default Gravecaller),
 *      DM_QA_ONLY=a,b (rite keys), DM_QA_WAITS=0.3,6 (override the screenshot times, seconds after the cast), DM_QA_ZOOM=0.3 (camera zoom for close-ups), DM_QA_NOSHOTS=1 (perf only), DM_QA_NOPERF=1, DM_QA_PLAYWRIGHT_MODULE / DM_CHROMIUM_PATH.
 * Perf numbers come from software GL (swiftshader), so compare before/after on the same machine, not against hardware.
 */
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const OUT = process.env.DM_QA_OUT || os.tmpdir();
const TAG = process.env.DM_QA_TAG || 'run';
const QUALITY = process.env.DM_QA_QUALITY || 'high';
const REDUCED = process.env.DM_QA_REDUCED === '1';
const ONLY = (process.env.DM_QA_ONLY || '').split(',').filter(Boolean);
const WAITS = (process.env.DM_QA_WAITS || '').split(',').filter(Boolean).map(Number);
const ZOOM = Number(process.env.DM_QA_ZOOM || 0.55);
const ROUNDS = Number(process.env.DM_QA_ROUNDS || 1);
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5331/?offline';

/**
 * key: [ability id, setup, waits (s) after the cast for each screenshot, loadout override]
 * setup: 'pack' (5 enemies 5m east, corpses beside the pack), 'corpses' (corpses only), 'thralls' (a legion first), 'self'.
 */
const RITES = {
  needle: ['bone_needle', 'pack', [0.12, 0.32], null],
  reap: ['bone_needle', 'near', [0.12, 0.3], { reap: true }],
  staff: ['bone_needle', 'line', [0.3], { needlePierce: 2, needleRangeMult: 1.3 }],
  spear: ['marrow_spear', 'line', [0.35, 0.9], null],
  exhume: ['exhume', 'corpses', [0.5, 1.2], null],
  miasma: ['miasma', 'pack', [0.9, 2.2], null],
  litany: ['black_litany', 'thralls', [0.12, 0.5], null],
  explosion: ['corpse_explosion', 'pack', [0.1, 0.5], null],
  skull: ['wailing_skull', 'pack', [0.3, 0.7], null],
  step: ['grave_step', 'corpses', [0.3, 0.8], null],
  frost: ['grave_frost', 'pack', [0.7, 1.4], null],
  siphon: ['soul_siphon', 'pack1', [0.8], null],
  prison: ['bone_prison', 'pack', [0.3, 1.0], null],
  hands: ['grave_hands', 'pack', [0.7, 2.0], null],
  storm: ['bone_storm', 'pack', [0.9, 2.0], null],
  wall: ['ossuary_wall', 'pack', [0.4, 1.0], null],
  rend: ['command_rend', 'thralls', [0.3, 0.8], null],
  dirge: ['dirge', 'pack', [0.5, 1.4], null],
  bloom: ['plague_bloom', 'pack', [0.5, 1.4], null],
  mantle: ['bone_mantle', 'corpses', [0.5, 1.2], null],
  thrall: ['exhume', 'corpses', [0.9, 1.5], null, 'thrall rise (the exhume rising)'],
  harvest: ['marrow_spear', 'line', [0.2, 0.5], null, 'soul harvest release', { souls: true }],
};

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await browser.newPage({ viewport: { width: 1024, height: 700 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  await page.addInitScript(([q, r]) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, reducedMotion: r, tips: false, autoCombat: false })), [QUALITY, REDUCED]);
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `feelqa_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('feelqa@example.invalid');
  await page.fill('#cw-pass', 'TestingFeel1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: process.env.DM_QA_DISC || 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(async () => {
    const d = window.__cwDebug;
    (await import('/src/gameplay/devAccess.ts')).devAccess.active = true;
    window.__qaRt = (await import('/src/app/GameRuntime.ts')).getRuntime();
    window.__qaScene = window.__qaRt.view;
    d.god(true);
    d.unlockAll();
    d.goto('graves');
    d.advance(0.5);
    d.teleport(-12, -4);
    d.advance(2.5);
  });

  const report = { quality: QUALITY, reduced: REDUCED, rites: {} };
  if (process.env.DM_QA_NOSHOTS !== '1') {
    for (const [key, [id, setup, rawWaits, loadout, , extra]] of Object.entries(RITES)) {
      const waits = WAITS.length ? WAITS : rawWaits;
      if (ONLY.length && !ONLY.includes(key)) continue;
      const res = await page.evaluate(([id, setup, loadout, extra, zoom]) => {
        const d = window.__cwDebug;
        const sim0 = () => d.sim();
        const scene = window.__qaScene;
        const p = d.player;
        d.freeze(false);
        // Isolate the rite: end the previous one's zones, timed fields, mantle and legion.
        const ab = scene.abilities;
        for (const tm of [...ab.timed]) tm.end?.();
        ab.timed.length = 0;
        ab.mantleFx?.kill();
        ab.mantleUntil = 0;
        for (const z of sim0().zones.values()) z.until = -1;
        for (const th of [...sim0().thralls.values()]) sim0().killThrall(th, 'crumbled');
        d.clear();
        d.advance(1.6);
        d.zoom(zoom);
        p.hp = p.stats.maxHp;
        p.barrier = 0;
        p.face(p.x, p.z - 5);
        const NO = { main: null, mainTier: null, off: null, offTier: null, spellMult: 1, needleRangeMult: 1, needlePierce: 0, needleCadenceMult: 1, needleDamageMult: 1, needleWithered: 0, reap: false, exhumeRefund: 0, thrallBonus: 0, riteCooldownMult: 1, bellAllyHeal: 0, ...(loadout || {}) };
        p.loadout = NO;
        const sim = d.sim();
        const mk = (n, dx, spread, def = 'robber') => {
          const list = [];
          for (let i = 0; i < n; i++) {
            const e = sim.spawnEnemy(def, 'graves', p.x + Math.sin(i * 2.4) * spread, p.z - dx + Math.cos(i * 2.4) * spread, false, false);
            e.hp = e.maxHp = 1e6;
            e.speed = 0;
            e.attackCd = 99;
            list.push(e);
          }
          return list;
        };
        let target;
        let list = [];
        if (setup === 'near') list = mk(4, 2, 0.8);
        if (setup === 'pack' || setup === 'pack1') list = mk(setup === 'pack1' ? 1 : 5, 5, setup === 'pack1' ? 0 : 1.3);
        if (setup === 'line') list = [...mk(1, 4.5, 0), ...mk(1, 6.5, 0), ...mk(1, 8, 0)];
        if (setup === 'pack') for (let i = 0; i < 3; i++) sim.addCorpse(p.x - 1.4 + i * 0.7, p.z - 3.4, 'normal', 'robber', false, 0, 1, 'graves');
        if (setup === 'corpses' || setup === 'thralls') for (let i = 0; i < 5; i++) sim.addCorpse(p.x + Math.sin(i * 1.7) * 1.4, p.z - 3 + Math.cos(i * 1.7) * 1.4, 'normal', 'robber', false, 0, 1, 'graves');
        const cast = (rite, t) => {
          p.essence = p.resource.max;
          p.cooldowns.clear();
          p.castUntil = 0;
          return scene.abilities.cast(rite, t, scene.now);
        };
        if (setup === 'thralls') {
          const mine = () => [...sim.thralls.values()].filter((t) => t.owner === scene.selfId && t.state !== 'dead').length;
          for (let k = 0; k < 14 && mine() < 4; k++) {
            if (!sim.corpses.size) for (let i = 0; i < 3; i++) sim.addCorpse(p.x + Math.sin(i * 1.7) * 1.4, p.z - 3 + Math.cos(i * 1.7) * 1.4, 'normal', 'robber', false, 0, 1, 'graves');
            cast('exhume', { x: p.x, z: p.z - 3 });
            d.advance(0.3);
          }
          d.advance(1.8);
          mk(6, 5.5, 1.5);
          for (let i = 0; i < 4; i++) sim.addCorpse(p.x + 1.5 + i * 0.5, p.z + 1.4, 'normal', 'robber', false, 0, 1, 'graves');
          list = [...sim.enemies.values()];
        }
        if (extra && extra.souls) {
          p.souls = p.soulsMax;
        }
        const first = list[0];
        target = first ? { x: first.x, z: first.z, enemyId: first.id } : { x: p.x, z: p.z - 4.5 };
        if (id === 'bone_prison' || id === 'grave_hands' || id === 'bone_storm' || id === 'miasma' || id === 'plague_bloom' || id === 'ossuary_wall' || id === 'command_rend') target = { x: p.x, z: p.z - 5 };
        const before = Object.fromEntries(Object.keys(d.counts()).map((k) => [k, d.counts()[k]]));
        const result = cast(id, target);
        return { result, thralls: d.counts().thralls, before };
      }, [id, setup, loadout, extra, ZOOM]);
      assert.ok(res.result === 'ok', `${key} (${id}) cast: ${res.result}`);
      const shots = [];
      let elapsed = 0;
      for (let i = 0; i < waits.length; i++) {
        await page.evaluate((s) => window.__cwDebug.advance(s), waits[i] - elapsed);
        elapsed = waits[i];
        await page.waitForTimeout(120);
        const file = path.join(OUT, `${TAG}-${key}-${i + 1}.png`);
        await page.screenshot({ path: file, clip: { x: 160, y: 50, width: 704, height: 480 } });
        shots.push(file);
      }
      // Effects still playing after the last frame: a rite that leaves a one-shot behind is a leak.
      const live = await page.evaluate(() => window.__qaScene.effects.binbun.live.filter((l) => !l.dead && !/waystone|brazier|bonfire|candle|beacon|fog|crypt_mist|area_gate|portal|kiln|altar|loot_|interact_rim|censer|enemy_breach|soul_orb/.test(l.id)).map((l) => `${l.id}@${l.t.toFixed(1)}/${(l.end ?? 0).toFixed ? l.end.toFixed(1) : l.end}`));
      report.rites[key] = { id, result: res.result, shots: shots.map((s) => path.basename(s)), liveOneShots: live };
      if (live.length) console.log('  still playing:', live.join(' '));
      console.log('rite', key, res.result);
    }
  }

  if (process.env.DM_QA_NOPERF !== '1') {
    const perf = await page.evaluate((rounds) => {
      const d = window.__cwDebug;
      const scene = window.__qaScene;
      const rt = window.__qaRt;
      const p = d.player;
      const out = {};
      d.clear();
      d.teleport(-12, -4);
      p.loadout = { ...p.loadout, reap: false };
      p.hp = p.stats.maxHp;
      // A legion first (thralls are real sim units), then the ring of 40 around it.
      for (let i = 0; i < 12; i++) d.sim().addCorpse(p.x + Math.sin(i) * 2, p.z + Math.cos(i) * 2, 'normal', 'robber', false, 0, 1, 'graves');
      const cast = (rite, t) => {
        p.essence = p.resource.max;
        p.cooldowns.clear();
        p.castUntil = 0;
        return scene.abilities.cast(rite, t, scene.now);
      };
      for (let k = 0; k < 8; k++) {
        cast('exhume', { x: p.x, z: p.z });
        d.advance(0.25);
      }
      d.advance(1.5);
      const ids = d.ring('robber', 40, 7);
      for (const id of ids) {
        const e = d.sim().enemies.get(id);
        if (e) e.hp = e.maxHp = 1e7;
      }
      d.advance(1.2);
      out.thralls = d.counts().thralls;
      out.enemies = d.counts().enemies ?? ids.length;
      // The busy rites back to back, each cast twice per round with the motif layer on and off (alternating which goes
      // first), so slow drift in the fight (corpses piling up, zones) lands on both sides equally. Per cast we record what
      // the rite itself added within 0.15 s (particles, billboard/decal transients, Binbun effects), the synchronous cost
      // of the cast call, and one full render. Round 0 is a warm-up and is not recorded.
      const rotation = ['bone_needle', 'marrow_spear', 'miasma', 'black_litany', 'corpse_explosion', 'wailing_skull', 'grave_frost', 'bone_prison', 'grave_hands', 'bone_storm', 'bone_mantle', 'dirge', 'plague_bloom', 'exhume'];
      const ef = scene.effects;
      const cam = scene.rig.camera;
      const gl = rt.renderer.getContext();
      const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
      const mean = (a) => a.reduce((x, y) => x + y, 0) / (a.length || 1);
      const live = () => ef.additive.active + ef.smoke.active;
      const rows = { on: { render: [], castMs: [], emitted: [], transients: [], binbun: [] }, off: { render: [], castMs: [], emitted: [], transients: [], binbun: [] } };
      const motif0 = d.necroMotifs();
      let motifSeen = { particles: 0, billboards: 0, decals: 0, hands: 0 };
      let flip = false;
      for (let round = 0; round < rounds + 1; round++) {
        for (const r of rotation) {
          for (const on of flip ? [false, true] : [true, false]) {
            d.necroMotifs(on);
            for (let i = 0; i < 4; i++) d.sim().addCorpse(p.x + Math.sin(i + round) * 3, p.z + Math.cos(i + round) * 3, 'normal', 'robber', false, 0, 1, 'graves');
            const near = [...d.sim().enemies.values()].sort((a, b) => Math.hypot(a.x - p.x, a.z - p.z) - Math.hypot(b.x - p.x, b.z - p.z))[0];
            const m0 = d.necroMotifs();
            const t0 = ef.transientLoad;
            const b0 = d.vfxCount();
            const c0 = performance.now();
            cast(r, near ? { x: near.x, z: near.z, enemyId: near.id } : { x: p.x, z: p.z - 5 });
            const castMs = performance.now() - c0;
            d.advance(0.15);
            if (round === 0) continue;
            const R = rows[on ? 'on' : 'off'];
            const t1 = performance.now();
            rt.renderer.render(scene.scene, cam);
            gl.finish();
            R.render.push(performance.now() - t1);
            R.castMs.push(castMs);
            const m1 = d.necroMotifs();
            R.emitted.push(m1.emitted - m0.emitted);
            if (on) for (const k of Object.keys(motifSeen)) motifSeen[k] += m1[k] - m0[k];
            R.transients.push(ef.transientLoad - t0);
            R.binbun.push(d.vfxCount() - b0);
          }
          flip = !flip;
        }
      }
      d.necroMotifs(true);
      const sum = (R) => ({ renderMsMedian: +med(R.render).toFixed(1), castCallMsMean: +mean(R.castMs).toFixed(3), emittedPerCastMean: +mean(R.emitted).toFixed(1), emittedPerCastMax: Math.max(...R.emitted), transientsAddedMean: +mean(R.transients).toFixed(1), transientsAddedMax: Math.max(...R.transients), binbunAddedMean: +mean(R.binbun).toFixed(1) });
      out.summary = { off: sum(rows.off), on: sum(rows.on) };
      out.motifLayerDrew = motifSeen;
      out.motifSkipped = d.necroMotifs().skipped - motif0.skipped;
      out.peakTransients = ef.transientLoad;
      const pf = d.perf(60);
      out.updateMs = +pf.updateMs.toFixed(3);
      out.calls = pf.calls;
      out.triangles = pf.triangles;
      out.counts = d.counts();
      return out;
    }, ROUNDS);
    report.perf = perf;
    console.log('perf', JSON.stringify(report));
  }

  fs.writeFileSync(path.join(OUT, `${TAG}-report.json`), JSON.stringify(report, null, 2));
  const bad = errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e));
  await browser.close();
  assert.deepEqual(bad, [], 'page errors');
  console.log('ok');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
