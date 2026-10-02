// Shared helpers for the browser smokes. Keep this small: scripts stay readable on their own.
const SWIFTSHADER_ARGS = ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'];

/** Console/response noise that is not a game bug: the favicon, an offline realtime socket, and `@fontsource` 403s
 *  (Vite refuses to serve fonts when node_modules is a symlink that points outside the Vite root). */
const BENIGN_URL = /\/node_modules\/@fontsource\/|favicon/;
const BENIGN_TEXT = /favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|@fontsource/;

/** True when an error string or URL is known noise. */
function isBenign(text) { return BENIGN_TEXT.test(text || ''); }

/**
 * Collect page errors into `errors` (an array), ignoring the benign set above. Chromium's generic console line
 * "Failed to load resource: ... 403" carries no URL in its text, so it is judged by the message location.
 * Returns `{ errors, bad }`; `bad` is a Set of "status url" for every response >= 400 outside the benign set
 * (kept separate on purpose: scripts that care can assert on it, the rest only see real console/page errors).
 */
function watchErrors(page, errors = []) {
  const bad = new Set();
  page.on('pageerror', (e) => { if (!isBenign(e.message)) errors.push(e.message); });
  page.on('crash', () => errors.push('PAGE CRASHED (renderer process died; usually memory or GPU pressure on a loaded box)'));
  page.on('console', (m) => {
    if (m.type() !== 'error') return;
    const url = m.location()?.url || '';
    if (BENIGN_URL.test(url) || isBenign(m.text())) return;
    errors.push(m.text());
  });
  page.on('response', (r) => { if (r.status() >= 400 && !BENIGN_URL.test(r.url())) bad.add(`${r.status()} ${r.url()}`); });
  return { errors, bad };
}

/**
 * Preload app modules a QA script needs onto `window.__qaMods` and wait for them. Doing the dynamic `import()`
 * inside a long async `page.evaluate` is what produced Playwright's "Resulting promise was garbage collected" on a
 * loaded machine; here the evaluate returns at once and the wait is an explicit poll, so later evaluates stay
 * synchronous. Always loaded: `runtime` (GameRuntime) and `devAccess` (module). `extra` maps more names to
 * `/src/...` paths. Call after the world is up. In the page:
 *   const { runtime, devAccess } = window.__qaMods; const scene = runtime.getRuntime().view; devAccess.devAccess.active = true;
 */
async function preloadModules(page, extra = {}, timeout = 120000) {
  const mods = { runtime: '/src/app/GameRuntime.ts', devAccess: '/src/gameplay/devAccess.ts', ...extra };
  await page.evaluate((mods) => {
    if (window.__qaMods || window.__qaModsLoading) return;
    window.__qaModsLoading = true;
    Promise.all(Object.entries(mods).map(([k, p]) => import(/* @vite-ignore */ p).then((m) => [k, m])))
      .then((all) => { window.__qaMods = Object.fromEntries(all); })
      .catch((e) => { window.__qaModsError = String(e); });
  }, mods);
  await page.waitForFunction(() => window.__qaMods || window.__qaModsError, null, { timeout });
  const err = await page.evaluate(() => window.__qaModsError || null);
  if (err) throw new Error('preloadModules failed: ' + err);
}

/** Retry `fn` when Playwright reports the known load-dependent evaluate failures (never for assertion errors). */
async function retryTransient(fn, tries = 3) {
  for (let i = 0; ; i++) {
    try { return await fn(); } catch (e) {
      if (i >= tries - 1 || !/garbage collected|Execution context was destroyed|Target closed|Timeout .* exceeded/.test(String(e && e.message))) throw e;
    }
  }
}

/** Screenshot with retries: on a loaded box `page.screenshot` can time out while the page is healthy. */
async function shot(page, file, opts = {}) {
  return retryTransient(() => page.screenshot({ path: file, timeout: 60000, ...opts }), 4);
}

/** Wait until `fn` (run in the page, with `arg`) returns truthy; advances the game clock between polls so waiting never depends on rAF. */
async function waitGame(page, fn, arg, { timeout = 60000, step = 0.25 } = {}) {
  const t0 = Date.now();
  for (;;) {
    const v = await page.evaluate(fn, arg);
    if (v) return v;
    if (Date.now() - t0 > timeout) throw new Error('waitGame timed out: ' + String(fn).slice(0, 120));
    await page.evaluate((s) => window.__cwDebug.advance(s), step);
  }
}

module.exports = { SWIFTSHADER_ARGS, isBenign, watchErrors, preloadModules, retryTransient, shot, waitGame };
