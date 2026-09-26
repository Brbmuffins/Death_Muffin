-- Necromancer progression storage (additive migration — no existing table changes).
-- Run once on rod_online AFTER a mysqldump backup (see VPS_HANDOFF.md).
--
-- The whole progression record is one JSON document validated by necro-rules.cjs
-- (the same rules the web client uses). A few generated columns expose the
-- values the GM dashboard / support queries need without parsing JSON by hand.

CREATE TABLE IF NOT EXISTS character_necro_progress (
  character_id  INT UNSIGNED NOT NULL PRIMARY KEY,
  state         JSON NOT NULL,
  version       INT UNSIGNED NOT NULL DEFAULT 0,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  ascension     TINYINT UNSIGNED AS (JSON_UNQUOTE(JSON_EXTRACT(state, '$.ascension'))) STORED,
  boss_kills    INT UNSIGNED AS (JSON_UNQUOTE(JSON_EXTRACT(state, '$.bossKills'))) STORED,
  total_kills   INT UNSIGNED AS (JSON_UNQUOTE(JSON_EXTRACT(state, '$.totalKills'))) STORED,
  KEY idx_ascension (ascension),
  CONSTRAINT fk_necro_progress_character FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- If `characters(id)` is not the real table/column (or its id is signed INT), adjust the FK
-- and the character_id type to match exactly, or drop the CONSTRAINT line — the routes
-- check that the character exists inside every transaction anyway.
--
-- Rollback:  DROP TABLE character_necro_progress;
