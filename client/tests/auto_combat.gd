extends SceneTree
## Easy auto combat's decisions (client/game/dm_auto_combat.gd, ported to cost a quarter as much and choose the same: client/code.list "Ported") against TODAY'S: the reference is
## the old game's game/dm_auto_combat.gd itself, kept as text (tests/fixtures/old_game/game/dm_auto_combat.gd.txt, so Godot never parses it) and compiled at run time (its class_name line dropped).
##   - seeded Full-Party-sized contexts (sixty-odd enemies in reach, corpses of every kind, boss or none, random cooldowns, essence, hurt, souls and thralls; stacked enemies for equal
##     distances) for the necromancer's rites and the Reaper's: the port's choice must equal the reference's, every rule of the list reached;
##   - the movement (`select_movement`) on seeded rooms, memory included;
##   - the walk round what stands in the way (`routeNav`: the game's navmesh asked for the straight line and for a path): when it asks and how often, the stuck flag, and that the dodge never asks it.
## The frozen web game's golden cases are replayed on the port by tests/auto_combat_fixtures/run.gd (the one home of them). Run: godot --headless --path client --script res://tests/auto_combat.gd

const TODAY := "res://tests/fixtures/old_game/game/dm_auto_combat.gd.txt"   ## the old game's decision code, kept as text
const RITES := ["bone_needle", "bone_fan", "exhume", "grave_offering", "rally_dead", "carrion_seed", "bone_mantle", "black_litany", "corpse_explosion", "ivory_cleave", "miasma", "bone_prison",
	"grave_hands", "bone_storm", "soul_siphon", "grave_frost", "marrow_spear", "wailing_skull", "command_rend", "plague_bloom", "ossuary_wall", "dirge", "scythe_sweep", "reap", "harvest_spin",
	"scythe_throw", "wraith_walk", "soul_burst"]
const STATES := ["chase", "chase", "chase", "windup", "attack", "channel", "dead", "rising", "burrow"]

var fails := 0
var checks := 0
var ref: GDScript


## A navigation the test controls: whether the straight line is clear, the path it answers, and how many times each was asked.
class FakeNav extends RefCounted:
	var clear := true
	var path: Array = []
	var lines := 0
	var paths := 0

	func clear_line(_ax: float, _az: float, _bx: float, _bz: float, _r: float = 0.45) -> bool:
		lines += 1
		return clear

	func find_path(_fx: float, _fz: float, _tx: float, _tz: float, _r: float = 0.45) -> Array:
		paths += 1
		return path


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL auto_combat: " + what)


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	var src := FileAccess.get_file_as_string(TODAY)
	check(src != "", "today's decision code is readable at %s" % TODAY)
	if src == "":
		_end()
		return
	var today := GDScript.new()
	today.source_code = src.replace("class_name DmAutoCombat\n", "")
	check(today.reload() == OK, "today's decision code compiles in this project")
	ref = today
	_seeded_actions("necromancer", 700, 20261017)
	_seeded_actions("reaper", 500, 20261018)
	_seeded_movement(160, 20261019)
	_route_round()
	_end()


