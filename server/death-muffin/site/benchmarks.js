// Benchmark history page. Everything from the API is player/client-supplied: it is only ever put in the page with textContent / setAttribute.
const CLASSES = { 1: 'Ossuary', 2: 'Gravecaller', 3: 'Mourner', 4: 'Rotweaver', 11: 'Reaper' };
const ROOMS = { graves: 'The Hollow Graves', warren: 'The Catacomb Warren', ossuary: 'The Marrow Ossuary', nave: 'The Drowned Nave', coliseum: 'The Bone Coliseum', sanctum: 'The Bell Sanctum', cloister: 'The Plague Cloister', pyre: 'The Cinder Pyre', fen: 'The Mourning Fen' };
const COLORS = ['#9b5cff', '#dcc38a', '#5ad1c4', '#ff7d7d', '#7fb4ff', '#e58bd8', '#9be37f', '#ffb066'];
// Compare panel: which direction is better. Metrics in neither list are shown without a colour.
const HIGHER_BETTER = new Set(['avg_fps', 'kills_per_min', 'kills']);
const LOWER_BETTER = new Set(['avg_ms', 'median_ms', 'p95_ms', 'p99_ms', 'worst_ms', 'hitches', 'draw_calls', 'objects', 'primitives', 'render_cpu_ms', 'render_gpu_ms', 'process_ms', 'physics_ms']);

const $ = (id) => document.getElementById(id);
const statusEl = $('bench-status');
const className = (i) => CLASSES[i] || 'Unknown';
const roomName = (r) => ROOMS[r] || r || '—';
const cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : '—');
const fmt = (v, d = 1) => (v == null || !Number.isFinite(v) ? '—' : v.toLocaleString(undefined, { maximumFractionDigits: d }));
const shortCpu = (c) => (c || '').replace(/\((R|TM)\)/gi, '').replace(/\b(CPU|Processor|with Radeon.*|@ .*)\b.*$/i, '').replace(/\s+/g, ' ').trim().slice(0, 28) || '—';
const dateOf = (r) => (r.ranAt || r.createdAt || '').slice(0, 10) || '—';
function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text != null) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}
function svg(tag, attrs, text) {
  const e = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, String(v));
  if (text != null) e.textContent = text;
  return e;
}

// Filter controls
function fillSelect(sel, pairs) {
  sel.replaceChildren(...pairs.map(([v, t]) => { const o = el('option', t); o.value = v; return o; }));
}
fillSelect($('f-room'), [['', 'Any'], ...Object.entries(ROOMS)]);
fillSelect($('f-class'), [['', 'Any'], ...Object.entries(CLASSES)]);

let runs = [];
let picked = [];   // ids ticked for compare, at most 2
let loadSeq = 0;

function query() {
  const q = new URLSearchParams({ limit: '1000' });
  const set = (k, v) => { if (v) q.set(k, v); };
  set('room', $('f-room').value); set('discipline', $('f-class').value); set('size', $('f-size').value); set('length', $('f-length').value);
  set('gpu', $('f-gpu').value.trim()); set('account', $('f-player').value.trim());
  if ($('f-standard').checked) q.set('standard', '1');
  if ($('f-flagged').checked) q.set('includeFlagged', '1');
  return q.toString();
}

async function load() {
  const seq = ++loadSeq;
  statusEl.textContent = 'Reading the benchmark ledger…';
  try {
    const response = await fetch(`api/benchmarks?${query()}`);
    const data = await response.json();
    if (seq !== loadSeq) return;
    if (!response.ok || !data.success) throw new Error(data.error || 'Could not load the benchmark history.');
    runs = Array.isArray(data.runs) ? data.runs : [];
    picked = [];
    statusEl.textContent = runs.length ? `${runs.length.toLocaleString()} run${runs.length === 1 ? '' : 's'}${runs.length >= 1000 ? ' (newest 1,000)' : ''}.` : 'No runs match these filters yet.';
    render();
  } catch (error) {
    if (seq !== loadSeq) return;
    statusEl.textContent = error instanceof Error ? error.message : 'Could not load the benchmark history.';
  }
}

function render() {
  renderChart();
  renderRows();
  renderCompare();
}

