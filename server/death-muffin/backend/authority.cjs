'use strict';
/**
 * Server authority, step 1: plausibility guards (docs/SERVER-AUTHORITY.md).
 *
 * The browser still plays the game and reports level, XP, gold and its bag. These guards decide whether a report is believable
 * for the real time that passed, using the ceilings in gathering/authority-rules.cjs (generated from server/rules/gameplay/authorityRules.ts).
 *
 *   AUTHORITY_MODE=report (default)  log what would have been refused or clamped; NEVER change a save or a reply.
 *   AUTHORITY_MODE=enforce           clamp the part that is not believable and tell the player in plain words.
 *
 * Guards fail OPEN: if the authority tables are missing (migration 021 not applied) or a query fails, the save goes through as it
 * did before and one line is logged. Staff accounts are exempt. Every function takes `db`, a pool or a connection.
 */
const rules = require('./gathering/authority-rules.cjs');
const { SaveRefusal } = require('./loot-instances.cjs');

const A = rules.AUTHORITY;
const MINUTE = 60_000;

/** 'enforce' only when the env says so exactly; anything else (unset, typo) is report-only. Read on every call. */
function authorityMode(env = process.env) {
  return String(env.AUTHORITY_MODE || '').trim().toLowerCase() === 'enforce' ? 'enforce' : 'report';
}

const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
const fmt = (n) => Math.round(n).toLocaleString('en-US');

// ── State and audit rows ──────────────────────────────────────────────────────────────────────────────────────────────

const STATE_COLUMNS = 'xp_bucket, gold_bucket, bucket_at, gold_credit, item_budget, flags';

function parseJson(v, fallback) {
  if (v == null) return fallback;
  try { return typeof v === 'string' ? JSON.parse(v) : v; } catch { return fallback; }
}

async function loadState(db, characterId) {
  await db.execute('INSERT IGNORE INTO character_authority (character_id) VALUES (?)', [characterId]);
  const [[row]] = await db.execute(`SELECT ${STATE_COLUMNS} FROM character_authority WHERE character_id = ? FOR UPDATE`, [characterId]);
  const r = row || {};
  return {
    xpBucket: num(r.xp_bucket),
    goldBucket: num(r.gold_bucket),
    bucketAt: r.bucket_at == null ? null : num(r.bucket_at),
    goldCredit: num(r.gold_credit),
    itemBudget: parseJson(r.item_budget, {}) || {},
    flags: num(r.flags),
  };
}

/** One audit row per finding. Best effort: a failed insert is logged and never fails the save. */
async function audit(db, { characterId, accountId, kind, mode, action, detail }, log = console) {
  try {
    await db.execute('INSERT INTO progress_audit (character_id, account_id, kind, mode, action, detail) VALUES (?, ?, ?, ?, ?, ?)',
      [characterId, accountId, kind, mode, action, JSON.stringify(detail ?? {})]);
  } catch (err) {
    log.error(`[AUTHORITY] audit insert failed: ${err.code || err.message}`);
  }
  log.warn(`[AUTHORITY] ${mode}/${action} ${kind} char#${characterId} acct#${accountId} ${JSON.stringify(detail ?? {})}`);
}

/** The necromancer record's unlocked grounds and Ascension rank (the server already keeps them). Unknown = a fresh character. */
async function necroSummary(db, characterId) {
  let out;
  try {
    const [[row]] = await db.execute('SELECT state FROM character_necro_progress WHERE character_id = ?', [characterId]);
    const s = parseJson(row && row.state, null) || {};
    out = { unlocked: Array.isArray(s.unlockedAreas) && s.unlockedAreas.length ? s.unlockedAreas : ['chapterhouse', 'graves'], ascension: s.vows && typeof s.vows === 'object' ? s.vows : num(s.ascension) };
  } catch {
    out = { unlocked: ['chapterhouse', 'graves'], ascension: 0 };
  }
  // The deepest Catacomb Depths floor the Chronicle holds for the character bounds the Depths' XP and gold ceilings (0 = never been, or no Chronicle).
  let deepest = 0;
  try {
    const [[row]] = await db.execute('SELECT life FROM character_chronicle WHERE character_id = ?', [characterId]);
    deepest = num(parseJson(row && row.life, {})['peak.depth']);
  } catch { /* no Chronicle table yet: the ceilings assume the shallowest floors */ }
  return { ...out, deepest };
}

