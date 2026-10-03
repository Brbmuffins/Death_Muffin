/**
 * VFX cost table: what each rite / rune / legendary effect / loot / level-up / surge / partner cast / busy fight costs.
 *
 *   npx vite --host 127.0.0.1 --port 5407 --strictPort
 *   DM_QA_URL='http://127.0.0.1:5407/?offline' DM_PLAYWRIGHT_MODULE=... DM_QA_TAG=before DM_QA_OUT=/tmp/vfx node tools/qa/vfx-cost.cjs
 *
 * Per scenario (peak over samples at 0.12 / 0.4 / 0.9 / 1.6 s after the cast, minus the same measure just before it):
 *   calls    draw calls the effect layer adds (render with Effects.group visible minus hidden)
 *   layers   transparent overdraw: effect fragment-layers per screen pixel (src/graphics/fxProbe.ts renders every transparent
 *            effect material as a constant additive 1 over the opaque depth, so empty texels count: that is the fill the GPU pays)
 *   cover    share of the screen any effect touches   max  deepest pixel stack
 *   parts    particles alive (additive + smoke rings)   bb  Binbun effects live   trans  pooled transients
 *   cpu      Effects.update ms per frame (mean over the first second, minus the pre-cast mean); bbCpu is its Binbun share
 *   rend     software-GL render ms with the effects minus without (noisy: compare, don't trust)
 *   progs/mats/geos   shader programs / distinct FX materials / geometries this cast created (in scenario order)
 * Env: DM_QA_ONLY=a,b  DM_QA_TAG  DM_QA_OUT  DM_QA_QUALITY=high|low  DM_QA_FIGHT_S (default 10)  DM_QA_NOFIGHT=1  DM_QA_BREAKDOWN=1 (top fill contributors per scenario)
 *   DM_QA_SHOTONLY=1 DM_QA_SHOT_AT=0.3,0.8 DM_QA_SEED=1: skip the probe, cast each scenario and save cropped screenshots <out>/<tag>-<key>-<t>.png (a seeded Math.random makes a before/after pair comparable)
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5407/?offline';
const OUT = process.env.DM_QA_OUT || os.tmpdir();
const TAG = process.env.DM_QA_TAG || 'run';
const QUALITY = process.env.DM_QA_QUALITY || 'high';
const ONLY = (process.env.DM_QA_ONLY || '').split(',').filter(Boolean);
const SHOTS = (process.env.DM_QA_SHOTS || '').split(',').filter(Boolean);
const FIGHT_S = Number(process.env.DM_QA_FIGHT_S || 10);
const BREAKDOWN = process.env.DM_QA_BREAKDOWN === '1';
const SHOTONLY = process.env.DM_QA_SHOTONLY === '1';
const SHOT_AT = (process.env.DM_QA_SHOT_AT || '0.45').split(',').map(Number);
const ZOOM = Number(process.env.DM_QA_ZOOM || 0.55);
fs.mkdirSync(OUT, { recursive: true });

/** key: [ability id | special, setup, rune socket {rite: runeId} | null, loadout override | null, extra] */
const SCEN = {
  // --- auto-attack projectiles
  needle: ['bone_needle', 'pack'],
  bone_fan: ['bone_fan', 'pack'],
  rot_lance: ['rot_lance', 'line'],
  // --- necromancer rites
  spear: ['marrow_spear', 'line'],
  exhume: ['exhume', 'corpses'],
  miasma: ['miasma', 'pack'],
  litany: ['black_litany', 'thralls'],
  explosion: ['corpse_explosion', 'pack'],
  skull: ['wailing_skull', 'pack'],
  step: ['grave_step', 'corpses'],
  frost: ['grave_frost', 'pack'],
  siphon: ['soul_siphon', 'pack1'],
  prison: ['bone_prison', 'pack'],
  hands: ['grave_hands', 'pack'],
  storm: ['bone_storm', 'pack'],
  mantle: ['bone_mantle', 'corpses'],
  wall: ['ossuary_wall', 'pack'],
  rend: ['command_rend', 'thralls'],
  dirge: ['dirge', 'pack'],
  bloom: ['plague_bloom', 'pack'],
  offering: ['grave_offering', 'corpses'],
  rally: ['rally_dead', 'thralls'],
  seed: ['carrion_seed', 'corpses'],
  cleave: ['ivory_cleave', 'near'],
  veil: ['veil_step', 'pack'],
  // --- rune variants
  'rune:splinter': ['bone_needle', 'pack', { bone_needle: 'rune_splinter' }],
  'rune:volley': ['bone_needle', 'pack', { bone_needle: 'rune_volley' }],
  'rune:ring': ['marrow_spear', 'line', { marrow_spear: 'rune_ossuary_ring' }],
  'rune:impale': ['marrow_spear', 'line', { marrow_spear: 'rune_impale' }],
  'rune:mass_grave': ['exhume', 'corpses', { exhume: 'rune_mass_grave' }],
  'rune:colossus': ['exhume', 'corpses', { exhume: 'rune_bone_colossus' }],
  'rune:creeping_rot': ['miasma', 'pack', { miasma: 'rune_creeping_rot' }],
  'rune:contagion': ['miasma', 'pack', { miasma: 'rune_contagion' }],
  'rune:choir': ['black_litany', 'thralls', { black_litany: 'rune_hollow_choir' }],
  'rune:requiem': ['black_litany', 'thralls', { black_litany: 'rune_requiem' }],
  // --- legendary set effects (mods forced on; see legendary-mech-smoke.cjs)
  'legend:wisps': ['marrow_spear', 'line', null, null, { mods: { thrallDeathBurst: 0.6 }, kill: true }],
  'legend:champion': ['exhume', 'corpses', null, null, { legend: 'legion_unburied' }],
  // --- nothing cast: what the scene's ambient effects (braziers, waystones, persistent decals) cost by themselves
  ambient: ['@none', 'self'],
  // --- world effects
  levelup: ['@levelup', 'self'],
  surge: ['@surge', 'self'],
  loot_rare: ['@loot', 'self', null, null, { item: 'bone_dagger', n: 3 }],
  boss_telegraph: ['@boss', 'self'],
  // --- a partner's spells replayed as remote events (co-op: same look, someone else's casts)
  'coop:partner_rotation': ['@partner', 'thralls', null, null, { rotation: ['miasma', 'black_litany', 'corpse_explosion', 'bone_mantle', 'exhume'] }],
};

