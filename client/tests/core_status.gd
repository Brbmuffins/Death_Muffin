extends SceneTree
## Statuses in the combat core against DmStatusSet (godot/next/status/dm_status_set.gd): the 0.1 s step (7 ticks at 60 Hz), DoT lumps every
## 3 steps (21 ticks), stacking and ownership rules, multipliers on the body, stun, the ghoul's dig-in clear, Withered on death, the wire bytes.
## Run: godot --headless --path client --script res://tests/core_status.gd

const EV_STATE := 2
const EV_DIED := 4
const EV_STATUS_CHANGED := 14
const EV_DOT := 15
const EV_EXPIRED := 16
const EV_WITHERED_DIED := 17
const HURT := 4
const DIG := 10
const DT := 1.0 / 60.0

var fails := 0
var checks := 0
var data := {}


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL core_status: " + what)


func load_json(name: String) -> Dictionary:
	var f := FileAccess.open(ProjectSettings.globalize_path("res://").path_join("../godot/data/content/%s.json" % name), FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func make() -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(5)
	c.load_enemy_defs(data["enemies"]["ENEMIES"])
	c.load_tuning(data["enemies"])
	check(c.load_status_defs(DmStatusRules.build(data["abilities"], data["statuses"], data["enemies"])) == 16, "16 status rules load")
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	return c


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


func steps(c: RefCounted, n: int, log: Array) -> void:
	for i in n:
		c.step(DT)
		for e in events(c):
			e["tick"] = i + 1
			log.append(e)


func _init() -> void:
	for n in ["enemies", "abilities", "statuses"]:
		data[n] = load_json(n)
	withered()
	multipliers()
	ownership()
	stun_and_dig()
	death()
	if fails == 0:
		print("PASS core_status %d checks" % checks)
	quit(1 if fails > 0 else 0)


## Withered: stacks x dps per second, paid in lumps every 3 status steps (21 ticks), credited to the last stacker.
func withered() -> void:
	var c := make()
	var e: int = c.spawn_enemy("golem", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	events(c)
	c.apply_status(e, "withered", 77, 2, -1.0, {"dps": 10.0})
	check(c.status_stacks(e, "withered") == 2.0, "withered: 2 stacks")
	var log := []
	steps(c, 130, log)
	var dots: Array = log.filter(func(x: Dictionary) -> bool: return x["type"] == EV_DOT)
	check(dots.size() >= 5, "withered: DoT lumps come (%d)" % dots.size())
	if dots.size() >= 3:
		check(dots[2]["tick"] - dots[1]["tick"] == 21, "withered: lumps every 21 ticks (3 steps of 7)")
		check(dots[1]["ints"][1] == 77, "withered: the stacker owns the damage")
		check(absf(dots[1]["floats"][0] - 2.0 * 10.0 * 21.0 / 60.0) < 0.01, "withered: a lump = stacks x dps x 0.35 s (%.3f)" % dots[1]["floats"][0])
	var total := 0.0
	for d in dots:
		total += d["floats"][0]
	var lost: float = c.enemy_info(e)["max_hp"] - c.enemy_info(e)["hp"]
	check(absf(total - lost) < 0.01, "withered: the lumps are the health lost")
	c.apply_status(e, "withered", 88, 1, -1.0, {"dps": 4.0})
	check(c.status_stacks(e, "withered") == 3.0, "withered: stacks add")
	var log2 := []
	steps(c, 50, log2)
	var later: Array = log2.filter(func(x: Dictionary) -> bool: return x["type"] == EV_DOT)
	check(not later.is_empty() and later[0]["ints"][1] == 88, "withered: the last stacker owns it now")
	# The first lump after the third stack still holds time accrued at 2 stacks; the next one is a whole window at 3.
	check(later.size() >= 2 and absf(later[1]["floats"][0] - 3.0 * 10.0 * 21.0 / 60.0) < 0.01, "withered: the strongest dps stays (10, not 4)")


## Slows take the strongest, everything else multiplies; root stops movement; chill also slows attacks; fracture raises damage taken.
func multipliers() -> void:
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	c.apply_status(e, "slow", 1)
	c.apply_status(e, "ward_slow", 1)
	check(is_equal_approx(c.enemy_info(e)["speed_mult"], 0.6), "slows: the strongest (0.6) wins, not 0.6 x 0.75")
	c.apply_status(e, "chill", 1)
	check(is_equal_approx(c.enemy_info(e)["speed_mult"], 0.6 * 0.7) and is_equal_approx(c.enemy_info(e)["attack_rate_mult"], 0.75), "chill: move x0.7 with the slow, attacks x0.75")
	c.apply_status(e, "root", 1)
	check(c.enemy_info(e)["speed_mult"] == 0.0, "root: no movement")
	var log := []
	steps(c, 140, log)   # slow 0.3 s, root 1.8 s, chill 2.5 s
	var gone: Array = log.filter(func(x: Dictionary) -> bool: return x["type"] == EV_EXPIRED).map(func(x: Dictionary) -> int: return x["ints"][0])
	check(gone.slice(0, 2) == [0, 1] and gone.has(3), "expiry: slow and ward slow first (0.3 s), root by 1.8 s (%s)" % str(gone))
	check(is_equal_approx(c.enemy_info(e)["speed_mult"], 0.7) and is_equal_approx(c.enemy_info(e)["attack_rate_mult"], 0.75), "only chill is left")
	c.apply_status(e, "fracture", 1, 2)
	check(is_equal_approx(c.enemy_info(e)["taken_mult"], 1.3), "fracture: 2 stacks = damage taken x1.3")
	c.apply_status(e, "fracture", 1, 5)
	check(c.status_stacks(e, "fracture") == 3.0 and is_equal_approx(c.enemy_info(e)["taken_mult"], 1.45), "fracture: capped at 3 stacks")
	var hp0: float = c.enemy_info(e)["hp"]
	c.damage(e, 10.0, 1)
	check(is_equal_approx(hp0 - c.enemy_info(e)["hp"], 14.5), "damage taken applies to every hit")


## Bleed: the stronger dps takes over the bleed and its owner; a weaker one only refreshes nothing.
func ownership() -> void:
	var c := make()
	var e: int = c.spawn_enemy("golem", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	c.apply_status(e, "bleed", 5, 1, -1.0, {"dps": 6.0})
	c.apply_status(e, "bleed", 6, 1, -1.0, {"dps": 3.0})
	events(c)
	var log := []
	steps(c, 25, log)
	var dots: Array = log.filter(func(x: Dictionary) -> bool: return x["type"] == EV_DOT)
	check(not dots.is_empty() and dots[0]["ints"][1] == 5, "bleed: the stronger bleed keeps its owner")
	c.apply_status(e, "bleed", 7, 1, -1.0, {"dps": 9.0})
	var log2 := []
	steps(c, 25, log2)
	var dots2: Array = log2.filter(func(x: Dictionary) -> bool: return x["type"] == EV_DOT)
	check(not dots2.is_empty() and dots2[0]["ints"][1] == 7, "bleed: a stronger bleed takes over")


## Stun via a status forces HURT; a ghoul digging in drops bleed, withered, root, slow and chill, and keeps fracture.
func stun_and_dig() -> void:
	var c := make()
	var r: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	c.apply_status(r, "stun", 1)
	check(c.enemy_info(r)["state"] == HURT, "stun status: the body is stunned")
	var g: int = c.spawn_enemy("ghoul", Vector2(5, 0), 1, 1.0, 1.0, false, "graves", false)
	for s in ["bleed", "withered", "root", "slow", "chill", "fracture"]:
		c.apply_status(g, s, 1, 1, -1.0, {"dps": 1.0})
	c.damage(g, 40.0, 1)   # 60 -> 20: below half, digs in
	check(c.enemy_info(g)["state"] == DIG, "ghoul: digs in")
	var log := []
	steps(c, 50, log)
	var b: PackedByteArray = c.statuses(g)
	var left := []
	for i in range(0, b.size(), 4):
		left.append(b[i])
	check(left == [8], "dig-in: only fracture is left (%s)" % str(left))


## Death: Withered is reported (source, stacks, dps) before the died event, then the set is empty; the wire bytes before that.
func death() -> void:
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", false)
	c.apply_status(e, "withered", 9, 4, -1.0, {"dps": 2.5})
	var b: PackedByteArray = c.statuses(e)
	check(b.size() == 4 and b[0] == 7 and b[1] == 4 and (b[2] | (b[3] << 8)) == 50, "wire: withered, 4 stacks, 5.0 s")
	events(c)
	c.damage(e, 1000.0, 3)
	var ev := events(c)
	var order: Array = ev.map(func(x: Dictionary) -> int: return x["type"])
	var wi := order.find(EV_WITHERED_DIED)
	var di := order.find(EV_DIED)
	check(wi >= 0 and di > wi, "death: withered reported before the died event")
	if wi >= 0:
		check(ev[wi]["ints"][0] == 9 and ev[wi]["floats"][0] == 4.0 and ev[wi]["floats"][1] == 2.5, "death: withered source, stacks and dps")
	check(c.statuses(e).is_empty(), "death: the set is cleared")