// ── Experience, gold, stats (POST /api/character/save-progress) ──────────────────────────────────────────────────────

/**
 * Pure decision for one save. `prev` is the stored character, `next` the bounded values the client sent. Returns what to write and
 * what was found; report mode (`enforce` false) returns `write` equal to `next` and still reports every finding.
 */
function evaluateProgress({ prev, next, state, necro, now, enforce }) {
  const ceil = rules.ceilingsFor(necro.unlocked, necro.ascension, num(prev.level, 1), num(necro.deepest));
  const fresh = state.bucketAt == null;
  const dt = fresh ? 0 : Math.min(A.BANK_MINUTES, Math.max(0, (now - state.bucketAt) / MINUTE));
  const xpCap = ceil.xpPerMin * A.BANK_MINUTES + A.XP_BURST;
  const goldCap = ceil.goldPerMin * A.BANK_MINUTES + A.GOLD_BURST;
  const xpBucket = fresh ? Math.min(xpCap, ceil.xpPerMin * A.FIRST_MINUTES + A.XP_BURST) : Math.min(xpCap, state.xpBucket + ceil.xpPerMin * dt);
  const goldBucket = fresh ? Math.min(goldCap, ceil.goldPerMin * A.FIRST_MINUTES + A.GOLD_BURST) : Math.min(goldCap, state.goldBucket + ceil.goldPerMin * dt);

  const findings = [];
  const write = { ...next };
  const prevTotal = rules.totalXp(prev.level, prev.experience);
  const nextTotal = rules.totalXp(next.level, next.xp);
  const xpGain = nextTotal - prevTotal;
  let xpUsed = 0;
  const messages = [];

  if (xpGain < 0) {
    findings.push({ kind: 'xp_stale', from: { level: num(prev.level), xp: num(prev.experience) }, to: { level: next.level, xp: next.xp } });
    if (enforce) {
      write.level = num(prev.level);
      write.xp = num(prev.experience);
      messages.push('That save was older than your latest progress, so the server kept the newer level and experience.');
    }
  } else if (xpGain > 0) {
    xpUsed = Math.min(xpGain, xpBucket);
    if (xpGain > xpBucket) {
      findings.push({ kind: 'xp_rate', gain: xpGain, allowed: Math.floor(xpBucket), perMin: ceil.xpPerMin, area: ceil.area, levelFrom: num(prev.level), levelTo: next.level });
      if (enforce) {
        const clamped = rules.splitXp(prevTotal + Math.floor(xpBucket));
        write.level = clamped.level;
        write.xp = clamped.xp;
        messages.push(`Your level and experience rose faster than play can explain (${fmt(xpGain)} XP at once), so the server held back part of it. It will catch up as you play.`);
      }
    }
  }

  const goldGain = next.gold - num(prev.gold);
  let goldUsed = 0;
  let creditUsed = 0;
  if (goldGain > 0) {
    const fromBucket = Math.min(goldGain, goldBucket);
    const fromCredit = Math.min(goldGain - fromBucket, state.goldCredit);
    goldUsed = fromBucket;
    creditUsed = fromCredit;
    const allowed = fromBucket + fromCredit;
    if (goldGain > allowed) {
      findings.push({ kind: 'gold_rate', gain: goldGain, allowed: Math.floor(allowed), perMin: ceil.goldPerMin, credit: Math.floor(state.goldCredit), area: ceil.area });
      if (enforce) {
        write.gold = num(prev.gold) + Math.floor(allowed);
        messages.push(`Your gold rose faster than play can explain (${fmt(goldGain)} at once), so the server held back part of it. It will catch up as you play.`);
      }
    }
  }

  for (const key of ['stat_str', 'stat_agi', 'stat_int', 'stat_vit']) {
    if (next[key] > num(prev[key])) {
      findings.push({ kind: 'stat_raise', stat: key, from: num(prev[key]), to: next[key] });
      if (enforce) {
        write[key] = num(prev[key]);
        if (!messages.some((m) => m.startsWith('Stat points'))) messages.push('Stat points cannot be changed by saving, so the server kept yours as they were.');
      }
    }
  }

  const accepted = {
    xp: Math.max(0, rules.totalXp(write.level, write.xp) - prevTotal),
    gold: Math.max(0, write.gold - num(prev.gold)),
  };
  return {
    findings,
    write,
    message: messages.join(' '),
    state: { xpBucket: xpBucket - xpUsed, goldBucket: goldBucket - goldUsed, bucketAt: now, creditUsed, accepted },
  };
}

