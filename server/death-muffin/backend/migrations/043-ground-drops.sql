-- 043: gear dropped from a bag onto the ground of a party session (ground.cjs, DECISIONS B16).
--
-- loot_instances.found_session_id / found_at: the party session a piece was rolled in (POST /api/loot/roll-gear with the session id) and when.
-- Members who were in that session at that moment may pick the piece up after someone drops it; NULL = found outside a session.
-- ground_drops: one row per piece lying on the ground. A bag save that names an instance lying here is refused (inventory-save.cjs); a
-- pickup moves the instance to the picker's account. Rows of an ended session are deleted with their instances (the piece is gone).
--
-- Additive and idempotent. Rollback: DROP TABLE ground_drops; ALTER TABLE loot_instances DROP COLUMN found_session_id, DROP COLUMN found_at;
SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'loot_instances' AND COLUMN_NAME = 'found_session_id');
SET @ddl := IF(@has = 0, 'ALTER TABLE loot_instances ADD COLUMN found_session_id CHAR(32) NULL DEFAULT NULL, ADD COLUMN found_at BIGINT UNSIGNED NULL DEFAULT NULL', 'SELECT 1');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

CREATE TABLE IF NOT EXISTS ground_drops (
  -- 32 hex chars from the CSPRNG
  id CHAR(32) NOT NULL,
  session_id CHAR(32) NOT NULL,
  instance_id INT UNSIGNED NOT NULL,
  item_id VARCHAR(64) NOT NULL,
  from_character_id INT UNSIGNED NOT NULL,
  from_account_id INT UNSIGNED NOT NULL,
  -- where it lies (the game draws it there for everyone who may take it)
  x FLOAT NOT NULL DEFAULT 0,
  z FLOAT NOT NULL DEFAULT 0,
  created_at BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_ground_drops_instance (instance_id),
  KEY idx_ground_drops_session (session_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
