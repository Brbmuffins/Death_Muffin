'use strict';
/**
 * Server-decided drops (server authority Phase 1, DECISIONS B20). The client never names what dropped: each character has a "tape" per
 * drop kind (kill, elite, boss, surge), one secret-derived seed per event. The client is handed the next seeds ahead of time and rolls an
 * event the instant it happens (DmLoot.roll_event, so drops still appear at once); picking a drop up is a claim, and the server rolls the same
 * event from the same seed (gathering/loot-rules.cjs rollEvent, proven equal to the client by the loot parity fixture) and grants exactly
 * what it rolled, once. Facts the server knows it takes from its own records (discipline, character level, owned legendaries, owned runes);
 * the rest it bounds (the ground is open or the party carries you, Wave Speed owned, fortune, rising rune chance, first boss kills, a surge
 * rate), and every kind's tape is spent no faster than the kill ledger's accepted kills (and bosses) since the tape began.
 *
 *   POST /api/drops/tape  { characterId, next?: { kind: index } } -> { data: { mode, tape: { kind: { from, seeds: [[w, w, w, w], ...] } } } }
 *   POST /api/drops/claim { characterId, kind, n, index, facts, expect?, sessionId? } -> { data: { item, bag } }
 *
 * DROPS_MODE=enforce (the default, drops-mode.cjs) rolls with the bound and refuses a claim that breaks one; DROPS_MODE=audit logs it
 * (progress_audit `drop_*`) and lets the claim through, rolled with the client's value up to the hard limits (audit never changes what
 * dropped). Migrations 047, 049.
 */
const crypto = require('crypto');
const rules = require('./gathering/loot-rules.cjs');
const killRules = require('./gathering/kill-rules.cjs');
const gather = require('./gathering/gathering-rules.cjs');
const { audit, necroSummary } = require('./authority.cjs');
const store = require('./loot-instances.cjs');
const { INV_SELECT } = require('./bag-store.cjs');
const { LIMITS } = require('./party-sessions.cjs');

const BAG = gather.BAG_SLOTS;
const AHEAD = { kill: 128, elite: 48, boss: 6, surge: 6, floor: 8, chest: 4 };
const SLACK = { kills: 60, bosses: 2, floors: 3 };   // claims may come before the kill report that backs them (reports flush every few seconds)
const DEPTH_SLACK = 1;   // a floor's drop may be claimed just before the report that proves the floor
const SURGE_GAP_MS = 20_000;
const MAX_FORTUNE = 0.3;                   // the strongest fortune brew (reagents.ts: fortune <= +30%)
const DIFFICULTIES = new Set(['easy', 'medium', 'hard']);
const SESSION_RE = /^[0-9a-f]{32}$/;

const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
const int = (v) => (Number.isInteger(Number(v)) ? Number(v) : NaN);
const parse = (v, d) => {
  if (v == null) return d;
  try { return typeof v === 'string' ? JSON.parse(v) : v; } catch { return d; }
};
const { dropsMode } = require('./drops-mode.cjs');
const playerError = (message, status = 400) => Object.assign(new Error(message), { player: true, status });

/** The tape's secret, derived from the JWT secret (no new secret to keep). */
function tapeKey(env = process.env) {
  if (!env.JWT_SECRET) throw new Error('JWT_SECRET is required for the drop tape');
  return crypto.createHmac('sha256', String(env.JWT_SECRET)).update('dm-drop-tape-v1').digest();
}
/** Event `n` of `kind` for a character: four 32-bit words (the client gets them from /tape; the server re-derives them on a claim). */
function seedFor(key, characterId, kind, n) {
  const h = crypto.createHmac('sha256', key).update(`${characterId}|${kind}|${n}`).digest();
  return [h.readUInt32LE(0), h.readUInt32LE(4), h.readUInt32LE(8), h.readUInt32LE(12)];
}

async function ledgerTotals(conn, characterId) {
  try {
    const [[r]] = await conn.execute('SELECT kills_total, bosses_total, floors_total, depth_proved FROM character_kill_ledger WHERE character_id = ?', [characterId]);
    return r ? { known: true, kills: num(r.kills_total), bosses: num(r.bosses_total), floors: num(r.floors_total), depth: num(r.depth_proved) }
      : { known: false, kills: 0, bosses: 0, floors: 0, depth: 0 };
  } catch {
    return { known: false, kills: 0, bosses: 0, floors: 0, depth: 0 };
  }
}

