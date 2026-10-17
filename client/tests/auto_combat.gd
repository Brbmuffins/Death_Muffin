extends SceneTree
## Easy auto combat's decisions (client/game/dm_auto_combat.gd, ported to cost a quarter as much and choose the same: client/code.list "Ported") against TODAY'S: the reference is
## godot/game/dm_auto_combat.gd itself, read and compiled at run time (its class_name line dropped), so it can never drift from the live game.
##   - the golden cases of the live game's test (godot/tests/game/fixtures/auto_action.json, auto_movement.json: generated from the frozen web game, read from there: one home) replayed
##     against both: the action and movement choices, the enemies and corpses once as plain dictionaries and once as objects (the half of the cases the live test feeds sim objects);
##   - seeded Full-Party-sized contexts (sixty-odd enemies in reach, corpses of every kind, boss or none, random cooldowns, essence, hurt, souls and thralls; stacked enemies for equal
##     distances) for the necromancer's rites and the Reaper's: the port's choice must equal the reference's, every rule of the list reached;
##   - the movement (`select_movement`) on seeded rooms, memory included.
## Prints INFO: a decision's time on both sides on a Full Party sized context. Run: godot --headless --path client --script res://tests/auto_combat.gd

const TODAY := "godot/game/dm_auto_combat.gd"
const FIXTURES := "godot/tests/game/fixtures/"
const RITES := ["bone_needle", "bone_fan", "exhume", "grave_offering", "rally_dead", "carrion_seed", "bone_mantle", "black_litany", "corpse_explosion", "ivory_cleave", "miasma", "bone_prison",
	"grave_hands", "bone_storm", "soul_siphon", "grave_frost", "marrow_spear", "wailing_skull", "command_rend", "plague_bloom", "ossuary_wall", "dirge", "scythe_sweep", "reap", "harvest_spin",
	"scythe_throw", "wraith_walk", "soul_burst"]
const STATES := ["chase", "chase", "chase", "windup", "attack", "channel", "dead", "rising", "burrow"]

var fails := 0
var checks := 0
var ref: GDScript
var navs: Array = []


class FakeEnemy:
	extends RefCounted
	var id := 0
	var x := 0.0
	var z := 0.0
	var hp := 0.0
	var maxHp := 0.0
	var state := ""
	var radius := 0.5
	var elite := false
	var area := ""
	var hexOwner := ""


class FakeCorpse:
	extends RefCounted
	var x := 0.0
	var z := 0.0
	var kind := "normal"
	var area := ""
	var seedOwner := ""
	var echoOwner := ""


class FakeBoss:
	extends RefCounted
	var active := false
	var x := 0.0
	var z := 0.0
	var hp := 0.0
	var state := ""


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL auto_combat: " + what)


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	var root_dir := ProjectSettings.globalize_path("res://").path_join("..")
	var src := FileAccess.get_file_as_string(root_dir.path_join(TODAY).simplify_path())
	check(src != "", "today's decision code is readable at %s" % TODAY)
	if src == "":
		_end()
		return
	var today := GDScript.new()
	today.source_code = src.replace("class_name DmAutoCombat\n", "")
	check(today.reload() == OK, "today's decision code compiles in this project")
	ref = today
	var fixtures := root_dir.path_join(FIXTURES).simplify_path()
	for name in ["auto_action", "auto_movement"]:
		var path := fixtures.path_join(name + ".json")
		check(FileAccess.file_exists(path), "the golden cases %s are there" % name)
		if FileAccess.file_exists(path):
			_golden(name, DmSimExact.load_json(path))
	_seeded_actions("necromancer", 700, 20261017)
	_seeded_actions("reaper", 500, 20261018)
	_seeded_movement(160, 20261019)
	_timing()
	_end()


