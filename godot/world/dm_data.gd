class_name DmData
extends RefCounted
## Loads the slice JSON (godot/data/slice/*.json; originally exported from the web game's TS).

static var _cache: Dictionary = {}

static func load_json(name: String) -> Variant:
	if _cache.has(name):
		return _cache[name]
	var v: Variant = DmDb.slice(name)
	if v == null:
		push_error("DmData: missing slice dataset %s (run tools/godot/export-slice.ts)" % name)
		return {}
	_cache[name] = v
	return v

static func world() -> Dictionary:
	return load_json("world")

static func enemies() -> Dictionary:
	return load_json("enemies")

static func hero() -> Dictionary:
	return load_json("hero")

static func color(hex: String) -> Color:
	return Color.html(hex)
