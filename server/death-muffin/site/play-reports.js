// Play reports page. Everything from the API is player/client-supplied: it is only ever put in the page with textContent.
const AREAS = {
  chapterhouse: 'The Chapterhouse', acre: "The Sexton's Acre", alchemist_wing: "The Alchemist's Wing", graves: 'The Hollow Graves', warren: 'The Catacomb Warren', ossuary: 'The Marrow Ossuary',
  nave: 'The Drowned Nave', coliseum: 'The Bone Coliseum', depths: 'The Catacomb Depths', sanctum: 'The Bell Sanctum', cloister: 'The Plague Cloister', pyre: 'The Cinder Pyre', fen: 'The Mourning Fen',
};
const PRESETS = { low: 'Low', medium: 'Medium', high: 'High', ultra: 'Ultra', custom: 'Custom', unknown: 'Unknown' };
const REASONS = { quit: 'Quit the game', logout: 'Logged out', switch: 'Switched character', crash: 'Crashed', disconnect: 'Lost the connection', unknown: 'Unknown' };

const $ = (id) => document.getElementById(id);
const statusEl = $('reports-status');
const fmt = (v, d = 1) => (v == null || !Number.isFinite(v) ? '—' : v.toLocaleString(undefined, { maximumFractionDigits: d }));
const fps = (ms) => (ms > 0 ? fmt(1000 / ms, 0) : '—');
const areaName = (id) => AREAS[id] || id;
const plural = (n, word) => `${n.toLocaleString()} ${word}${n === 1 ? '' : 's'}`;
function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text != null) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}

/** Fill a table body: `rows` is a list of cell lists; a cell is text, or [text, 'num'] for a right-aligned number. */
function fillRows(id, rows, columns) {
  const body = $(id);
  if (!rows.length) {
    const td = el('td', 'Nothing yet.');
    td.colSpan = columns;
    const tr = document.createElement('tr');
    tr.append(td);
    body.replaceChildren(tr);
    return;
  }
  const frag = document.createDocumentFragment();
  for (const cells of rows) {
    const tr = document.createElement('tr');
    for (const cell of cells) tr.append(Array.isArray(cell) ? el('td', cell[0], cell[1]) : el('td', cell));
    frag.append(tr);
  }
  body.replaceChildren(frag);
}
const num = (v, d = 1) => [fmt(v, d), 'num'];

let loadSeq = 0;

async function getJson(path) {
  const response = await fetch(path);
  const data = await response.json();
  if (!response.ok || !data.success) throw new Error(data.error || 'Could not load the play reports.');
  return data;
}

async function loadReleases() {
  try {
    const { releases } = await getJson('api/play-reports/releases');
    const select = $('r-version');
    if (!Array.isArray(releases) || !releases.length) {
      statusEl.textContent = 'No play reports have come in yet.';
      $('reports-body').hidden = true;
      select.replaceChildren();
      return;
    }
    select.replaceChildren(...releases.map((r) => {
      const o = el('option', `${r.version} (${plural(r.reports, 'session')}, ${plural(r.players, 'player')})`);
      o.value = r.version;
      return o;
    }));
    const wanted = new URLSearchParams(location.search).get('version');
    if (wanted && releases.some((r) => r.version === wanted)) select.value = wanted;
    await loadSummary();
  } catch (error) {
    statusEl.textContent = error instanceof Error ? error.message : 'Could not load the play reports.';
  }
}

async function loadSummary() {
  const version = $('r-version').value;
  if (!version) return;
  const seq = ++loadSeq;
  statusEl.textContent = 'Reading the play reports…';
  try {
    const { summary } = await getJson(`api/play-reports/summary?version=${encodeURIComponent(version)}`);
    if (seq !== loadSeq) return;
    render(summary);
    statusEl.textContent = summary.reports ? `Release ${summary.version}: ${plural(summary.reports, 'session')} from ${plural(summary.players, 'player')}.` : `No play reports for release ${summary.version}.`;
  } catch (error) {
    if (seq !== loadSeq) return;
    $('reports-body').hidden = true;
    statusEl.textContent = error instanceof Error ? error.message : 'Could not load the play reports.';
  }
}

function render(s) {
  $('reports-body').hidden = !s.reports;
  if (!s.reports) return;
  $('r-truncated').hidden = !s.truncated;
  const facts = [[s.reports.toLocaleString(), 'Sessions'], [s.players.toLocaleString(), 'Players'], [fmt(s.hours), 'Hours played'], [fmt(s.medianMinutes, 0), 'Minutes, typical session'], [fmt(s.averageMinutes, 0), 'Minutes, average session']];
  $('r-facts').replaceChildren(...facts.map(([value, label]) => {
    const box = el('div', null, 'reports-fact');
    box.append(el('b', value), el('span', label));
    return box;
  }));
  fillRows('r-presets', s.presets.map((p) => [PRESETS[p.preset] || p.preset, num(p.reports, 0), num(p.avgMs, 2), [fps(p.avgMs), 'num'], num(p.p99Ms, 1), num(p.worstMedianMs, 0), num(p.hitchesPerHour, 1)]), 7);
  fillRows('r-gpus', s.gpus.map((g) => [g.gpu, num(g.reports, 0), num(g.avgMs, 2), [fps(g.avgMs), 'num'], num(g.p99Ms, 1)]), 5);
  const share = (count) => [`${fmt((count / s.reports) * 100, 0)}%`, 'num'];
  fillRows('r-reasons', s.endReasons.map((r) => [REASONS[r.reason] || r.reason, num(r.count, 0), share(r.count)]), 3);
  fillRows('r-end-areas', s.endAreas.map((a) => [areaName(a.area), num(a.count, 0), share(a.count)]), 3);
  fillRows('r-areas', s.areas.map((a) => [areaName(a.area), num(a.hours, 1), num(a.deaths, 0), num(a.deathsPerHour, 1), num(a.avgMs, 2)]), 5);
  renderServer(s.server);
}

function renderServer(v) {
  const note = $('r-server-note');
  if (!v || !v.sessions) {
    note.textContent = 'These come from the game\'s own server, not from players\' PCs. No party session is named by these reports yet.';
    fillRows('r-server', [], 3);
    return;
  }
  note.textContent = `These come from the game's own server, not from players' PCs. It adds up what each party member earned in the ${plural(v.sessions, 'party session')} these reports name: ${fmt(v.hours)} player-hours, `
    + 'counting each member from joining to leaving. XP and gold are what their progress saves paid. Drops are not counted: the server does not record which session a drop came from.';
  fillRows('r-server', [
    ['XP', num(v.xp, 0), num(v.xpPerHour, 0)],
    ['Gold', num(v.gold, 0), num(v.goldPerHour, 0)],
    ['Kills', num(v.kills, 0), num(v.killsPerHour, 1)],
    ['Boss kills', num(v.bosses, 0), num(v.bossesPerHour, 1)],
    ['Drops', ['—', 'num'], num(v.dropsPerHour, 1)],
  ], 3);
}

$('r-version').addEventListener('change', loadSummary);
void loadReleases();
