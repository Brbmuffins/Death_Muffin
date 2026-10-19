-- 059-team-release.sql — the team app's fourth job, `release` (ROADMAP Phase 1 "New: the team app"): after every client release each team PC runs the release checks
-- (install, quit while loading, screens, stutter, bench, soak) and the results are posted to #build-alerts as one report per release.
--   team_jobs.reported_at   when the report that holds this job's result was posted (set through POST /internal/team/jobs/:id/reported); NULL = not reported yet.
-- Additive and idempotent: safe to run twice, existing rows keep NULL. Apply BEFORE restarting the backend that mounts team-jobs.cjs (deploy-release.sh does): the
-- internal job routes name the column. Rollback: ALTER TABLE team_jobs DROP COLUMN reported_at;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'team_jobs' AND COLUMN_NAME = 'reported_at');
SET @sql := IF(@has = 0, 'ALTER TABLE team_jobs ADD COLUMN reported_at DATETIME NULL', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
