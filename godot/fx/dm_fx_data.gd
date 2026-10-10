class_name DmFxData
extends RefCounted
## The effect tables in res://assets/fx/fx_data.json: SPELL_FX colours, the
## Binbun presets, the catalog lists, per-effect defaults and the caps/budgets (originally exported from the web game's TS).

const PATH := "res://assets/fx/fx_data.json"
static var _d: Dictionary = {}


static func data() -> Dictionary:
	if _d.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:
			_d = parsed
	return _d


static func caps() -> Dictionary:
	return data().get("caps", {})


static func cap(key: String) -> float:
	return float(caps().get(key, 0))


## 0xRRGGBB int (as exported) -> Color (sRGB, like THREE.Color(hex)).
static func hex(c: int) -> Color:
	return Color(float((c >> 16) & 255) / 255.0, float((c >> 8) & 255) / 255.0, float(c & 255) / 255.0, 1.0)


## SPELL_FX[group][key] as a Color; e.g. spell("miasma", "rot").
static func spell(group: String, key: String) -> Color:
	var g: Dictionary = data().get("spell_fx", {}).get(group, {})
	return hex(int(g.get(key, 0xffffff)))


## SPELL_FX[group] as {key: Color}.
static func spell_group(group: String) -> Dictionary:
	var out := {}
	var g: Dictionary = data().get("spell_fx", {}).get(group, {})
	for k in g:
		out[k] = hex(int(g[k]))
	return out


## Anything colour-like (Color, 0xRRGGBB int/float, [r,g,b] array) -> Color.
static func to_color(v: Variant) -> Color:
	if v is Color:
		return v
	if v is int or v is float:
		return hex(int(v))
	if v is Array and v.size() >= 3:
		return Color(v[0], v[1], v[2], v[3] if v.size() > 3 else 1.0)
	return Color.WHITE


## FX_PRESETS[id] ({colors?, scale?, y?, alpha?}) with colours converted to Color; {} when there is none.
static func preset(id: String) -> Dictionary:
	var p: Variant = data().get("presets", {}).get(id)
	if not (p is Dictionary):
		return {}
	var out := {}
	for k in p:
		if k == "colors":
			var cols: Array[Color] = []
			for c in p[k]:
				cols.append(to_color(c))
			out[k] = cols
		else:
			out[k] = p[k]
	return out


static func effect_info(id: String) -> Dictionary:
	return data().get("effects", {}).get(id, {})


static func catalog(list: String) -> Array:
	return data().get("catalog", {}).get(list, [])


static func is_impact(id: String) -> bool:
	return id in catalog("impacts")


static func is_looper(id: String) -> bool:
	return id in catalog("loopers")


## SHEETS[id] ({cols, rows, frames, fps, loop}): a flipbook from the licensed sheet pack, {} when unknown. See DmFxTex.has_sheet for whether
## its texture is installed (the pack is kept out of git).
static func sheet(id: String) -> Dictionary:
	return data().get("sheets", {}).get(id, {})
