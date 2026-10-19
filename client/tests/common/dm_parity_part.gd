extends "res://tests/common/dm_suite_part.gd"
## Base of a client / server parity replay. The server's vitest (server/rules/gameplay/__tests__/*.parity.test.ts) writes
## fixtures/<name>_parity.json = {"cases": [{fn, in, out}]} from the TypeScript rules; a subclass names the fixtures and implements
## call_fn(fn, args), which runs the GDScript port. Numbers match within 1e-9 (int and float alike), everything else exactly.
## Subclasses: tests/rules_*/parity_part.gd. The TS side: server/rules/README.md "Parity fixtures".

var passed := 0
var failed := 0
var _shown := 0
var _cur := ""


## [[suite fixture dir, fixture name], ...], e.g. [["rules_combat", "kill"]].
func fixtures() -> Array:
	return []


func call_fn(_fn: String, _args: Variant) -> Variant:
	return "UNKNOWN FN"


func _initialize() -> void:
	for pair in fixtures():
		_cur = String(pair[1])
		var path := "res://tests/%s/fixtures/%s_parity.json" % [pair[0], pair[1]]
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			print("FAIL %s missing (committed in git)" % path)
			failed += 1
			continue
		var fx: Dictionary = JSON.parse_string(f.get_as_text())
		for c: Dictionary in fx["cases"]:
			check(String(c["fn"]), call_fn(String(c["fn"]), c["in"]), c["out"], c["in"])
	print("--- parity: %d / %d passed, %d failed ---" % [passed, passed + failed, failed])
	quit(0 if failed == 0 else 1)


func eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		var x := float(a)
		var y := float(b)
		return absf(x - y) <= 1e-9 or absf(x - y) <= 1e-12 * maxf(absf(x), absf(y))
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not eq(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not eq(a[key], b[key]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


## First differing path, for the failure message.
func diff(a: Variant, b: Variant, path: String = "") -> String:
	if eq(a, b):
		return ""
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not b.has(k):
				return path + "/" + str(k) + " (unexpected)"
			var d := diff(a[k], b[k], path + "/" + str(k))
			if d != "":
				return d
		for k in b:
			if not a.has(k):
				return path + "/" + str(k) + " (missing)"
	if a is Array and b is Array and a.size() == b.size():
		for i in a.size():
			var d2 := diff(a[i], b[i], path + "[%d]" % i)
			if d2 != "":
				return d2
	if a is Array and b is Array and a.size() != b.size():
		return "%s: %d items, want %d" % [path, a.size(), b.size()]
	return "%s: got %s want %s" % [path, JSON.stringify(a).left(120), JSON.stringify(b).left(120)]


func check(fn: String, got: Variant, want: Variant, ctx: Variant) -> void:
	if eq(got, want):
		passed += 1
		return
	failed += 1
	if _shown < 25:
		_shown += 1
		print("FAIL [%s.%s] %s\n  in  : %s" % [_cur, fn, diff(got, want), JSON.stringify(ctx).left(600)])
