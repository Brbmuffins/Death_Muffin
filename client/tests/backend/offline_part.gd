extends "res://tests/common/dm_suite_part.gd"
## Offline (dev-offline) backend tests, a part of tests/backend/run.gd. (The golden replay against the deleted web mock is gone, 2026-10-10.)
## test_routes.gd: every DmApi call the game makes answers (no 404/501), persistence survives a relaunch, atomic writes, error paths.
## test_session.gd: the offline session / progress paths on a booted game.

var pass_count := 0
var fail_count := 0

func ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
		print("FAIL: ", label, " ", extra)

## First difference between two parsed JSON values ("" = equal). Numbers compare by value.
static func diff(a: Variant, b: Variant, path: String = "") -> String:
	var ta := typeof(a)
	var tb := typeof(b)
	if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
		return "" if absf(float(a) - float(b)) < 1e-9 else "%s: %s vs %s" % [path, a, b]
	if ta != tb:
		return "%s: type %s vs %s (%s vs %s)" % [path, ta, tb, str(a).left(60), str(b).left(60)]
	if ta == TYPE_DICTIONARY:
		for k in a:
			if not b.has(k):
				return "%s.%s: only in godot" % [path, k]
		for k in b:
			if not a.has(k):
				return "%s.%s: missing in godot" % [path, k]
			var d := diff(a[k], b[k], path + "." + str(k))
			if d != "":
				return d
		return ""
	if ta == TYPE_ARRAY:
		if a.size() != b.size():
			return "%s: array size %d vs %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	return "" if a == b else "%s: %s vs %s" % [path, str(a).left(80), str(b).left(80)]

func _initialize() -> void:
	await _main()

func _main() -> void:
	var tr = load("res://tests/backend/test_routes.gd")
	if tr != null:
		var res: Array = await tr.run(tree)
		pass_count += int(res[0])
		fail_count += int(res[1])
	var ts = load("res://tests/backend/test_session.gd")
	if ts != null:
		var res2: Array = await ts.run(tree)
		pass_count += int(res2[0])
		fail_count += int(res2[1])
	print("offline tests: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
