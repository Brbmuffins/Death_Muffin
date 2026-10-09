'use strict';
/**
 * Server authority, step 2: the kill ledger (docs/SERVER-AUTHORITY.md "Step 2").
 *
 * The browser reports every kill in small batches (POST /api/kills/report). This module validates a batch against the real time that
 * passed and the game's own tables (gathering/kill-rules.cjs, generated from server/rules/gameplay/killRules.ts), converts the valid part into
 * CREDITS (kills per ground, XP, gold, soul shards, Depths floors), and makes the routes that carry progression pay out of them:
 *
 *   save-progress        level/XP/gold gains          <- xp / gold credits (+ a small refilling lump for non-kill income)
 *   necro-progress/save  areaKills (-> totalKills), shards (-> summons -> boss kills -> Ascension)
 *   chronicle            playSeconds, peak.depth, run count (the leaderboard's own columns)
 *   leaderboard          totalKills never exceeds what the ledger believes
 *
 *   AUTHORITY_KILLS=off      (default) reports are acknowledged and ignored. Saves behave exactly as before.
 *   AUTHORITY_KILLS=audit    the ledger is kept and every save is compared with it; findings go to progress_audit. NOTHING is held back.
 *   AUTHORITY_KILLS=enforce  saves can only claim what the ledger credits. Unbacked claims are clamped and the player is told.
 *
 * Read on every call, like AUTHORITY_MODE. Every function fails OPEN (a missing table or failed query never costs a player a save) and
 * staff accounts are exempt from every clamp. All functions take `db` (a pool or a connection) and an optional `now`/`env`/`log`.
 */
const rules = require('./gathering/kill-rules.cjs');
const { audit, necroSummary } = require('./authority.cjs');
const authorityRules = require('./gathering/authority-rules.cjs');

const K = rules.KILLS;
const MINUTE = 60_000;
const PRELATE_KEY = '_prelate';
const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
const fmt = (n) => Math.round(n).toLocaleString('en-US');

function killsMode(env = process.env) {
  const v = String(env.AUTHORITY_KILLS || '').trim().toLowerCase();
  return v === 'enforce' ? 'enforce' : v === 'audit' ? 'audit' : 'off';
}

function parseJson(v, fallback) {
  if (v == null) return fallback;
  try { return typeof v === 'string' ? JSON.parse(v) : v; } catch { return fallback; }
}

// ── The ledger row ────────────────────────────────────────────────────────────────────────────────────────────────────

const COLUMNS = `seq, bucket_at, kill_bucket, boss_bucket, floor_bucket, xp_credit, gold_credit, shard_credit, kill_credit,
  lump_xp, lump_gold, lump_at, play_bucket, play_at, depth_proved, max_cleared, kills_base, kills_total, bosses_total, floors_total,
  xp_total, gold_total, shards_total, xp_used, gold_used, reports`;

function fromRow(r, now) {
  return {
    seq: num(r.seq),
    bucketAt: r.bucket_at == null ? null : num(r.bucket_at),
    killBucket: num(r.kill_bucket), bossBucket: num(r.boss_bucket), floorBucket: num(r.floor_bucket),
    xpCredit: num(r.xp_credit), goldCredit: num(r.gold_credit), shardCredit: num(r.shard_credit),
    killCredit: parseJson(r.kill_credit, {}) || {},
    lumpXp: num(r.lump_xp), lumpGold: num(r.lump_gold), lumpAt: r.lump_at == null ? null : num(r.lump_at),
    playBucket: num(r.play_bucket), playAt: r.play_at == null ? null : num(r.play_at),
    depthProved: num(r.depth_proved), maxCleared: num(r.max_cleared),
    killsBase: num(r.kills_base), killsTotal: num(r.kills_total), bossesTotal: num(r.bosses_total), floorsTotal: num(r.floors_total),
    xpTotal: num(r.xp_total), goldTotal: num(r.gold_total), shardsTotal: num(r.shards_total), xpUsed: num(r.xp_used), goldUsed: num(r.gold_used),
    reports: num(r.reports),
    now,
  };
}

