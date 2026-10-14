-- 049-drop-rune-order.sql — the rising rune chance of a claimed elite drop is bounded by the elites since the last rune that landed BEFORE it in
-- roll order (drops.cjs); picking drops up out of order no longer shortens it. character_drop_events.rune_claimed marks an elite event whose
-- rune was claimed. Additive and idempotent: safe to run twice. Rollback: ALTER TABLE character_drop_events DROP COLUMN rune_claimed;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'character_drop_events' AND COLUMN_NAME = 'rune_claimed');
SET @sql := IF(@has = 0, 'ALTER TABLE character_drop_events ADD COLUMN rune_claimed TINYINT(1) NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

UPDATE character_drop_events SET rune_claimed = 1
 WHERE kind = 'elite' AND JSON_CONTAINS(claimed, CAST(JSON_LENGTH(items) - 1 AS JSON)) AND JSON_UNQUOTE(JSON_EXTRACT(items, CONCAT('$[', JSON_LENGTH(items) - 1, '].item_id'))) LIKE 'rune\_%';
