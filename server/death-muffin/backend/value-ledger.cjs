'use strict';
/**
 * The value ledger (authority Phase 2, DECISIONS B24): one row for every server write of a character's gold, XP or soul shards,
 * with the reason. It is the record a refund, a rollback or an investigation starts from; nothing reads it to decide a write.
 *
 *   await record(conn, { characterId, currency: 'gold', delta: -cost, balance: after, reason: 'reforge', ref: instanceId });
 *
 * Call it with the connection of the write's own transaction, so the row and the balance commit or roll back together.
 * It never fails the write: a missing table (migration 054 not applied) or any other error is logged once and skipped.
 */
const CURRENCIES = new Set(['gold', 'xp', 'shards']);
const int = (v) => Math.trunc(Number(v) || 0);
let warned = false;

async function record(db, entries, log = console) {
  const rows = (Array.isArray(entries) ? entries : [entries])
    .filter((e) => e && CURRENCIES.has(e.currency) && int(e.characterId) > 0 && int(e.delta) !== 0)
    .map((e) => [int(e.characterId), e.currency, int(e.delta), e.balance == null ? null : int(e.balance),
      String(e.reason || 'unknown').slice(0, 32), e.ref == null ? null : String(e.ref).slice(0, 64), Date.now()]);
  if (!rows.length) return;
  try {
    await db.query('INSERT INTO value_ledger (character_id, currency, delta, balance, reason, ref, created_at) VALUES ?', [rows]);
  } catch (err) {
    if (!warned) { warned = true; (log.error || console.error)(`[value-ledger] not recorded: ${err.code || err.message}`); }
  }
}

module.exports = { record, CURRENCIES };
