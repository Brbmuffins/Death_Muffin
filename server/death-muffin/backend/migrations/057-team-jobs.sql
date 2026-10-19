-- 057-team-jobs.sql — the team app's job queue (ROADMAP Phase 1, "New: the team app"; DECISIONS B54, B55): jobs that need a real graphics card run on
-- the team's own PCs (a small Windows app); the server queues them, the app claims one, uploads its results and finishes it. team-jobs.cjs
-- is the only code that uses these tables.
--   team_members  the accounts that may use the team routes. Rows are added by hand (README "Team jobs"), never by a route or a migration.
--   team_tokens   the team app's own sign-ins: a token per PC, kept only as its SHA-256, good for 90 days, never the game's login session.
--   team_pcs      every PC that sent a heartbeat: its mode (ask | auto | yes) and state, and when it was last seen.
--   team_jobs     the queue: queued -> running -> done | failed; queued -> expired; queued | running -> cancelled.
-- Additive and idempotent: safe to run twice. Apply BEFORE restarting the backend that mounts team-jobs.cjs; until then every team route
-- answers a readable 503. Rollback: DROP TABLE team_jobs; DROP TABLE team_pcs; DROP TABLE team_tokens; DROP TABLE team_members;

CREATE TABLE IF NOT EXISTS team_members (
  account_id  INT UNSIGNED NOT NULL PRIMARY KEY,
  added_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_team_member_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS team_tokens (
  token_hash  CHAR(64) NOT NULL PRIMARY KEY,
  account_id  INT UNSIGNED NOT NULL,
  pc_id       VARCHAR(64) NOT NULL,
  pc_name     VARCHAR(64) NOT NULL DEFAULT '',
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  last_used   DATETIME NULL,
  expires_at  DATETIME NOT NULL,
  revoked     TINYINT(1) NOT NULL DEFAULT 0,
  KEY idx_team_tokens_account (account_id, revoked, expires_at),
  CONSTRAINT fk_team_token_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS team_pcs (
  account_id  INT UNSIGNED NOT NULL,
  pc_id       VARCHAR(64) NOT NULL,
  name        VARCHAR(64) NOT NULL DEFAULT '',
  version     VARCHAR(32) NOT NULL DEFAULT '',
  gpu         VARCHAR(120) NOT NULL DEFAULT '',
  mode        VARCHAR(8) NOT NULL DEFAULT 'ask',
  state       JSON NULL,
  last_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (account_id, pc_id),
  KEY idx_team_pcs_seen (last_seen)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS team_jobs (
  id               CHAR(12) NOT NULL PRIMARY KEY,
  kind             VARCHAR(24) NOT NULL,
  title            VARCHAR(160) NOT NULL,
  weight_s         INT UNSIGNED NOT NULL DEFAULT 60,
  payload          JSON NOT NULL,
  status           VARCHAR(12) NOT NULL DEFAULT 'queued',
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),   -- to the millisecond: the oldest queued job is offered first
  expires_at       DATETIME NOT NULL,
  claimed_account  INT UNSIGNED NULL,
  claimed_pc       VARCHAR(64) NULL,
  claimed_at       DATETIME NULL,
  heartbeat_at     DATETIME NULL,
  finished_at      DATETIME NULL,
  result           JSON NULL,
  error            VARCHAR(400) NULL,
  tries            INT UNSIGNED NOT NULL DEFAULT 0,
  KEY idx_team_jobs_status (status, created_at),
  KEY idx_team_jobs_expires (status, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