async function loadTape(conn, characterId) {
  const sel = 'SELECT issued, spent, base_kills, base_bosses, base_floors, last_rune_elite, last_surge_at FROM character_drop_tape WHERE character_id = ? FOR UPDATE';
  let [[row]] = await conn.execute(sel, [characterId]);
  if (!row) {
    const t = await ledgerTotals(conn, characterId);
    await conn.execute('INSERT IGNORE INTO character_drop_tape (character_id, issued, spent, base_kills, base_bosses, base_floors) VALUES (?, ?, ?, ?, ?, ?)', [characterId, '{}', '{}', t.kills, t.bosses, t.floors]);
    [[row]] = await conn.execute(sel, [characterId]);
  }
  return {
    issued: parse(row.issued, {}) || {}, spent: parse(row.spent, {}) || {}, baseKills: num(row.base_kills), baseBosses: num(row.base_bosses), baseFloors: num(row.base_floors),
    lastRuneElite: num(row.last_rune_elite, -1), lastSurgeAt: num(row.last_surge_at),
  };
}

async function saveTape(conn, characterId, t) {
  await conn.execute('UPDATE character_drop_tape SET issued = ?, spent = ?, base_kills = ?, base_bosses = ?, base_floors = ?, last_rune_elite = ?, last_surge_at = ? WHERE character_id = ?',
    [JSON.stringify(t.issued), JSON.stringify(t.spent), t.baseKills, t.baseBosses, t.baseFloors, t.lastRuneElite, t.lastSurgeAt, characterId]);
}

/** The next seeds of every kind, from where the client says it is (never before what is already spent). */
async function issueTape(pool, { characterId, next, env = process.env }) {
  const key = tapeKey(env);
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const t = await loadTape(conn, characterId);
    const tape = {};
    for (const kind of rules.DROP_KINDS) {
      const hint = Math.max(0, Math.min(num(t.issued[kind]), Math.trunc(num(next && next[kind]))));
      const from = Math.max(num(t.spent[kind]), hint);
      const seeds = [];
      for (let n = from; n < from + AHEAD[kind]; n++) seeds.push(seedFor(key, characterId, kind, n));
      t.issued[kind] = Math.max(num(t.issued[kind]), from + AHEAD[kind]);
      tape[kind] = { from, seeds };
    }
    await saveTape(conn, characterId, t);
    await conn.commit();
    return { mode: dropsMode(env), tape };
  } catch (err) {
    await conn.rollback().catch(() => {});
    throw err;
  } finally {
    conn.release();
  }
}

/** Whether the character is an active member of a live party session (a carried ground: the host's world, not its own seals). */
async function carriedIn(conn, sessionId, characterId, now) {
  if (!SESSION_RE.test(String(sessionId || ''))) return false;
  try {
    const [[r]] = await conn.execute(
      `SELECT s.status, s.last_host_at FROM party_sessions s JOIN party_session_members m ON m.session_id = s.id
        WHERE s.id = ? AND m.character_id = ? AND m.status = 'active'`, [String(sessionId), characterId]);
    return !!r && String(r.status) === 'open' && now - Number(r.last_host_at) <= LIMITS.SESSION_IDLE_MS;
  } catch {
    return false;
  }
}

/** What the server knows about the character that a roll reads. */
async function context(conn, ch, sessionId, now) {
  const necro = await necroSummary(conn, ch.id);
  let waveOwned = 0;
  try {
    const [[r]] = await conn.execute('SELECT state FROM character_necro_progress WHERE character_id = ?', [ch.id]);
    waveOwned = num((parse(r && r.state, {}) || {}).waveTierOwned);
  } catch { /* no record yet: no Wave Speed */ }
  const [legs] = await conn.execute("SELECT item_id FROM inventory WHERE character_id = ? AND item_id LIKE 'leg\\_%'", [ch.id]);
  return {
    level: Math.max(1, num(ch.level, 1)), disciplineId: rules.disciplineIdFor(num(ch.cls)), unlocked: necro.unlocked, waveOwned,
    owned: [...new Set(legs.map((r) => r.item_id))], carried: await carriedIn(conn, sessionId, ch.id, now),
  };
}

