extends SceneTree
## The combat core's skeleton API (native/README.md "Design"): queries in spawn order, synchronous kills, the event buffer, seeded
## stats, the rise and the 4 s body linger. Run: godot --headless --path client --script res://tests/core_api.gd

## The defs are the test's own fixture; the elite multipliers come from the data (ELITE in enemies.json).
const DEFS := {
	"robber": {"hp": 68, "damage": 11, "speed": 2.6, "radius": 0.45, "attackRange": 1.3, "windupMs": 420, "cooldownMs": 1300},
	"golem": {"hp": 430, "damage": 26, "speed": 1.5, "radius": 1.1},
}
const EV_SPAWNED := 1
const EV_STATE := 2
const EV_DAMAGED := 3
const EV_DIED := 4
const EV_REMOVED := 5
const EV_CORPSE_ADDED := 18

var fails := 0
var checks := 0
var elite: Dictionary = {}   ## ELITE of enemies.json: hpMult, damageMult


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL core_api: " + what)


func make(seed_: int) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	check(c.load_enemy_defs(DEFS) == 2, "two defs load")
	c.load_tuning(DmCoreData.json("res://data/content/enemies.json"))
	c.set_area_bounds(Vector2(-40, -40), Vector2(40, 40))
	c.set_wander(false)
	return c


## Events of one take_events() as dictionaries (the GDScript dispatcher will decode the same way).
func events(c: RefCounted) -> Array:
	var raw: Array = c.take_events()
	var ints: PackedInt32Array = raw[0]
	var floats: PackedFloat32Array = raw[1]
	var out := []
	var i := 0
	var f := 0
	while i < ints.size():
		var ni := ints[i + 2]
		var nf := ints[i + 3]
		out.append({"type": ints[i], "id": ints[i + 1], "ints": ints.slice(i + 4, i + 4 + ni), "floats": floats.slice(f, f + nf)})
		i += 4 + ni
		f += nf
	return out


