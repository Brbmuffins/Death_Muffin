-- 050-drop-depths.sql — the Catacomb Depths' floor rewards and chests come from the drop tape too (drops.cjs kinds floor / chest):
-- character_drop_tape.base_floors = the kill ledger's floors_total when the tape began (the budget a floor / chest claim is spent against).
-- Additive and idempotent: safe to run twice. Rollback: ALTER TABLE character_drop_tape DROP COLUMN base_floors;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'character_drop_tape' AND COLUMN_NAME = 'base_floors');
SET @sql := IF(@has = 0, 'ALTER TABLE character_drop_tape ADD COLUMN base_floors BIGINT UNSIGNED NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

UPDATE character_drop_tape t JOIN character_kill_ledger l ON l.character_id = t.character_id SET t.base_floors = l.floors_total WHERE t.base_floors = 0;