async function ownsRune(conn, ch, runeId) {
  const [[a]] = await conn.execute('SELECT COUNT(*) AS n FROM character_runes WHERE character_id = ? AND rune_id = ?', [ch.id, runeId]).catch(() => [[{ n: 0 }]]);
  const [[b]] = await conn.execute('SELECT COUNT(*) AS n FROM inventory WHERE character_id = ? AND item_id = ?', [ch.id, runeId]);
  const [[c]] = await conn.execute('SELECT COUNT(*) AS n FROM account_vault WHERE account_id = ? AND item_id = ?', [ch.account_id, runeId]).catch(() => [[{ n: 0 }]]);
  return num(a.n) + num(b.n) + num(c.n) > 0;
}

/**
 * The facts the server rolls an event from: its own where it knows them (discipline, level, owned legendaries), the client's where they are
 * bounded. A value past its bound is a finding. Enforce rolls with the bound (and refuses the claim anyway); audit must never change what
 * dropped, so it rolls with the client's value and only stops it at the hard limits (the most any player can have). Throws a player error for
 * facts that name nothing.
 */
async function rollFacts(conn, kind, raw, ctx, n, findings, enforce) {
  const c = raw && typeof raw === 'object' ? raw : {};
  const f = { characterLevel: ctx.level, disciplineId: ctx.disciplineId, owned: ctx.owned, level: Math.max(1, Math.min(9999, Math.trunc(num(c.level, 1)))) };
  const difficulty = DIFFICULTIES.has(c.difficulty) ? c.difficulty : 'medium';
  const bounded = (claimed, allowed, hard, finding) => {
    if (claimed > allowed + 1e-9) findings.push({ ...finding, claimed, allowed });
    return enforce ? Math.min(claimed, allowed) : Math.min(claimed, hard);
  };
  const ground = (area) => {
    if (!killRules.groundOpen(area, ctx.unlocked) && !ctx.carried) findings.push({ kind: 'drop_area', area });
  };
  const wave = () => bounded(Math.max(0, Math.trunc(num(c.waveTier))), ctx.waveOwned, rules.MAX_WAVE_TIER, { kind: 'drop_wave' });
  if (kind === 'kill' || kind === 'elite') {
    if (!rules.isEnemy(String(c.def)) || !rules.isLootArea(String(c.area))) throw playerError('That drop could not be found.');
    ground(c.area);
    const icm = Math.max(1, bounded(num(c.itemChanceMult, 1), 1 + MAX_FORTUNE, 1 + MAX_FORTUNE, { kind: 'drop_fortune' }));
    let pity = 1;
    if (kind === 'elite') {
      // The rising rune chance counts elites since the last rune that LANDED before this one in roll order (picking drops up out of order
      // must not shorten it): the newest elite below `n` whose rune was claimed.
      const [[r]] = await conn.execute("SELECT MAX(n) AS n FROM character_drop_events WHERE character_id = ? AND kind = 'elite' AND rune_claimed = 1 AND n < ?", [ctx.id, n]);
      const last = r && r.n != null ? num(r.n) : -1;
      pity = Math.max(1, bounded(num(c.runePity, 1), rules.runePityMult(Math.max(0, n - last - 1)), rules.runePityMult(1e9), { kind: 'drop_pity' }));
    }
    return { ...f, def: String(c.def), area: String(c.area), waveTier: wave(), difficulty, itemChanceMult: icm, runePity: pity };
  }
  if (kind === 'boss') {
    const info = rules.bossInfo(String(c.boss));
    if (!info) throw playerError('That drop could not be found.');
    ground(info.area);
    let first = c.first === true && c.boss !== 'prelate';
    if (first) {
      const [[had]] = await conn.execute(
        "SELECT COUNT(*) AS n FROM character_drop_events WHERE character_id = ? AND kind = 'boss' AND JSON_UNQUOTE(JSON_EXTRACT(facts, '$.boss')) = ? AND JSON_EXTRACT(facts, '$.first') = true",
        [ctx.id, String(c.boss)]);
      if (num(had.n) > 0) {
        findings.push({ kind: 'drop_first', boss: c.boss });
        if (enforce) first = false;
      }
    }
    return { ...f, boss: String(c.boss), area: info.area, costShards: info.shards, first, waveTier: wave(), difficulty };
  }
  if (kind === 'floor' || kind === 'chest') {
    const depth = Math.max(1, Math.trunc(num(c.depth, 1)));
    if (kind === 'chest' && !rules.hasChest(depth)) throw playerError('That drop could not be found.');
    // The deepest floor the kill ledger has proven, plus one (a floor's drop can be claimed just before its report lands).
    if (ctx.depthProved != null && depth > ctx.depthProved + DEPTH_SLACK) findings.push({ kind: 'drop_depth', claimed: depth, proved: ctx.depthProved });
    return { ...f, area: 'depths', depth };
  }
  if (!rules.isLootArea(String(c.area))) throw playerError('That drop could not be found.');
  ground(c.area);
  return { ...f, area: String(c.area) };
}