// ---- Trend chart ----
function renderChart() {
  const metric = document.querySelector('input[name="metric"]:checked').value;
  const key = metric === 'fps' ? 'avgFps' : 'p99Ms';
  const label = metric === 'fps' ? 'Average fps (higher is better)' : 'p99 frame ms (lower is better)';
  const chart = $('bench-chart');
  const legend = $('bench-legend');
  // Versions in order of first appearance (oldest run first); one series per PC.
  // Flagged runs (V-Sync capped, cancelled) are listed in the table but kept out of the trend.
  const oldestFirst = runs.filter((r) => r[key] != null && r.version && !r.flagged).slice().sort((a, b) => a.id - b.id);
  // Different setups never share a line: when the filters let several through, each line is one PC on one setup.
  const setupOf = (r) => `${roomName(r.room)}, ${className(r.discipline)}, ${cap(r.size)}, ${cap(r.length)}`;
  const mixed = new Set(oldestFirst.map(setupOf)).size > 1;
  const versions = [];
  const series = new Map();
  for (const r of oldestFirst) {
    if (!versions.includes(r.version)) versions.push(r.version);
    const name = `${r.gpu || 'Unknown GPU'} / ${shortCpu(r.cpu)}${mixed ? ` — ${setupOf(r)}` : ''}`;
    if (!series.has(name)) series.set(name, new Map());
    const byVersion = series.get(name);
    if (!byVersion.has(r.version)) byVersion.set(r.version, []);
    byVersion.get(r.version).push(r[key]);
  }
  legend.replaceChildren();
  if (!versions.length) {
    chart.replaceChildren(el('p', 'Nothing to chart yet.'));
    return;
  }
  const W = 720, H = 300, L = 54, R = 16, T = 14, B = 44;
  const all = [];
  const pts = [...series.entries()].map(([name, byVersion]) => ({ name, points: [...byVersion.entries()].map(([v, list]) => ({ v, y: list.reduce((a, b) => a + b, 0) / list.length, n: list.length })) }));
  for (const s of pts) for (const p of s.points) all.push(p.y);
  let lo = Math.min(...all), hi = Math.max(...all);
  if (lo === hi) { lo = Math.max(0, lo - 1); hi += 1; }
  const pad = (hi - lo) * 0.1;
  lo = Math.max(0, lo - pad); hi += pad;
  const x = (i) => (versions.length === 1 ? (L + W - R) / 2 : L + (i * (W - L - R)) / (versions.length - 1));
  const y = (val) => T + (1 - (val - lo) / (hi - lo)) * (H - T - B);
  const root = svg('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': label });
  for (let i = 0; i <= 4; i++) {
    const val = lo + ((hi - lo) * i) / 4;
    root.append(svg('line', { class: 'grid', x1: L, x2: W - R, y1: y(val), y2: y(val) }), svg('text', { x: L - 6, y: y(val) + 4, 'text-anchor': 'end' }, fmt(val, hi - lo < 10 ? 1 : 0)));
  }
  root.append(svg('line', { class: 'axis', x1: L, x2: L, y1: T, y2: H - B }), svg('line', { class: 'axis', x1: L, x2: W - R, y1: H - B, y2: H - B }));
  const step = Math.ceil(versions.length / 10);
  versions.forEach((v, i) => {
    if (i % step === 0 || i === versions.length - 1) root.append(svg('text', { x: x(i), y: H - B + 16, 'text-anchor': 'middle' }, v.length > 12 ? `${v.slice(0, 11)}…` : v));
  });
  root.append(svg('text', { x: L, y: H - 6 }, label));
  pts.forEach((s, si) => {
    const color = COLORS[si % COLORS.length];
    const coords = s.points.map((p) => [x(versions.indexOf(p.v)), y(p.y), p]);
    if (coords.length > 1) root.append(svg('polyline', { points: coords.map((c) => `${c[0]},${c[1]}`).join(' '), fill: 'none', stroke: color, 'stroke-width': 2 }));
    for (const [cx, cy, p] of coords) {
      const dot = svg('circle', { cx, cy, r: 4, fill: color });
      dot.append(svg('title', {}, `${s.name}\nVersion ${p.v}: ${fmt(p.y)}${metric === 'fps' ? ' fps' : ' ms'} (${p.n} run${p.n === 1 ? '' : 's'})`));
      root.append(dot);
    }
    const item = el('li');
    const swatch = el('i');
    swatch.style.background = color;
    item.append(swatch, document.createTextNode(s.name));
    legend.append(item);
  });
  chart.replaceChildren(root);
}