/**
 * Persist the verdict and return what the route should write. Never throws: on any trouble it returns `next` unchanged.
 * `account` = { id, staff }. Staff accounts skip the guard entirely (dev access: god mode, debug leveling).
 */
async function guardProgress(db, { char, next, account, now = Date.now(), env = process.env, log = console }) {
  const mode = authorityMode(env);
  if (account && account.staff) return { write: next, message: '', findings: [] };
  try {
    const state = await loadState(db, char.id);
    const necro = await necroSummary(db, char.id);
    // AUTHORITY_KILLS=enforce implies the step-1 clamp on XP and gold too: the ledger bounds a claim by what its kills were worth, step 1 by the
    // best honest rate, and a save must satisfy both (step 2 alone would be looser than step 1 for a claim built from the richest allowed kills).
    const enforce1 = mode === 'enforce' || require('./kills.cjs').killsMode(env) === 'enforce';
    const out = evaluateProgress({ prev: char, next, state, necro, now, enforce: enforce1 });
    const flagged = out.findings.length > 0;
    await db.execute(
      `UPDATE character_authority SET xp_bucket = ?, gold_bucket = ?, bucket_at = ?, last_progress_at = ?,
         gold_credit = GREATEST(0, gold_credit - ?), xp_accepted = xp_accepted + ?, gold_accepted = gold_accepted + ?, flags = flags + ?
       WHERE character_id = ?`,
      [out.state.xpBucket, out.state.goldBucket, now, now, Math.floor(out.state.creditUsed), Math.floor(out.state.accepted.xp), Math.floor(out.state.accepted.gold), flagged ? 1 : 0, char.id]);
    for (const f of out.findings) {
      const { kind, ...detail } = f;
      await audit(db, { characterId: char.id, accountId: char.account_id, kind, mode: enforce1 ? 'enforce' : mode, action: enforce1 ? 'clamp' : 'report', detail }, log);
    }
    const step1 = enforce1 ? { write: out.write, message: out.message } : { write: next, message: '' };
    // Step 2 (kills.cjs, AUTHORITY_KILLS): pay the gain out of the kill ledger's credits. Off by default; fails open on its own.
    const step2 = await require('./kills.cjs').creditPass(db, { char, write: step1.write, saleCredit: state.goldCredit, account, now, env, log });
    return { write: step2.write, message: [step1.message, step2.message].filter(Boolean).join(' '), findings: [...out.findings, ...step2.findings] };
  } catch (err) {
    log.error(`[AUTHORITY] progress guard unavailable, saving unchecked: ${err.code || err.message}`);
    return { write: next, message: '', findings: [], failedOpen: true };
  }
}

// ── Items: bag saves, add-item, roll-gear ─────────────────────────────────────────────────────────────────────────────

/** The units of `itemId` the character may still add from the ground right now, and its cap. 0 for items that never come off the ground. */
function itemAvailable(itemId, budget, now) {
  const cap = rules.itemCap(itemId);
  if (cap <= 0) return { avail: 0, cap: 0 };
  const entry = budget[itemId];
  if (!entry) return { avail: cap, cap };
  const dt = Math.max(0, (now - num(entry.t)) / MINUTE);
  return { avail: Math.min(cap, num(entry.b) + rules.itemRatePerMin(itemId) * dt), cap };
}

/**
 * Pure: charge `introduced` ({item: qty}) against the budget. Returns the refused part per item and the new budget (entries that
 * have refilled to their cap are dropped, so the JSON stays small).
 */
