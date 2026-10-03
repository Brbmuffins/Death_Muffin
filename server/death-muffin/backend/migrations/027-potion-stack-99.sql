-- 027: minor potions stacked to 40 on the server while the client stacked without a cap, so a 41st potion made every bag
-- save fail (400 "exceeds its maximum stack size"). Align them with every other brew/flask at 99. Idempotent.
UPDATE items SET max_stack_size = 99 WHERE id IN ('flask_hp_minor', 'flask_mp_minor') AND max_stack_size < 99;
