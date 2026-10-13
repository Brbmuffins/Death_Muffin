-- 045-friends.sql — mutual friends (owner 2026-10-13, Social window): one row per pair of accounts, stored with the lower account id first so
-- a pair can exist only once. `requested_by` sent the request; `status` is 'pending' until the other account accepts. Declining, cancelling
-- and removing all delete the row (friends.cjs).
-- Additive and idempotent: safe to run twice. Apply BEFORE restarting the backend that mounts friends.cjs; until then GET /api/friends
-- answers an empty list and the writes answer a readable 503. Rollback: DROP TABLE friendships;

CREATE TABLE IF NOT EXISTS friendships (
  account_lo   INT UNSIGNED NOT NULL,
  account_hi   INT UNSIGNED NOT NULL,
  requested_by INT UNSIGNED NOT NULL,
  status       ENUM('pending', 'accepted') NOT NULL DEFAULT 'pending',
  created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  accepted_at  TIMESTAMP NULL DEFAULT NULL,
  PRIMARY KEY (account_lo, account_hi),
  KEY idx_friendships_hi (account_hi),
  CONSTRAINT fk_friendships_lo FOREIGN KEY (account_lo) REFERENCES accounts (id) ON DELETE CASCADE,
  CONSTRAINT fk_friendships_hi FOREIGN KEY (account_hi) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