/** The kind's tape spent past `n`: within the kill ledger's accepted kills (bosses) since the tape began, plus a little slack. */
function budgetFindings(kind, t, n, totals, now) {
  const out = [];
  const spent = (k) => Math.max(num(t.spent[k]), k === kind ? n + 1 : 0);
  if ((kind === 'kill' || kind === 'elite') && totals.known) {
    const used = spent('kill') + spent('elite');
    const allowed = totals.kills - t.baseKills + SLACK.kills;
    if (used > allowed) out.push({ kind: 'drop_budget', drops: kind, used, allowed });
  }
  if (kind === 'boss' && totals.known) {
    const used = spent('boss');
    const allowed = totals.bosses - t.baseBosses + SLACK.bosses;
    if (used > allowed) out.push({ kind: 'drop_budget', drops: 'boss', used, allowed });
  }
  if ((kind === 'floor' || kind === 'chest') && totals.known) {
    const used = spent('floor') + spent('chest');
    const allowed = totals.floors - t.baseFloors + SLACK.floors;
    if (used > allowed) out.push({ kind: 'drop_budget', drops: 'depths', used, allowed });
  }
  if (kind === 'surge' && now - t.lastSurgeAt < SURGE_GAP_MS) out.push({ kind: 'drop_rate', drops: 'surge', gapMs: now - t.lastSurgeAt });
  return out;
}

/** Put one granted drop in the bag: gear as a new instance in the first free slot, the rest stacked first. Returns false when it does not fit,
 * else true, or the new instance's id for gear. */
async function putInBag(conn, ch, d) {
  const [[meta]] = await conn.execute('SELECT stackable, max_stack_size FROM items WHERE id = ?', [d.item_id]);
  if (!meta) throw playerError('That item is not known to the server.');
  const [bag] = await conn.execute('SELECT id, slot_index, item_id, quantity, instance_id FROM inventory WHERE character_id = ? AND slot_index BETWEEN 0 AND ? ORDER BY slot_index FOR UPDATE', [ch.id, BAG - 1]);
  const occupied = new Set(bag.map((r) => num(r.slot_index)));
  const free = () => { for (let s = 0; s < BAG; s++) if (!occupied.has(s)) return s; return -1; };
  if (d.instance) {
    const slot = free();
    if (slot < 0) return false;
    const inst = await store.insertInstance(conn, ch.account_id, d.item_id, d.instance);
    await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot, instance_id) VALUES (?, ?, ?, 1, 0, NULL, ?)', [ch.id, slot, d.item_id, inst]);
    return inst;
  }
  const maxStack = meta.stackable ? Math.max(num(meta.max_stack_size, 1), 1) : 1;
  let left = num(d.quantity, 1);
  if (meta.stackable) {
    for (const r of bag) {
      if (left <= 0) break;
      if (r.item_id !== d.item_id || r.instance_id != null || num(r.quantity) >= maxStack) continue;
      const add = Math.min(left, maxStack - num(r.quantity));
      await conn.execute('UPDATE inventory SET quantity = quantity + ? WHERE id = ?', [add, r.id]);
      left -= add;
    }
  }
  while (left > 0) {
    const slot = free();
    if (slot < 0) return false;
    const add = Math.min(left, maxStack);
    await conn.execute('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot) VALUES (?, ?, ?, ?, 0, NULL)', [ch.id, slot, d.item_id, add]);
    occupied.add(slot);
    left -= add;
  }
  return true;
}

