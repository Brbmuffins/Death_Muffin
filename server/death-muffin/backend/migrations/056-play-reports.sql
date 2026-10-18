-- 056-play-reports.sql — play reports (ROADMAP Phase 1, "New: play reports"): when a play session ends, the game sends one small summary
-- (how smoothly it ran, the graphics preset and card, time and deaths per area, how the session ended). play-reports.cjs stores it and the
-- public page site/play-reports.html shows the numbers per release, beside the server's own numbers over the party sessions the report names.
-- One row per session; (account_id, report_id) is unique so a resent report is a no-op. The account id is kept only to count players and to cap
-- spam and is never returned. The headline numbers are columns for the page's sums; the frame histogram, the per-area table and the party
-- session ids are JSON. Nothing personal is stored: no names, no emails, no chat.
-- Additive and idempotent: safe to run twice. Apply BEFORE restarting the backend that mounts play-reports.cjs; until then GET answers an empty
-- list and POST a readable 503. Rollback: DROP TABLE play_reports;

CREATE TABLE IF NOT EXISTS play_reports (
  id               INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  account_id       INT UNSIGNED NOT NULL,
  report_id        VARCHAR(64) NOT NULL,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version          VARCHAR(40) NOT NULL,
  seconds          FLOAT NOT NULL DEFAULT 0,
  end_reason       VARCHAR(12) NOT NULL DEFAULT 'unknown',
  end_area         VARCHAR(24) NULL,
  discipline_index TINYINT UNSIGNED NULL,
  level            SMALLINT UNSIGNED NULL,
  party_size       TINYINT UNSIGNED NULL,
  host             TINYINT(1) NOT NULL DEFAULT 0,
  preset           VARCHAR(8) NULL,
  gpu              VARCHAR(120) NULL,
  driver           VARCHAR(60) NULL,
  os               VARCHAR(40) NULL,
  cpu_cores        SMALLINT UNSIGNED NULL,
  ram_mb           INT UNSIGNED NULL,
  resolution       VARCHAR(20) NULL,
  vsync            TINYINT(1) NULL,
  fps_cap          SMALLINT UNSIGNED NULL,
  frames_count     INT UNSIGNED NOT NULL DEFAULT 0,
  avg_ms           FLOAT NULL,
  p50_ms           FLOAT NULL,
  p99_ms           FLOAT NULL,
  worst_ms         FLOAT NULL,
  hitches          INT UNSIGNED NOT NULL DEFAULT 0,
  frame_hist       JSON NULL,
  areas            JSON NULL,
  session_ids      JSON NULL,
  UNIQUE KEY uq_play_report (account_id, report_id),
  KEY idx_play_report_version (version, created_at),
  KEY idx_play_report_account_time (account_id, created_at),
  CONSTRAINT fk_play_report_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
