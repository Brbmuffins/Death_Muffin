-- 037-loadout-presets.sql — necromancer loadout presets (Grimoire -> Loadouts): rites, socketed runes and worn weapon/off-hand saved
-- together under a name, up to six per character (slot 0..5). `data` is the validated preset JSON (gameplay/loadoutRules.ts); the gear half is
-- applied server-side over the inventory rows, so a preset only ever names items, never grants them. Additive and idempotent.
-- Apply BEFORE deploying the client that calls /api/loadouts (the backend restart needs the table; the old client never calls it).

CREATE TABLE IF NOT EXISTS character_loadouts (
  character_id INT UNSIGNED NOT NULL,
  slot         TINYINT UNSIGNED NOT NULL,
  name         VARCHAR(24) NOT NULL,
  data         JSON NOT NULL,
  updated_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (character_id, slot),
  CONSTRAINT fk_character_loadouts_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
