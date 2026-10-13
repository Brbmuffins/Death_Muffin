-- 044-learned-runes.sql — learned relic runes (owner 2026-10-13): a rune drops as an item, the player clicks Learn on it in the bag, and
-- the character knows it for good. Sockets (inventory slots 130-134) take any learned rune of their rite (runes.cjs); a learned rune never
-- drops for that character again. One row per (character, rune).
-- Additive and idempotent: CREATE IF NOT EXISTS, and every rune already sitting in a socket counts as learned (INSERT IGNORE). Runes in
-- the bag or the Vault stay items: the player learns them with a click.
-- Apply BEFORE restarting the backend that mounts the new runes.cjs. Rollback: DROP TABLE character_runes;

CREATE TABLE IF NOT EXISTS character_runes (
  character_id INT UNSIGNED NOT NULL,
  rune_id      VARCHAR(48) NOT NULL,
  learned_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (character_id, rune_id),
  CONSTRAINT fk_character_runes_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO character_runes (character_id, rune_id)
  SELECT inv.character_id, inv.item_id FROM inventory inv JOIN items i ON i.id = inv.item_id
   WHERE inv.slot_index BETWEEN 130 AND 134 AND i.item_type = 'rune';
