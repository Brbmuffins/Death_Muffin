-- 058-team-bench.sql — the team app's second job, `bench` (ROADMAP Phase 1 "New: the team app"): after every client release each team PC benchmarks the release
-- build and its runs land on the public benchmarks page under that member's account, marked as team-PC runs.
--   team_jobs.target_pc        a job with a target is offered to, and may be claimed by, that PC only (team_pcs.pc_id); NULL = any team PC, as before.
--   benchmark_runs.source      NULL for a run a player sent from the game; 'team' for a run a team PC uploaded with its finished `bench` job. Set by the server only, never read from a POST.
--   benchmark_runs.source_pc   the team PC (its pc_id) a 'team' run came from; NULL otherwise. Never returned by the public API.
-- Additive and idempotent: safe to run twice, existing rows keep NULL. Apply BEFORE restarting the backend that mounts team-jobs.cjs and benchmarks.cjs
-- (deploy-release.sh does): the new code names these columns. Rollback: ALTER TABLE team_jobs DROP COLUMN target_pc;
-- ALTER TABLE benchmark_runs DROP COLUMN source_pc, DROP COLUMN source;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'team_jobs' AND COLUMN_NAME = 'target_pc');
SET @sql := IF(@has = 0, 'ALTER TABLE team_jobs ADD COLUMN target_pc VARCHAR(64) NULL', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'benchmark_runs' AND COLUMN_NAME = 'source');
SET @sql := IF(@has = 0, 'ALTER TABLE benchmark_runs ADD COLUMN source VARCHAR(12) NULL', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'benchmark_runs' AND COLUMN_NAME = 'source_pc');
SET @sql := IF(@has = 0, 'ALTER TABLE benchmark_runs ADD COLUMN source_pc VARCHAR(64) NULL', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