const publicItem = (d, instanceId) => ({ item_id: d.item_id, quantity: d.quantity, source: d.source,
  ...(d.instance ? { instance_id: instanceId, ilvl: d.instance.ilvl, affixes: d.instance.affixes } : {}) });

/** One claim. Returns { status, body }. `log` gets the audit lines. */
async function claimDrop(pool, { characterId, accountId, body, env = process.env, now = Date.now(), log = console }) {
  const b = body || {};
  const kind = String(b.kind);
  const n = int(b.n);
  const index = int(b.index);
  if (!rules.DROP_KINDS.includes(kind) || !(n >= 0) || !(index >= 0)) return { status: 400, body: { success: false, error: 'That drop could not be found.' } };
  const mode = dropsMode(env);
  const key = tapeKey(env);
  const conn = await pool.getConnection();
  const findings = [];
  let who = null;
  // Findings are written after the transaction ends: progress_audit references the character row this claim holds locked.
  const writeFindings = async () => {
    for (const f of findings) {
      const { kind: k, ...detail } = f;
      await audit(pool, { characterId: who.id, accountId: who.account_id, kind: k, mode, action: mode === 'enforce' && k !== 'drop_mismatch' ? 'refuse' : 'report', detail }, log);
    }
  };
  try {
    await conn.beginTransaction();
    const [[ch]] = await conn.execute('SELECT id, account_id, level, COALESCE(discipline_index, class_index) AS cls FROM characters WHERE id = ? FOR UPDATE', [characterId]);
    if (!ch) throw playerError('Character not found.', 404);
    who = ch;
    const t = await loadTape(conn, ch.id);
    const spentBefore = num(t.spent[kind]);   // where this kind's tape stands before this claim (a refusal sends the client back here)
    if (n >= num(t.issued[kind])) throw playerError('That drop was never dealt.');
    const [[row]] = await conn.execute('SELECT facts, items, claimed FROM character_drop_events WHERE character_id = ? AND kind = ? AND n = ? FOR UPDATE', [ch.id, kind, n]);
    let items;
    let claimed;
    if (row) {
      items = parse(row.items, []);
      claimed = parse(row.claimed, []);
    } else {
      const totals = await ledgerTotals(conn, ch.id);
      const ctx = { ...(await context(conn, ch, b.sessionId, now)), id: ch.id, depthProved: totals.known ? totals.depth : null };
      const facts = await rollFacts(conn, kind, b.facts, ctx, n, findings, mode === 'enforce');
      if (totals.known && totals.kills < t.baseKills) t.baseKills = Math.max(0, totals.kills - num(t.spent.kill) - num(t.spent.elite));   // the ledger was rebased
      if (totals.known && totals.bosses < t.baseBosses) t.baseBosses = Math.max(0, totals.bosses - num(t.spent.boss));
      if (totals.known && totals.floors < t.baseFloors) t.baseFloors = Math.max(0, totals.floors - num(t.spent.floor) - num(t.spent.chest));
      findings.push(...budgetFindings(kind, t, n, totals, now));
      items = rules.rollEvent(kind, facts, rules.eventStreams(kind, seedFor(key, ch.id, kind, n))).items;
      claimed = [];
      await conn.execute('INSERT INTO character_drop_events (character_id, kind, n, facts, items, claimed) VALUES (?, ?, ?, ?, ?, ?)', [ch.id, kind, n, JSON.stringify(facts), JSON.stringify(items), '[]']);
      t.spent[kind] = Math.max(num(t.spent[kind]), n + 1);
      if (kind === 'surge') t.lastSurgeAt = now;
    }
    const d = items[index];
    if (d && b.expect != null && String(b.expect) !== d.item_id) findings.push({ kind: 'drop_mismatch', expect: String(b.expect), rolled: d.item_id, event: `${kind}#${n}` });
    if (!d && b.expect != null) findings.push({ kind: 'drop_mismatch', expect: String(b.expect), rolled: null, event: `${kind}#${n}` });
    if (mode === 'enforce' && findings.some((f) => f.kind !== 'drop_mismatch')) {
      // Over budget: the client's tape ran ahead of the kills (bosses, floors) the ledger accepted, e.g. a host's GM-summoned bosses for a guest.
      // Tell it where the server's tape is, so it goes back there and its next honest event pays (seeds are re-used in order: no picking).
      const e = playerError('The server could not confirm that drop.');
      if (findings.some((f) => f.kind === 'drop_budget')) e.resync = { kind, spent: spentBefore };
      throw e;
    }
    if (!d) throw playerError('That drop could not be found.');
    if (claimed.includes(index)) throw playerError('That drop was already picked up.');
    claimed.push(index);
    const runeLanded = kind === 'elite' && String(d.item_id).startsWith('rune_');
    if (runeLanded) t.lastRuneElite = Math.max(t.lastRuneElite, n);
    let granted = false;
    let put = false;
    if (String(d.item_id).startsWith('rune_') && (await ownsRune(conn, ch, d.item_id))) {
      granted = false;   // a rune you have never drops (DmLootView.rune_owned): nothing to grant, and it cannot be claimed again
    } else if (!(put = await putInBag(conn, ch, d))) {
      throw playerError('Your bag is full.', 409);
    } else {
      granted = true;
    }
    await conn.execute(`UPDATE character_drop_events SET claimed = ?${runeLanded ? ', rune_claimed = 1' : ''} WHERE character_id = ? AND kind = ? AND n = ?`, [JSON.stringify(claimed), ch.id, kind, n]);
    await saveTape(conn, ch.id, t);
    await conn.commit();
    await writeFindings();
    if (!granted) return { status: 200, body: { success: false, error: 'You already have that rune.' } };
    const [bag] = await pool.execute(INV_SELECT, [ch.id]);
    return { status: 200, body: { success: true, data: { item: publicItem(d, put === true ? null : put), bag } } };
  } catch (err) {
    await conn.rollback().catch(() => {});
    if (who) await writeFindings();   // a refused claim keeps its audit rows
    if (err && err.player) return { status: err.status === 404 ? 404 : 200, body: { success: false, error: err.message, ...(err.resync ? { resync: err.resync } : {}) } };
    throw err;
  } finally {
    conn.release();
  }
}

