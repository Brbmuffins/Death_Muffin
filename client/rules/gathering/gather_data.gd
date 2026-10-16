class_name DmGatherData
extends RefCounted
## Typed view of data/gathering/gathering.json (loaded by DmDb; originally exported from the web game's TS).
## JSON numbers arrive as floats; integral ones are normalised to int so rule code can use them as indexes / quantities.


static var _data: Dictionary = {}
static var _nodes: Dictionary = {}


static func get_data() -> Dictionary:
	if _data.is_empty():
		_data = normalize(DmDb.gathering())
		for n in _data["nodes"]:
			_nodes[n["id"]] = n
	return _data


## Recursively turn integral floats into ints.
static func normalize(v: Variant) -> Variant:
	if v is float:
		var fv: float = v
		if fv == floorf(fv) and absf(fv) < 9.0e15:
			return int(fv)
		return fv
	if v is Array:
		var out: Array = []
		for e in v:
			out.append(normalize(e))
		return out
	if v is Dictionary:
		var d: Dictionary = {}
		for k in v:
			d[k] = normalize(v[k])
		return d
	return v


## NODES[id] (Dictionary with id, skill, name, kind, level, xp, ticks, item, yields, respawnS, extras, gold?, tint) or {}.
static func node(id: String) -> Dictionary:
	get_data()
	return _nodes.get(id, {})


static func nodes() -> Dictionary:
	get_data()
	return _nodes


## content/items.ts ITEMS entry ({name,type,rarity,sell,stack?}); itemMeta() fallback for unknown ids.
static func item_meta(id: String) -> Dictionary:
	var items: Dictionary = get_data()["items"]
	if items.has(id):
		return items[id]
	return {"name": id.replace("_", " "), "type": "material", "rarity": "common", "sell": 0}
