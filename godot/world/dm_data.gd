class_name DmData
extends RefCounted
## Loads the slice JSON written by tools/godot/export-slice.ts (godot/data/slice/*.json). Single source of truth: never hand-edit.

static var _cache: Dictionary = {}

static func load_json(name: String) -> Variant:
	if _cache.has(name):
		return _cache[name]
	var f := FileAccess.open("res://data/slice/%s.json" % name, FileAccess.READ)
	if f == null:
		push_error("DmData: missing res://data/slice/%s.json (run tools/godot/export-slice.ts)" % name)
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
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
