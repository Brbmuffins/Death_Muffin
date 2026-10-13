-- 048-benchmark-runs.sql — in-game benchmark history (owner 2026-10-13): the Godot client uploads every finished benchmark run
-- (Character select -> Benchmark) so performance can be tracked across builds and PCs; the public page site/benchmarks.html lists them.
-- One row per run; (account_id, client_run_id) is unique so a retried upload is a no-op. `flagged` runs (vsync-capped or cancelled) are kept
-- but left out of trends by default. The headline columns are for sorting and charts; `metrics` / `breakdown` / `report` hold the rest.
-- Additive and idempotent: safe to run twice. Apply BEFORE restarting the backend that mounts benchmarks.cjs; until then GET /api/benchmarks
-- answers an empty list and POST a readable 503. Rollback: DROP TABLE benchmark_runs;

CREATE TABLE IF NOT EXISTS benchmark_runs (
  id               INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  account_id       INT UNSIGNED NOT NULL,
  client_run_id    VARCHAR(40) NOT NULL,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ran_at           DATETIME NULL,
  version          VARCHAR(40) NULL,
  godot            VARCHAR(60) NULL,
  gpu              VARCHAR(120) NULL,
  cpu              VARCHAR(120) NULL,
  cores            SMALLINT UNSIGNED NULL,
  os               VARCHAR(40) NULL,
  renderer         VARCHAR(80) NULL,
  resolution       VARCHAR(20) NULL,
  refresh_hz       FLOAT NULL,
  preset           VARCHAR(16) NULL,
  room             VARCHAR(32) NULL,
  discipline_index TINYINT UNSIGNED NULL,
  size             VARCHAR(12) NULL,
  length           VARCHAR(12) NULL,
  standard         TINYINT(1) NOT NULL DEFAULT 0,
  flagged          TINYINT(1) NOT NULL DEFAULT 0,
  flag_reason      VARCHAR(40) NULL,
  avg_fps          FLOAT NULL,
  p95_ms           FLOAT NULL,
  p99_ms           FLOAT NULL,
  worst_ms         FLOAT NULL,
  hitches          INT NULL,
  draw_calls       FLOAT NULL,
  kills_per_min    FLOAT NULL,
  metrics          JSON NULL,
  breakdown        JSON NULL,
  report           MEDIUMTEXT NULL,
  UNIQUE KEY uq_benchmark_run (account_id, client_run_id),
  KEY idx_benchmark_setup (room, discipline_index, size, length),
  KEY idx_benchmark_created (created_at),
  CONSTRAINT fk_benchmark_account FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
