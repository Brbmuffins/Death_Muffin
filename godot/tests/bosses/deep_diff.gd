class_name DmDeepDiff
extends RefCounted
## Deep compare for fixture checks. null / absent dictionary keys are equivalent (TS `undefined` is dropped by JSON); numbers compare
## with a relative tolerance (Godot's JSON float parse is not bit-exact).

const TOL := 1e-9


## "" when equal, else the path of the first difference.
static func diff(a: Variant, b: Variant, path: String) -> String:
	if (a is float or a is int) and (b is float or b is int):
		var fa := float(a)
		var fb := float(b)
		if fa == fb or absf(fa - fb) <= TOL * maxf(1.0, absf(fb)):
			return ""
		return "%s: %s != %s" % [path, a, b]
	if a is Dictionary and b is Dictionary:
		var keys := {}
		for k in a:
			keys[k] = true
		for k in b:
			keys[k] = true
		for k in keys:
			var d := diff(a.get(k, null), b.get(k, null), path + "." + str(k))
			if d != "":
				return d
		return ""
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: size %d != %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if typeof(a) != typeof(b) and not (a == null or b == null):
		return "%s: type %s != %s (%s vs %s)" % [path, typeof(a), typeof(b), a, b]
	return "" if a == b else "%s: %s != %s" % [path, a, b]
