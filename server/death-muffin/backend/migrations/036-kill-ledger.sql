-- 036: server authority, step 2 (docs/SERVER-AUTHORITY.md "Step 2: the kill ledger").
--
-- character_kill_ledger: one row per character that has reported kills. The browser reports each kill (what, where, how old) in small
-- batches; the server validates the batch against real time and the game's tables and turns the valid part into CREDITS: kills per
-- ground, XP, gold and soul shards. The save routes can only pay out of credits when AUTHORITY_KILLS=enforce (audit just compares).
-- It also keeps the refilling buckets that bound the reports (kills, bosses, floors), the lump allowances for non-kill income, the play-time
-- bucket for the Chronicle, the deepest Catacomb Depths floor proven, and the lifetime totals the leaderboard is checked against.
--
-- Grandfathering: the row is created at first sight with kills_base = the character's necromancer total_kills and depth_proved = its Chronicle
-- peak.depth, so existing leaderboard numbers stand and only NEW gains need a ledger behind them.
--
-- Additive and idempotent. The backend fails open when the table is missing, and AUTHORITY_KILLS defaults to off, so this can be applied
-- before the code that uses it. Rollback: DROP TABLE character_kill_ledger; (nothing else reads it).
CREATE TABLE IF NOT EXISTS character_kill_ledger (
  character_id INT UNSIGNED NOT NULL,
  -- last accepted report sequence (client milliseconds, strictly increasing): a replayed or older report is ignored.
  seq BIGINT UNSIGNED NOT NULL DEFAULT 0,
  -- epoch ms the report buckets were last refilled; NULL = not used yet (starts with a few minutes in the bank).
  bucket_at BIGINT UNSIGNED NULL DEFAULT NULL,
  kill_bucket DOUBLE NOT NULL DEFAULT 0,
  boss_bucket DOUBLE NOT NULL DEFAULT 0,
  floor_bucket DOUBLE NOT NULL DEFAULT 0,
  -- credits a save may still claim
  xp_credit BIGINT UNSIGNED NOT NULL DEFAULT 0,
  gold_credit BIGINT UNSIGNED NOT NULL DEFAULT 0,
  shard_credit INT UNSIGNED NOT NULL DEFAULT 0,
  -- { "<ground>": kills still claimable in a necromancer save }
  kill_credit JSON NULL,
  -- refilling allowances for income that is not a kill (labour, contracts, milestones, rounding): XP and gold
  lump_xp DOUBLE NOT NULL DEFAULT 0,
  lump_gold DOUBLE NOT NULL DEFAULT 0,
  lump_at BIGINT UNSIGNED NULL DEFAULT NULL,
  -- Chronicle play-time bucket (seconds) and the clock it refills on
  play_bucket DOUBLE NOT NULL DEFAULT 0,
  play_at BIGINT UNSIGNED NULL DEFAULT NULL,
  -- deepest Catacomb Depths floor proven by floor-clear reports (grandfathered from the Chronicle) and the highest floor cleared
  depth_proved INT UNSIGNED NOT NULL DEFAULT 0,
  max_cleared INT UNSIGNED NOT NULL DEFAULT 0,
  -- the necromancer total_kills this ledger was started (or last re-based, after an offline load) from, and kills validated since
  kills_base BIGINT UNSIGNED NOT NULL DEFAULT 0,
  kills_total BIGINT UNSIGNED NOT NULL DEFAULT 0,
  bosses_total BIGINT UNSIGNED NOT NULL DEFAULT 0,
  floors_total BIGINT UNSIGNED NOT NULL DEFAULT 0,
  -- lifetime credited vs. lifetime claimed: xp_total should stay at or above xp_used for honest play (the audit-mode health check)
  xp_total BIGINT UNSIGNED NOT NULL DEFAULT 0,
  gold_total BIGINT UNSIGNED NOT NULL DEFAULT 0,
  shards_total BIGINT UNSIGNED NOT NULL DEFAULT 0,
  xp_used BIGINT UNSIGNED NOT NULL DEFAULT 0,
  gold_used BIGINT UNSIGNED NOT NULL DEFAULT 0,
  reports INT UNSIGNED NOT NULL DEFAULT 0,
  rejected_kills BIGINT UNSIGNED NOT NULL DEFAULT 0,
  last_report_at BIGINT UNSIGNED NULL DEFAULT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (character_id),
  CONSTRAINT fk_character_kill_ledger_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
