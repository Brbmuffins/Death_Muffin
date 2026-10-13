-- 047-drop-tape.sql — server-decided drops (server authority Phase 1, drops.cjs, DECISIONS B20).
-- character_drop_tape: per character, how far each drop kind's tape was issued (`issued`) and spent (`spent`: the highest event index claimed
-- or passed over, +1), and the kill ledger's totals when the tape started (the budget a tape is spent against). character_drop_events: one row
-- per drop event the server has rolled (on its first claim), with the facts it was rolled from, what it dropped and which drops were claimed.
-- Additive and idempotent: safe to run twice. Apply BEFORE restarting the backend that mounts drops.cjs (deploy-release.sh does).
-- Rollback: DROP TABLE character_drop_events; DROP TABLE character_drop_tape;

CREATE TABLE IF NOT EXISTS character_drop_tape (
  character_id    INT UNSIGNED NOT NULL PRIMARY KEY,
  issued          JSON NOT NULL,
  spent           JSON NOT NULL,
  base_kills      BIGINT UNSIGNED NOT NULL DEFAULT 0,
  base_bosses     BIGINT UNSIGNED NOT NULL DEFAULT 0,
  last_rune_elite INT NOT NULL DEFAULT -1,
  last_surge_at   BIGINT UNSIGNED NOT NULL DEFAULT 0,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS character_drop_events (
  character_id INT UNSIGNED NOT NULL,
  kind         VARCHAR(8) NOT NULL,
  n            INT UNSIGNED NOT NULL,
  facts        JSON NOT NULL,
  items        JSON NOT NULL,
  claimed      JSON NOT NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (character_id, kind, n),
  KEY idx_drop_events_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
