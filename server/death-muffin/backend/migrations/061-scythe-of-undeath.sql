-- The Scythe of Undeath: one Reaper test weapon with three affixes, made at the Workbench (server/rules/content/undeathScythe.ts). Additive and safe to rerun.
INSERT IGNORE INTO items
  (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus, icon_id, sell_value, crafted, stackable, max_stack_size)
VALUES
  ('scythe_of_undeath', 'Scythe of Undeath', 'legendary', 'weapon', 'main_hand', 0, '{"stat_int":26,"stat_vit":11}', 'art/items/scythe_of_undeath.svg', 400, 0, 0, 1);
INSERT IGNORE INTO recipes (id, name, profession_id, skill_level_required, result_item_id, recipe_type, craft_time_seconds, result_quantity) VALUES ('craft_scythe_of_undeath', 'Scythe of Undeath', 'mining', 1, 'scythe_of_undeath', 'craft', 6, 1);
INSERT IGNORE INTO recipe_ingredients (recipe_id, item_id, quantity) VALUES ('craft_scythe_of_undeath', 'ingot_copper', 1);
INSERT IGNORE INTO recipe_ingredients (recipe_id, item_id, quantity) VALUES ('craft_scythe_of_undeath', 'bones_old', 1);
