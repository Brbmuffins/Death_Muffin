// Pixel metrics for QA screenshots: our own implementation of the idea in Majid Manzarpour's `computePixelMetrics`
// (MIT, threejs-game-skills): colour entropy, dominant-colour share, edge density, luminance contrast, blank/black detection.
// No image library is installed in the repo, so the PNG is decoded by Chromium: the buffer goes into a canvas on a blank page.
//
// Our palette is dark, so there are NO absolute brightness/contrast thresholds here. A zone is compared with its own stored
// baseline (tools/qa/baselines/pixel-metrics.json) and a regression is flagged only beyond a tolerance in the bad direction.
//
//   const pm = await createAnalyzer(browser);            // browser = a Playwright Browser
//   const m = await pm.analyze(fs.readFileSync(png));    // or a Buffer from page.screenshot()
//   const base = loadBaselines(); const r = compare(m, base.groups['zone-tour']?.[key]);
//   await pm.close();
const fs = require('node:fs');
const path = require('node:path');

const BASELINE_FILE = process.env.DM_QA_PIXEL_BASELINES || path.join(__dirname, '..', 'baselines', 'pixel-metrics.json');
const GRID_W = 160;
const GRID_H = 90;

// Runs in the page. Keep it dependency free.
function inPage({ b64, gw, gh }) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onerror = () => reject(new Error('could not decode image'));
    img.onload = () => {
      const c = document.createElement('canvas');
      c.width = gw; c.height = gh;
      const ctx = c.getContext('2d', { willReadFrequently: true });
      ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(img, 0, 0, gw, gh);
      const px = ctx.getImageData(0, 0, gw, gh).data;
      const n = gw * gh;
      const lum = new Float32Array(n);
      const bins = new Map();
      let sum = 0, sumSq = 0;
      for (let i = 0; i < n; i++) {
        const r = px[i * 4], g = px[i * 4 + 1], bl = px[i * 4 + 2];
        const l = 0.2126 * r + 0.7152 * g + 0.0722 * bl;
        lum[i] = l; sum += l; sumSq += l * l;
        const key = (r >> 4) << 8 | (g >> 4) << 4 | (bl >> 4); // 16 levels per channel
        bins.set(key, (bins.get(key) || 0) + 1);
      }
      let entropy = 0, dominant = 0;
      for (const v of bins.values()) { const p = v / n; entropy -= p * Math.log2(p); if (p > dominant) dominant = p; }
      const sorted = Float32Array.from(lum).sort();
      const q = (f) => sorted[Math.min(n - 1, Math.floor(f * (n - 1)))];
      const mean = sum / n;
      const std = Math.sqrt(Math.max(0, sumSq / n - mean * mean));
      let edges = 0;
      for (let y = 0; y < gh - 1; y++) for (let x = 0; x < gw - 1; x++) {
        const i = y * gw + x;
        if (Math.abs(lum[i] - lum[i + 1]) + Math.abs(lum[i] - lum[i + gw]) > 18) edges++;
      }
      resolve({
        colorEntropyBits: +entropy.toFixed(3),
        dominantColorShare: +dominant.toFixed(3),
        edgeDensity: +(edges / ((gw - 1) * (gh - 1))).toFixed(4),
        lumMean: +mean.toFixed(2),
        lumStd: +std.toFixed(2),
        lumP5: +q(0.05).toFixed(1),
        lumP95: +q(0.95).toFixed(1),
        contrast: +(q(0.95) - q(0.05)).toFixed(1),
      });
    };
    img.src = 'data:image/png;base64,' + b64;
  });
}

async function createAnalyzer(browser) {
  const page = await browser.newPage();
  await page.setContent('<!doctype html><title>pixel-metrics</title>');
  return {
    /** Metrics for a PNG/JPEG buffer, plus `blank` (no variation at all) and `black` (a black frame). */
    async analyze(buf) {
      const m = await page.evaluate(inPage, { b64: Buffer.from(buf).toString('base64'), gw: GRID_W, gh: GRID_H });
      m.black = m.lumP95 < 6 && m.lumMean < 3;
      m.blank = m.lumStd < 1.5 || m.colorEntropyBits < 0.25;
      return m;
    },
    close: () => page.close().catch(() => {}),
  };
}

