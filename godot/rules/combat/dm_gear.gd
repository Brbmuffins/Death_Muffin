class_name DmGear
extends RefCounted
## Port of src/content/gear.ts (slot resolution only) + the Legion-kit slot predicate from legionRules.ts.
## An inventory slot is a Dictionary shaped like the server row: slot_index, equipped, item_id, item_type, equipped_slot,
## item_equipment_slot, stat_bonus {stat_str..}, inst {ilvl, affixes [{id, v}]}.

const EQUIP_SLOT_IDS: Array[String] = ["head", "chest", "legs", "feet", "hands", "main_hand", "off_hand", "ring", "trinket"]
const TYPE_TO_SLOT := {
	"weapon": "main_hand", "offhand": "off_hand", "armor_head": "head", "armor_chest": "chest", "armor_legs": "legs",
	"armor_feet": "feet", "armor_hands": "hands", "ring": "ring", "trinket": "trinket",
}
const KIT_BASE := 120
const KIT_SLOT_COUNT := 2


static func is_kit_slot(slot: Variant) -> bool:
	if not (slot is int or slot is float):
		return false
	var f := float(slot)
	return f == floorf(f) and f >= KIT_BASE and f < KIT_BASE + KIT_SLOT_COUNT


## The slot an item goes in, or "" (JS null) for materials and consumables. The server's own answer wins.
static func equip_slot_of(s: Dictionary) -> String:
	var own: Variant = DmCombatData.nn(s.get("equipped_slot"), s.get("item_equipment_slot"))
	if DmCombatData.truthy(own) and own is String and EQUIP_SLOT_IDS.has(own):
		return own
	var t: Variant = s.get("item_type")
	if t is String and TYPE_TO_SLOT.has(t):
		return TYPE_TO_SLOT[t]
	return ""


## What is currently worn, by slot id -> slot Dictionary. The Legion kit (slots 120+) is never "yours".
static func equipped_by_slot(slots: Array) -> Dictionary:
	var out := {}
	for s: Dictionary in slots:
		if not DmCombatData.truthy(s.get("equipped")) or is_kit_slot(s.get("slot_index")):
			continue
		var slot := equip_slot_of(s)
		if slot != "":
			out[slot] = s
	return out