/** The character's chronicle peak depth and the necromancer record's lifetime kills: what the ledger grandfathers at first sight. */
async function baselines(db, characterId) {
  let peak = 0;
  let kills = 0;
  try {
    const [[row]] = await db.execute('SELECT life FROM character_chronicle WHERE character_id = ?', [characterId]);
    peak = num(parseJson(row && row.life, {})['peak.depth']);
  } catch { /* no chronicle yet */ }
  try {
    const [[row]] = await db.execute('SELECT state FROM character_necro_progress WHERE character_id = ?', [characterId]);
    kills = num(parseJson(row && row.state, {}).totalKills);
  } catch { /* no necromancer record yet */ }
  return { peak, kills };
}

/** Read the ledger row under a lock, creating it (grandfathering what the character already has) on first sight. */
async function loadLedger(db, characterId, now = Date.now()) {
  const [[have]] = await db.execute(`SELECT ${COLUMNS} FROM character_kill_ledger WHERE character_id = ? FOR UPDATE`, [characterId]);
  if (have) return fromRow(have, now);
  const b = await baselines(db, characterId);
  await db.execute('INSERT IGNORE INTO character_kill_ledger (character_id, depth_proved, max_cleared, kills_base) VALUES (?, ?, ?, ?)', [characterId, b.peak, b.peak, b.kills]);
  const [[row]] = await db.execute(`SELECT ${COLUMNS} FROM character_kill_ledger WHERE character_id = ? FOR UPDATE`, [characterId]);
  return fromRow(row, now);
}

/** After an offline load, a necromancer import or anything else that rewrites the record outside the ledger: take the new totals as the base. */
async function rebase(db, characterId, log = console) {
  try {
    const b = await baselines(db, characterId);
    await db.execute(
      `INSERT INTO character_kill_ledger (character_id, depth_proved, max_cleared, kills_base) VALUES (?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE kills_base = VALUES(kills_base), kills_total = 0, kill_credit = NULL,
         depth_proved = GREATEST(depth_proved, VALUES(depth_proved)), max_cleared = GREATEST(max_cleared, VALUES(max_cleared))`,
      [characterId, b.peak, b.peak, b.kills]);
  } catch (err) {
    log.error(`[AUTHORITY] ledger rebase unavailable: ${err.code || err.message}`);
  }
}

// ── Refilling buckets ─────────────────────────────────────────────────────────────────────────────────────────────────

/** Pure: the buckets after the time since `bucketAt` has refilled them. A ledger not yet used starts with FIRST_MINUTES in the bank. */
function refill(ledger, unlocked, now) {
  const caps = rules.bucketCaps(unlocked);
  const fresh = ledger.bucketAt == null;
  const dt = fresh ? 0 : Math.min(K.BANK_MINUTES, Math.max(0, (now - ledger.bucketAt) / MINUTE));
  const grow = (have, perMin, cap, first) => (fresh ? Math.min(cap, perMin * first) : Math.min(cap, have + perMin * dt));
  return {
    killBucket: grow(ledger.killBucket, caps.killPerMin, caps.killCap, K.FIRST_MINUTES),
    bossBucket: grow(ledger.bossBucket, caps.bossPerMin, caps.bossCap, K.FIRST_MINUTES),
    floorBucket: grow(ledger.floorBucket, caps.floorPerMin, caps.floorCap, K.FIRST_MINUTES),
    caps,
  };
}

/** Lump allowances (non-kill XP and gold) refill separately, on the clock of the last save that drew from them. */
function refillLump(ledger, now) {
  const fresh = ledger.lumpAt == null;
  const dt = fresh ? 0 : Math.max(0, (now - ledger.lumpAt) / MINUTE);
  return {
    xp: fresh ? K.LUMP_XP_CAP : Math.min(K.LUMP_XP_CAP, ledger.lumpXp + K.LUMP_XP_PER_MIN * dt),
    gold: fresh ? K.LUMP_GOLD_CAP : Math.min(K.LUMP_GOLD_CAP, ledger.lumpGold + K.LUMP_GOLD_PER_MIN * dt),
  };
}

/** necroSummary answers the sworn vows ({ vowId: steps }) or, for older saves, a numeric rank; the kill rules take a rank (the vows' total heat).
 *  Passing the vows object straight through made every ceiling NaN, so every report from a character with vows failed (ER_DATA_OUT_OF_RANGE). */
function ascensionRank(a) {
  if (a && typeof a === 'object') return rules.vowHeat(a);
  return Math.max(0, num(a));
}

