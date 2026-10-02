-- Six legacy gear items stored their stats under unprefixed keys (str/agi/int/vit) with old Crossworlds values, so the client
-- (which reads stat_str/stat_agi/stat_int/stat_vit) gave them NO stats on the live server. This sets each to the game's designed
-- stats from src/content/items.ts (offlineStats), with the right keys. Item definitions only; inventories are untouched. Idempotent.
UPDATE items SET stat_bonus = '{"stat_agi":4}' WHERE id = 'bow_oak';
UPDATE items SET stat_bonus = '{"stat_vit":9,"stat_str":2}' WHERE id = 'chest_iron';
UPDATE items SET stat_bonus = '{"stat_vit":3}' WHERE id = 'helm_copper';
UPDATE items SET stat_bonus = '{"stat_vit":6,"stat_int":4}' WHERE id = 'helm_gold';
UPDATE items SET stat_bonus = '{"stat_vit":5,"stat_str":1}' WHERE id = 'helm_iron';
UPDATE items SET stat_bonus = '{"stat_int":5}' WHERE id = 'staff_oak';
