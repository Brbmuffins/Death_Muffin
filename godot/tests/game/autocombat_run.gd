extends SceneTree
## Golden-fixture runner for dm_auto_combat.gd / dm_auto_dodge.gd / dm_boss_telegraphs.gd.
## Run: godot --headless --path godot --script res://tests/game/autocombat_run.gd [-- only=auto_action,dodge]
## Fixtures: tools/godot/fixtures-autocombat.ts (npx vite-node tools/godot/fixtures-autocombat.ts, or tools/godot/gen-fixtures.sh).

const DIR := "res://tests/game/fixtures/"
var passed := 0
var failed := 0
var per_file: Dictionary = {}
var _shown := 0
var _only: PackedStringArray = PackedStringArray()
var _navs: Array = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="):
			_only = a.substr(5).split(",")
	if not FileAccess.file_exists(DIR + "auto_action.json"):
		print("fixtures missing: run tools/godot/gen-fixtures.sh")
		quit(1)
		return
	for n in ["auto_action", "auto_movement", "telegraph", "dodge", "math"]:
		if not _only.is_empty() and not (n in _only):
			continue
		_run_file(n)
	print("%d passed, %d failed" % [passed, failed])
	for k in per_file:
		print("  %-14s %s" % [k, per_file[k]])
	quit(0 if failed == 0 else 1)


func _run_file(name: String) -> void:
	var f: Dictionary = DmSimExact.load_json(DIR + name + ".json")
	var p0 := passed
	var f0 := failed
	var cases: Array = f["cases"]
	for i in cases.size():
		var c: Dictionary = cases[i]
		var msg := ""
		match name:
			"auto_action": msg = _case_action(c, i)
			"auto_movement": msg = _case_movement(c, i)
			"telegraph": msg = _case_telegraph(c)
			"dodge": msg = _case_dodge(c)
			"math": msg = _case_math(c)
		if msg == "":
			passed += 1
		else:
			failed += 1
			if _shown < 12:
				_shown += 1
				print("FAIL %s #%d: %s" % [name, i, msg])
	per_file[name] = "%d passed, %d failed" % [passed - p0, failed - f0]


# --- helpers ---------------------------------------------------------------------------------------------------------

## Actual -> comparable: ints to floats, INF to null (JSON), nested.
func _norm(v: Variant) -> Variant:
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _norm(v[k])
		return d
	if v is Array:
		var a := []
		for x in v:
			a.append(_norm(x))
		return a
	if v is int:
		return float(v)
	if v is float and is_inf(v):
		return null
	return v


