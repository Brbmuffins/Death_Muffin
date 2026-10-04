class_name DmProgContent
extends RefCounted
## Loads res://data/progression/content.json (generated from the TS by tools/godot/fixtures-progression.ts):
## areas (order/safe/unlock), bosses, vows, boons, upgrade constants, kill-chain tiers, milestones, limits.

const PATH := "res://data/progression/content.json"

static var _data: Dictionary = {}


static func get_data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(PATH, FileAccess.READ)
		assert(f != null, "missing " + PATH)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		_data = DmProgUtil.ints(parsed)
	return _data


static func area_order() -> Array:
	return get_data()["areaOrder"]


static func areas() -> Dictionary:
	return get_data()["areas"]


static func vows() -> Dictionary:
	return get_data()["vows"]


static func vow_order() -> Array:
	return get_data()["vowOrder"]


static func boons() -> Dictionary:
	return get_data()["boons"]


static func boon_order() -> Array:
	return get_data()["boonOrder"]


static func bosses() -> Dictionary:
	return get_data()["bosses"]


static func ascension() -> Dictionary:
	return get_data()["ascension"]


static func upgrades() -> Dictionary:
	return get_data()["upgrades"]


static func limits() -> Dictionary:
	return get_data()["limits"]


## Areas with no seal are open to everyone; an instance (the Depths) only while a run is.
static func is_always_open(id: String) -> bool:
	var a: Dictionary = areas()[id]
	return a["unlock"] == null and not a["instance"]
