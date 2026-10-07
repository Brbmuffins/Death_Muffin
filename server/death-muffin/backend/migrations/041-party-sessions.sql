-- 041: host-reported party sessions (SESSION-REPORTS.md, Godot rebuild decision D1).
--
-- A host (one player's Godot game) runs a session for 1-4 players and reports what the session's members killed. The kill ledger
-- (migration 036, kills.cjs) still does ALL the judging and crediting, per member, exactly as if each member had reported their own
-- kills. These two tables only record who is in which session, so a host can never credit a character whose owner did not attach, plus
-- the idempotency cursor (last_batch) and the counters the end-of-session cross-check reads.
--
-- Additive and idempotent. The session routes answer 503 when the tables are missing and nothing else reads them.
-- Rollback: DROP TABLE party_session_members; DROP TABLE party_sessions;
CREATE TABLE IF NOT EXISTS party_sessions (
  -- 32 hex chars from the CSPRNG: unguessable, it is the invite the host hands out through the lobby
  id CHAR(32) NOT NULL,
  host_account_id INT UNSIGNED NOT NULL,
  host_character_id INT UNSIGNED NOT NULL,
  status ENUM('open', 'ended') NOT NULL DEFAULT 'open',
  created_at BIGINT UNSIGNED NOT NULL,
  -- epoch ms of the host's last authenticated call; a session idle past SESSION_IDLE_MS counts as ended
  last_host_at BIGINT UNSIGNED NOT NULL,
  -- highest accepted batch number (strictly increasing; a repeat or older number is a duplicate and ignored)
  last_batch BIGINT UNSIGNED NOT NULL DEFAULT 0,
  batches INT UNSIGNED NOT NULL DEFAULT 0,
  ended_at BIGINT UNSIGNED NULL DEFAULT NULL,
  ended_reason VARCHAR(24) NULL DEFAULT NULL,
  -- the host's end-of-session summary, sanitised and size-limited (informational: nothing is credited from it)
  summary JSON NULL,
  PRIMARY KEY (id),
  KEY idx_party_sessions_host (host_account_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS party_session_members (
  session_id CHAR(32) NOT NULL,
  character_id INT UNSIGNED NOT NULL,
  account_id INT UNSIGNED NOT NULL,
  status ENUM('active', 'left') NOT NULL DEFAULT 'active',
  joined_at BIGINT UNSIGNED NOT NULL,
  left_at BIGINT UNSIGNED NULL DEFAULT NULL,
  -- the member's own "I was there" heartbeat; a report only credits a member seen recently
  last_seen_at BIGINT UNSIGNED NOT NULL,
  -- the member's own count of kills it saw (monotonic, from its heartbeats): the end-of-session cross-check compares it with the host's
  seen_kills BIGINT UNSIGNED NOT NULL DEFAULT 0,
  -- the sequence number last handed to the kill ledger for this member (strictly increasing)
  last_seq BIGINT UNSIGNED NOT NULL DEFAULT 0,
  reported_kills BIGINT UNSIGNED NOT NULL DEFAULT 0,
  accepted_kills BIGINT UNSIGNED NOT NULL DEFAULT 0,
  accepted_bosses BIGINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (session_id, character_id),
  KEY idx_party_session_members_char (character_id, status),
  CONSTRAINT fk_party_session_members_session FOREIGN KEY (session_id) REFERENCES party_sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_party_session_members_character FOREIGN KEY (character_id) REFERENCES characters (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
