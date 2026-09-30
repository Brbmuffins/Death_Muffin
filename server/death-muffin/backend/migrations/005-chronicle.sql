-- 005-chronicle.sql — the Chronicle: lifetime stats that Ascension never resets, plus one archived row per finished run.
-- Additive and idempotent (CREATE TABLE IF NOT EXISTS). Counters are merged by chronicle.cjs; nothing else reads these tables
-- except the public leaderboard's totals.

CREATE TABLE IF NOT EXISTS character_chronicle (
  character_id   INT UNSIGNED NOT NULL PRIMARY KEY,
  life           JSON NOT NULL,
  run            JSON NOT NULL,
  run_no         INT UNSIGNED NOT NULL DEFAULT 1,
  run_started_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_chronicle_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS character_runs (
  id              INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  character_id    INT UNSIGNED NOT NULL,
  run_no          INT UNSIGNED NOT NULL,
  started_at      TIMESTAMP NOT NULL,
  ended_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ascension_after TINYINT UNSIGNED NOT NULL DEFAULT 0,
  stats           JSON NOT NULL,
  KEY idx_runs_character (character_id, run_no),
  CONSTRAINT fk_runs_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