// ── POST /api/kills/report ────────────────────────────────────────────────────────────────────────────────────────────

const ENFORCE_NOTICE = 'Some of your kills could not be verified against the time that passed, so the server did not count them.';

/**
 * Judge and record one kill report. Returns { status, body }. `char` is the owned character row, `account` = { staff }.
 * Off: acknowledge, write nothing. Audit and enforce keep the same ledger (so audit shows exactly what enforce would do).
 */
async function handleReport(pool, { char, accountId, body, account, now = Date.now(), env = process.env, log = console }) {
  const mode = killsMode(env);
  if (mode === 'off') return { status: 200, body: { success: true, data: { mode } } };
  const report = rules.parseKillReport(body);
  if (!report) return { status: 400, body: { success: false, error: 'That kill report was not understood.' } };
  if (report.seq > now + K.SEQ_FUTURE_SLACK_MS) return { status: 400, body: { success: false, error: 'That kill report is dated in the future.' } };

  let conn;
  try {
    conn = await pool.getConnection();
    await conn.beginTransaction();
    const [[locked]] = await conn.execute('SELECT id, level FROM characters WHERE id = ? FOR UPDATE', [char.id]);
    if (!locked) { await conn.rollback(); return { status: 404, body: { success: false, error: 'character not found' } }; }
    const ledger = await loadLedger(conn, char.id, now);
    const necro = await necroSummary(conn, char.id);
    if (report.seq === ledger.seq) { await conn.commit(); return { status: 200, body: { success: true, data: { mode, duplicate: true } } }; }
    if (report.seq < ledger.seq) {
      await audit(conn, { characterId: char.id, accountId, kind: 'kill_replay', mode, action: 'report', detail: { seq: report.seq, last: ledger.seq } }, log);
      await conn.commit();
      return { status: 200, body: { success: true, data: { mode, duplicate: true } } };
    }
    const buckets = refill(ledger, necro.unlocked, now);
    const rank = ascensionRank(necro.ascension);
    const ev = rules.evaluateKillReport(report, {
      unlocked: necro.unlocked, ascension: rank, heroLevel: num(locked.level, 1), deepest: ledger.depthProved,
      killBucket: buckets.killBucket, bossBucket: buckets.bossBucket, floorBucket: buckets.floorBucket, maxCleared: ledger.maxCleared, staff: !!(account && account.staff),
    });
    const credit = { ...ledger.killCredit };
    for (const [area, n] of Object.entries(ev.credits.kills)) credit[area] = (credit[area] || 0) + n;
    // The Prelate's kills share the JSON under a key no ground can have.
    if (ev.credits.prelate) credit[PRELATE_KEY] = (credit[PRELATE_KEY] || 0) + ev.credits.prelate;
    const claimedKills = report.groups.reduce((n, g) => n + g.n, 0);
    const dropped = Math.max(0, claimedKills - ev.killsAccepted);
    await conn.execute(
      `UPDATE character_kill_ledger SET seq = ?, bucket_at = ?, kill_bucket = ?, boss_bucket = ?, floor_bucket = ?,
         xp_credit = xp_credit + ?, gold_credit = gold_credit + ?, shard_credit = shard_credit + ?, kill_credit = ?,
         depth_proved = GREATEST(depth_proved, ?), max_cleared = GREATEST(max_cleared, ?),
         kills_total = kills_total + ?, bosses_total = bosses_total + ?, floors_total = floors_total + ?,
         xp_total = xp_total + ?, gold_total = gold_total + ?, shards_total = shards_total + ?, reports = reports + 1, rejected_kills = rejected_kills + ?,
         last_report_at = ?
       WHERE character_id = ?`,
      [report.seq, now, buckets.killBucket - ev.killsAccepted, buckets.bossBucket - ev.bossesAccepted, buckets.floorBucket - ev.floorsAccepted,
        Math.floor(ev.credits.xp), Math.floor(ev.credits.gold), Math.floor(ev.credits.shards), JSON.stringify(credit),
        ev.depthProved, ev.depthProved ? ev.depthProved - 1 : 0,
        ev.killsAccepted, ev.bossesAccepted, ev.floorsAccepted, Math.floor(ev.credits.xp), Math.floor(ev.credits.gold), Math.floor(ev.credits.shards), dropped, now, char.id]);
    for (const f of ev.findings) {
      const { kind, ...detail } = f;
      await audit(conn, { characterId: char.id, accountId, kind, mode, action: mode === 'enforce' ? 'drop' : 'report', detail }, log);
    }
    // An Empowered boss's kill (gold sinks): tie it to the bound summon it names so the prize claim can see a reported kill.
    if (ev.bossesAccepted > 0) await require('./boss-key.cjs').markSummonKills(conn, char.id, report.bosses, log);
    await conn.commit();
    const data = { mode, accepted: { kills: ev.killsAccepted, bosses: ev.bossesAccepted, floors: ev.floorsAccepted } };
    // `authority.message` sits at the top of the reply, where the client's notice listener reads it (api.ts).
    return { status: 200, body: { success: true, data, ...(mode === 'enforce' && dropped > 0 ? { authority: { message: ENFORCE_NOTICE } } : {}) } };
  } catch (err) {
    if (conn) await conn.rollback().catch(() => {});
    // Fail open: the report is lost, nothing else is touched. In enforce mode the unclaimed kills simply earn no credit this time.
    log.error(`[AUTHORITY] kill report unavailable: ${err.code || err.message}`);
    return { status: 200, body: { success: true, data: { mode, unavailable: true } } };
  } finally {
    if (conn) conn.release();
  }
}