function chargeItems(introduced, budget, now) {
  const next = { ...budget };
  const over = [];
  for (const [item, qty] of Object.entries(introduced)) {
    if (qty <= 0) continue;
    const { avail, cap } = itemAvailable(item, budget, now);
    const used = Math.min(qty, Math.floor(avail));
    if (qty > avail) over.push({ item, introduced: qty, allowed: Math.floor(avail), source: cap > 0 ? 'ground' : 'server-only' });
    if (cap > 0) next[item] = { b: avail - used, t: now };
  }
  for (const item of Object.keys(next)) {
    const cap = rules.itemCap(item);
    if (cap <= 0 || next[item].b >= cap) delete next[item];
  }
  return { over, budget: next };
}

const sumByItem = (rows) => {
  const out = {};
  for (const r of rows) out[r.item_id] = (out[r.item_id] || 0) + num(r.quantity, 1);
  return out;
};

/** Drop `excess` units of `itemId` from the slot list, highest slot first, so earlier stacks survive. Returns a new list. */
function trimSlots(slots, itemId, excess) {
  const out = slots.map((s) => ({ ...s }));
  const order = out.filter((s) => s.item_id === itemId).sort((a, b) => Number(b.slot_index) - Number(a.slot_index));
  let left = excess;
  for (const s of order) {
    if (left <= 0) break;
    const take = Math.min(left, num(s.quantity, 1));
    s.quantity = num(s.quantity, 1) - take;
    left -= take;
  }
  return out.filter((s) => num(s.quantity, 1) > 0);
}

/**
 * Called by inventory-save.replaceBag with the rows currently in the character's bag range and the slots the client sent.
 * Compares totals per item: more of an item than the bag held is "introduced", and only things that come off the ground, at the
 * pace the ground allows, may be introduced. Items that left the bag credit the gold bucket (selling). Returns the slots to write
 * (unchanged in report mode). Fails open.
 */
async function guardBagSave(db, { characterId, accountId, existingRows, slots, bagSize, account, now = Date.now(), env = process.env, log = console }) {
  const mode = authorityMode(env);
  if (account && account.staff) return { slots, message: '' };
  try {
    const state = await loadState(db, characterId);
    const before = sumByItem(existingRows.filter((r) => num(r.slot_index) >= 0 && num(r.slot_index) < bagSize));
    const after = sumByItem(slots);
    const introduced = {};
    const removed = {};
    for (const id of new Set([...Object.keys(before), ...Object.keys(after)])) {
      const d = (after[id] || 0) - (before[id] || 0);
      if (d > 0) introduced[id] = d;
      else if (d < 0) removed[id] = -d;
    }
    const charge = chargeItems(introduced, state.itemBudget, now);
    // Gold credit for what left the bag (sold, thrown away, spent): the most that can have been sold is what was there.
    let credit = 0;
    const removedIds = Object.keys(removed);
    if (removedIds.length) {
      const [rows] = await db.query('SELECT id, sell_value FROM items WHERE id IN (?)', [removedIds]);
      for (const r of rows) credit += num(r.sell_value) * removed[r.id];
    }
    let out = slots;
    const messages = [];
    for (const f of charge.over) {
      await audit(db, { characterId, accountId, kind: 'item_intro', mode, action: mode === 'enforce' ? 'clamp' : 'report', detail: f }, log);
      if (mode === 'enforce') {
        out = trimSlots(out, f.item, f.introduced - f.allowed);
        messages.push(f.source === 'server-only'
          ? `${f.item} cannot appear in your bag from a save, so the server left it out.`
          : `More ${f.item} arrived than play can explain, so the server kept ${f.allowed}.`);
      }
    }
    // In enforce mode the budget is charged for what was kept; in report mode for what the client sent (the save goes through whole).
    await db.execute(
      'UPDATE character_authority SET item_budget = ?, last_bag_at = ?, gold_credit = LEAST(?, gold_credit + ?), flags = flags + ? WHERE character_id = ?',
      [JSON.stringify(charge.budget), now, A.SALE_CREDIT_CAP, Math.floor(credit), charge.over.length ? 1 : 0, characterId]);
    if (mode !== 'enforce') return { slots, message: '' };
    return { slots: out, message: messages.join(' ') };
  } catch (err) {
    log.error(`[AUTHORITY] bag guard unavailable, saving unchecked: ${err.code || err.message}`);
    return { slots, message: '', failedOpen: true };
  }
}

