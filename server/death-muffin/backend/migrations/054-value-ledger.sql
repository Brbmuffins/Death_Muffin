-- 054-value-ledger.sql — the value ledger (authority Phase 2, DECISIONS B24): one row per server write of a character's gold, XP or soul
-- shards, with its reason (save, sell, contract, labor, gather, reforge, boss-key, necro routes, offline sync, adjust). value-ledger.cjs
-- writes it inside each write's own transaction; nothing reads it to decide a write. Additive and idempotent.
-- Rollback: DROP TABLE value_ledger;

CREATE TABLE IF NOT EXISTS value_ledger (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  character_id INT UNSIGNED NOT NULL,
  currency ENUM('gold', 'xp', 'shards') NOT NULL,
  delta BIGINT NOT NULL,
  balance BIGINT NULL,
  reason VARCHAR(32) NOT NULL,
  ref VARCHAR(64) NULL,
  created_at BIGINT UNSIGNED NOT NULL,
  KEY value_ledger_char_time (character_id, created_at),
  KEY value_ledger_reason_time (reason, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