/** A request may carry several unacknowledged reports (a retry after a lost reply, or two saves in flight): judge them in order, skipping repeats. */
async function handleReports(pool, opts) {
  const list = Array.isArray(opts.reports) ? opts.reports.slice(0, 6) : [];
  let message = '';
  let last = { status: 200, body: { success: true, data: { mode: killsMode(opts.env) } } };
  for (const body of list) {
    last = await handleReport(pool, { ...opts, body });
    if (last.status >= 400) break;
    if (last.body.authority && last.body.authority.message) message = last.body.authority.message;
  }
  return { ...last, message };
}

// ── save-progress: pay level/XP/gold out of the credits ───────────────────────────────────────────────────────────────

/**
 * Pure: how much of a save's XP and gold gain the ledger backs. `prevTotal`/`nextTotal` are lifetime XP; `goldGain` may be negative.
 * Credits are drawn after the refilling lump (non-kill income); what is left of a credit stays for the next save.
 */
function evaluateCredits({ xpGain, goldGain, ledger, saleCredit, now }) {
  const lump = refillLump(ledger, now);
  const findings = [];
  const out = { xpFromLump: 0, xpFromCredit: 0, goldFromLump: 0, goldFromSale: 0, goldFromCredit: 0, xpAllowed: Infinity, goldAllowed: Infinity, lump };
  if (xpGain > 0) {
    out.xpFromLump = Math.min(xpGain, lump.xp);
    out.xpFromCredit = Math.min(xpGain - out.xpFromLump, ledger.xpCredit);
    out.xpAllowed = out.xpFromLump + out.xpFromCredit;
    if (xpGain > out.xpAllowed) findings.push({ kind: 'unbacked_xp', gain: xpGain, backed: Math.floor(out.xpAllowed), credit: Math.floor(ledger.xpCredit), lump: Math.floor(lump.xp), reports: ledger.reports });
  }
  if (goldGain > 0) {
    out.goldFromLump = Math.min(goldGain, lump.gold);
    out.goldFromSale = Math.min(goldGain - out.goldFromLump, Math.max(0, saleCredit));
    out.goldFromCredit = Math.min(goldGain - out.goldFromLump - out.goldFromSale, ledger.goldCredit);
    out.goldAllowed = out.goldFromLump + out.goldFromSale + out.goldFromCredit;
    if (goldGain > out.goldAllowed) findings.push({ kind: 'unbacked_gold', gain: goldGain, backed: Math.floor(out.goldAllowed), credit: Math.floor(ledger.goldCredit), lump: Math.floor(lump.gold), reports: ledger.reports });
  }
  return { ...out, findings };
}

/**
 * Called by authority.guardProgress after the step-1 verdict. `prev` is the stored character, `write` what step 1 would write.
 * Returns { write, message, findings }. Audit mode returns `write` untouched; enforce clamps to what the credits back.
 * It also CONSUMES the credits it paid out (and the lump) in every non-off mode, so audit shows the same balances enforce would.
 */