/** POST /api/inventory/add-item: the same per-item allowance as a bag save. Returns { allowed: bool, message }. Fails open. */
async function guardAddItem(db, { characterId, accountId, itemId, quantity, account, now = Date.now(), env = process.env, log = console }) {
  const mode = authorityMode(env);
  if (account && account.staff) return { allowed: true, message: '' };
  try {
    const state = await loadState(db, characterId);
    const charge = chargeItems({ [itemId]: quantity }, state.itemBudget, now);
    if (!charge.over.length) {
      await db.execute('UPDATE character_authority SET item_budget = ? WHERE character_id = ?', [JSON.stringify(charge.budget), characterId]);
      return { allowed: true, message: '' };
    }
    const f = charge.over[0];
    await audit(db, { characterId, accountId, kind: 'item_intro', mode, action: mode === 'enforce' ? 'refuse' : 'report', detail: { ...f, via: 'add-item' } }, log);
    await db.execute('UPDATE character_authority SET item_budget = ?, flags = flags + 1 WHERE character_id = ?', [JSON.stringify(charge.budget), characterId]);
    if (mode !== 'enforce') return { allowed: true, message: '' };
    return { allowed: false, message: f.source === 'server-only' ? `${itemId} cannot be added to a bag directly.` : `More ${itemId} than play can explain. Try again later.` };
  } catch (err) {
    log.error(`[AUTHORITY] add-item guard unavailable, adding unchecked: ${err.code || err.message}`);
    return { allowed: true, message: '', failedOpen: true };
  }
}

/** POST /api/loot/roll-gear: only items that exist in a drop table can be rolled. Returns { ok, message } and logs; fails open. */
async function guardRollGear(db, { characterId, accountId, itemIds, account, env = process.env, log = console }) {
  const mode = authorityMode(env);
  if (account && account.staff) return { ok: true, message: '' };
  try {
    const bad = [...new Set(itemIds)].filter((id) => !rules.isGroundItem(id));
    if (!bad.length) return { ok: true, message: '' };
    await audit(db, { characterId, accountId, kind: 'roll_gear', mode, action: mode === 'enforce' ? 'refuse' : 'report', detail: { items: bad } }, log);
    await db.execute('UPDATE character_authority SET flags = flags + 1 WHERE character_id = ?', [characterId]).catch(() => {});
    return mode === 'enforce' ? { ok: false, message: 'That drop could not be rolled.' } : { ok: true, message: '' };
  } catch (err) {
    log.error(`[AUTHORITY] roll-gear guard unavailable: ${err.code || err.message}`);
    return { ok: true, message: '', failedOpen: true };
  }
}

// ── Offline full sync and offline stats ───────────────────────────────────────────────────────────────────────────────

const qtyByItem = (slots) => sumByItem(slots.filter((s) => s && typeof s.item_id === 'string'));

/**
 * Pure: how believable is `offline` (an account snapshot from the browser-only edition) as a replacement for `online`? Both are
 * offline-full-sync snapshots. Time is the offline save's own play-time counter beyond the online one (the server cannot measure
 * time spent offline), at least OFFLINE_MIN_MINUTES, at most OFFLINE_MAX_MINUTES; the counter is client-supplied, so this is a
 * tripwire for jumps, not proof. Only INCREASES count (replacing online with something smaller is the player's choice, and backed up).
 */
