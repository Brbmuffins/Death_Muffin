-- 029-bug-reports.sql — players' in-game bug reports (Settings → Report a bug), read daily by the bug-report agent
-- (server/death-muffin/bug-agent/). Additive and idempotent. `message` is player text: anything that reads it treats it as data.

CREATE TABLE IF NOT EXISTS bug_reports (
  id           INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  account_id   INT UNSIGNED NOT NULL,
  character_id INT UNSIGNED NULL,
  category     VARCHAR(16) NOT NULL,
  message      TEXT NOT NULL,
  context      JSON NOT NULL,
  status       VARCHAR(16) NOT NULL DEFAULT 'new',
  agent_notes  TEXT NULL,
  fix_ref      VARCHAR(80) NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_bug_reports_status (status, created_at),
  KEY idx_bug_reports_account (account_id, created_at),
  CONSTRAINT fk_bug_reports_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