async function creditPass(db, { char, write, saleCredit, account, now = Date.now(), env = process.env, log = console }) {
  const mode = killsMode(env);
  const none = { write, message: '', findings: [] };
  if (mode === 'off' || (account && account.staff)) return none;
  try {
    const ledger = await loadLedger(db, char.id, now);
    const prevTotal = authorityRules.totalXp(char.level, char.experience);
    const nextTotal = authorityRules.totalXp(write.level, write.xp);
    const xpGain = nextTotal - prevTotal;
    const goldGain = write.gold - num(char.gold);
    const v = evaluateCredits({ xpGain, goldGain, ledger, saleCredit, now });
    const out = { ...write };
    const messages = [];
    let xpPaid = Math.max(0, xpGain);
    let goldPaid = Math.max(0, goldGain);
    if (mode === 'enforce') {
      if (xpGain > 0 && xpGain > v.xpAllowed) {
        const clamped = authorityRules.splitXp(prevTotal + Math.floor(v.xpAllowed));
        out.level = clamped.level;
        out.xp = clamped.xp;
        xpPaid = Math.floor(v.xpAllowed);
        messages.push(ledger.reports === 0
          ? 'This version of the game could not report your kills, so the server could not count your experience. Reload the page to update.'
          : `Your experience rose faster than your verified kills explain (${fmt(xpGain)} XP), so the server held back part of it. It will catch up as your kills are verified.`);
      }
      if (goldGain > 0 && goldGain > v.goldAllowed) {
        out.gold = num(char.gold) + Math.floor(v.goldAllowed);
        goldPaid = Math.floor(v.goldAllowed);
        messages.push(`Your gold rose faster than your verified kills explain (${fmt(goldGain)} gold), so the server held back part of it. It will catch up as your kills are verified.`);
      }
    }
    const lumpXpUsed = Math.min(xpPaid, v.xpFromLump);
    const xpCreditUsed = Math.min(Math.max(0, xpPaid - lumpXpUsed), v.xpFromCredit);
    const lumpGoldUsed = Math.min(goldPaid, v.goldFromLump);
    const goldCreditUsed = Math.min(Math.max(0, goldPaid - lumpGoldUsed - v.goldFromSale), v.goldFromCredit);
    await db.execute(
      `UPDATE character_kill_ledger SET lump_xp = ?, lump_gold = ?, lump_at = ?, xp_credit = GREATEST(0, xp_credit - ?), gold_credit = GREATEST(0, gold_credit - ?),
         xp_used = xp_used + ?, gold_used = gold_used + ? WHERE character_id = ?`,
      [v.lump.xp - lumpXpUsed, v.lump.gold - lumpGoldUsed, now, Math.floor(xpCreditUsed), Math.floor(goldCreditUsed), Math.floor(xpPaid), Math.floor(goldPaid), char.id]);
    for (const f of v.findings) {
      const { kind, ...detail } = f;
      await audit(db, { characterId: char.id, accountId: char.account_id, kind, mode, action: mode === 'enforce' ? 'clamp' : 'report', detail }, log);
    }
    return { write: mode === 'enforce' ? out : write, message: mode === 'enforce' ? messages.join(' ') : '', findings: v.findings };
  } catch (err) {
    log.error(`[AUTHORITY] kill credits unavailable, saving unchecked: ${err.code || err.message}`);
    return { ...none, failedOpen: true };
  }
}

// ── necro-progress/save: kills and shards ─────────────────────────────────────────────────────────────────────────────

/**
 * Pure: clamp a necromancer save's areaKills and shards to the ledger. Returns the (possibly new) values and what to consume if the save lands.
 */
