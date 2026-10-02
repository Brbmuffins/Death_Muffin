-- Gear never stacks. 47 legacy Crossworlds starter items (base class sets, copper/iron helms and plates, starter
-- weapons) were stackable to 99, so equipping one moved the whole stack into the equipment slot. No live row holds
-- more than one (checked 2026-10-02); this only changes the item definitions. Idempotent.
UPDATE items
   SET stackable = 0, max_stack_size = 1
 WHERE stackable = 1
   AND item_type IN ('weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands', 'ring', 'trinket');