// Tolerances in the BAD direction only (a drop in entropy / edges / contrast, a rise in the dominant share); mean luminance
// is checked both ways because a lighting change that doubles or halves the brightness is a regression either way.
// Screens with live enemies and particles are noisy, hence the generous defaults; tighten per call for static screens.
const DEFAULT_TOL = {
  colorEntropyBits: { abs: 0.6 },
  dominantColorShare: { abs: 0.12 },
  edgeDensity: { rel: 0.4, abs: 0.015 },
  contrast: { rel: 0.35, abs: 8 },
  lumMean: { rel: 0.4, abs: 6, both: true },
};
const BAD_UP = new Set(['dominantColorShare']);

/** Compare metrics with a stored baseline entry. Returns { status: 'ok'|'regression'|'new', flags: [...], notes: [...] }. */
function compare(m, base, tol = {}) {
  if (m.black) return { status: 'regression', flags: ['black frame'], notes: [] };
  if (m.blank) return { status: 'regression', flags: ['blank frame (no variation)'], notes: [] };
  if (!base) return { status: 'new', flags: [], notes: ['no baseline'] };
  const T = { ...DEFAULT_TOL, ...tol };
  const flags = [], notes = [];
  for (const [k, t] of Object.entries(T)) {
    const a = base[k], b = m[k];
    if (typeof a !== 'number' || typeof b !== 'number') continue;
    const allow = Math.max(t.abs ?? 0, (t.rel ?? 0) * Math.abs(a));
    const d = b - a;
    const bad = t.both ? Math.abs(d) > allow : BAD_UP.has(k) ? d > allow : -d > allow;
    if (bad) flags.push(`${k} ${a} -> ${b} (allowed +-${+allow.toFixed(3)})`);
    else if (!t.both && (BAD_UP.has(k) ? -d : d) > allow) notes.push(`${k} improved ${a} -> ${b}`);
  }
  return { status: flags.length ? 'regression' : 'ok', flags, notes };
}

function loadBaselines(file = BASELINE_FILE) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return { meta: {}, groups: {} }; }
}

/** Merge `entries` ({ key: metrics }) into group `group` and write the file. Only called with DM_QA_PIXELS_UPDATE=1. */
function saveBaselines(group, entries, meta = {}, file = BASELINE_FILE) {
  const all = loadBaselines(file);
  all.meta = { ...all.meta, ...meta, updated: new Date().toISOString().slice(0, 10), note: 'Per-zone baselines of our own screenshots (dark palette). Regenerate with DM_QA_PIXELS_UPDATE=1 after an intended look change.' };
  all.groups = all.groups || {};
  all.groups[group] = { ...(all.groups[group] || {}), ...entries };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(all, null, 1) + '\n');
}

/** Convenience for a smoke: analyse a list of { key, file | buffer }, compare, optionally update baselines, print and return rows. */
async function checkShots(browser, group, shots, { update = process.env.DM_QA_PIXELS_UPDATE === '1', tol, meta } = {}) {
  const pm = await createAnalyzer(browser);
  const base = loadBaselines().groups?.[group] || {};
  const rows = [], fresh = {};
  try {
    for (const s of shots) {
      let m;
      try { m = await pm.analyze(s.buffer || fs.readFileSync(s.file)); } catch (e) { rows.push({ key: s.key, status: 'error', flags: [String(e.message).slice(0, 120)], notes: [] }); continue; }
      const r = compare(m, base[s.key], tol);
      rows.push({ key: s.key, metrics: m, ...r });
      if (!m.black && !m.blank) fresh[s.key] = m;
    }
  } finally { await pm.close(); }
  if (update) saveBaselines(group, fresh, meta);
  return rows;
}

function printRows(rows) {
  for (const r of rows) console.log(`  pixels ${r.status.padEnd(10)} ${r.key}` + (r.metrics ? `  H=${r.metrics.colorEntropyBits} dom=${r.metrics.dominantColorShare} edge=${r.metrics.edgeDensity} lum=${r.metrics.lumMean} contrast=${r.metrics.contrast}` : '') + (r.flags.length ? '  !! ' + r.flags.join('; ') : ''));
}

module.exports = { createAnalyzer, compare, loadBaselines, saveBaselines, checkShots, printRows, DEFAULT_TOL, BASELINE_FILE };
