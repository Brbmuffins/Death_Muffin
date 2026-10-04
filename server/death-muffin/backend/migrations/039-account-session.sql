-- One active session per account (newest login wins). session.cjs reads/writes this; NULL = no session claimed yet (everything allowed).
-- Idempotent: safe to run twice. The backend fails open while the column is missing, so apply it before or after the API restart.
SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'accounts' AND COLUMN_NAME = 'active_session');
SET @ddl := IF(@has = 0, 'ALTER TABLE accounts ADD COLUMN active_session VARCHAR(64) NULL', 'SELECT 1');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
