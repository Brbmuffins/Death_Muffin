// Shared helpers for the first-hour audit and smoke: virtual UI timers (so counsel cards, toasts and banners age with GAME time
// while __cwDebug.advance steps the sim), an event recorder over the HUD, and an overlap detector for HUD elements.
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

// Installed before the app loads: timers of 200 ms or more run on a clock we advance by hand.
const VIRTUAL_TIMERS = () => {
  const real = { st: window.setTimeout.bind(window), ct: window.clearTimeout.bind(window) };
  let now = 0, seq = 1;
  const q = new Map();
  window.__vt = {
    now: () => now,
    run(ms) {
      const end = now + ms;
      for (;;) {
        let best = null;
        for (const [id, t] of q) if (t.at <= end && (!best || t.at < best.at || (t.at === best.at && id < best.id))) best = { id, at: t.at };
        if (!best) break;
        const t = q.get(best.id); q.delete(best.id);
        now = Math.max(now, t.at);
        try { t.fn(...t.args); } catch (e) { console.error('vt', e && e.message); }
      }
      now = end;
    },
  };
  window.setTimeout = (fn, ms = 0, ...args) => {
    if (typeof fn !== 'function' || ms < 200) return real.st(fn, ms, ...args);
    const id = 1e9 + seq++;
    q.set(id, { at: now + ms, fn, args, id });
    return id;
  };
  window.clearTimeout = (id) => { if (q.has(id)) q.delete(id); else real.ct(id); };
  globalThis.setTimeout = window.setTimeout;
  globalThis.clearTimeout = window.clearTimeout;
};

// The HUD pieces a player can see. Each entry: [name, selector for the element, visibility predicate runs in page].
const WATCH = [
  ['tip', '.cw-tip:not(.out)'],
  ['dialogue', '.cw-dialogue'],
  ['next', '[data-next]:not([hidden])'],
  ['toast', '.hud-toast'],
  ['banner', '[data-banner].show'],
  ['prompt', '[data-prompt]:not([hidden])'],
  ['hint', '[data-hint]'],
  ['omen', '[data-omen]:not([hidden])'],
  ['chain', '[data-chain]:not([hidden])'],
  ['party', '[data-party]'],
  ['minimap', '[data-mapframe]'],
  ['area', '[data-area]'],
  ['prog', '[data-prog]'],
  ['menu', '.hud-menu'],
  ['upgrades', '.hud-upgrades'],
  ['currency', '.hud-currency'],
  ['altar', '.hud-altar'],
  ['xpbar', '.hud-xp'],
  ['target', '[data-target]:not([hidden])'],
  ['brews', '[data-brews]:not([hidden])'],
  ['ward', '[data-ward]:not([hidden])'],
  ['boss', '[data-boss]:not([hidden])'],
  ['death', '[data-death]:not([hidden])'],
  ['panel', '.cw-panel-float, .cw-panel, .cw-modal'],
];

