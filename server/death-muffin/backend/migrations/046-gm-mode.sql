-- 046-gm-mode.sql — GM mode (owner 2026-10-13, gm-mode.cjs): accounts that may GM switch it on and off; only while it is on are they staff.
-- accounts.gm_active = GM mode is on now (starts off for everyone). characters.gm_marked = this character was played in GM mode (the
-- leaderboard marks it). Characters of accounts that could already GM are marked now: until today GM was always on for them.
-- Additive and idempotent: safe to run twice. Apply BEFORE restarting the backend that reads these columns (deploy-release.sh does).
-- Rollback: ALTER TABLE accounts DROP COLUMN gm_active; ALTER TABLE characters DROP COLUMN gm_marked;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'accounts' AND COLUMN_NAME = 'gm_active');
SET @sql := IF(@has = 0, 'ALTER TABLE accounts ADD COLUMN gm_active TINYINT(1) NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'characters' AND COLUMN_NAME = 'gm_marked');
SET @sql := IF(@has = 0, 'ALTER TABLE characters ADD COLUMN gm_marked TINYINT(1) NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

UPDATE characters c JOIN accounts a ON a.id = c.account_id SET c.gm_marked = 1 WHERE a.role IN ('admin', 'gm') OR a.gm_enabled = 1;