func _end() -> void:
	print("%s auto_combat %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


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


# ------------------------------------------------------------------------------------------------------------------ the walk round what is in the way

## One enemy out of reach to the east of the hero at (0, -18) in the Graves, nothing else: the hero has to close, in a straight line unless something is in the way.
func _lone_foe_ctx() -> Dictionary:
	var reach := 9.0
	var foe := {"id": 7, "x": reach + 12.0, "z": -18.0, "hp": 100.0, "maxHp": 100.0, "state": "chase", "radius": 0.5, "elite": false, "area": "graves", "hexOwner": ""}
	return {"player": {"x": 0.0, "z": -18.0, "essence": 50.0, "maxEssence": 100.0, "hp": 200.0, "maxHp": 200.0, "area": "graves", "souls": 0}, "enemies": [foe], "corpses": [],
		"boss": {"active": false, "hp": 0.0, "state": "idle", "x": 0.0, "z": 0.0}, "thrallCount": 0, "thrallCap": 0, "family": "necromancer", "primary": "bone_needle", "primaryRange": reach,
		"selfId": "p1", "signature": "", "now": 1000.0}


func _route_round() -> void:
	# the line is clear: straight at it, one look at the line, no path asked
	var ctx := _lone_foe_ctx()
	var nav := FakeNav.new()
	ctx["routeNav"] = nav
	var mem: Dictionary = {}
	var d: Variant = DmAutoCombat.select_movement(ctx, mem, 1000.0, 0.0)
	check(d != null and absf(float(d["x"]) - 1.0) < 0.001 and absf(float(d["z"])) < 0.001, "route: a clear line is walked straight (%s)" % str(d))
	check(nav.lines == 1 and nav.paths == 0, "route: ...one look at the line and no path (%d, %d)" % [nav.lines, nav.paths])
	# something in the way: the first point of the path it is given, the path asked once and followed
	nav = FakeNav.new()
	nav.clear = false
	nav.path = [[0.0, -8.0], [20.0, -8.0]]
	ctx["routeNav"] = nav
	mem = {}
	d = DmAutoCombat.select_movement(ctx, mem, 1000.0, 0.0)
	check(d != null and absf(float(d["x"])) < 0.001 and absf(float(d["z"]) - 1.0) < 0.001, "route: a blocked line walks to the path's first point (%s)" % str(d))
	check(nav.lines == 1 and nav.paths == 1, "route: ...asked once for the line and once for the path (%d, %d)" % [nav.lines, nav.paths])
	var t := 1000.0
	while t < 1000.0 + DmAutoCombat.ROUTE_MS - 100.0:   # every 100 ms move tick until the route is due again
		t += 100.0
		DmAutoCombat.select_movement(ctx, mem, t, 0.0)
	check(nav.paths == 1 and nav.lines <= 1 + int(ceilf(DmAutoCombat.ROUTE_MS / DmAutoCombat.SIGHT_MS)), "route: the path is followed for ROUTE_MS and the line is looked at only every SIGHT_MS (%d looks, %d paths in %.0f ms)" % [nav.lines, nav.paths, t - 1000.0])
	DmAutoCombat.select_movement(ctx, mem, 1000.0 + DmAutoCombat.ROUTE_MS + 1.0, 0.0)
	check(nav.paths == 2, "route: ...and asked for again after that (%d)" % nav.paths)
	# the line clears again (the hero is past the corner): straight at the enemy, the route dropped
	nav.clear = true
	d = DmAutoCombat.select_movement(ctx, mem, 1000.0 + DmAutoCombat.ROUTE_MS + DmAutoCombat.SIGHT_MS + 2.0, 0.0)
	check(d != null and absf(float(d["x"]) - 1.0) < 0.001 and mem.get("route") == null, "route: a clear line again is walked straight and the route dropped (%s)" % str(d))
	# stuck: the caller says so, and the walk takes the path although the line looks clear, until the stuck time is up
	nav = FakeNav.new()
	nav.path = [[0.0, -8.0]]
	ctx["routeNav"] = nav
	mem = {"stuckUntil": 5000.0}
	d = DmAutoCombat.select_movement(ctx, mem, 4000.0, 0.0)
	check(d != null and absf(float(d["z"]) - 1.0) < 0.001 and nav.paths == 1, "route: stuck, it takes the path although the line looks clear (%s, %d paths)" % [str(d), nav.paths])
	mem["sightAt"] = 0.0
	d = DmAutoCombat.select_movement(ctx, mem, 6000.0, 0.0)
	check(d != null and absf(float(d["x"]) - 1.0) < 0.001, "route: ...and goes straight again once the stuck time is up (%s)" % str(d))
	# the dodge never asks the route's navigation: only a `nav` of its own
	var pool_nav := FakeNav.new()
	var route_nav := FakeNav.new()
	ctx = _lone_foe_ctx()
	ctx["nav"] = pool_nav
	ctx["routeNav"] = route_nav
	ctx["hazards"] = [DmAutoDodge.pool_hazard({"x": 0.0, "z": -18.0, "r": 3.0}, 0.45)]
	d = DmAutoCombat.select_movement(ctx, {}, 1000.0, 0.0)
	check(d != null and pool_nav.lines > 0 and route_nav.lines == 0 and route_nav.paths == 0, "route: stepping out of a pool asks the dodge's navigation (%d looks), never the route's (%d looks)" % [pool_nav.lines, route_nav.lines])
	# a context with only `nav` (the golden cases) still walks round with it
	nav = FakeNav.new()
	nav.clear = false
	nav.path = [[0.0, -8.0]]
	ctx = _lone_foe_ctx()
	ctx["nav"] = nav
	d = DmAutoCombat.select_movement(ctx, {}, 1000.0, 0.0)
	check(d != null and absf(float(d["z"]) - 1.0) < 0.001 and nav.paths == 1, "route: with `nav` alone the walk goes round with it as before (%s)" % str(d))