func _eq(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if a is Dictionary:
		if not (b is Dictionary) or a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _eq(a[k], b[k]):
				return false
		return true
	if a is Array:
		if not (b is Array) or a.size() != b.size():
			return false
		for i in a.size():
			if not _eq(a[i], b[i]):
				return false
		return true
	if (a is float or a is int) and (b is float or b is int):
		return float(a) == float(b)
	return a == b


func _cmp(actual: Variant, expected: Variant) -> String:
	var a: Variant = _norm(actual)
	if _eq(a, expected):
		return ""
	return "got %s expected %s" % [JSON.stringify(a), JSON.stringify(expected)]


func _hazards(arr: Variant) -> Array:
	var out: Array = []
	if arr == null:
		return out
	for h in arr:
		var d: Dictionary = (h as Dictionary).duplicate(true)
		if d.get("until") == null:
			d["until"] = INF
		out.append(d)
	return out


func _nav(i: int) -> Variant:
	if i < 0:
		return null
	if _navs.is_empty():
		var all: Array = []
		for a in DmContent.area_order():
			if a != "depths":
				all.append(a)
		_navs = [_world_nav(null), _world_nav(all), _world_nav(["ossuary", "nave"])]
	return _navs[i]


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


func _enemy_obj(e: Dictionary) -> DmSimEnemy:
	var o := DmSimEnemy.new()
	o.id = int(e["id"])
	o.x = e["x"]
	o.z = e["z"]
	o.hp = e["hp"]
	o.maxHp = e.get("maxHp", 0.0)
	o.state = e["state"]
	o.radius = e.get("radius", 0.5)
	o.elite = e.get("elite", false)
	o.area = e.get("area", "")
	o.hexOwner = e.get("hexOwner", "")
	return o


func _corpse_obj(c: Dictionary) -> DmSimCorpse:
	var o := DmSimCorpse.new()
	o.x = c["x"]
	o.z = c["z"]
	o.kind = c["kind"]
	o.area = c.get("area", "")
	o.seedOwner = c.get("seedOwner", "")
	o.echoOwner = c.get("echoOwner", "")
	return o


func _enemies(arr: Array, objs: bool) -> Array:
	var out: Array = []
	for e in arr:
		out.append(_enemy_obj(e) if objs else e)
	return out


# --- cases -----------------------------------------------------------------------------------------------------------

func _case_action(c: Dictionary, idx: int) -> String:
	var inp: Dictionary = c["in"]
	var objs := idx % 2 == 1
	var ready_set: Array = inp["ready"]
	var ctx: Dictionary = inp.duplicate()
	ctx["ready"] = func(id: String) -> bool: return ready_set.has(id)
	ctx["enemies"] = _enemies(inp["enemies"], objs)
	var cs: Array = []
	for cp in inp["corpses"]:
		cs.append(_corpse_obj(cp) if objs else cp)
	ctx["corpses"] = cs
	if objs:
		var b: Dictionary = inp["boss"]
		var bs := DmBossState.new()
		bs.active = b["active"]
		bs.x = b["x"]
		bs.z = b["z"]
		bs.hp = b["hp"]
		bs.state = b["state"]
		ctx["boss"] = bs
	return _cmp(DmAutoCombat.select_action(ctx), c["out"])


func _case_movement(c: Dictionary, idx: int) -> String:
	var inp: Dictionary = c["in"]
	var objs := idx % 2 == 1
	var mem: Variant = null
	if inp["useMem"]:
		mem = inp["memInit"].duplicate(true) if inp["memInit"] != null else {}
	var nav: Variant = _nav(int(inp["ni"]))
	var si := 0
	for s in inp["steps"]:
		var ctx := {"player": s["player"], "enemies": _enemies(s["enemies"], objs)}
		if nav != null:
			ctx["nav"] = nav
		if s.has("hazards"):
			ctx["hazards"] = _hazards(s["hazards"])
		for k in ["primary", "primaryRange", "family"]:
			if inp.get(k) != null:
				ctx[k] = inp[k]
		var out: Variant = DmAutoCombat.select_movement(ctx, mem, float(s["now"]), float(s["dt"]))
		var m := _cmp(out, s["out"])
		if m == "":
			m = _cmp(mem, s["mem"])
			if m != "":
				m = "mem " + m
		if m != "":
			return "step %d: %s" % [si, m]
		si += 1
	return ""


func _case_telegraph(c: Dictionary) -> String:
	var bt := DmBossTelegraphs.new()
	var ops: Array = c["in"]["ops"]
	var outs: Array = c["out"]
	for i in ops.size():
		var o: Dictionary = ops[i]
		var now := float(o["now"])
		match o["op"]:
			"event": bt.on_event(o["ev"], now)
			"clear": bt.clear()
		var m := _cmp(bt.active(now), outs[i])
		if m != "":
			return "op %d (%s): %s" % [i, o["op"], m]
	return ""


func _case_dodge(c: Dictionary) -> String:
	var inp: Dictionary = c["in"]
	var out: Dictionary = c["out"]
	var hazards := _hazards(inp["hazards"])
	var p: Dictionary = inp["p"]
	var nav: Variant = _nav(int(inp["ni"]))
	var opts := {}
	if inp["useRect"]:
		opts["rect"] = DmContent.area(inp["area"])["rect"]
	if nav != null:
		opts["nav"] = nav
	var probes: Array = []
	for pr in inp["probes"]:
		var row: Array = []
		for h in hazards:
			row.append(DmAutoDodge.in_hazard(h, pr["x"], pr["z"], pr["margin"]))
		probes.append(row)
	var o1 := opts.duplicate()
	o1["prefer"] = inp.get("prefer")
	var mem: Variant = inp["mem"].duplicate(true) if inp["mem"] != null else null
	var got := {
		"probes": probes,
		"safe": DmAutoDodge.nearest_safe_point(p, hazards, o1),
		"safeNoPrefer": DmAutoDodge.nearest_safe_point(p, hazards, opts),
		"step": DmAutoDodge.dodge_step(p, hazards, mem, float(inp["now"]), opts),
		"mem": mem,
		"stepInto": DmAutoDodge.step_into_hazard(p, inp["dir"], hazards),
		"stepInto2": DmAutoDodge.step_into_hazard(p, inp["dir"], hazards, inp["len"], inp["margin"]),
		"stepIntoEmpty": DmAutoDodge.step_into_hazard(p, inp["dir"], []),
		"pool": DmAutoDodge.pool_hazard(inp["pool"], inp["playerRadius"]),
	}
	return _cmp(got, out)


func _case_math(c: Dictionary) -> String:
	var inp: Dictionary = c["in"]
	var o: Dictionary = c["out"]
	var dt: float = inp["dt"]
	var m: float = inp["m"]
	var bad := ""
	if DmFdlibmX.exp_(-dt / 0.1) != float(o["exp"]):
		bad += " exp(dt=%s)" % str(dt)
	if DmFdlibmX.asin_(m) != float(o["asinB"]):
		bad += " asin(%s)" % str(m)
	if DmFdlibmX.asin_(minf(1.0, (m * 3.0) / float(inp["d"]))) != float(o["asin"]):
		bad += " asin-margin"
	if tan((35.0 * PI) / 180.0) != float(o["tan"]):
		bad += " tan"
	return bad