function evaluateOffline({ online, offline }) {
  const oc = online.character;
  const fc = offline.character;
  const playMin = (snap) => num(snap.chronicle && snap.chronicle.life && snap.chronicle.life.playSeconds) / 60;
  const minutes = Math.min(A.OFFLINE_MAX_MINUTES, Math.max(A.OFFLINE_MIN_MINUTES, playMin(offline) - playMin(online)));
  const necro = offline.necro || {};
  const ceil = rules.ceilingsFor(Array.isArray(necro.unlockedAreas) ? necro.unlockedAreas : ['chapterhouse', 'graves'], necro.vows && typeof necro.vows === 'object' ? necro.vows : num(necro.ascension), num(fc.level, 1),
    num(offline.chronicle && offline.chronicle.life && offline.chronicle.life['peak.depth']));
  const findings = [];
  const xpGain = rules.totalXp(fc.level, fc.experience) - rules.totalXp(oc.level, oc.experience);
  const xpAllowed = ceil.xpPerMin * minutes + A.XP_BURST;
  if (xpGain > xpAllowed) findings.push({ kind: 'xp_rate', gain: xpGain, allowed: Math.floor(xpAllowed), minutes: Math.round(minutes), levelFrom: oc.level, levelTo: fc.level });
  const goldGain = num(fc.gold) - num(oc.gold);
  const goldAllowed = ceil.goldPerMin * minutes + A.GOLD_BURST;
  if (goldGain > goldAllowed) findings.push({ kind: 'gold_rate', gain: goldGain, allowed: Math.floor(goldAllowed), minutes: Math.round(minutes) });
  // Items that can only come off the ground: more than the pace allows is not believable. Crafted and gathered things are not checked here
  // (dev-offline mode crafts and gathers too), only items that appear in a drop table.
  const had = qtyByItem(online.slots || []);
  const has = qtyByItem(offline.slots || []);
  const itemFindings = [];
  for (const [id, q] of Object.entries(has)) {
    if (!rules.isGroundItem(id)) continue;
    const gain = q - (had[id] || 0);
    const allowed = Math.ceil(Math.max(A.ITEM_MIN_BURST, rules.itemRatePerMin(id) * A.ITEM_BURST_MINUTES) + rules.itemRatePerMin(id) * Math.min(minutes, A.OFFLINE_MAX_MINUTES));
    if (gain > allowed) itemFindings.push({ item: id, gain, allowed });
  }
  if (itemFindings.length) findings.push({ kind: 'item_intro', items: itemFindings.slice(0, 10), count: itemFindings.length });
  return { findings, minutes };
}

const OFFLINE_MESSAGE = 'This offline save is far ahead of your online character for the time it claims. It can still be loaded: your current online save is kept as a version you can restore. Load it anyway?';

/**
 * Offline full-sync check. Returns { needsConfirm, message, findings }. Report mode only logs and never asks. Enforce mode asks
 * for confirmation (the route answers 409 until the request carries confirmImplausible: true) and audits a confirmed load.
 */
async function guardOfflineLoad(db, { characterId, accountId, online, offline, confirmed, account, env = process.env, log = console }) {
  const mode = authorityMode(env);
  if (account && account.staff) return { needsConfirm: false, message: '', findings: [] };
  try {
    const verdict = evaluateOffline({ online, offline });
    if (!verdict.findings.length) return { needsConfirm: false, message: '', findings: [] };
    const needsConfirm = mode === 'enforce' && !confirmed;
    const action = mode !== 'enforce' ? 'report' : confirmed ? 'confirm' : 'refuse';
    for (const f of verdict.findings) {
      const { kind, ...detail } = f;
      await audit(db, { characterId, accountId, kind: 'offline_load', mode, action, detail: { ...detail, finding: kind, minutes: verdict.minutes } }, log);
    }
    if (!needsConfirm) await db.execute('UPDATE character_authority SET flags = flags + 1 WHERE character_id = ?', [characterId]).catch(() => {});
    return { needsConfirm, message: needsConfirm ? OFFLINE_MESSAGE : '', findings: verdict.findings };
  } catch (err) {
    log.error(`[AUTHORITY] offline guard unavailable: ${err.code || err.message}`);
    return { needsConfirm: false, message: '', findings: [], failedOpen: true };
  }
}

/** POST /api/offline/sync-stats: a bare level/XP claim with no play-time evidence. Judged like an offline load with the minimum window. */
async function guardOfflineStats(db, { characterId, accountId, online, level, experience, confirmed, account, env = process.env, log = console }) {
  const snap = (l, x) => ({ character: { level: l, experience: x, gold: 0 }, slots: [], necro: {} });
  return guardOfflineLoad(db, { characterId, accountId, online: snap(num(online.level), num(online.experience)), offline: snap(level, experience), confirmed, account, env, log });
}

module.exports = {
  authorityMode, evaluateProgress, evaluateOffline, guardProgress, guardBagSave, guardAddItem, guardRollGear, guardOfflineLoad, guardOfflineStats,
  chargeItems, trimSlots, itemAvailable, loadState, audit, necroSummary, OFFLINE_MESSAGE, SaveRefusal,
};