func _init() -> void:
	elite = DmCoreData.json("res://data/content/enemies.json")["ELITE"]
	var c := make(7)
	var a: int = c.spawn_enemy("robber", Vector2(0, 0), 3, 1.0, 1.0, false, "graves", false)
	var b: int = c.spawn_enemy("robber", Vector2(2.4, 0), 3, 1.0, 1.0, false, "graves", false)
	var g: int = c.spawn_enemy("golem", Vector2(5.0, 0), 3, 1.0, 1.0, true, "graves", false)
	var far: int = c.spawn_enemy("robber", Vector2(30, 30), 3, 1.0, 1.0, false, "graves", true)
	# Queries see bodies spawned since the last step, and after it, through the grid; spawn order either way.
	check(Array(c.enemies_in_radius(Vector2(0, 0), 2.0)) == [a, b], "fresh spawns: radius 2 finds a and b (b's edge at 1.95)")
	c.step(1.0 / 60.0)
	check(Array(c.enemies_in_radius(Vector2(0, 0), 2.0)) == [a, b], "after a step: same answer from the grid")
	check(Array(c.enemies_in_radius(Vector2(0, 0), 3.7)) == [a, b, g], "the elite golem's edge (5 - 1.375) is inside 3.7")
	check(Array(c.enemies_in_radius(Vector2(0, 0), 3.6)) == [a, b], "and not inside 3.6")
	check(Array(c.enemies_in_radius(Vector2(30, 30), 1.0)) == [far], "a RISING body counts in queries (today's alive_enemy)")
	# `foes_in_radius` is the same query with the record's numbers in one call: ten a body (id x z radius hp state elite level def area), the very values `enemy_info` gives.
	for q in [[Vector2(0, 0), 2.0], [Vector2(0, 0), 3.7], [Vector2(30, 30), 1.0], [Vector2(0, 0), 60.0], [Vector2(-30, 0), 1.0]]:
		var rows: PackedFloat64Array = c.foes_in_radius(q[0], q[1])
		var ids: Array = Array(c.enemies_in_radius(q[0], q[1]))
		var same := rows.size() == ids.size() * 10
		for n in mini(ids.size(), rows.size() / 10):
			var info: Dictionary = c.enemy_info(ids[n])
			var k := n * 10
			var pos: Vector2 = info["pos"]
			same = same and int(rows[k]) == ids[n] and rows[k + 1] == pos.x and rows[k + 2] == pos.y and rows[k + 3] == info["radius"] and rows[k + 4] == info["hp"] \
				and int(rows[k + 5]) == info["state"] and (rows[k + 6] != 0.0) == info["elite"] and int(rows[k + 7]) == info["level"] \
				and c.def_name(int(rows[k + 8])) == info["def"] and c.area_name(int(rows[k + 9])) == info["area"]
		check(same, "foes_in_radius%s equals enemies_in_radius with each record's numbers (%d foes)" % [str(q), ids.size()])
	# the one-field reads give the record's own values, and the gone values for an id the core does not know
	var fields_same := true
	for id in [a, b, g, far]:
		var info: Dictionary = c.enemy_info(id)
		fields_same = fields_same and c.enemy_state(id) == int(info["state"]) and c.enemy_pos(id) == info["pos"] and c.enemy_radius(id) == float(info["radius"])
	check(fields_same and c.enemy_state(999999) == -1 and is_inf(c.enemy_pos(999999).x) and c.enemy_radius(999999) == 0.0, "enemy_state / enemy_pos / enemy_radius are the record's values; -1, INF and 0 when gone")
	var gi: Dictionary = c.enemy_info(g)
	# the radius multiplier (x1.25) is compiled into the core: enemies.json has none
	check(is_equal_approx(gi["max_hp"], 430.0 * float(elite["hpMult"])) and is_equal_approx(gi["damage"], 26.0 * float(elite["damageMult"])) and is_equal_approx(gi["radius"], 1.375), "elite stats: hp and damage x the ELITE multipliers, radius x1.25")
	var sp: float = c.enemy_info(a)["speed"]
	check(sp >= 2.6 * 0.92 and sp <= 2.6 * 1.08, "speed jitter within +-8%")
	events(c)  # spawn events checked below with a fresh core

	# Damage: refused while RISING, partial, then a kill resolved inside the call.
	check(c.damage(far, 10, 99)["dealt"] == 0.0, "RISING refuses damage")
	var r1: Dictionary = c.damage(a, 30.0, 7)
	check(r1["dealt"] == 30.0 and not r1["killed"], "partial hit")
	var r2: Dictionary = c.damage(a, 40.0, 7)
	check(r2["killed"], "lethal hit reports the kill at once")
	check(c.enemy_info(a)["state"] == 6 and c.enemy_info(a)["hp"] == 0.0, "dead: state DEAD, hp 0")
	check(Array(c.enemies_in_radius(Vector2(0, 0), 2.0)) == [b], "a dead body leaves queries")
	check(c.damage(a, 5.0, 7)["dealt"] == 0.0, "a dead body takes no damage")
	var ev := events(c)
	check(ev.size() == 6, "events: damaged, IDLE->HURT (stagger), damaged, HURT->DEAD, corpse added, died (got %d)" % ev.size())
	if ev.size() == 6:
		check(ev[0]["type"] == EV_DAMAGED and is_equal_approx(ev[0]["floats"][1], 38.0), "first damaged event carries hp 38")
		check(ev[1]["type"] == EV_STATE and Array(ev[1]["ints"]) == [1, 4], "the first hit staggers an idle body")
		check(ev[3]["type"] == EV_STATE and Array(ev[3]["ints"]) == [4, 6], "HURT -> DEAD state edge")
		check(ev[4]["type"] == EV_CORPSE_ADDED and ev[4]["id"] == 1, "a def without a corpse key lays a normal corpse, before the died event")
		check(ev[5]["type"] == EV_DIED and Array(ev[5]["ints"]) == [0, 3, 0, 0, 7], "died: def, level, elite, area, source")
		check(c.def_name(ev[5]["ints"][0]) == "robber" and c.area_name(ev[5]["ints"][3]) == "graves", "def and area names decode")

	# The rise: RISING for 1.1 s, then IDLE; the body lingers 4 s after death, counted until removed.
	for i in 60:
		c.step(1.0 / 60.0)
	check(c.enemy_count() == 4, "the dead body still counts")
	for i in 6:
		c.step(1.0 / 60.0)
	var risen := c.enemy_info(far)["state"] as int
	c.step(1.0 / 60.0)
	check(risen == 0 or c.enemy_info(far)["state"] == 1, "RISING -> IDLE at 1.1 s")
	for i in 240:
		c.step(1.0 / 60.0)
	check(c.enemy_count() == 3 and c.enemy_info(a).is_empty(), "the dead body is removed after 4 s")
	var gone := events(c).filter(func(e: Dictionary) -> bool: return e["type"] == EV_REMOVED)
	check(gone.size() == 1 and gone[0]["id"] == a, "one removed event, for the dead body")
	check(Array(c.enemies_in_radius(Vector2(0, 0), 3.7)) == [b, g], "spawn order kept after compaction")

	# remove_enemy: a living body leaves silently (a boss's adds go with the boss): no death, no corpse, no credit, the others keep spawn order and their ids.
	var rc := make(11)
	var r_a: int = rc.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	var r_b: int = rc.spawn_enemy("robber", Vector2(2.0, 0), 1, 1.0, 1.0, false, "graves", false)
	var r_c: int = rc.spawn_enemy("robber", Vector2(4.0, 0), 1, 1.0, 1.0, true, "graves", false)
	rc.step(1.0 / 60.0)
	events(rc)
	check(rc.remove_enemy(r_b) and rc.enemy_count() == 2 and rc.enemy_info(r_b).is_empty(), "remove_enemy takes a living body out of the table at once")
	check(Array(rc.enemies_in_radius(Vector2(0, 0), 9.0)) == [r_a, r_c] and rc.enemy_info(r_c)["pos"] == Vector2(4.0, 0.0), "the others keep their ids, their places and their order, and the queries see it before the next step")
	var rev := events(rc)
	check(rev.size() == 1 and rev[0]["type"] == EV_REMOVED and rev[0]["id"] == r_b and Array(rev[0]["ints"]) == [1], "one removed event with 1 (it was alive), no died event")
	check(rc.corpse_count() == 0, "no corpse was laid")
	check(not rc.remove_enemy(r_b) and not rc.remove_enemy(999), "an id that is gone is refused")
	rc.damage(r_a, 1.0e6, 7)
	check(not rc.remove_enemy(r_a), "a dead body is refused (it leaves on its own after 4 s)")
	events(rc)
	for i in 5:
		rc.step(1.0 / 60.0)
	check(rc.enemy_count() == 2 and rc.enemy_info(r_c)["hp"] > 0.0, "the next steps go on with the bodies that are left")

	# Seeded: same seed, same stats; another seed, other stats.
	var s1 := make(42)
	var s2 := make(42)
	var s3 := make(43)
	var i1: int = s1.spawn_enemy("robber", Vector2.ZERO, 1, 1.0, 1.0, false, "graves", true)
	var i2: int = s2.spawn_enemy("robber", Vector2.ZERO, 1, 1.0, 1.0, false, "graves", true)
	var i3: int = s3.spawn_enemy("robber", Vector2.ZERO, 1, 1.0, 1.0, false, "graves", true)
	check(s1.enemy_info(i1)["speed"] == s2.enemy_info(i2)["speed"], "same seed, same speed roll")
	check(s1.enemy_info(i1)["speed"] != s3.enemy_info(i3)["speed"], "other seed, other speed roll")
	var sev := events(s1)
	check(sev.size() == 1 and sev[0]["type"] == EV_SPAWNED and Array(sev[0]["ints"]) == [0, 1, 0, 0, 0], "spawned event: def, level, elite, area, affixes")

	_navmesh_regions()
	if fails == 0:
		print("PASS core_api %d checks" % checks)
	quit(1 if fails > 0 else 0)


