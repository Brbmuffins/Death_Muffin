-- 020: item level and affixes (GRIND-LOOP #2). Server-rolled loot instances.
--
-- A gear drop that rolled an item level and affixes gets one row here; the bag (inventory) and the Vault (account_vault) point at it
-- by instance_id. The client never sends affixes: it can only name an instance the server created for this account, so a bag save
-- cannot mint or edit a roll (inventory-save.cjs checks owner and item). Plain rows keep instance_id NULL and keep working exactly
-- as before (base stats from items.stat_bonus). Named loot_instances because the legacy Crossworlds table item_instance exists.
--
-- Additive and idempotent: safe to run twice. Deleting an instance leaves the item as a plain row (ON DELETE SET NULL).
CREATE TABLE IF NOT EXISTS loot_instances (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id INT UNSIGNED NOT NULL,
  item_id VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  ilvl SMALLINT UNSIGNED NOT NULL,
  affixes JSON NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_loot_instances_account (account_id, created_at),
  CONSTRAINT fk_loot_instances_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE,
  CONSTRAINT fk_loot_instances_item FOREIGN KEY (item_id) REFERENCES items (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- inventory.instance_id (UNIQUE: one instance, one row, across every character).
SET @ddl = (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE inventory ADD COLUMN instance_id BIGINT UNSIGNED NULL DEFAULT NULL, ADD UNIQUE KEY uq_inventory_instance (instance_id), ADD CONSTRAINT fk_inventory_instance FOREIGN KEY (instance_id) REFERENCES loot_instances (id) ON DELETE SET NULL',
  'SELECT 1')
  FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'inventory' AND COLUMN_NAME = 'instance_id');
PREPARE st FROM @ddl; EXECUTE st; DEALLOCATE PREPARE st;

-- account_vault.instance_id
SET @ddl = (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE account_vault ADD COLUMN instance_id BIGINT UNSIGNED NULL DEFAULT NULL, ADD UNIQUE KEY uq_account_vault_instance (instance_id), ADD CONSTRAINT fk_account_vault_instance FOREIGN KEY (instance_id) REFERENCES loot_instances (id) ON DELETE SET NULL',
  'SELECT 1')
  FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'account_vault' AND COLUMN_NAME = 'instance_id');
PREPARE st FROM @ddl; EXECUTE st; DEALLOCATE PREPARE st;
