-- Offline sync keeps a recoverable copy of both choices before a full save is loaded.
CREATE TABLE IF NOT EXISTS character_save_versions (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  account_id INT UNSIGNED NOT NULL,
  character_id INT UNSIGNED NOT NULL,
  source VARCHAR(16) NOT NULL,
  snapshot JSON NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_save_versions_character (character_id, id),
  CONSTRAINT fk_save_versions_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE,
  CONSTRAINT fk_save_versions_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
