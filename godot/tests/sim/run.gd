extends SceneTree
## Golden-fixture runner for godot/sim. Run: godot --headless --path godot --script res://tests/sim/run.gd [-- only=<name>[,<name>]]
## Fixtures: tools/godot/fixtures-sim.ts (npx vite-node tools/godot/fixtures-sim.ts, or tools/godot/gen-fixtures.sh) -> tests/sim/fixtures/*.json
## Unit-style files are {fn, cases:[{in, out}]} and map fn -> h_<fn> below; scenario replays live in scenario_runner.gd.

const DIR := "res://tests/sim/fixtures/"
var passed := 0
var failed := 0
var per_file: Dictionary = {}
var _shown := 0
var _only: PackedStringArray = PackedStringArray()
var _dump: String = ""
var _tol: float = 1e-9
var _rel: float = 1e-12


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="):
			_only = a.substr(5).split(",")
		elif a.begins_with("tol="):
			_tol = float(a.substr(4))
		elif a.begins_with("rel="):
			_rel = float(a.substr(4))
		elif a.begins_with("dump="):
			_dump = a.substr(5)
	var dir := DirAccess.open(DIR)
	if dir == null or not FileAccess.file_exists(DIR + "nav_basic.json"):
		print("fixtures missing: run tools/godot/gen-fixtures.sh")
		quit(1)
		return
	var names: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".json"):
			names.append(f.get_basename())
	names.sort()
	for n in names:
		if not _only.is_empty() and not (n in _only):
			continue
		run_file(n)
	if _only.is_empty() or "combat_cast" in _only:
		var cc = load("res://tests/sim/combat_cast.gd").new()
		var cdir := "res://tests/rules-combat/fixtures/"
		if FileAccess.file_exists(cdir + "ability_damage.json"):
			cc.run_damage(cdir + "ability_damage.json")
			cc.run_cast(cdir + "ability_cast.json")
			passed += cc.passed
			failed += cc.failed
			per_file["combat_cast (1300 rules-combat cases)"] = "%d checks, %d skipped" % [cc.passed + cc.failed, cc.skipped]
			for m in cc.messages:
				print(m)
		else:
			print("rules-combat fixtures missing: run tools/godot/gen-fixtures.sh (combat_cast skipped)")
	var total := passed + failed
	print("--- sim: %d / %d passed, %d failed ---" % [passed, total, failed])
	for k in per_file:
		print("  %-24s %s" % [k, per_file[k]])
	quit(0 if failed == 0 else 1)


## Numbers: absolute 1e-9 or relative 1e-12 unless a tolerance is given.
func eq(a: Variant, b: Variant, tol: float = 1e-9) -> bool:
	return diff(a, b, "", tol) == ""


func diff(a: Variant, b: Variant, path: String = "", tol: float = 1e-9, rel: float = 1e-12) -> String:
	if (a is int or a is float) and (b is int or b is float):
		var x := float(a)
		var y := float(b)
		if is_nan(x) and is_nan(y):
			return ""
		var d := absf(x - y)
		return "" if (d <= tol or d <= rel * maxf(absf(x), absf(y)) or x == y) else "%s: got %s want %s" % [path, String.num(x, 17), String.num(y, 17)]
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: array size got %d want %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i], tol, rel)
			if d != "":
				return d
		return ""
	if a is Dictionary and b is Dictionary:
		for k in b:
			if not a.has(k):
				return "%s.%s: missing in got" % [path, k]
			var d := diff(a[k], b[k], "%s.%s" % [path, k], tol, rel)
			if d != "":
				return d
		for k in a:
			if not b.has(k):
				return "%s.%s: unexpected in got" % [path, k]
		return ""
	if a == null and b == null:
		return ""
	return "" if (typeof(a) == typeof(b) and a == b) else "%s: got %s (%s) want %s (%s)" % [path, a, type_string(typeof(a)), b, type_string(typeof(b))]


