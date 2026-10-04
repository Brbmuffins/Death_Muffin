class_name DmJson
extends RefCounted
## JSON helpers. Godot's JSON parser returns every number as float; ids, counts and slot indexes are used as ints all over the game
## (array indexes, %d, ==), so integral numbers are normalised back to int. Non-integral numbers stay float.

static func parse(text: String) -> Variant:
	if text.strip_edges().is_empty():
		return null
	var v: Variant = JSON.parse_string(text)
	return normalise(v)

static func normalise(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			if is_finite(f) and f == floorf(f) and absf(f) < 9007199254740992.0:
				return int(f)
			return f
		TYPE_ARRAY:
			var a: Array = v
			for i in a.size():
				a[i] = normalise(a[i])
			return a
		TYPE_DICTIONARY:
			var d: Dictionary = v
			for k in d.keys():
				d[k] = normalise(d[k])
			return d
	return v

static func stringify(v: Variant) -> String:
	return JSON.stringify(v)
