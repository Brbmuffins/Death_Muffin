class_name DmProgUtil
extends RefCounted
## JS-semantics helpers shared by the progression rules (Number(), Math.round, Math.floor, ints from JSON).
## The TS rules take untrusted JSON (saves, server rows, request bodies) and clamp it; these reproduce
## exactly how `Number(x)` / `Math.floor` / `clampInt` treat odd values so the ports agree on garbage too.

const NAN_VALUE: float = NAN


## JS `Number(v)`: null/false -> 0, true -> 1, "" -> 0, numeric strings parse, [] -> 0, [x] -> Number(x), else NaN.
static func js_num(v: Variant) -> float:
	match typeof(v):
		TYPE_NIL:
			return 0.0
		TYPE_BOOL:
			return 1.0 if v else 0.0
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s: String = String(v).strip_edges()
			if s == "":
				return 0.0
			if s.begins_with("0x") or s.begins_with("0X"):
				return float(s.hex_to_int()) if s.substr(2).is_valid_hex_number() else NAN
			if s.is_valid_float():
				return s.to_float()
			return NAN
		TYPE_ARRAY:
			var a: Array = v
			if a.is_empty():
				return 0.0
			if a.size() == 1:
				return js_num(a[0])
			return NAN
	return NAN


static func is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## JS Math.round (half rounds up), as an int.
static func js_round(x: float) -> int:
	return int(floor(x + 0.5))


## The TS `clampInt(v, lo, hi)`: floor(Number(v)), non-finite -> lo, else clamped.
static func clamp_int(v: Variant, lo: int, hi: int) -> int:
	var n: float = js_num(v)
	if is_nan(n) or is_inf(n):
		return lo
	n = floorf(n)
	return int(maxf(float(lo), minf(float(hi), n)))


## `Math.floor(Number(v)) || 0` (NaN -> 0).
static func floor_or_zero(v: Variant) -> float:
	var n: float = js_num(v)
	if is_nan(n):
		return 0.0
	return floorf(n)


## JS-style number to text: whole floats print without ".0" (as in the TS template strings).
static func fmt(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT:
		var f: float = v
		if is_finite(f) and f == floorf(f) and absf(f) < 1e15:
			return str(int(f))
	return str(v)


## Recursively turn whole-number floats into ints (JSON.parse gives floats; the saves/server rows are integers).
static func ints(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			if is_finite(f) and f == floorf(f) and absf(f) < 9e15:
				return int(f)
			return f
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var out: Dictionary = {}
			for k in d:
				out[k] = ints(d[k])
			return out
		TYPE_ARRAY:
			var a: Array = v
			var out_a: Array = []
			for x in a:
				out_a.append(ints(x))
			return out_a
	return v


static func dict_or_empty(v: Variant) -> Dictionary:
	return v if typeof(v) == TYPE_DICTIONARY else {}


## `value ?? fallback` (null/missing only).
static func nn(v: Variant, fallback: Variant) -> Variant:
	return fallback if v == null else v


static func deep_copy(v: Variant) -> Variant:
	if typeof(v) == TYPE_DICTIONARY or typeof(v) == TYPE_ARRAY:
		return v.duplicate(true)
	return v
