-- 002-gathering.sql — the professions/gathering layer (docs/PROFESSIONS-ROADMAP.md §8).
-- Death Muffin database `death_muffin` ONLY. Additive and idempotent: safe to re-run.
-- Take a mysqldump first (server/death-muffin/GATHERING_DEPLOY.md).
--
-- STEP 0 (check once, by hand): new profession ids 'gravedigging' and 'gardening'
-- go into professions.profession_id. If that column is an ENUM, widen it first:
--   SHOW COLUMNS FROM professions LIKE 'profession_id';
--   -- only if Type starts with enum(...):
--   ALTER TABLE professions MODIFY profession_id VARCHAR(32) NOT NULL;

-- 1. Time budget per character for POST /api/gather.
CREATE TABLE IF NOT EXISTS gather_ledger (
  character_id  INT NOT NULL PRIMARY KEY,
  last_at       BIGINT UNSIGNED NOT NULL DEFAULT 0,   -- ms timestamp of the last accepted batch
  hour_start    BIGINT UNSIGNED NOT NULL DEFAULT 0,   -- start of the current hour window (ms)
  hour_actions  INT UNSIGNED NOT NULL DEFAULT 0,      -- actions accepted in that window
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 2. New gathered materials (stack to 250, like every gathered material below).
INSERT IGNORE INTO items
  (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus, icon_id, sell_value, crafted, stackable, max_stack_size)
VALUES
  ('log_elm',            'Elm Log',              'common',   'material', NULL, 0, '{}', NULL,  3, 0, 1, 250),
  ('log_willow',         'Willow Log',           'uncommon', 'material', NULL, 0, '{}', NULL,  6, 0, 1, 250),
  ('log_yew',            'Yew Log',              'uncommon', 'material', NULL, 0, '{}', NULL, 10, 0, 1, 250),
  ('log_blackthorn',     'Blackthorn Log',       'rare',     'material', NULL, 0, '{}', NULL, 16, 0, 1, 250),
  ('log_ghostwood',      'Ghostwood Log',        'rare',     'material', NULL, 0, '{}', NULL, 24, 0, 1, 250),
  ('log_bone_elder',     'Bone Elder Log',       'epic',     'material', NULL, 0, '{}', NULL, 36, 0, 1, 250),
  ('fish_crypt_eel',     'Crypt Eel',            'common',   'material', NULL, 0, '{}', NULL,  3, 0, 1, 250),
  ('fish_bell_carp',     'Bell Carp',            'uncommon', 'material', NULL, 0, '{}', NULL,  6, 0, 1, 250),
  ('fish_drowned_pike',  'Drowned Pike',         'uncommon', 'material', NULL, 0, '{}', NULL, 10, 0, 1, 250),
  ('fish_lanternfish',   'Lanternfish',          'rare',     'material', NULL, 0, '{}', NULL, 16, 0, 1, 250),
  ('fish_coelacanth',    'Abyssal Coelacanth',   'epic',     'material', NULL, 0, '{}', NULL, 30, 0, 1, 250),
  ('bones_old',          'Old Bones',            'common',   'material', NULL, 0, '{}', NULL,  1, 0, 1, 250),
  ('bones_barrow',       'Barrow Bones',         'common',   'material', NULL, 0, '{}', NULL,  4, 0, 1, 250),
  ('bones_crypt',        'Crypt Bones',          'uncommon', 'material', NULL, 0, '{}', NULL,  8, 0, 1, 250),
  ('bones_ancient',      'Ancient Bones',        'rare',     'material', NULL, 0, '{}', NULL, 18, 0, 1, 250),
  ('seed_mourning_moss', 'Mourning Moss Seed',   'common',   'material', NULL, 0, '{}', NULL,  2, 0, 1, 250),
  ('reliquary_fragment', 'Reliquary Fragment',   'rare',     'material', NULL, 0, '{}', NULL, 25, 0, 1, 250),
  ('covenant_seal',      'Covenant Seal',        'epic',     'material', NULL, 0, '{}', NULL, 60, 0, 1, 250),
  ('gem_grave_garnet',   'Grave Garnet',         'uncommon', 'material', NULL, 0, '{}', NULL, 20, 0, 1, 250),
  ('gem_bone_opal',      'Bone Opal',            'rare',     'material', NULL, 0, '{}', NULL, 45, 0, 1, 250),
  ('gem_void_sapphire',  'Void Sapphire',        'epic',     'material', NULL, 0, '{}', NULL, 90, 0, 1, 250);

-- 3. Existing materials that gathering now grants: make sure they stack to 250 too
--    (only ever raises a limit; no other column changes).
UPDATE items SET stackable = 1, max_stack_size = GREATEST(COALESCE(max_stack_size, 1), 250)
 WHERE id IN ('log_oak', 'fish_river', 'ore_copper', 'ore_tin', 'ore_iron', 'ore_bronze',
              'ore_silver', 'ore_gold', 'ore_steel', 'ore_hell', 'ore_moon')
   AND item_type = 'material';

-- Rollback (code first: remove the mountGathering line and restart; then, if wanted):
--   DROP TABLE gather_ledger;
--   Gathered item rows are harmless to keep. To remove them, first make sure no
--   inventory row references them:  SELECT COUNT(*) FROM inventory WHERE item_id IN (...);
