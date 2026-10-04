-- 035-gold-sinks.sql — two gold sinks (docs/polish/loot.md #17, docs/GRIND-LOOP.md §3 #7). Additive and idempotent; no existing table is altered.
--
--  loot_reforges      how many times a rolled piece has been reforged at the Workbench (the price rises with it). A piece with no row has
--                     had none. The row goes when the piece does (salvage, sale, drop delete the loot_instances row).
--  empowered_summons  one row per Covenant-Seal summon of an Empowered area boss: the seal and gold were taken when the row was written,
--                     and the kill's prize is paid once, to the character that holds the row ('open' -> 'claimed'), or the summon is taken
--                     back within two minutes if the host refused it ('open' -> 'refunded'). Unclaimed rows expire after three hours.
--                     `killed_at` is set when the kill ledger (036, kills.cjs) receives a kill report naming this summon; with AUTHORITY_KILLS=enforce
--                     the prize claim needs it. The altar also asks the server which summons are still bound (/api/boss-key/status).
-- Apply BEFORE deploying the backend that serves /api/reforge/* and /api/boss-key/* (those routes answer a readable error until it is).

CREATE TABLE IF NOT EXISTS loot_reforges (
  instance_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  rerolls     SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_loot_reforges_instance FOREIGN KEY (instance_id) REFERENCES loot_instances (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS empowered_summons (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  character_id INT UNSIGNED NOT NULL,
  boss         VARCHAR(16) NOT NULL,
  gold         INT UNSIGNED NOT NULL,
  status       VARCHAR(10) NOT NULL DEFAULT 'open',
  created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  killed_at    TIMESTAMP NULL DEFAULT NULL,
  resolved_at  TIMESTAMP NULL DEFAULT NULL,
  KEY idx_empowered_open (character_id, boss, status, created_at),
  CONSTRAINT fk_empowered_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
