-- 021: server authority, step 1 (docs/SERVER-AUTHORITY.md). Plausibility guards for level, XP, gold and items.
--
-- character_authority: one small row per character that remembers how much the server will believe next. It holds an XP and a
-- gold allowance that refill with real time (a token bucket), the gold credited for items the character gave up (sold), a
-- per-item allowance for things that can only come off the ground, and counters. Nothing the game plays from lives here.
-- progress_audit: one row per save that looked wrong (or was held back, or an offline save that needed confirming). Read it
-- before switching AUTHORITY_MODE from report to enforce.
--
-- Additive and idempotent: safe to run twice. Both tables vanish with their character or account. Rollback: DROP TABLE
-- progress_audit; DROP TABLE character_authority; (the game does not read them; the backend fails open when they are missing).
CREATE TABLE IF NOT EXISTS character_authority (
  character_id INT UNSIGNED NOT NULL,
  xp_bucket DOUBLE NOT NULL DEFAULT 0,
  gold_bucket DOUBLE NOT NULL DEFAULT 0,
  -- epoch milliseconds the buckets were last refilled; NULL = this character has not been seen since the guards shipped.
  bucket_at BIGINT UNSIGNED NULL DEFAULT NULL,
  gold_credit BIGINT UNSIGNED NOT NULL DEFAULT 0,
  -- { "<item_id>": { "b": units still allowed, "t": epoch ms } }; an item missing here has its full allowance.
  item_budget JSON NULL,
  last_progress_at BIGINT UNSIGNED NULL DEFAULT NULL,
  last_bag_at BIGINT UNSIGNED NULL DEFAULT NULL,
  xp_accepted BIGINT UNSIGNED NOT NULL DEFAULT 0,
  gold_accepted BIGINT UNSIGNED NOT NULL DEFAULT 0,
  flags INT UNSIGNED NOT NULL DEFAULT 0,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (character_id),
  CONSTRAINT fk_character_authority_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS progress_audit (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  character_id INT UNSIGNED NOT NULL,
  account_id INT UNSIGNED NOT NULL,
  -- xp_rate | xp_stale | gold_rate | stat_raise | item_intro | roll_gear | offline_load | offline_stats
  kind VARCHAR(24) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  -- the mode in force when it happened: report | enforce
  mode VARCHAR(8) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  -- what was done about it: report (nothing changed) | clamp | refuse | confirm (the player accepted an offline load)
  action VARCHAR(8) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  detail JSON NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_progress_audit_character (character_id, id),
  KEY idx_progress_audit_kind (kind, id),
  CONSTRAINT fk_progress_audit_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE,
  CONSTRAINT fk_progress_audit_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