if (process.env.DM_QA_BBALL === '1') {
  for (const k of Object.keys(SCEN)) delete SCEN[k];
  const ids = JSON.parse(fs.readFileSync(path.join(__dirname, '../../public/fx/binbun/index.json'), 'utf8'));
  for (const e of Array.isArray(ids) ? ids : ids.effects || Object.keys(ids)) {
    const id = typeof e === 'string' ? e : e.id;
    if (/^(world_|loot_|brazier|bonfire|kiln|waystone|chapterhouse|nave_fog|crypt_mist|altar|area_gate|recall)/.test(id)) continue;
    SCEN[`bb:${id}`] = ['@vfx', 'self', null, null, { id }];
  }
}

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await browser.newPage({ viewport: { width: 1024, height: 700 } });
  page.setDefaultTimeout(240000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  if (process.env.DM_QA_SEED === '1') {
    // Same random stream in both builds, so a before/after pair differs only by what the code changed.
    await page.addInitScript(() => {
      let a = 0x9e3779b9;
      Math.random = () => { a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
    });
  }
  await page.addInitScript((q) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, tips: false, autoCombat: false })), QUALITY);
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `vfxcost_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('vfxcost@example.invalid');
  await page.fill('#cw-pass', 'TestingCost1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(async (shot) => {
    const d = window.__cwDebug;
    (await import('/src/gameplay/devAccess.ts')).devAccess.active = true;
    const rt = (await import('/src/app/GameRuntime.ts')).getRuntime();
    const scene = rt.view;
    let P = null;
    try { P = await import('/src/graphics/fxProbe.ts'); } catch { /* shots-only run against a tree without the probe */ }
    const ef = scene.effects;
    const acc = { rec: false, fx: [], bb: [] };
    const u0 = ef.update.bind(ef);
    ef.update = (...a) => { const t = performance.now(); u0(...a); if (acc.rec) acc.fx.push(performance.now() - t); };
    const b0 = ef.binbun.update.bind(ef.binbun);
    ef.binbun.update = (...a) => { const t = performance.now(); b0(...a); if (acc.rec) acc.bb.push(performance.now() - t); };
    // Dead particles keep their last size in the ring buffers (old code); zero them so a scenario's delta is its own. No-op once the code does it itself.
    const purge = () => { for (const ps of [ef.additive, ef.smoke]) for (let i = 0; i < ps.capacity; i++) if (ps.life[i] <= 0) { ps.size[i] = 0; ps.alpha[i] = 0; } };
    window.__vc = { d, rt, scene, P, ef, acc, purge, r: rt.renderer, cam: scene.rig.camera };
    if (shot) rt.stop();
    d.god(true);
    d.unlockAll();
    d.goto('graves');
    d.advance(0.5);
    d.teleport(-12, -4);
    d.advance(2.5);
    // Warm everything the cast paths might compile, so "programs created" means a rite's own, not first-render noise.
    rt.renderer.render(scene.scene, scene.rig.camera);
  }, SHOTONLY);

  const rows = {};
  const run = async (key, spec) => {
    const [id, setup, runes, loadout, extra] = spec;
    const res = await page.evaluate(async ([key, id, setup, runes, loadout, extra, zoom, wantBreakdown, shotMode]) => {
      const { d, rt, scene, P, ef, acc, purge, r, cam } = window.__vc;
      if (shotMode) { let a = 0x1234abcd; Math.random = () => { a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
      const p = d.player;
      const sim = () => d.sim();
      const med = (a) => (a.length ? [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)] : 0);
      const mean = (a) => a.reduce((x, y) => x + y, 0) / (a.length || 1);
      for (const pid of window.__vcPeers || []) {
        const rr = scene.remotes.get(pid);
        if (rr) { rr.avatar.dispose(); rr.pet?.dispose(); scene.remotes.delete(pid); }
      }
      window.__vcPeers = [];
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
      p.barrier = 0;
      p.face(p.x, p.z - 5);
      p.runes = { ...(runes || {}) };
      d.forceMods(null);
      const NO = { main: null, mainTier: null, off: null, offTier: null, spellMult: 1, needleRangeMult: 1, needlePierce: 0, needleCadenceMult: 1, needleDamageMult: 1, needleWithered: 0, reap: false, exhumeRefund: 0, thrallBonus: 0, riteCooldownMult: 1, bellAllyHeal: 0, ...(loadout || {}) };
      p.loadout = NO;
      // Let the previous effect finish, then settle.
      d.advance(1.0);
      for (let i = 0; i < 40 && (ef.transientLoad > 0 || ef.additive.active + ef.smoke.active > 0 || ef.activeHandFields > 0); i++) d.advance(0.25, false);
      const mk = (n, dx, spread, def = 'robber') => {
        const list = [];
        for (let i = 0; i < n; i++) {
          const e = sim().spawnEnemy(def, 'graves', p.x + Math.sin(i * 2.4) * spread, p.z - dx + Math.cos(i * 2.4) * spread, false, false);
          e.hp = e.maxHp = 1e6;
          e.speed = 0;
          e.attackCd = 99;
          list.push(e);
        }
        return list;
      };
      const cast = (rite, t) => {
        p.essence = p.resource.max;
        p.cooldowns.clear();
        p.castUntil = 0;
        return ab.cast(rite, t, scene.now);
      };
      let list = [];
      if (setup === 'near') list = mk(4, 2, 0.8);
      if (setup === 'pack' || setup === 'pack1') list = mk(setup === 'pack1' ? 1 : 5, 5, setup === 'pack1' ? 0 : 1.3);
      if (setup === 'line') list = [...mk(1, 4.5, 0), ...mk(1, 6.5, 0), ...mk(1, 8, 0)];
      if (setup === 'pack') for (let i = 0; i < 3; i++) sim().addCorpse(p.x - 1.4 + i * 0.7, p.z - 3.4, 'normal', 'robber', false, 0, 1, 'graves');
      if (setup === 'corpses' || setup === 'thralls') for (let i = 0; i < 5; i++) sim().addCorpse(p.x + Math.sin(i * 1.7) * 1.4, p.z - 3 + Math.cos(i * 1.7) * 1.4, 'normal', 'robber', false, 0, 1, 'graves');
      if (setup === 'thralls') {
        const mine = () => [...sim().thralls.values()].filter((t) => t.owner === scene.selfId && t.state !== 'dead').length;
        for (let k = 0; k < 14 && mine() < 4; k++) {
          if (!sim().corpses.size) for (let i = 0; i < 3; i++) sim().addCorpse(p.x + Math.sin(i * 1.7) * 1.4, p.z - 3 + Math.cos(i * 1.7) * 1.4, 'normal', 'robber', false, 0, 1, 'graves');
          cast('exhume', { x: p.x, z: p.z - 3 });
          d.advance(0.3);
        }
        d.advance(1.8);
        mk(6, 5.5, 1.5);
        for (let i = 0; i < 4; i++) sim().addCorpse(p.x + 1.5 + i * 0.5, p.z + 1.4, 'normal', 'robber', false, 0, 1, 'graves');
        list = [...sim().enemies.values()];
        for (let i = 0; i < 40 && (ef.transientLoad > 0 || ef.additive.active + ef.smoke.active > 0); i++) d.advance(0.25, false);
      }
      if (extra && extra.mods) d.forceMods(extra.mods);
      const first = list[0];
      let target = first ? { x: first.x, z: first.z, enemyId: first.id } : { x: p.x, z: p.z - 4.5 };
      if (['bone_prison', 'grave_hands', 'bone_storm', 'miasma', 'plague_bloom', 'ossuary_wall', 'command_rend', 'dirge'].includes(id)) target = { x: p.x, z: p.z - 5 };

      const callsOf = () => {
        r.info.autoReset = false;
        r.info.reset();
        r.render(scene.scene, cam);
        const n = r.info.render.calls;
        r.info.autoReset = true;
        return n;
      };
      const gl = r.getContext();
      const renderMs = () => {
        const t0 = performance.now();
        r.render(scene.scene, cam);
        gl.finish();
        return performance.now() - t0;
      };
      const sample = () => {
        const c1 = callsOf();
        const rm1 = Math.min(renderMs(), renderMs());
        ef.group.visible = false;
        const c0 = callsOf();
        const rm0 = Math.min(renderMs(), renderMs());
        ef.group.visible = true;
        const f = P.fillStats(r, scene.scene, cam, ef);
        return { calls: c1 - c0, rend: rm1 - rm0, layers: f.layers, vis: f.visible, cover: f.covered, max: f.max, objs: f.objects, parts: ef.additive.active + ef.smoke.active, bb: ef.binbun.count, trans: ef.transientLoad, mats: P.fxMaterials(ef), programs: r.info.programs.filter((q) => !q.cacheKey.includes('fxprobe')).length, geos: r.info.memory.geometries, tex: r.info.memory.textures };
      };
      const frames = (s) => {
        const n = Math.round(s * 60);
        for (let i = 0; i < n; i++) d.advance(1 / 60, false);
      };

      let base = { parts: 0 };
      let baseFx = 0;
      let baseBb = 0;
      let stale = 0;
      if (!shotMode) {
        // Baseline: the scene as it stands (ambient braziers, waystones, persistent decals).
        acc.rec = true;
        acc.fx.length = 0;
        acc.bb.length = 0;
        frames(0.5);
        baseFx = mean(acc.fx);
        baseBb = mean(acc.bb);
        // Dead particles keep their last size in the ring buffers: measure that stale fill, then clear it so each scenario's delta is its own.
        const stale0 = P.fillStats(r, scene.scene, cam, ef).layers;
        purge();
        d.advance(1 / 60, false);
        base = sample();
        stale = Math.max(0, stale0 - base.layers);
        acc.fx.length = 0;
        acc.bb.length = 0;
      }

      let result = 'ok';
      const progs0 = P ? r.info.programs.filter((q) => !q.cacheKey.includes('fxprobe')).length : 0;
      const mats0 = P ? P.fxMaterials(ef) : 0;
      const geos0 = r.info.memory.geometries;
      const castT0 = performance.now();
      if (id === '@levelup') d.xp(1e6);
      else if (id === '@surge') d.surge();
      else if (id === '@loot') await d.dropGear(extra.item, 10, 'kill', extra.n);
      else if (id === '@boss') d.boss('prelate');
      else if (id === '@vfx') d.vfx(extra.id);
      else if (id === '@none') result = 'ok';
      else if (id === '@partner') {
        // Two partners cast the rotation: record the events our own casts raise, then replay them as theirs (real remote
        // players, so the handlers see another `by`/`owner`, exactly as a co-op client does).
        const peers = ['peerA', 'peerB'];
        peers.forEach((id2, i) => scene.addRemote({ id: id2, characterId: 900 + i, name: id2, classIndex: 2, x: p.x + (i ? 5 : -5), z: p.z - 2, facing: 0, moving: false, hpFrac: 1, gear: {} }));
        const seen = [];
        const he = scene.handleEvent.bind(scene);
        scene.handleEvent = (ev) => { seen.push(ev); he(ev); };
        for (const rite of extra.rotation) {
          cast(rite, rite === 'exhume' ? { x: p.x, z: p.z - 3 } : target);
          d.advance(0.2, false);
        }
        scene.handleEvent = he;
        for (let ef2 = 0; ef2 < 30 && (ef.transientLoad > 0 || ef.additive.active + ef.smoke.active > base.parts); ef2++) d.advance(0.25, false);
        window.__vcPeers = peers;
        let k = 0;
        for (const peer of peers) {
          const dx = k ? 5 : -5;
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
      } else result = cast(id, target);
      if (extra && extra.kill) for (const e of sim().enemies.values()) e.hp = 0;
      const castMs = performance.now() - castT0;
      if (shotMode) return { result };

      const samples = [];
      let t = 0;
      const fxFrames = [];
      for (const at of [0.12, 0.4, 0.9, 1.6]) {
        const n = Math.round((at - t) * 60);
        for (let i = 0; i < n; i++) {
          d.advance(1 / 60, false);
          if (t + (i + 1) / 60 <= 1.0) fxFrames.push(acc.fx[acc.fx.length - 1] ?? 0);
        }
        t = at;
        samples.push({ at, ...sample() });
      }
      acc.rec = false;
      const peak = (k) => Math.max(...samples.map((s) => s[k]));
      const cpu = mean(acc.fx.slice(0, 60)) - baseFx;
      const bbCpu = mean(acc.bb.slice(0, 60)) - baseBb;
      const last = samples[samples.length - 1];
      const out = {
        key,
        result,
        calls: peak('calls') - base.calls,
        layers: +(peak('layers') - base.layers).toFixed(3),
        cover: +(peak('cover') - base.cover).toFixed(3),
        max: peak('max'),
        parts: peak('parts') - base.parts,
        bb: peak('bb') - base.bb,
        trans: peak('trans') - base.trans,
        cpu: +cpu.toFixed(3),
        bbCpu: +bbCpu.toFixed(3),
        rend: +(Math.max(...samples.map((s) => s.rend)) - base.rend).toFixed(1),
        progs: last.programs - progs0,
        mats: last.mats - mats0,
        geos: last.geos - geos0,
        castMs: +castMs.toFixed(1),
        stale: +stale.toFixed(3),
        base: { calls: base.calls, layers: +base.layers.toFixed(3), parts: base.parts, bb: base.bb },
      };
      if (wantBreakdown) {
        // Re-cast at the peak moment? The effect is already past it; sample the breakdown at the last sample's state is too late, so
        // repeat the cast and measure at 0.4 s.
        for (let i = 0; i < 40 && (ef.transientLoad > base.trans || ef.additive.active + ef.smoke.active > base.parts); i++) d.advance(0.25, false);
        if (id.startsWith('@') && id !== '@vfx' && id !== '@none') out.breakdown = [];
        else {
          if (id === '@vfx') d.vfx(extra.id);
          else if (id !== '@none') cast(id, target);
          frames(0.4);
          out.breakdown = P.fillBreakdown(r, scene.scene, cam, ef, 6).map((b) => `${b.label} x${b.count} ${b.layers.toFixed(3)} (visible ${(100 * b.vis / Math.max(1e-6, b.layers)).toFixed(0)}%)`);
        }
      }
      return out;
    }, [key, id, setup, runes || null, loadout || null, extra || null, ZOOM, BREAKDOWN, SHOTONLY]);
    if (SHOTONLY) {
      let at = 0;
      for (const t of SHOT_AT) {
        // The 3-D canvas only (no HUD text), read back right after a render: comparable between builds and never blank.
        const url = await page.evaluate((s) => { for (let i = 0; i < Math.round(s * 60); i++) window.__cwDebug.advance(1 / 60, false); return window.__vc.rt.capture('image/png'); }, t - at);
        at = t;
        if (process.env.DM_QA_DUMP === '1') {
          console.log(JSON.stringify(await page.evaluate(() => {
            const ef = window.__vc.ef;
            const out = [];
            for (const [k, l] of ef.decalLayers) for (const it of l.items) if (it.opacity > 0.02) out.push(`${k.slice(0, 6)} r=${(it.sx / 2).toFixed(1)} op=${it.opacity.toFixed(2)} c=${it.color.getHexString()} @${it.x.toFixed(1)},${it.z.toFixed(1)}`);
            return { t: window.__cwDebug.player.x.toFixed(1) + ',' + window.__cwDebug.player.z.toFixed(1), decals: out, level: window.__cwDebug.sim()?.time };
          })));
        }
        fs.writeFileSync(path.join(OUT, `${TAG}-${key.replace(':', '_')}-${t}.png`), Buffer.from(url.split(',')[1], 'base64'));
      }
      console.log('shot', key, res.result);
      return;
    }
    rows[key] = res;
    console.log(JSON.stringify(res));
  };

  for (const [key, spec] of Object.entries(SCEN)) {
    if (ONLY.length && !ONLY.includes(key)) continue;
    try {
      await run(key, spec);
    } catch (e) {
      console.log('FAILED', key, String(e.message || e).split('\n')[0]);
      rows[key] = { key, result: 'error: ' + String(e.message || e).split('\n')[0] };
    }
  }

  let fight = null;
  if (process.env.DM_QA_NOFIGHT !== '1' && !SHOTONLY) {
    fight = await page.evaluate(async (secs) => {
      const { d, rt, scene, P, ef, acc, purge, r, cam } = window.__vc;
      const p = d.player;
      const sim = () => d.sim();
      const mean = (a) => a.reduce((x, y) => x + y, 0) / (a.length || 1);
      const pct = (a, q) => [...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * q))] ?? 0;
      for (const z of sim().zones.values()) z.until = -1;
      d.forceMods(null);
      p.runes = {};
      d.clear();
      d.teleport(-12, -4);
      d.advance(1.5);
      p.loadout = { main: null, mainTier: null, off: null, offTier: null, spellMult: 1, needleRangeMult: 1, needlePierce: 0, needleCadenceMult: 1, needleDamageMult: 1, needleWithered: 0, reap: false, exhumeRefund: 0, thrallBonus: 0, riteCooldownMult: 1, bellAllyHeal: 0 };
      p.hp = p.stats.maxHp;
      const cast = (rite, t) => {
        p.essence = p.resource.max;
        p.cooldowns.clear();
        p.castUntil = 0;
        return scene.abilities.cast(rite, t, scene.now);
      };
      for (let i = 0; i < 12; i++) sim().addCorpse(p.x + Math.sin(i) * 2, p.z + Math.cos(i) * 2, 'normal', 'robber', false, 0, 1, 'graves');
      for (let k = 0; k < 6; k++) { cast('exhume', { x: p.x, z: p.z }); d.advance(0.25); }
      d.advance(1.5);
      const ids = d.ring('robber', 30, 7);
      for (const id of ids) { const e = sim().enemies.get(id); if (e) e.hp = e.maxHp = 1e7; }
      d.advance(1.0);
      // Four disciplines' typical rotations back to back, one cast every 0.35 s, for `secs` seconds.
      const rot = ['bone_needle', 'marrow_spear', 'miasma', 'black_litany', 'corpse_explosion', 'wailing_skull', 'grave_frost', 'bone_prison', 'grave_hands', 'bone_storm', 'bone_mantle', 'dirge', 'plague_bloom', 'exhume', 'bone_fan', 'rot_lance', 'grave_offering', 'rally_dead', 'carrion_seed', 'ivory_cleave'];
      acc.rec = true;
      acc.fx.length = 0;
      acc.bb.length = 0;
      const samples = [];
      let peakParts = 0;
      let peakTrans = 0;
      let peakBb = 0;
      const idPeak = {};
      let partsPeak = 0;
      const gl = r.getContext();
      const stale0 = P.fillStats(r, scene.scene, cam, ef).layers;
      purge();
      d.advance(1 / 60, false);
      const staleFill = Math.max(0, stale0 - P.fillStats(r, scene.scene, cam, ef).layers);
      const calls0 = r.info.programs.filter((q) => !q.cacheKey.includes('fxprobe')).length;
      const mats0 = P.fxMaterials(ef);
      let n = 0;
      const frameTimes = [];
      const total = Math.round(secs * 60);
      for (let f = 0; f < total; f++) {
        if (f % 21 === 0) {
          for (let i = 0; i < 3; i++) sim().addCorpse(p.x + Math.sin(f + i) * 3, p.z + Math.cos(f + i) * 3, 'normal', 'robber', false, 0, 1, 'graves');
          const near = [...sim().enemies.values()].sort((a, b) => Math.hypot(a.x - p.x, a.z - p.z) - Math.hypot(b.x - p.x, b.z - p.z))[0];
          cast(rot[n++ % rot.length], near ? { x: near.x, z: near.z, enemyId: near.id } : { x: p.x, z: p.z - 5 });
        }
        d.advance(1 / 60, false);
        peakParts = Math.max(peakParts, ef.additive.active + ef.smoke.active);
        peakTrans = Math.max(peakTrans, ef.transientLoad);
        peakBb = Math.max(peakBb, ef.binbun.count);
        if (f % 20 === 0) {
          const h = {};
          for (const l of ef.binbun.live) if (!l.dead && l.inst) h[l.id] = (h[l.id] || 0) + 1;
          for (const [k, v] of Object.entries(h)) idPeak[k] = Math.max(idPeak[k] || 0, v);
          let parts = 0;
          for (const l of ef.binbun.live) if (!l.dead && l.inst) parts += l.inst.parts.length;
          partsPeak = Math.max(partsPeak, parts);
        }
        if (f % 60 === 30) {
          const c = (() => { r.info.autoReset = false; r.info.reset(); r.render(scene.scene, cam); const k = r.info.render.calls; r.info.autoReset = true; return k; })();
          ef.group.visible = false;
          const c0 = (() => { r.info.autoReset = false; r.info.reset(); r.render(scene.scene, cam); const k = r.info.render.calls; r.info.autoReset = true; return k; })();
          const t0 = performance.now(); r.render(scene.scene, cam); gl.finish(); const rm0 = performance.now() - t0;
          ef.group.visible = true;
          const t1 = performance.now(); r.render(scene.scene, cam); gl.finish(); const rm1 = performance.now() - t1;
          const fs = P.fillStats(r, scene.scene, cam, ef);
          samples.push({ calls: c - c0, layers: fs.layers, cover: fs.covered, max: fs.max, rend: rm1 - rm0 });
        }
      }
      acc.rec = false;
      const fightBreakdown = P.fillBreakdown(r, scene.scene, cam, ef, 12).map((b) => `${b.label} x${b.count} ${b.layers.toFixed(3)} (visible ${(100 * b.vis / Math.max(1e-6, b.layers)).toFixed(0)}%)`);
      // The aftermath: let everything expire, then what is the screen still paying for?
      for (let i = 0; i < 40 && (ef.transientLoad > 0 || ef.additive.active + ef.smoke.active > 0); i++) d.advance(0.25, false);
      const staleAfter = P.fillStats(r, scene.scene, cam, ef).layers;
      return {
        fightBreakdown,
        staleAfter: +staleAfter.toFixed(3),
        seconds: secs,
        staleBefore: +staleFill.toFixed(3),
        casts: n,
        calls: { mean: +mean(samples.map((s) => s.calls)).toFixed(1), max: Math.max(...samples.map((s) => s.calls)) },
        layers: { mean: +mean(samples.map((s) => s.layers)).toFixed(3), max: +Math.max(...samples.map((s) => s.layers)).toFixed(3) },
        cover: +mean(samples.map((s) => s.cover)).toFixed(3),
        maxStack: Math.max(...samples.map((s) => s.max)),
        rend: +mean(samples.map((s) => s.rend)).toFixed(1),
        cpu: { mean: +mean(acc.fx).toFixed(3), p95: +pct(acc.fx, 0.95).toFixed(3), max: +Math.max(...acc.fx).toFixed(3) },
        bbCpu: { mean: +mean(acc.bb).toFixed(3), p95: +pct(acc.bb, 0.95).toFixed(3) },
        peakParticles: peakParts,
        peakTransients: peakTrans,
        peakBinbun: peakBb,
        peakBinbunParts: partsPeak,
        binbunPeakById: Object.entries(idPeak).sort((a, b) => b[1] - a[1]).slice(0, 10).map(([k, v]) => `${k}:${v}`).join(' '),
        programsDelta: r.info.programs.filter((q) => !q.cacheKey.includes('fxprobe')).length - calls0,
        programs: r.info.programs.filter((q) => !q.cacheKey.includes('fxprobe')).length,
        materials: P.fxMaterials(ef),
        materialsDelta: P.fxMaterials(ef) - mats0,
        geometries: r.info.memory.geometries,
      };
    }, FIGHT_S);
    console.log('FIGHT', JSON.stringify(fight));
  }

  if (SHOTONLY) { await browser.close(); return; }
  const report = { tag: TAG, quality: QUALITY, rows, fight };
  fs.writeFileSync(path.join(OUT, `${TAG}-vfx-cost.json`), JSON.stringify(report, null, 2));
  // Ranked table (by fill, then calls).
  const list = Object.values(rows).filter((r) => r.calls !== undefined).sort((a, b) => b.layers - a.layers || b.calls - a.calls);
  const pad = (v, n) => String(v).padStart(n);
  console.log('\nscenario'.padEnd(26) + ['calls', 'layers', 'cover', 'max', 'parts', 'bb', 'trans', 'cpu', 'bbCpu', 'rend', 'progs', 'mats', 'stale'].map((h) => pad(h, 8)).join(''));
  for (const r of list) console.log(r.key.padEnd(25) + [r.calls, r.layers, r.cover, r.max, r.parts, r.bb, r.trans, r.cpu, r.bbCpu, r.rend, r.progs, r.mats, r.stale].map((v) => pad(v, 8)).join(''));
  const bad = errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource|403/.test(e));
  if (bad.length) console.log('page errors:', bad.slice(0, 5));
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
