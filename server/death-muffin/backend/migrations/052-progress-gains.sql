-- 052-progress-gains.sql — progress saves send gains, not totals (DECISIONS B23, server.js save-progress): character_authority.progress_seq is
-- the last gains save applied, so a retried save (its answer lost) is not paid twice. Additive and idempotent: safe to run twice.
-- Rollback: ALTER TABLE character_authority DROP COLUMN progress_seq;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'character_authority' AND COLUMN_NAME = 'progress_seq');
SET @sql := IF(@has = 0, 'ALTER TABLE character_authority ADD COLUMN progress_seq BIGINT UNSIGNED NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
