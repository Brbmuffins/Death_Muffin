-- Migration tracking (audit 2026-10-15): one row per applied backend/migrations/*.sql, written by server/death-muffin/migrate.sh.
-- The runner applies this file itself before anything else; files 001-054 were recorded as a baseline when it was introduced.
CREATE TABLE IF NOT EXISTS schema_migrations (
  name VARCHAR(128) NOT NULL PRIMARY KEY,
  sha256 CHAR(64) NOT NULL,
  rev VARCHAR(40) NOT NULL DEFAULT '',
  applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
