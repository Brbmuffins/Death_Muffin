-- Four legendary armor sets (20 pieces); additive and safe to rerun.
-- BEFORE APPLYING: run SHOW COLUMNS FROM items LIKE 'rarity'. The server already accepts 'legendary' (server.js validRarities); if the column is an
-- ENUM without it, widen it first (ALTER TABLE items MODIFY rarity ENUM(...existing values..., 'legendary')). A VARCHAR needs nothing.
-- Apply to the Death Muffin database after a backup, before publishing the client.
INSERT IGNORE INTO items
  (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus, icon_id, sell_value, crafted, stackable, max_stack_size)
VALUES
  ('leg_legion_unburied_head', 'Warcrown of the Unburied', 'legendary', 'armor_head', 'head', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_legion_unburied_head.svg', 120, 0, 0, 1),
  ('leg_legion_unburied_chest', 'Cuirass of the Unburied', 'legendary', 'armor_chest', 'chest', 0, '{"stat_int":15,"stat_vit":7}', 'art/items/leg_legion_unburied_chest.svg', 180, 0, 0, 1),
  ('leg_legion_unburied_hands', 'Gauntlets of the Unburied', 'legendary', 'armor_hands', 'hands', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_legion_unburied_hands.svg', 120, 0, 0, 1),
  ('leg_legion_unburied_legs', 'Greaves of the Unburied', 'legendary', 'armor_legs', 'legs', 0, '{"stat_int":12,"stat_vit":5}', 'art/items/leg_legion_unburied_legs.svg', 150, 0, 0, 1),
  ('leg_legion_unburied_feet', 'Marching Boots of the Unburied', 'legendary', 'armor_feet', 'feet', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_legion_unburied_feet.svg', 120, 0, 0, 1),
  ('leg_colossus_mantle_head', 'Colossus Cowl', 'legendary', 'armor_head', 'head', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_colossus_mantle_head.svg', 120, 0, 0, 1),
  ('leg_colossus_mantle_chest', 'Colossus Mantle', 'legendary', 'armor_chest', 'chest', 0, '{"stat_int":15,"stat_vit":7}', 'art/items/leg_colossus_mantle_chest.svg', 180, 0, 0, 1),
  ('leg_colossus_mantle_hands', 'Colossus Fists', 'legendary', 'armor_hands', 'hands', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_colossus_mantle_hands.svg', 120, 0, 0, 1),
  ('leg_colossus_mantle_legs', 'Colossus Cuisses', 'legendary', 'armor_legs', 'legs', 0, '{"stat_int":12,"stat_vit":5}', 'art/items/leg_colossus_mantle_legs.svg', 150, 0, 0, 1),
  ('leg_colossus_mantle_feet', 'Colossus Footings', 'legendary', 'armor_feet', 'feet', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_colossus_mantle_feet.svg', 120, 0, 0, 1),
  ('leg_requiem_wraiths_head', 'Wraithveil Hood', 'legendary', 'armor_head', 'head', 0, '{"stat_int":9,"stat_agi":4}', 'art/items/leg_requiem_wraiths_head.svg', 120, 0, 0, 1),
  ('leg_requiem_wraiths_chest', 'Requiem Shroud', 'legendary', 'armor_chest', 'chest', 0, '{"stat_int":15,"stat_agi":7}', 'art/items/leg_requiem_wraiths_chest.svg', 180, 0, 0, 1),
  ('leg_requiem_wraiths_hands', 'Wraithgrasp Gloves', 'legendary', 'armor_hands', 'hands', 0, '{"stat_int":9,"stat_agi":4}', 'art/items/leg_requiem_wraiths_hands.svg', 120, 0, 0, 1),
  ('leg_requiem_wraiths_legs', 'Wraithwoven Leggings', 'legendary', 'armor_legs', 'legs', 0, '{"stat_int":12,"stat_agi":5}', 'art/items/leg_requiem_wraiths_legs.svg', 150, 0, 0, 1),
  ('leg_requiem_wraiths_feet', 'Requiem Slippers', 'legendary', 'armor_feet', 'feet', 0, '{"stat_int":9,"stat_agi":4}', 'art/items/leg_requiem_wraiths_feet.svg', 120, 0, 0, 1),
  ('leg_plague_choir_head', 'Choirmaster’s Mask', 'legendary', 'armor_head', 'head', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_plague_choir_head.svg', 120, 0, 0, 1),
  ('leg_plague_choir_chest', 'Plague Choir Surplice', 'legendary', 'armor_chest', 'chest', 0, '{"stat_int":15,"stat_vit":7}', 'art/items/leg_plague_choir_chest.svg', 180, 0, 0, 1),
  ('leg_plague_choir_hands', 'Blightmonger’s Gloves', 'legendary', 'armor_hands', 'hands', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_plague_choir_hands.svg', 120, 0, 0, 1),
  ('leg_plague_choir_legs', 'Choir Rotleggings', 'legendary', 'armor_legs', 'legs', 0, '{"stat_int":12,"stat_vit":5}', 'art/items/leg_plague_choir_legs.svg', 150, 0, 0, 1),
  ('leg_plague_choir_feet', 'Plague Choir Treads', 'legendary', 'armor_feet', 'feet', 0, '{"stat_int":9,"stat_vit":4}', 'art/items/leg_plague_choir_feet.svg', 120, 0, 0, 1);
