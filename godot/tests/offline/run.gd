extends SceneTree
## Offline backend tests. Headless:  godot --headless --path godot --script res://tests/offline/run.gd
## 1. Golden replay: every request the real web mock (src/net/mockBackend.ts) answered in (the retired web game\'s fixtures-offline exporter), replayed against
##    DmMockBackend with the same Math.random stream (mulberry32 seed) and clock, replies compared field for field.
## 2. test_routes.gd: every DmApi call the game makes answers (no 404/501), persistence survives a relaunch, atomic writes, error paths the web leaves out.

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
	_main.call_deferred()

func _replay(sc: Dictionary) -> void:
	var rng := DmRng.new(int(sc["seed"]))
	var clock := [0]
	var mock := DmMockBackend.new("")
	mock.rng = rng.as_callable()
	mock.now_ms = func(): return clock[0]
	var steps: Array = sc["steps"]
	var shown := 0
	for i in steps.size():
		var st: Dictionary = steps[i]
		clock[0] = int(st["now"])
		var url := String(st["path"])
		var headers := {"Content-Type": "application/json"}
		if st["token"]:
			headers["Authorization"] = "Bearer offline:qa_player"
		var req := {"method": st["method"], "url": url, "headers": headers, "body": "" if st.get("body") == null else JSON.stringify(st["body"])}
		var resp := mock.transport(req)
		var got: Variant = DmJson.parse(String(resp["text"]))
		var want: Variant = DmJson.normalise(st["res"])
		var label := "%s #%d %s %s" % [sc["name"], i, st["method"], url]
		var d := diff(got, want)
		if st["thrown"] and int(resp["status"]) != int(st["status"]):
			d = "status %d vs %d; %s" % [int(resp["status"]), int(st["status"]), d]
		if d != "" and shown < 12:
			shown += 1
			print("   ", d.left(300))
			print("   request: ", str(st.get("body")).left(200))
		ok(d == "", label, "")

func _main() -> void:
	var f := FileAccess.open("res://tests/offline/fixtures/offline.json", FileAccess.READ)
	if f == null:
		print("fixtures missing: they are committed in git (restore with git checkout)")
		quit(2)
		return
	var fx: Dictionary = JSON.parse_string(f.get_as_text())
	var steps := 0
	for sc in fx["scenarios"]:
		steps += sc["steps"].size()
		_replay(sc)
	print("golden replay: %d scenarios, %d steps" % [fx["scenarios"].size(), steps])
	var tr = load("res://tests/offline/test_routes.gd")
	if tr != null:
		var res: Array = await tr.run(self)
		pass_count += int(res[0])
		fail_count += int(res[1])
	var ts = load("res://tests/offline/test_session.gd")
	if ts != null:
		var res2: Array = await ts.run(self)
		pass_count += int(res2[0])
		fail_count += int(res2[1])
	print("offline tests: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
