-- Gear rows that never got an equipment slot (the original Crossworlds seed left `equipment_slot` NULL on augment_copper, augment_iron and
-- kit_iron_warden, and possibly other pre-Death-Muffin gear). POST /api/inventory/equip rejects a NULL slot with "item is not configured as
-- equippable", so a player could not wear an Iron Augment. Additive, idempotent, touches only NULL slots of gear-typed rows; safe to rerun.
-- Apply to the Death Muffin database after a backup. Nothing else (client, server code) has to ship with it.
-- Slot names are the server's reservedSlots keys (server.js /api/inventory/equip); they match src/content/gear.ts TYPE_TO_SLOT.
UPDATE items
   SET equipment_slot = CASE item_type
         WHEN 'weapon'      THEN 'main_hand'
         WHEN 'offhand'     THEN 'off_hand'
         WHEN 'armor_head'  THEN 'head'
         WHEN 'armor_chest' THEN 'chest'
         WHEN 'armor_legs'  THEN 'legs'
         WHEN 'armor_feet'  THEN 'feet'
         WHEN 'armor_hands' THEN 'hands'
         WHEN 'ring'        THEN 'ring'
         WHEN 'trinket'     THEN 'trinket'
       END
 WHERE equipment_slot IS NULL
   AND item_type IN ('weapon','offhand','armor_head','armor_chest','armor_legs','armor_feet','armor_hands','ring','trinket');
