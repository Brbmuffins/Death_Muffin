-- 051-drop-boss-credit.sql — boss drops are backed by paid summons, not by a kill rate (owner 2026-10-14: "it is totally normal to spam low
-- level bosses ... there should not be a limit"). character_drop_tape.boss_credit = boss events this character may claim drops for: +1 for
-- every summon it paid (Prelate bell, area boss, boss key) and +1 for every summon a host it is partying with paid (drops.cjs summonCredits).
-- Starts at what each tape already used, so nobody begins in debt. Additive and idempotent. Rollback: ALTER TABLE character_drop_tape DROP COLUMN boss_credit;

SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'character_drop_tape' AND COLUMN_NAME = 'boss_credit');
SET @sql := IF(@has = 0, 'ALTER TABLE character_drop_tape ADD COLUMN boss_credit BIGINT NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

UPDATE character_drop_tape SET boss_credit = GREATEST(boss_credit, COALESCE(CAST(JSON_EXTRACT(spent, '$.boss') AS SIGNED), 0));
