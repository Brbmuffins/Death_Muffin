-- 017: the Ossuary Vault, a stash shared by every character on an account (120 slots).
-- Additive and idempotent: safe to run twice. Item rows are moved to and from the bag by vault.cjs in one transaction.
CREATE TABLE IF NOT EXISTS account_vault (
  account_id INT UNSIGNED NOT NULL,
  slot_index SMALLINT UNSIGNED NOT NULL,
  item_id VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  quantity INT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (account_id, slot_index),
  KEY idx_account_vault_item (item_id),
  CONSTRAINT fk_account_vault_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE,
  CONSTRAINT fk_account_vault_item FOREIGN KEY (item_id) REFERENCES items (id),
  CONSTRAINT chk_account_vault_slot CHECK (slot_index < 120)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Salvaging: no schema change. The profession row is created on first use (INSERT IGNORE) and every material and reagent it
-- yields already exists in `items` (migrations 002, 004, 009, 014).
