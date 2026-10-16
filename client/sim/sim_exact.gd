class_name DmSimExact
extends RefCounted
## Bit-exact doubles in JSON. Godot's JSON parser is not correctly rounded for numbers with more than 12 significant digits (one ulp off for
## ~13% of random 17-digit doubles), so the sim's own data files (godot/data/sim/*.json) and the golden
## fixtures store such doubles as the string "d:<16 hex digits of the IEEE-754 bits>". Load them with load_json() (or decode() after parse_string).

static var _b: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])


static func load_json(path: String) -> Variant:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return decode(parsed)


## Replace every "d:<hex>" string inside `v` (in place for Arrays/Dictionaries) by the float it encodes; returns the converted value.
static func decode(v: Variant) -> Variant:
	if v is String:
		var s: String = v
		if s.length() == 18 and s.begins_with("d:"):
			return decode_double(s)
		return v
	if v is Array:
		var a: Array = v
		for i in a.size():
			var x: Variant = a[i]
			if x is String or x is Array or x is Dictionary:
				a[i] = decode(x)
		return a
	if v is Dictionary:
		var d: Dictionary = v
		for k in d:
			var x: Variant = d[k]
			if x is String or x is Array or x is Dictionary:
				d[k] = decode(x)
		return d
	return v


static func decode_double(s: String) -> float:
	_b.encode_u32(4, s.substr(2, 8).hex_to_int())
	_b.encode_u32(0, s.substr(10, 8).hex_to_int())
	return _b.decode_double(0)