function evaluateNecroClaim({ areaKills, shards, prelateKills, ledger }) {
  const kills = {};
  const used = {};
  const findings = [];
  const over = {};
  for (const [area, raw] of Object.entries(areaKills && typeof areaKills === 'object' ? areaKills : {})) {
    if (area === PRELATE_KEY) continue;
    const claim = Math.max(0, Math.trunc(Number(raw)) || 0);
    if (!claim) continue;
    const have = num(ledger.killCredit[area]);
    const take = Math.min(claim, have);
    if (take > 0) { kills[area] = take; used[area] = take; }
    if (claim > take) over[area] = { claimed: claim, backed: take };
  }
  if (Object.keys(over).length) findings.push({ kind: 'unbacked_kills', areas: over, reports: ledger.reports });
  const claimShards = Math.max(0, Math.trunc(Number(shards)) || 0);
  const shardTake = Math.min(claimShards, ledger.shardCredit);
  if (claimShards > shardTake) findings.push({ kind: 'unbacked_shards', claimed: claimShards, backed: shardTake, reports: ledger.reports });
  const claimPrelate = Math.max(0, Math.trunc(Number(prelateKills)) || 0);
  const prelateTake = Math.min(claimPrelate, num(ledger.killCredit[PRELATE_KEY]));
  if (claimPrelate > prelateTake) findings.push({ kind: 'unbacked_prelate', claimed: claimPrelate, backed: prelateTake, reports: ledger.reports });
  if (prelateTake > 0) used[PRELATE_KEY] = prelateTake;
  return { kills, shards: shardTake, prelate: prelateTake, used, shardsUsed: shardTake, findings };
}

/**
 * Express middleware for POST /api/necro-progress/save. In audit it only records findings; in enforce it replaces the claimed
 * areaKills and shards with what the ledger backs, and consumes them once the save has answered 2xx (a failed save keeps its credits so the
 * client's retry is not short). The rest of the request (prelate kills, wave tier) is the necromancer rules' business: summons already need paid shards.
 */
function necroGuard({ pool, ownsCharacter, isStaff, env = process.env, log = console }) {
  return async (req, res, next) => {
    const mode = killsMode(env);
    if (mode === 'off') return next();
    try {
      const characterId = Number(req.body && req.body.characterId);
      if (!Number.isInteger(characterId) || characterId <= 0 || !(await ownsCharacter(req, characterId))) return next();
      if (await isStaff(req).catch(() => false)) return next();
      const ledger = await loadLedger(pool, characterId, Date.now());
      const claim = evaluateNecroClaim({ areaKills: req.body.areaKills, shards: req.body.shards, prelateKills: req.body.prelateKills, ledger });
      for (const f of claim.findings) {
        const { kind, ...detail } = f;
        await audit(pool, { characterId, accountId: req.user.accountId, kind, mode, action: mode === 'enforce' ? 'clamp' : 'report', detail }, log);
      }
      // Audit consumes what enforce would have paid, so its balances stay comparable; the request itself is not touched.
      const consumeKills = claim.used;
      const consumeShards = claim.shardsUsed;
      if (mode === 'enforce') req.body = { ...req.body, areaKills: claim.kills, shards: claim.shards, prelateKills: claim.prelate };
      res.on('finish', () => {
        if (res.statusCode >= 400) return;
        consumeNecro(pool, characterId, consumeKills, consumeShards, log).catch((err) => log.error(`[AUTHORITY] necro credit consume failed: ${err.code || err.message}`));
      });
    } catch (err) {
      log.error(`[AUTHORITY] necro guard unavailable, saving unchecked: ${err.code || err.message}`);
    }
    return next();
  };
}

async function consumeNecro(pool, characterId, kills, shards, log = console) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [[row]] = await conn.execute('SELECT kill_credit, shard_credit FROM character_kill_ledger WHERE character_id = ? FOR UPDATE', [characterId]);
    if (!row) { await conn.rollback(); return; }
    const credit = parseJson(row.kill_credit, {}) || {};
    for (const [area, n] of Object.entries(kills)) {
      credit[area] = Math.max(0, num(credit[area]) - n);
      if (!credit[area]) delete credit[area];
    }
    await conn.execute('UPDATE character_kill_ledger SET kill_credit = ?, shard_credit = GREATEST(0, shard_credit - ?) WHERE character_id = ?', [JSON.stringify(credit), Math.floor(shards), characterId]);
    await conn.commit();
  } catch (err) {
    await conn.rollback().catch(() => {});
    throw err;
  } finally {
    conn.release();
  }
}

// ── Chronicle: play time, deepest floor, run count ────────────────────────────────────────────────────────────────────

/**
 * Pure: bound a Chronicle flush. `playSeconds` may rise only by the real seconds that passed (banked up to PLAY_BANK_SECONDS), `peak.depth`
 * only to the deepest floor the ledger has proven plus DEPTH_PEAK_SLACK. Returns the adjusted deltas/maxes, the new play bucket and findings.
 */
