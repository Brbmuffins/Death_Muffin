class_name DmProgContent
extends RefCounted
## Typed view of DmDb.progression_view() (projection of data/content/* + data/progression/extras.json):
## areas (order/safe/unlock), bosses, vows, boons, upgrade constants, kill-chain tiers, milestones, limits.

static var _data: Dictionary = {}


static func get_data() -> Dictionary:
	if _data.is_empty():
		_data = DmProgUtil.ints(DmDb.progression_view())
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
