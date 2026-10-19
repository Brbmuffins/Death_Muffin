-- 060-team-job-thread.sql — who asked for a team job, for the team app's job list (Helix 2026-10-19: "if it came from a discord thread the thread owner should have their
-- name there so people can run their own jobs", with the thread's name): the Discord agent sends both when it queues a job for a proposal.
--   team_jobs.requested_by   the name of the person who started the Discord thread; NULL for a job queued another way (a session, team-check.sh).
--   team_jobs.thread_name    the thread's name without emojis; NULL as above.
-- Additive and idempotent: safe to run twice, existing rows keep NULL. Apply BEFORE restarting the backend whose team-jobs.cjs names these columns (deploy-release.sh does).
-- Rollback: ALTER TABLE team_jobs DROP COLUMN thread_name, DROP COLUMN requested_by;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'team_jobs' AND COLUMN_NAME = 'requested_by');
SET @sql := IF(@has = 0, 'ALTER TABLE team_jobs ADD COLUMN requested_by VARCHAR(64) NULL', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'team_jobs' AND COLUMN_NAME = 'thread_name');
SET @sql := IF(@has = 0, 'ALTER TABLE team_jobs ADD COLUMN thread_name VARCHAR(120) NULL', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