func _end() -> void:
	print("%s auto_combat %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ the live game's golden cases

func _golden(name: String, file: Dictionary) -> void:
	var cases: Array = file["cases"]
	var bad := 0
	var first := ""
	for i in cases.size():
		var c: Dictionary = cases[i]
		for who in [ref, DmAutoCombat]:
			var msg := _case_action(c, i, who) if name == "auto_action" else _case_movement(c, i, who)
			if msg != "":
				bad += 1
				if first == "":
					first = "%s #%d (%s): %s" % [name, i, "today's" if who == ref else "the port", msg]
	check(bad == 0 and cases.size() > 100, "%s: %d golden cases, today's code and the port both give every answer%s" % [name, cases.size(), "" if bad == 0 else " (first miss: " + first.left(300) + ")"])


func _case_action(c: Dictionary, idx: int, who: Object) -> String:
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
		var bs := FakeBoss.new()
		bs.active = b["active"]
		bs.x = b["x"]
		bs.z = b["z"]
		bs.hp = b["hp"]
		bs.state = b["state"]
		ctx["boss"] = bs
	return _cmp(who.select_action(ctx), c["out"])


func _case_movement(c: Dictionary, idx: int, who: Object) -> String:
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
		var out: Variant = who.select_movement(ctx, mem, float(s["now"]), float(s["dt"]))
		var m := _cmp(out, s["out"])
		if m == "":
			m = _cmp(mem, s["mem"])
			if m != "":
				m = "mem " + m
		if m != "":
			return "step %d: %s" % [si, m]
		si += 1
	return ""


func _enemies(arr: Array, objs: bool) -> Array:
	var out: Array = []
	for e in arr:
		if not objs:
			out.append(e)
			continue
		var o := FakeEnemy.new()
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
		out.append(o)
	return out


func _corpse_obj(c: Dictionary) -> FakeCorpse:
	var o := FakeCorpse.new()
	o.x = c["x"]
	o.z = c["z"]
	o.kind = c["kind"]
	o.area = c.get("area", "")
	o.seedOwner = c.get("seedOwner", "")
	o.echoOwner = c.get("echoOwner", "")
	return o


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
	if navs.is_empty():
		var all: Array = []
		for a in DmContent.area_order():
			if a != "depths":
				all.append(a)
		navs = [_world_nav(null), _world_nav(all), _world_nav(["ossuary", "nave"])]
	return navs[i]


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


# ------------------------------------------------------------------------------------------------------------------ seeded Full-Party-sized contexts

## A fight around the hero at (100, 50): `enemies` bodies up to 22 m out (some stacked on one spot for equal distances), corpses of every kind, a boss sometimes.
func _context(rng: RandomNumberGenerator, family: String) -> Dictionary:
	var hx := 100.0
	var hz := 50.0
	var enemies: Array = []
	for i in rng.randi_range(0, 78):
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.4, 22.0)
		enemies.append({"id": i + 1, "x": hx + cos(a) * r, "z": hz + sin(a) * r, "hp": [0.0, 120.0, 272.9][rng.randi() % 3], "maxHp": 272.9, "state": STATES[rng.randi() % STATES.size()],
			"radius": [0.4, 0.5, 0.5, 0.9, 1.4][rng.randi() % 5], "elite": rng.randf() < 0.06, "area": "graves" if rng.randf() < 0.95 else "warren", "hexOwner": ""})
	if rng.randf() < 0.25 and enemies.size() > 6:
		for i in 6:
			enemies[i]["x"] = hx + 3.0
			enemies[i]["z"] = hz + 4.0
	var corpses: Array = []
	for i in rng.randi_range(0, 60):
		var a2 := rng.randf() * TAU
		var r2 := rng.randf_range(0.3, 20.0)
		corpses.append({"x": hx + cos(a2) * r2, "z": hz + sin(a2) * r2, "kind": ["normal", "normal", "resonant", "none"][rng.randi() % 4], "area": "graves",
			"seedOwner": "p1" if rng.randf() < 0.1 else "", "echoOwner": null if rng.randf() < 0.8 else ["", "*", "p1"][rng.randi() % 3]})
	var boss := {"active": false, "hp": 0.0, "state": "idle", "x": 0.0, "z": 0.0}
	if rng.randf() < 0.3:
		boss = {"active": true, "hp": 5000.0, "state": "idle", "x": hx + rng.randf_range(-14.0, 14.0), "z": hz + rng.randf_range(-14.0, 14.0)}
	var maxe := 100.0
	var ready_set: Array = []
	for rite in RITES:
		if rng.randf() < 0.65:
			ready_set.append(rite)
	return {"player": {"x": hx, "z": hz, "essence": rng.randf() * maxe, "maxEssence": maxe, "hp": [200.0, 180.0, 120.0, 100.0, 60.0, 40.0][rng.randi() % 6], "maxHp": 200.0, "area": "graves",
			"souls": [0, 3, 4, 9, 10, 14, 22, 28, 30][rng.randi() % 9]},
		"enemies": enemies, "corpses": corpses, "boss": boss, "thrallCount": rng.randi() % 8, "thrallCap": rng.randi() % 9, "ready": ready_set, "family": family,
		"primary": "scythe_sweep" if family == "reaper" else ["bone_needle", "bone_needle", "bone_fan"][rng.randi() % 3], "primaryRange": [null, 9.0, 12.0][rng.randi() % 3],
		"selfId": "p1", "signature": ["command_rend", "plague_bloom", "ossuary_wall", "dirge", ""][rng.randi() % 5], "now": 1000.0}


