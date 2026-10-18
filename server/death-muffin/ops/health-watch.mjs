#!/usr/bin/env node
// Watches the live Death Muffin services every minute (timer death-muffin-health-watch) and posts to #build-alerts when one goes down and
// when it comes back: the game server and its database, the public API through nginx and Cloudflare, the lobby, the UDP co-op relay and
// the client manifest the launchers download. A check must fail FAILS_TO_ALERT times in a row (2: two minutes) before it alerts, so a
// single blip stays quiet; while it stays down a reminder goes out every REMIND_MIN minutes (60). Nobody is mentioned. The state only
// changes after a post went out, so a failed post is retried on the next run.
//   health-watch.mjs [--dry-run]     --dry-run prints the message instead of posting it and keeps the state as it was
// Env (all optional): RUNTIME, HOOK_FILE, STATE, AUTH_URL, API_URL, LOBBY_URL, MANIFEST_URL, RELAY_UNIT (empty: skip the unit check),
// RELAY_PORT, FAILS_TO_ALERT, REMIND_MIN, NOW_MS (tests).
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const env = process.env;
const RUNTIME = env.RUNTIME || '/home/ubuntu/death-muffin';
const HOOK_FILE = env.HOOK_FILE || `${RUNTIME}/private/discord-build-alerts-webhook.url`;
const STATE = env.STATE || `${RUNTIME}/ops/state/health.json`;
const FAILS_TO_ALERT = Number(env.FAILS_TO_ALERT || 2);
const REMIND_MIN = Number(env.REMIND_MIN || 60);
const NOW = env.NOW_MS ? Number(env.NOW_MS) : Date.now();
const DRY = process.argv.includes('--dry-run');

async function getJson(url) {
  let r;
  try {
    r = await fetch(url, { signal: AbortSignal.timeout(8000), headers: { 'cache-control': 'no-cache' } });
  } catch (e) {
    throw new Error(`no answer (${e.cause?.code || e.name})`);
  }
  const text = await r.text();
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`not JSON: ${text.slice(0, 60)}`);
  }
}

const CHECKS = [
  {
    id: 'auth', name: 'Game server (accounts, saves, loot)', hint: 'sudo systemctl status death-muffin-auth',
    async run() {
      const j = await getJson(env.AUTH_URL || 'http://127.0.0.1:5190/api/health');
      if (j.status !== 'ok') throw new Error(`status ${j.status}`);
      if (j.db !== 'connected') throw new Error(`database ${j.db}`);
    },
  },
  {
    id: 'api', name: 'Public API (what players reach, through nginx and Cloudflare)', hint: 'the game server first, then nginx',
    async run() {
      const j = await getJson(env.API_URL || 'https://muffindevelopment.com/death-muffin/api/health');
      if (j.status !== 'ok') throw new Error(`status ${j.status}`);
    },
  },
  {
    id: 'lobby', name: 'Lobby (parties, friends online)', hint: 'sudo systemctl status deathmuffin-lobby',
    async run() {
      const j = await getJson(env.LOBBY_URL || 'http://127.0.0.1:5192/health');
      if (j.ok !== true) throw new Error('not ok');
    },
  },
  {
    id: 'relay', name: 'Co-op relay (UDP)', hint: 'sudo systemctl status deathmuffin-relay',
    async run() {
      const unit = env.RELAY_UNIT ?? 'deathmuffin-relay';
      const port = env.RELAY_PORT || '5193';
      if (unit) {
        try { execFileSync('systemctl', ['is-active', '--quiet', unit]); } catch { throw new Error(`${unit} is not running`); }
      }
      const out = execFileSync('ss', ['-Hlun', `sport = :${port}`], { encoding: 'utf8' });
      if (!out.trim()) throw new Error(`nothing listens on udp ${port}`);
    },
  },
  {
    id: 'downloads', name: "Game download (the launcher's client manifest)", hint: 'the manifest in /var/www/death-muffin/client/, then nginx',
    async run() {
      const j = await getJson(env.MANIFEST_URL || 'https://muffindevelopment.com/death-muffin/client/manifest.json');
      if (!j.version) throw new Error('the manifest has no version');
    },
  },
];

function loadState() {
  try { return JSON.parse(readFileSync(STATE, 'utf8')); } catch { return {}; }
}
function saveState(s) {
  mkdirSync(path.dirname(STATE), { recursive: true });
  writeFileSync(`${STATE}.tmp`, `${JSON.stringify(s, null, 1)}\n`);
  renameSync(`${STATE}.tmp`, STATE);
}
const clock = (ms) => new Date(ms).toISOString().slice(11, 16);
const mins = (ms) => Math.max(1, Math.round(ms / 60000));

const before = loadState();
const results = await Promise.all(CHECKS.map(async (c) => {
  try { await c.run(); return { c, ok: true }; } catch (e) { return { c, ok: false, why: String(e.message || e).slice(0, 140) }; }
}));

// Each check's next state if the post goes out (`sent`), and if it does not (`kept`): a failed post leaves the alert to the next run.
const lines = [];
const sent = {};
const kept = {};
for (const { c, ok, why } of results) {
  const s = { fails: 0, since: 0, alerted: false, remindedAt: 0, ...(before[c.id] || {}) };
  if (ok) {
    sent[c.id] = { fails: 0, since: 0, alerted: false, remindedAt: 0 };
    kept[c.id] = s.alerted ? s : sent[c.id];
    if (s.alerted) lines.push(`✅ **${c.name}** is back, after ${mins(NOW - s.since)} min down.`);
    continue;
  }
  const fails = s.fails + 1;
  const since = s.since || NOW;
  const n = { ...s, fails, since, why };
  sent[c.id] = n;
  kept[c.id] = n;
  if (!s.alerted && fails >= FAILS_TO_ALERT) {
    lines.push(`🔴 **${c.name}** is down: ${why}. Since ${clock(since)} UTC. Check: \`${c.hint}\``);
    sent[c.id] = { ...n, alerted: true, remindedAt: NOW };
  } else if (s.alerted && NOW - s.remindedAt >= REMIND_MIN * 60000) {
    lines.push(`⏳ **${c.name}** is still down after ${mins(NOW - since)} min: ${why}.`);
    sent[c.id] = { ...n, remindedAt: NOW };
  }
}
for (const { c, ok, why } of results) if (!ok) console.log(`health: ${c.id} failing (${why})`);

if (DRY) {
  console.log(lines.length ? lines.join('\n') : 'health: nothing to post');
} else if (!lines.length) {
  saveState(sent);
} else {
  let posted = false;
  try {
    const hook = readFileSync(HOOK_FILE, 'utf8').trim();
    const r = await fetch(hook, {
      method: 'POST',
      signal: AbortSignal.timeout(15000),
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'Death Muffin Alerts', allowed_mentions: { parse: [] }, content: lines.join('\n').slice(0, 1900) }),
    });
    posted = r.ok;
    if (!r.ok) console.log(`health: the #build-alerts post failed (HTTP ${r.status}); retrying next run`);
  } catch (e) {
    console.log(`health: the #build-alerts post failed (${e.message}); retrying next run`);
  }
  saveState(posted ? sent : kept);
  if (posted) console.log(`health: posted\n${lines.join('\n')}`);
}
