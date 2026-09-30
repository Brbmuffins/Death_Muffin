-- 008-labor.sql — Grave Laborers (thrall labour): a laborer works a gathering post on the server clock until you collect.
-- One row per character and slot; node_type NULL = idle. Additive and idempotent.
CREATE TABLE IF NOT EXISTS character_labor (
  character_id INT UNSIGNED NOT NULL,
  slot         TINYINT UNSIGNED NOT NULL,
  node_type    VARCHAR(48) NULL,
  started_at   BIGINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (character_id, slot),
  CONSTRAINT fk_labor_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
