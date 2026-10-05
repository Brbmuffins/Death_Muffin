class_name DmWfxData
extends RefCounted
## godot/data/world_fx/fx.json (tools/godot/export-world-fx.ts): windows, silhouettes, flames, mist, Atmosphere profiles, water inputs,
## bloom, wing table. Everything the dressing draws comes from here; nothing is retyped.

const PATH := "res://data/world_fx/fx.json"
static var _d: Dictionary = {}

static func get_data() -> Dictionary:
	if _d.is_empty():
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f != null:
			var v: Variant = JSON.parse_string(f.get_as_text())
			if v is Dictionary:
				_d = v
	return _d

## 0xRRGGBB number (JSON) -> Color
static func hex(v: Variant) -> Color:
	return Color.hex(int(v) * 256 + 255)

## Index of the area whose rect is nearest (0 inside), like WorldView.windowArea. `areas` = world.areas (id -> {rect}).
static func nearest_area(areas: Dictionary, order: Array, x: float, z: float) -> String:
	var best := str(order[0])
	var bd := INF
	for id in order:
		var r: Dictionary = areas[id].rect
		var dx := maxf(maxf(float(r.x0) - x, 0.0), x - float(r.x1))
		var dz := maxf(maxf(float(r.z0) - z, 0.0), z - float(r.z1))
		var d := sqrt(dx * dx + dz * dz)
		if d < bd:
			bd = d
			best = str(id)
	return best