const IN_PAGE = (WATCH_ARG) => {
  const WATCH = WATCH_ARG;
  const rectOf = (el) => {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.35) return null;
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return null;
    if (!(el.textContent || '').trim() && !el.querySelector('img,canvas')) return null;
    return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
  };
  window.__fhEvents = [];
  window.__fhGt = 0;
  const live = new Map();
  const labelOf = (name, el) => {
    if (name === 'tip') return (el.querySelector('.title')?.textContent || '').trim();
    if (name === 'next') return (el.querySelector('[data-nexttxt]')?.textContent || '').trim();
    if (name === 'banner') return ((el.querySelector('.t')?.textContent || '') + ' / ' + (el.querySelector('.s')?.textContent || '')).trim();
    if (name === 'dialogue') return (el.querySelector('.nm')?.textContent || '').trim();
    if (name === 'panel') return (el.className + ' ' + (el.querySelector('h1,h2,h3,.title,.hd')?.textContent || '')).trim().slice(0, 60);
    return (el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 110);
  };
  window.__fhScan = () => {
    const seen = new Set();
    for (const [name, sel] of WATCH) {
      if (['party', 'minimap', 'area', 'prog', 'menu', 'upgrades', 'currency', 'altar', 'xpbar'].includes(name)) continue;
      document.querySelectorAll(sel).forEach((el, i) => {
        if (!rectOf(el)) return;
        const label = labelOf(name, el);
        if (name === 'hint' && !label) return;
        const key = name + '|' + label;
        seen.add(key);
        if (!live.has(key)) { live.set(key, window.__fhGt); window.__fhEvents.push({ t: +window.__fhGt.toFixed(1), ev: 'on', name, label }); }
      });
    }
    for (const [key, t0] of [...live]) if (!seen.has(key)) { live.delete(key); const [name, ...rest] = key.split('|'); window.__fhEvents.push({ t: +window.__fhGt.toFixed(1), ev: 'off', name, label: rest.join('|'), dur: +(window.__fhGt - t0).toFixed(1) }); }
  };
  window.__fhRects = () => {
    const out = [];
    for (const [name, sel] of WATCH) {
      document.querySelectorAll(sel).forEach((el) => {
        const r = rectOf(el);
        if (r) out.push({ name, label: labelOf(name, el).slice(0, 40), kind: el.dataset ? el.dataset.kind : undefined, ...r });
      });
    }
    return out;
  };
};

// Pairs that overlap by more than a sliver. Containers that legitimately wrap other things are excluded by the caller.
function overlaps(rects, ignore = []) {
  const bad = [];
  for (let i = 0; i < rects.length; i++) for (let j = i + 1; j < rects.length; j++) {
    const a = rects[i], b = rects[j];
    if (a.name === b.name && a.name !== 'tip') continue;
    const key = [a.name, b.name].sort().join('+');
    if (ignore.includes(key)) continue;
    const ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    const oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
    if (ox > 6 && oy > 6) bad.push({ a: `${a.name}:${a.label}`, b: `${b.name}:${b.label}`, ox, oy, ra: a, rb: b });
  }
  return bad;
}

async function launch(viewport = { width: 1280, height: 800 }, opts = {}) {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
  page.on('response', (r) => { if (r.status() >= 400 && !/\/node_modules\/@fontsource\//.test(r.url())) errors.push(`HTTP ${r.status()} ${r.url()}`); });
  await page.addInitScript(VIRTUAL_TIMERS);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5343/?offline');
  return { browser, page, errors };
}

async function newCharacter(page, discipline, name) {
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', name || `fh_${Date.now() % 100000}`);
  await page.fill('#cw-email', 'fh@example.invalid');
  await page.fill('#cw-pass', 'TestingFirstHour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: discipline }).first().click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: Number(process.env.DM_LOAD_MS || 90000) });
  await page.evaluate(IN_PAGE, WATCH);
  // From here the game runs only when we step it, and every clock the game reads is the same virtual one: a slow machine must not
  // make a counsel card age faster than the game seconds it is shown for.
  // Math.random is seeded too (DM_QA_SEED, default 7): drops and spawns vary per run otherwise, and a toast that lands on a banner
  // in one run and not in the next made this check flaky. With the virtual clocks the whole hour is reproducible.
  await page.evaluate((seed) => {
    window.requestAnimationFrame = () => 0;
    const base = performance.now();
    performance.now = () => base + window.__vt.now();
    let a = seed | 0;
    Math.random = () => { a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }, Number(process.env.DM_QA_SEED || 7));
}

// Step the game and the UI timers together in 0.5 s slices, one browser round trip per slice. onSlice gets {gt, n, rects}.
async function step(page, seconds, onSlice, slice = 0.5) {
  for (let t = 0; t < seconds - 1e-6; t += slice) {
    const dt = Math.min(slice, seconds - t);
    const info = await page.evaluate((d) => {
      window.__cwDebug.advance(d, false); window.__vt.run(d * 1000); window.__fhGt += d; window.__fhScan();
      return { gt: window.__fhGt, n: window.__fhEvents.length, rects: window.__fhRects() };
    }, dt);
    if (onSlice) await onSlice(info);
  }
}

module.exports = { WATCH, VIRTUAL_TIMERS, overlaps, launch, newCharacter, step };