## The core's own copy of the navmesh (NavGrid): regions added, switched, replaced (a Depths floor changing) and emptied; the others untouched.
func _navmesh_regions() -> void:
	var c := make(5)
	var poly := PackedInt32Array([4, 0, 1, 2, 3])
	var sq := func(x0: float) -> PackedVector3Array: return PackedVector3Array([Vector3(x0, 0, 0), Vector3(x0 + 10, 0, 0), Vector3(x0 + 10, 0, 10), Vector3(x0, 0, 10)])
	var r0: int = c.nav_add_region(sq.call(0.0), poly, true)
	var r1: int = c.nav_add_region(sq.call(40.0), poly, true)
	check(r0 == 0 and r1 == 1 and c.nav_triangle_count() == 4, "nav: two square regions, two triangles each")
	check(c.nav_closest(Vector3(5, 0, 5)) == Vector3(5, 0, 5) and c.nav_closest(Vector3(15, 0, 5)) == Vector3(10, 0, 5) and c.nav_closest(Vector3(36, 0, 5)) == Vector3(40, 0, 5), "nav: a point on the mesh stays, one off it moves to the nearest edge")
	c.nav_set_region_enabled(r0, false)
	check(c.nav_closest(Vector3(5, 0, 5)) == Vector3(40, 0, 5), "nav: a switched-off region is no ground")
	# replace: the region's old triangles go, its new ones come; the other region is untouched
	check(c.nav_replace_region(r0, sq.call(20.0), poly, true) and c.nav_triangle_count() == 4, "nav: a region's polygons replaced (the old triangles are gone, not added to)")
	check(c.nav_closest(Vector3(5, 0, 5)) == Vector3(20, 0, 5) and c.nav_closest(Vector3(25, 0, 5)) == Vector3(25, 0, 5) and c.nav_closest(Vector3(45, 0, 5)) == Vector3(45, 0, 5), "nav: the new polygons answer, the other region is the same")
	check(c.nav_replace_region(r0, PackedVector3Array(), PackedInt32Array(), false) and c.nav_triangle_count() == 2, "nav: replaced with nothing, the region is empty")
	check(c.nav_closest(Vector3(25, 0, 5)) == Vector3(40, 0, 5), "nav: ...and no ground")
	check(c.nav_replace_region(r0, sq.call(0.0), poly, true) and c.nav_closest(Vector3(5, 0, 5)) == Vector3(5, 0, 5), "nav: an emptied region takes polygons again")
	check(not c.nav_replace_region(7, sq.call(0.0), poly, true) and not c.nav_replace_region(-1, sq.call(0.0), poly, true), "nav: an unknown region is refused")
	c.nav_clear_regions()
	check(c.nav_triangle_count() == 0, "nav: cleared")