// ---- Table ----
function renderRows() {
  const body = $('bench-rows');
  const frag = document.createDocumentFragment();
  for (const r of runs) {
    const tr = document.createElement('tr');
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = picked.includes(r.id);
    box.disabled = !box.checked && picked.length >= 2;
    box.setAttribute('aria-label', `Compare run ${r.id}`);
    box.addEventListener('change', () => {
      picked = box.checked ? [...picked, r.id] : picked.filter((id) => id !== r.id);
      renderRows();
      renderCompare();
    });
    const first = el('td');
    first.append(box);
    tr.append(first);
    const gpuCell = el('td', `${r.gpu || '—'}${r.cpu ? ` · ${shortCpu(r.cpu)}` : ''}`);
    gpuCell.title = [r.gpu, r.cpu, r.cores ? `${r.cores} cores` : '', r.os, r.resolution].filter(Boolean).join(' · ');
    const flag = el('td');
    if (r.flagged) {
      const badge = el('span', r.flagReason === 'vsync' ? 'Vsync' : r.flagReason === 'cancelled' ? 'Cancelled' : 'Flagged', 'bench-badge');
      badge.title = r.flagReason === 'vsync' ? 'Frame rate was capped by vsync, so it does not compare' : r.flagReason === 'cancelled' ? 'The run was cancelled before it finished' : 'Left out of trends by default';
      flag.append(badge);
    }
    for (const cell of [el('td', dateOf(r)), el('td', r.username), el('td', r.version || '—'), gpuCell, el('td', roomName(r.room)), el('td', className(r.discipline)), el('td', cap(r.size)), el('td', cap(r.length)), el('td', cap(r.preset)),
      el('td', fmt(r.avgFps)), el('td', fmt(r.p95Ms)), el('td', fmt(r.p99Ms)), el('td', fmt(r.hitches, 0)), el('td', fmt(r.drawCalls, 0)), el('td', fmt(r.killsPerMin)), flag]) tr.append(cell);
    frag.append(tr);
  }
  body.replaceChildren(frag);
}

// ---- Compare ----
let compareSeq = 0;
async function fetchRun(id) {
  const response = await fetch(`api/benchmarks/${encodeURIComponent(id)}`);
  const data = await response.json();
  if (!response.ok || !data.success) throw new Error(data.error || 'Could not load that run.');
  return data.run;
}
async function renderCompare() {
  const box = $('bench-compare');
  const seq = ++compareSeq;
  if (picked.length !== 2) { box.hidden = true; box.replaceChildren(); return; }
  box.hidden = false;
  box.replaceChildren(el('p', 'Loading both runs…'));
  try {
    const [a, b] = await Promise.all(picked.map(fetchRun));
    if (seq !== compareSeq) return;
    box.replaceChildren(compareView(a, b));
  } catch (error) {
    if (seq === compareSeq) box.replaceChildren(el('p', error instanceof Error ? error.message : 'Could not load those runs.'));
  }
}
function describe(r) {
  return [`#${r.id} ${r.username}`, `${r.gpu || '?'} / ${shortCpu(r.cpu)}`, `v${r.version || '?'} ${cap(r.preset)}`, `${roomName(r.room)}, ${className(r.discipline)}, ${cap(r.size)} ${cap(r.length)}`];
}
function compareView(a, b) {
  const wrap = document.createElement('div');
  const table = document.createElement('table');
  const head = document.createElement('tr');
  head.append(el('th', 'Metric'));
  for (const r of [a, b]) {
    const th = el('th');
    for (const line of describe(r)) th.append(el('div', line));
    head.append(th);
  }
  head.append(el('th', 'Difference'));
  const thead = document.createElement('thead');
  thead.append(head);
  const tbody = document.createElement('tbody');
  const keys = [...new Set([...Object.keys(a.metrics || {}), ...Object.keys(b.metrics || {})])];
  for (const k of keys) {
    const va = a.metrics[k], vb = b.metrics[k];
    const tr = document.createElement('tr');
    const diff = el('td', '—');
    if (Number.isFinite(va) && Number.isFinite(vb) && va !== 0) {
      const pct = ((vb - va) / Math.abs(va)) * 100;
      diff.textContent = `${pct > 0 ? '+' : ''}${fmt(pct)}%`;
      if (Math.abs(pct) >= 0.05 && (HIGHER_BETTER.has(k) || LOWER_BETTER.has(k))) {
        const better = HIGHER_BETTER.has(k) ? pct > 0 : pct < 0;
        diff.className = better ? 'better' : 'worse';
      }
    }
    tr.append(el('td', k), el('td', fmt(va, 2)), el('td', fmt(vb, 2)), diff);
    tbody.append(tr);
  }
  table.append(thead, tbody);
  wrap.append(table);
  const toggle = el('button', 'Full report', 'about-button');
  toggle.type = 'button';
  const reports = el('div');
  reports.hidden = true;
  for (const r of [a, b]) {
    reports.append(el('h3', `Report for run #${r.id}`));
    reports.append(el('pre', r.report || '(no report)'));
  }
  toggle.addEventListener('click', () => { reports.hidden = !reports.hidden; });
  wrap.append(toggle, reports);
  return wrap;
}

// ---- Wiring ----
let timer = 0;
const later = () => { clearTimeout(timer); timer = setTimeout(load, 300); };
for (const id of ['f-room', 'f-class', 'f-size', 'f-length', 'f-standard', 'f-flagged']) $(id).addEventListener('change', load);
for (const id of ['f-gpu', 'f-player']) $(id).addEventListener('input', later);
for (const radio of document.querySelectorAll('input[name="metric"]')) radio.addEventListener('change', renderChart);
void load();
