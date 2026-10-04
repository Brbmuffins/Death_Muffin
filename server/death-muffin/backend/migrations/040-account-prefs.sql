-- 040-account-prefs.sql — per-account UI preferences (one row per account and key), e.g. the Workbench's "Only show craftable" checkbox,
-- so a setting follows the account to any browser or device. `value` is a small JSON scalar; prefs.cjs only stores keys it knows and
-- validates every value. Additive and idempotent: safe to run twice.
-- Apply BEFORE restarting the backend that mounts prefs.cjs. Until then GET /api/prefs answers an empty list and POST answers a readable
-- 503 (the client keeps its browser copy), so nothing breaks if the order is reversed.

CREATE TABLE IF NOT EXISTS account_prefs (
  account_id INT UNSIGNED NOT NULL,
  pref_key   VARCHAR(40) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  value      VARCHAR(200) NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (account_id, pref_key),
  CONSTRAINT fk_account_prefs_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
