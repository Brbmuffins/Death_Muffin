-- 006-contracts.sql — Sexton's Contracts: the daily delivery board. One row per character, UTC day and slot (0-2 are the orders;
-- slot 9 marks the day's bonus as claimed). Additive and idempotent. Boards are generated lazily from contract-rules.cjs.
CREATE TABLE IF NOT EXISTS character_contracts (
  character_id INT UNSIGNED NOT NULL,
  day          DATE NOT NULL,
  slot         TINYINT UNSIGNED NOT NULL,
  contract     JSON NOT NULL,
  done         TINYINT(1) NOT NULL DEFAULT 0,
  done_at      TIMESTAMP NULL DEFAULT NULL,
  PRIMARY KEY (character_id, day, slot),
  KEY idx_contracts_done (character_id, done, day),
  CONSTRAINT fk_contracts_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