function mountDrops(app, pool, { requireAuth, ownsCharacter, limiter, env = process.env, now = () => Date.now(), log = console }) {
  const pre = limiter ? [limiter] : [];
  const owned = async (req, res) => {
    const id = parseInt(req.body && req.body.characterId, 10);
    if (!id || !(await ownsCharacter(req, id))) { res.status(403).json({ success: false, error: 'character not found or not owned by this account' }); return 0; }
    return id;
  };
  app.post('/api/drops/tape', ...pre, requireAuth, async (req, res) => {
    try {
      const id = await owned(req, res);
      if (!id) return;
      res.json({ success: true, data: await issueTape(pool, { characterId: id, next: req.body.next, env }) });
    } catch (err) {
      log.error(`POST /api/drops/tape: ${err.code || err.message}`);
      res.status(503).json({ success: false, error: 'Drops are not available right now. Try again in a moment.' });
    }
  });
  app.post('/api/drops/claim', ...pre, requireAuth, async (req, res) => {
    try {
      const id = await owned(req, res);
      if (!id) return;
      const out = await claimDrop(pool, { characterId: id, accountId: req.user.accountId, body: req.body, env, now: now(), log });
      res.status(out.status).json(out.body);
    } catch (err) {
      log.error(`POST /api/drops/claim: ${err.code || err.message}`);
      res.status(503).json({ success: false, error: 'The server could not check that drop right now. Try again in a moment.' });
    }
  });
}

module.exports = { mountDrops, issueTape, claimDrop, seedFor, tapeKey, dropsMode, AHEAD, SLACK };
