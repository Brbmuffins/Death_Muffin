-- Armor set item rows (Soul Harbinger’s Raiment; 5 pieces), written by tools/generate-armor-assets.mjs; additive and safe to rerun.
INSERT IGNORE INTO items
  (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus, icon_id, sell_value, crafted, stackable, max_stack_size)
VALUES
  ('leg_soul_harbingers_head', 'Harbinger’s Hood', 'legendary', 'armor_head', 'head', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_soul_harbingers_head.svg', 120, 0, 0, 1),
  ('leg_soul_harbingers_chest', 'Harbinger’s Ribcage', 'legendary', 'armor_chest', 'chest', 0, '{"stat_int":15,"stat_vit":7}', 'art/items/leg_soul_harbingers_chest.svg', 180, 0, 0, 1),
  ('leg_soul_harbingers_hands', 'Harbinger’s Grasp', 'legendary', 'armor_hands', 'hands', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_soul_harbingers_hands.svg', 120, 0, 0, 1),
  ('leg_soul_harbingers_legs', 'Harbinger’s Legwraps', 'legendary', 'armor_legs', 'legs', 0, '{"stat_int":12,"stat_vit":5}', 'art/items/leg_soul_harbingers_legs.svg', 150, 0, 0, 1),
  ('leg_soul_harbingers_feet', 'Harbinger’s Treads', 'legendary', 'armor_feet', 'feet', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_soul_harbingers_feet.svg', 120, 0, 0, 1);
