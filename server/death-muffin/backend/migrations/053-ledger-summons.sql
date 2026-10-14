-- 053-ledger-summons.sql — the kill ledger backs boss kills with paid summons too (owner 2026-10-14: "it is totally normal to spam low level
-- bosses ... there should not be a limit"): a boss kill draws first on summons the character paid for (character_drop_tape.boss_credit, 051),
-- then on the clock bucket. summon_used = summons the ledger has already spent. It starts at each character's current credit, so nobody gets
-- old summons back as free boss kills; the backfill runs only when the column is added. Additive and idempotent.
-- Rollback: ALTER TABLE character_kill_ledger DROP COLUMN summon_used;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'character_kill_ledger' AND COLUMN_NAME = 'summon_used');
SET @sql := IF(@has = 0, 'ALTER TABLE character_kill_ledger ADD COLUMN summon_used BIGINT NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

SET @sql := IF(@has = 0, 'UPDATE character_kill_ledger k JOIN character_drop_tape t ON t.character_id = k.character_id SET k.summon_used = t.boss_credit', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
