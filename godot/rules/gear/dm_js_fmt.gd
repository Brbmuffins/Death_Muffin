class_name DmJsFmt
extends RefCounted
## JavaScript number-to-text rules that GDScript's % formatting does not share (tie rounding, "2" vs "2.0").


## Number.prototype.toFixed: exact decimal value, ties (only possible for dyadic values) round half up in magnitude.
static func to_fixed(x: float, digits: int) -> String:
	var neg := x < 0.0
	var a := absf(x)
	var s := a * pow(10.0, digits)
	var q := a * pow(2.0, digits + 1)
	if q == floorf(q) and s - floorf(s) == 0.5:
		var up := (floorf(s) + 1.0) / pow(10.0, digits)
		var out := ("%." + str(digits) + "f") % up
		return ("-" if neg else "") + out
	var o := ("%." + str(digits) + "f") % a
	return ("-" if neg else "") + o


## String(x) for the values this module formats (integers, or numbers already rounded to a few decimals).
static func num_str(x: float) -> String:
	if is_nan(x):
		return "NaN"
	if x == floorf(x) and absf(x) < 1e15:
		return str(int(x))
	return str(x)


## `+x.toFixed(d)`: the number back from its rounded text, printed the way JS prints it ("12.0" -> "12").
static func plus_fixed(x: float, digits: int) -> String:
	return num_str(float(to_fixed(x, digits)))


## Number.prototype.toLocaleString() in en-US (integers get thousands separators; fractions up to 3 digits).
static func locale(x: float) -> String:
	if x != floorf(x):
		var t := to_fixed(x, 3)
		while t.ends_with("0"):
			t = t.substr(0, t.length() - 1)
		var parts := t.split(".")
		return _group(parts[0]) + ("." + parts[1] if parts.size() > 1 else "")
	return _group(str(int(x)))


static func _group(digits: String) -> String:
	var neg := digits.begins_with("-")
	var d := digits.substr(1) if neg else digits
	var out := ""
	var n := d.length()
	for i in n:
		if i > 0 and (n - i) % 3 == 0:
			out += ","
		out += d[i]
	return ("-" if neg else "") + out