function evaluateChronicle({ deltas, maxes, ledger, now }) {
  const out = { deltas: { ...deltas }, maxes: { ...maxes }, findings: [] };
  const fresh = ledger.playAt == null;
  const bucket = fresh ? K.PLAY_FIRST_SECONDS : Math.min(K.PLAY_BANK_SECONDS, ledger.playBucket + Math.max(0, (now - ledger.playAt) / 1000));
  let left = bucket;
  if (out.deltas.playSeconds > 0) {
    const claim = out.deltas.playSeconds;
    const take = Math.min(claim, Math.floor(left));
    if (claim > take) out.findings.push({ kind: 'play_rate', claimed: claim, allowed: take });
    out.deltas.playSeconds = take;
    left -= take;
  }
  if (out.deltas.afkSeconds > 0) {
    // AFK seconds are a second clock on the same wall time: they may not exceed it either.
    const take = Math.min(out.deltas.afkSeconds, Math.floor(Math.max(0, left + (out.deltas.playSeconds || 0))));
    if (out.deltas.afkSeconds > take) out.findings.push({ kind: 'play_rate', claimed: out.deltas.afkSeconds, allowed: take, key: 'afkSeconds' });
    out.deltas.afkSeconds = take;
  }
  if (out.maxes['peak.depth'] > 0) {
    const allowed = Math.max(1, ledger.depthProved + K.DEPTH_PEAK_SLACK);
    if (out.maxes['peak.depth'] > allowed) {
      out.findings.push({ kind: 'depth_peak', claimed: out.maxes['peak.depth'], allowed, proved: ledger.depthProved });
      out.maxes['peak.depth'] = allowed;
    }
  }
  return { ...out, playBucket: left };
}

/** Chronicle guard for POST /api/chronicle/add. Returns { deltas, maxes }, adjusted in enforce, untouched otherwise. */
async function guardChronicleAdd(db, { characterId, accountId, deltas, maxes, account, now = Date.now(), env = process.env, log = console }) {
  const mode = killsMode(env);
  const same = { deltas, maxes };
  if (mode === 'off' || (account && account.staff)) return same;
  try {
    const ledger = await loadLedger(db, characterId, now);
    const v = evaluateChronicle({ deltas, maxes, ledger, now });
    await db.execute('UPDATE character_kill_ledger SET play_bucket = ?, play_at = ? WHERE character_id = ?', [v.playBucket, now, characterId]);
    for (const f of v.findings) {
      const { kind, ...detail } = f;
      await audit(db, { characterId, accountId, kind, mode, action: mode === 'enforce' ? 'clamp' : 'report', detail }, log);
    }
    return mode === 'enforce' ? { deltas: v.deltas, maxes: v.maxes } : same;
  } catch (err) {
    log.error(`[AUTHORITY] chronicle guard unavailable: ${err.code || err.message}`);
    return same;
  }
}

/**
 * Chronicle ascend: a run may only be archived (the leaderboard's "runs") while there are fewer archived runs than Ascension ranks, plus one
 * for the client sending the Chronicle call just before the necromancer one. Returns true when the archive may go ahead.
 */
async function mayArchiveRun(db, { characterId, runNo, accountId, account, env = process.env, log = console }) {
  const mode = killsMode(env);
  if (mode === 'off' || (account && account.staff)) return true;
  try {
    const necro = await necroSummary(db, characterId);
    const ok = runNo - 1 <= ascensionRank(necro.ascension);
    if (!ok) await audit(db, { characterId, accountId, kind: 'run_count', mode, action: mode === 'enforce' ? 'refuse' : 'report', detail: { runNo, ascension: ascensionRank(necro.ascension) } }, log);
    return mode === 'enforce' ? ok : true;
  } catch (err) {
    log.error(`[AUTHORITY] run guard unavailable: ${err.code || err.message}`);
    return true;
  }
}

module.exports = {
  killsMode, loadLedger, rebase, refill, refillLump, handleReport, handleReports, evaluateCredits, creditPass, evaluateNecroClaim, necroGuard, consumeNecro,
  evaluateChronicle, guardChronicleAdd, mayArchiveRun, ENFORCE_NOTICE,
};