func _ready_of(ctx: Dictionary) -> Callable:
	var rd: Array = ctx["ready"]
	return func(id: String) -> bool: return rd.has(id)


func _seeded_actions(family: String, n: int, seed_: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var bad := 0
	var first := ""
	var seen := {}
	for i in n:
		var ctx := _context(rng, family)
		var a: Variant = ref.select_action(_with_ready(ctx))
		var b: Variant = DmAutoCombat.select_action(_with_ready(ctx))
		seen["none" if a == null else String(a["id"])] = true
		if str(a) != str(b):
			bad += 1
			if first == "":
				first = "case %d: today's %s, the port's %s" % [i, str(a), str(b)]
	check(bad == 0, "%s: %d seeded fights, the port chooses what today's code chooses (%d different rites chosen)%s" % [family, n, seen.size(), "" if bad == 0 else " (first miss: " + first.left(300) + ")"])
	check(seen.size() >= (9 if family == "necromancer" else 6), "%s: the fights reach many rules of the list (%s)" % [family, ", ".join(seen.keys())])
	print("INFO auto_combat: %s fights chose %s" % [family, ", ".join(seen.keys())])


func _with_ready(ctx: Dictionary) -> Dictionary:
	var c: Dictionary = ctx.duplicate(true)
	c["ready"] = _ready_of(ctx)
	return c


func _seeded_movement(n: int, seed_: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var bad := 0
	var first := ""
	for i in n:
		var ctx := _context(rng, "necromancer")
		var steps := rng.randi_range(1, 4)
		var mem_a: Variant = {} if rng.randf() < 0.75 else null
		var mem_b: Variant = mem_a.duplicate(true) if mem_a != null else null
		for s in steps:
			var now := 1000.0 + float(s) * 100.0
			var ca := ctx.duplicate(true)
			var cb := ctx.duplicate(true)
			ca.erase("ready")
			cb.erase("ready")
			var a: Variant = ref.select_movement(ca, mem_a, now, 0.1)
			var b: Variant = DmAutoCombat.select_movement(cb, mem_b, now, 0.1)
			if str(a) != str(b) or str(mem_a) != str(mem_b):
				bad += 1
				if first == "":
					first = "case %d step %d: today's %s %s, the port's %s %s" % [i, s, str(a), str(mem_a), str(b), str(mem_b)]
				break
	check(bad == 0, "movement: %d seeded rooms of up to 4 steps, the port steers where today's code steers, memory included%s" % [n, "" if bad == 0 else " (first miss: " + first.left(300) + ")"])


# ------------------------------------------------------------------------------------------------------------------ INFO: what a decision costs

func _timing() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var ctx := _context(rng, "necromancer")
	var enemies: Array = []
	for i in 62:
		var a := rng.randf() * TAU
		var r := rng.randf_range(1.0, 13.0)
		enemies.append({"id": i + 1, "x": 100.0 + cos(a) * r, "z": 50.0 + sin(a) * r, "hp": 272.9, "maxHp": 272.9, "state": "chase", "radius": 0.5, "elite": false, "area": "graves", "hexOwner": ""})
	ctx["enemies"] = enemies
	var corpses: Array = []
	for i in 31:
		var a2 := rng.randf() * TAU
		var r2 := rng.randf_range(1.0, 13.0)
		corpses.append({"x": 100.0 + cos(a2) * r2, "z": 50.0 + sin(a2) * r2, "kind": "normal", "area": "graves", "seedOwner": "", "echoOwner": null})
	ctx["corpses"] = corpses
	ctx["boss"] = {"active": false, "hp": 0.0, "state": "idle", "x": 0.0, "z": 0.0}
	ctx["ready"] = ["corpse_explosion", "command_rend", "bone_needle"]
	ctx["player"]["essence"] = 90.0
	ctx["thrallCount"] = 4
	ctx["thrallCap"] = 4
	var us := [0.0, 0.0]
	var reps := 40
	for k in 2:
		var who: Object = ref if k == 0 else DmAutoCombat
		for i in reps:
			var c := _with_ready(ctx)
			var t0 := Time.get_ticks_usec()
			who.select_action(c)
			us[k] += float(Time.get_ticks_usec() - t0)
	print("INFO auto_combat: one decision with 62 enemies and 31 corpses in reach: today's %.2f ms, the port's %.2f ms" % [us[0] / reps / 1000.0, us[1] / reps / 1000.0])
