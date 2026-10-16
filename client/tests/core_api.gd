extends SceneTree
## The combat core's skeleton API (native/README.md "Design"): queries in spawn order, synchronous kills, the event buffer, seeded
## stats, the rise and the 4 s body linger. Run: godot --headless --path client --script res://tests/core_api.gd

const DEFS := {
	"robber": {"hp": 68, "damage": 11, "speed": 2.6, "radius": 0.45, "attackRange": 1.3, "windupMs": 420, "cooldownMs": 1300},
	"golem": {"hp": 430, "damage": 26, "speed": 1.5, "radius": 1.1},
}
const EV_SPAWNED := 1
const EV_STATE := 2
const EV_DAMAGED := 3
const EV_DIED := 4
const EV_REMOVED := 5

var fails := 0
var checks := 0


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL core_api: " + what)


func make(seed_: int) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	check(c.load_enemy_defs(DEFS) == 2, "two defs load")
	c.set_area_bounds(Vector2(-40, -40), Vector2(40, 40))
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
	var gi: Dictionary = c.enemy_info(g)
	check(is_equal_approx(gi["max_hp"], 430.0 * 3.6) and is_equal_approx(gi["damage"], 26.0 * 1.5) and is_equal_approx(gi["radius"], 1.375), "elite stats x3.6 hp, x1.5 damage, x1.25 radius")
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
	check(ev.size() == 4, "events: damaged, damaged, state->DEAD, died (got %d)" % ev.size())
	if ev.size() == 4:
		check(ev[0]["type"] == EV_DAMAGED and is_equal_approx(ev[0]["floats"][1], 38.0), "first damaged event carries hp 38")
		check(ev[2]["type"] == EV_STATE and Array(ev[2]["ints"]) == [1, 6], "IDLE -> DEAD state edge")
		check(ev[3]["type"] == EV_DIED and Array(ev[3]["ints"]) == [0, 3, 0, 0, 7], "died: def, level, elite, area, source")
		check(c.def_name(ev[3]["ints"][0]) == "robber" and c.area_name(ev[3]["ints"][3]) == "graves", "def and area names decode")

	# The rise: RISING for 1.1 s, then IDLE; the body lingers 4 s after death, counted until removed.
	for i in 66:
		c.step(1.0 / 60.0)
	var risen := c.enemy_info(far)["state"] as int
	c.step(1.0 / 60.0)
	check(risen == 0 or c.enemy_info(far)["state"] == 1, "RISING -> IDLE at 1.1 s")
	check(c.enemy_count() == 4, "the dead body still counts")
	for i in 240:
		c.step(1.0 / 60.0)
	check(c.enemy_count() == 3 and c.enemy_info(a).is_empty(), "the dead body is removed after 4 s")
	var gone := events(c).filter(func(e: Dictionary) -> bool: return e["type"] == EV_REMOVED)
	check(gone.size() == 1 and gone[0]["id"] == a, "one removed event, for the dead body")
	check(Array(c.enemies_in_radius(Vector2(0, 0), 3.7)) == [b, g], "spawn order kept after compaction")

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
	check(sev.size() == 1 and sev[0]["type"] == EV_SPAWNED and Array(sev[0]["ints"]) == [0, 1, 0, 0], "spawned event: def, level, elite, area")

	if fails == 0:
		print("PASS core_api %d checks" % checks)
	quit(1 if fails > 0 else 0)