func run_file(name: String) -> void:
	var text := FileAccess.get_file_as_string(DIR + name + ".json")
	var fx: Dictionary = DmSimExact.decode(JSON.parse_string(text))
	if fx.has("cast"):
		var cr = load("res://tests/sim/cast_runner.gd").new()
		cr.dump_dir = _dump
		cr.tol = _tol
		cr.rel = _rel
		cr._snap.rel = _rel
		cr._snap.tol = _tol
		var r2: Dictionary = cr.run(fx)
		passed += int(r2["passed"])
		failed += int(r2["failed"])
		per_file[name] = r2["summary"]
		for m in r2["messages"]:
			print(m)
		return
	if fx.has("scenario"):
		var runner = load("res://tests/sim/scenario_runner.gd").new()
		runner.dump_dir = _dump
		runner.tol = _tol
		runner.rel = _rel
		var r: Dictionary = runner.run(fx)
		passed += int(r["passed"])
		failed += int(r["failed"])
		per_file[name] = r["summary"]
		for m in r["messages"]:
			print(m)
		return
	var fn: String = fx["fn"]
	if not has_method("h_" + fn):
		print("no handler for ", fn)
		failed += 1
		per_file[name] = "NO HANDLER"
		return
	var ok := 0
	var cases: Array = fx["cases"]
	var exact: bool = fn.begins_with("trig_")
	for i in cases.size():
		var got: Variant = call("h_" + fn, cases[i]["in"])
		var d := diff(got, cases[i]["out"], "", 0.0, 0.0) if exact else diff(got, cases[i]["out"])
		if d == "":
			ok += 1
			passed += 1
		else:
			failed += 1
			if _shown < 40:
				_shown += 1
				print(("FAIL %s #%d  %s" % [name, i, d]).substr(0, 300))
	per_file[name] = "%d / %d" % [ok, cases.size()]


# --------------------------------------------------------------------------------------------------------------------
var _navs: Array = []


func _world_nav(unlocked: Variant) -> DmNav:
	var nav := DmNav.new()
	var w: Dictionary = DmSimExact.load_json("res://data/sim/world.json")
	for o in w["obstacles"]:
		nav.add_obstacle(DmNavObstacle.from_dict(o))
	for s in w["sightBlockers"]:
		nav.add_sight_blocker(DmNavObstacle.from_dict(s))
	if unlocked != null:
		nav.set_unlocked(unlocked)
	return nav


func _get_nav(i: int) -> DmNav:
	if _navs.is_empty():
		var all: Array = []
		for a in DmContent.area_order():
			if a != "depths":
				all.append(a)
		_navs = [_world_nav(null), _world_nav(all), _world_nav(["ossuary", "nave"])]
	return _navs[i]


static func v2(v: Array) -> Array:
	return v


static func v2s(a: Array) -> Array:
	var out: Array = []
	for v: Array in a:
		out.append({"x": v[0], "z": v[1]})
	return out


func h_nav_basic(i: Dictionary) -> Variant:
	var nav := _get_nav(int(i["ni"]))
	var x: float = i["x"]
	var z: float = i["z"]
	var r: float = i["r"]
	var qx: float = i["qx"]
	var qz: float = i["qz"]
	var a := nav.area_at(x, z)
	var n := nav.nearest_area(x, z)
	return {
		"resolve": v2(nav.resolve(x, z, r)), "inArea": v2(nav.resolve_in_area(i["area"], x, z, r)), "pushOut": v2(nav.push_out(x, z, r)),
		"areaAt": a if a != "" else null, "blocked": nav.blocked(x, z, r), "clearLine": nav.clear_line(x, z, qx, qz, r),
		"sight": nav.sight_blocked(x, z, qx, qz), "nearest": n if n != "" else null, "unlocked": nav.is_unlocked(i["area"]),
		"route": v2s(nav.route(x, z, qx, qz)),
	}


func h_nav_paths(i: Dictionary) -> Variant:
	var nav := _get_nav(int(i["ni"]))
	return {"path": v2s(nav.find_path(i["x"], i["z"], i["qx"], i["qz"], i["r"]))}


func h_depths_floor(i: Dictionary) -> Variant:
	var fs := DmDepthsFloor.floor_seed(int(i["runSeed"]), int(i["depth"]))
	var f := DmDepthsFloor.generate_floor(fs, int(i["depth"]), 5)
	var probes: Array = []
	for p: Dictionary in i["pts"]:
		var a: Dictionary = p["a"]
		var b: Dictionary = p["b"]
		var ra := DmDepthsFloor.room_at(f, a["x"], a["z"])
		var rb := DmDepthsFloor.room_at(f, b["x"], b["z"])
		probes.append({"rooms": [ra, rb], "hop": DmDepthsFloor.floor_hop(f, a["x"], a["z"], b["x"], b["z"]), "hops": DmDepthsFloor.floor_hops(f, ra, rb),
			"path": v2s(DmDepthsFloor.floor_path(f, a["x"], a["z"], b["x"], b["z"]))})
	return {"floorSeed": fs, "floor": f, "problems": DmDepthsFloor.floor_problems(f), "obstacles": DmDepthsFloor.floor_obstacles(f).size(),
		"sight": DmDepthsFloor.floor_sight_boxes(f).size(), "probes": probes}


func h_trig_sincos(i: Dictionary) -> Variant:
	var x: float = i["x"]
	return {"sin": DmFdlibm.sin_(x), "cos": DmFdlibm.cos_(x)}


func h_trig_atan2(i: Dictionary) -> Variant:
	var y: float = i["y"]
	var x: float = i["x"]
	return {"r": DmFdlibm.atan2_(y, x), "t": DmFdlibm.atan_(y)}
