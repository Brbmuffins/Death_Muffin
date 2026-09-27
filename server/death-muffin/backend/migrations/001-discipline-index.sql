-- Apply once to the isolated Death Muffin database. NULL keeps the original class.
-- The original class slot and all character IDs/progress remain unchanged.
ALTER TABLE characters ADD COLUMN discipline_index TINYINT UNSIGNED NULL DEFAULT NULL;
