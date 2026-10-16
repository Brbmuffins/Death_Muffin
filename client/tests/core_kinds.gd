extends SceneTree
## The kinds the other areas add to the combat core, against today's rules (godot/enemies): so far the Marrow Ossuary's two, the Bone Golem and the
## Crypt Deacon. Later area groups append their kinds here.
##   - the golem (dm_enemy_hazard.gd, the sac's script): its slam (radius, wind-up, cooldown, damage, the aim fixed at the wind-up's start, who it reaches), its
##     stats and the three corpses it falls into;
##   - the deacon (dm_enemy_deacon.gd, dm_state_cath_support.gd): the keep-away walk, the curse (wind-up, reach at the blow, damage), the raise (the corpse chosen,
##     the 1.5 s channel, the atomic consume, the Risen with the body's level and multipliers, nothing when the corpse is gone, one Risen for two deacons),
##     Sanctify (the most wounded unblessed ally of another kind in range, the status, its 5 s, the cooldown factor, the cue), the order of the three, the scan
##     cadence, silence and stun, an elite deacon;
##   - the wire: a guest's puppet shows the deacon's telegraphs and Sanctify, and the Risen it raised;
##   - the roster: the whole Ossuary roster runs on the core, and a seeded run replays bit for bit.
## The expected ticks come from mirrors of today's arithmetic (countdowns that lose 1/60 s a tick in doubles, clocks that gain it), the numbers from today's data and
## from the scripts' own `const` lines. Seeded, no navmesh (straight lines). Run: godot --headless --path client --script res://tests/core_kinds.gd [-- --verbose]

const EV_SPAWNED := 1
const EV_STATE := 2
const EV_DAMAGED := 3
const EV_DIED := 4
const EV_REMOVED := 5
const EV_ATTACK := 6
const EV_TELEGRAPH := 7
const EV_CUE := 8
const EV_HIT := 9
const EV_STATUS_CHANGED := 14
const EV_STATUS_EXPIRED := 16
const EV_CORPSE_ADDED := 18
const EV_CORPSE_CONSUMED := 19
const EV_CORPSE_GONE := 20
const TELL_SLAM := 1
const TELL_RAISE := 5
const TELL_CURSE := 6
const CUE_SLAM := 0
const CUE_SANCTIFY := 3
const CR_RAISED := 4
const RISING := 0
const IDLE := 1
const CHASE := 2
const ATTACK := 3
const HURT := 4
const DEAD := 6
const DT := 1.0 / 60.0
const ELITE_WINDUP := 0.85    ## dm_enemy.gd _ready: an elite's wind-up and cooldown factors
const ELITE_COOLDOWN := 0.8
const FAR := Vector2(40.0, 0.0)   ## a hero out of the deacon's sight (aggro 15 m)
const SCRIPTS: Array[String] = ["enemies/dm_enemy.gd", "enemies/kinds/dm_enemy_deacon.gd", "enemies/states/dm_state_cath_support.gd", "next/corpses/dm_corpse_field.gd"]

var fails := 0
var checks := 0
var verbose := false
var godot_dir: String
var content: Dictionary
var statuses: Dictionary
var K: Dictionary        ## the scripts' `const` lines (CORPSE_RANGE, BACK_OFF_DIST, SCAN_S, STRIKE_REACH_MULT ...)
var S: Dictionary        ## statuses.json SANCTIFIED
var tick := 0
var keep := []


func check(ok: bool, what: String) -> void:
	checks += 1
	if ok and verbose:
		print("ok   " + what)
	if not ok:
		fails += 1
		printerr("FAIL core_kinds: " + what)


func def(id: String) -> Dictionary:
	return content["ENEMIES"][id]


func make(seed_: int = 11) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	DmCoreData.load_all(c, godot_dir)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	tick = 0
	return c


func hero(c: RefCounted, at: Vector2) -> int:
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, at, true)
	return h


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


## Steps n ticks; every event is labelled with the tick it happened on (calls between ticks count toward the next tick).
func run(c: RefCounted, n: int, log: Array) -> void:
	for i in n:
		tick += 1
		c.step(DT)
		for e in events(c):
			e["tick"] = tick
			log.append(e)


func run_to(c: RefCounted, target: int, log: Array) -> void:
	run(c, maxi(0, target - tick), log)


func drain(c: RefCounted, log: Array) -> void:
	for e in events(c):
		e["tick"] = tick + 1
		log.append(e)


## The events of a type (and of one body, and with a first int) in the log.
func of(log: Array, type: int, id: int = 0, first: int = -99) -> Array:
	return log.filter(func(e: Dictionary) -> bool: return e["type"] == type and (id == 0 or e["id"] == id) and (first == -99 or (not e["ints"].is_empty() and e["ints"][0] == first)))


func first_tick(list: Array) -> int:
	return int(list[0]["tick"]) if not list.is_empty() else -1


func state_edges(log: Array, id: int, to: int) -> Array:
	return log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_STATE and e["id"] == id and e["ints"][1] == to)


# ------------------------------------------------------------------------------------------------------------------ mirrors of today's arithmetic

## Ticks until a countdown that starts at `v` and loses DT a tick (a double, as the brain subtracts it) is <= 0 (dm_enemy.gd: attack_cd -= delta).
func to_zero(v: float) -> int:
	var n := 0
	while v > 0.0:
		v -= DT
		n += 1
	return n


## Ticks until a clock that gains DT a tick (DmEnemyState.t += dt) has reached `limit` (the wind-up, the recovery, a flinch).
func to_reach(limit: float) -> int:
	var t := 0.0
	var n := 0
	while t < limit:
		t += DT
		n += 1
	return n


func spawn_deacon(c: RefCounted, at: Vector2, level := 1, hp_mult := 1.0, dmg_mult := 1.0, elite := false) -> int:
	return c.spawn_enemy("deacon", at, level, hp_mult, dmg_mult, elite, "ossuary", false)


func corpse(c: RefCounted, at: Vector2, kind := "normal", area := "graves") -> int:
	return c.corpse_add(at, kind, "robber", false, 0.0, 1.0, area)


## A counted wound: `frac` of the body's health is gone (no stagger, no aggro).
func wound(c: RefCounted, id: int, frac: float) -> void:
	c.damage(id, float(c.enemy_info(id)["max_hp"]) * frac, 0, false)


func silence(c: RefCounted, id: int) -> void:
	c.apply_status(id, "silence", 0, 1.0, 1000.0)


func _init() -> void:
	verbose = "--verbose" in OS.get_cmdline_user_args()
	godot_dir = ProjectSettings.globalize_path("res://").path_join("../godot")
	content = DmCoreData.json(godot_dir.path_join("data/content/enemies.json"))
	statuses = DmCoreData.json(godot_dir.path_join("data/content/statuses.json"))
	S = statuses["SANCTIFIED"]
	K = DmCoreData.consts(godot_dir, SCRIPTS)
	names_and_tables()
	golem_slam()
	golem_stats_and_corpses()
	deacon_stats_and_keep_away()
	deacon_curse()
	deacon_raise()
	deacon_raise_edges()
	deacon_two_on_one_corpse()
	deacon_sanctify()
	deacon_sanctify_edges()
	deacon_order()
	deacon_scan_cadence()
	deacon_silence_and_stun()
	deacon_elite()
	deacon_on_the_wire()
	the_roster_and_a_replay()
	keep.clear()
	if fails == 0:
		print("PASS core_kinds %d checks" % checks)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ names

## The tables GDScript decodes events with end in the new names, append only, and the scripts' constants are the ones this suite reads.
func names_and_tables() -> void:
	check(DmCoreEvents.TELLS.size() == 7 and DmCoreEvents.TELLS[TELL_SLAM] == &"slam" and DmCoreEvents.TELLS[TELL_RAISE] == &"raise" and DmCoreEvents.TELLS[TELL_CURSE] == &"curse", "the telegraph names: raise and curse appended after toll")
	check(DmCoreEvents.CUES.size() == 4 and DmCoreEvents.CUES[CUE_SLAM] == &"slam" and DmCoreEvents.CUES[CUE_SANCTIFY] == &"sanctify", "the cue names: sanctify appended after dig_in")
	check(K.has("CORPSE_RANGE") and K.has("BACK_OFF_DIST") and K.has("BACK_OFF_SPEED") and K.has("SCAN_S") and K.has("STRIKE_REACH_MULT") and K.has("EXTRA_RING"),
		"the scripts' own constants are read (%s)" % str(K.keys()))
	var c := make()
	check(String(c.version()) == "dmcore 0.8", "the core's version names this step")
	var t: Dictionary = c.tuning()
	check(t["SANCTIFIED.range"] == float(S["range"]) and t["SANCTIFIED.durationS"] == float(S["durationS"]) and t["SANCTIFIED.cooldownMult"] == float(S["cooldownMult"]),
		"Sanctify's range, duration and cooldown factor are statuses.json's")


# ------------------------------------------------------------------------------------------------------------------ the golem

## The golem slams the ground at the aim fixed when the wind-up starts: everything within slamRadius of it, for the def's damage, after windupMs; the next
## swing comes one cooldown after the impact; a hero who leaves the circle in the wind-up is not hit.
func golem_slam() -> void:
	var g := def("golem")
	var r := float(g["slamRadius"])
	var c := make(21)
	var a := hero(c, Vector2(4, 0))
	var inside := hero(c, Vector2(4, r - 0.1))    # in the circle, but farther from the golem than the target
	var outside := hero(c, Vector2(4, r + 0.1))
	var id: int = c.spawn_enemy("golem", Vector2(0, 0), 1, 1.0, 1.0, false, "ossuary", false)
	var info: Dictionary = c.enemy_info(id)
	check(info["max_hp"] == float(g["hp"]) and info["damage"] == float(g["damage"]) and info["radius"] == float(g["radius"]) and info["windup_s"] == float(g["windupMs"]) / 1000.0,
		"golem: hp %d, damage %d, radius %.1f, wind-up %.2f s from the def" % [int(info["max_hp"]), int(info["damage"]), info["radius"], info["windup_s"]])
	check(float(info["speed"]) >= float(g["speed"]) * 0.92 - 1e-6 and float(info["speed"]) <= float(g["speed"]) * 1.08 + 1e-6, "golem: speed %.2f within the +-8%% roll of %.1f" % [info["speed"], float(g["speed"])])
	var log := []
	for i in 1200:
		run(c, 1, log)
		if not of(log, EV_TELEGRAPH, id, TELL_SLAM).is_empty():
			break
	var tell: Array = of(log, EV_TELEGRAPH, id, TELL_SLAM)
	check(tell.size() == 1, "golem: a slam telegraph (%d)" % tell.size())
	if tell.is_empty():
		return
	var k0 := int(tell[0]["tick"])
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[2], 4.0) and is_equal_approx(f[3], 0.0) and is_equal_approx(f[4], r) and is_equal_approx(f[5], float(g["windupMs"]) / 1000.0),
		"golem: the telegraph is the circle (r %.1f) at the hero's place for %.2f s" % [f[4], f[5]])
	var attack: Array = of(log, EV_ATTACK, id)
	check(attack.size() == 1 and attack[0]["ints"][0] == 3 and is_equal_approx(attack[0]["floats"][2], float(g["windupMs"]) / 1000.0), "golem: its swing is the slam blow with the def's wind-up")
	var d := Vector2(c.enemy_info(id)["pos"]).distance_to(Vector2(4, 0))
	check(d <= float(g["attackRange"]) + float(K["ATTACK_TRIGGER_PAD"]) + 0.05 and d > float(g["attackRange"]) * float(K["STOP_FRAC"]) - 0.2, "golem: swings from %.2f m (attack range %.1f + %.2f)" % [d, float(g["attackRange"]), float(K["ATTACK_TRIGGER_PAD"])])
	var ks := k0 + to_reach(float(g["windupMs"]) / 1000.0)
	run_to(c, ks - 1, log)
	check(of(log, EV_HIT, id).is_empty(), "golem: nothing lands before the wind-up ends")
	run_to(c, ks, log)
	var hits := of(log, EV_HIT, id)
	var who := {}
	for h in hits:
		who[int(h["ints"][0])] = [h["floats"][0], h["ints"][1], int(h["tick"])]
	check(who.has(a) and who.has(inside) and not who.has(outside) and hits.size() == 2, "golem: the slam reaches the two heroes inside %.1f m of the aim, not the one outside (%s)" % [r, str(who.keys())])
	check(who.has(a) and who[a][0] == float(g["damage"]) and who[a][1] == 0 and who[a][2] == ks, "golem: %d damage, melee, on tick %d (windup %d ticks after the telegraph)" % [int(g["damage"]), ks, ks - k0])
	var cues := of(log, EV_CUE, id, CUE_SLAM)
	check(cues.size() == 1 and int(cues[0]["tick"]) == ks and is_equal_approx(cues[0]["floats"][2], r) and is_equal_approx(cues[0]["floats"][0], 4.0), "golem: a slam cue at the aim on the blow's tick")
	# The cooldown starts at the impact: the next swing is one cooldown later.
	var cooldown := float(g["cooldownMs"]) / 1000.0
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "golem: the cooldown is %.1f s at the impact" % cooldown)
	run_to(c, ks + to_zero(cooldown) - 1, log)
	check(of(log, EV_TELEGRAPH, id, TELL_SLAM).size() == 1, "golem: no second swing before the cooldown is up")
	run_to(c, ks + to_zero(cooldown), log)
	var second := of(log, EV_TELEGRAPH, id, TELL_SLAM)
	check(second.size() == 2 and int(second[1]["tick"]) == ks + to_zero(cooldown), "golem: the second swing starts one cooldown (%d ticks) after the first impact (tick %d)" % [to_zero(cooldown), first_tick(second.slice(1))])
	# Stepping out of the circle in the wind-up dodges it; standing in it does not.
	c.set_external(a, Vector2(4.0 + r + 1.0, 0), true)
	var after := []
	run(c, to_reach(float(g["windupMs"]) / 1000.0) + 2, after)
	var hit2 := of(after, EV_HIT, id)
	check(hit2.size() == 1 and hit2[0]["ints"][0] == inside, "golem: the hero who left the circle is not hit, the one who stayed is (%s)" % str(hit2.map(func(e: Dictionary) -> int: return e["ints"][0])))


## Stats from the def, and the three corpses it falls into: its own at its feet and two more on the ring (`deathCorpses`), all "normal".
func golem_stats_and_corpses() -> void:
	var g := def("golem")
	var c := make(22)
	var h := hero(c, FAR)
	var id: int = c.spawn_enemy("golem", Vector2(5, 5), 3, 2.0, 1.5, false, "ossuary", false)
	var info: Dictionary = c.enemy_info(id)
	check(is_equal_approx(info["max_hp"], float(g["hp"]) * 2.0) and is_equal_approx(info["damage"], float(g["damage"]) * 1.5), "golem: hp and damage take the spawn's multipliers")
	events(c)
	var yaw := float(c.enemy_info(id)["yaw"])
	var r: Dictionary = c.damage(id, 1.0e6, h, false)
	check(bool(r["killed"]), "golem: dies")
	var added := of(events(c), EV_CORPSE_ADDED)
	var n := int(g["deathCorpses"])
	check(added.size() == n and n == 3, "golem: %d corpses" % added.size())
	if added.size() != n:
		return
	var ok_kind := true
	for e in added:
		ok_kind = ok_kind and e["ints"][0] == 0   # CK_NORMAL
	check(ok_kind and c.def_name(added[0]["ints"][1]) == "golem" and c.def_name(added[1]["ints"][1]) == "risen" and c.def_name(added[2]["ints"][1]) == "risen", "golem: normal corpses; its own, then two risen on the ring")
	var f0: PackedFloat32Array = added[0]["floats"]
	check(is_equal_approx(f0[0], 5.0) and is_equal_approx(f0[1], 5.0) and is_equal_approx(f0[3], float(g["scale"])), "golem: its own lies at its feet, at the def's scale")
	var ring := float(K["EXTRA_RING"])
	var ring_ok := true
	for k in range(1, n):
		var a := yaw + float(k) / float(n - 1) * TAU
		var f: PackedFloat32Array = added[k]["floats"]
		ring_ok = ring_ok and absf(f[0] - (5.0 + sin(a) * ring)) < 1e-3 and absf(f[1] - (5.0 + cos(a) * ring)) < 1e-3
	check(ring_ok, "golem: the extra corpses lie on the %.1f m ring, evenly turned from its facing" % ring)


# ------------------------------------------------------------------------------------------------------------------ the deacon: stats and keep-away

## The deacon keeps its distance (dm_state_cath_support.gd): it walks in while the target is farther than attackRange - 0.5, backs off at BACK_OFF_SPEED
## when closer than BACK_OFF_DIST and stands, facing it, between. Silenced here so that nothing else moves it.
func deacon_stats_and_keep_away() -> void:
	var d := def("deacon")
	var band_far := float(d["attackRange"]) - 0.5
	var near := float(K["BACK_OFF_DIST"])
	var c := make(32)
	var h := hero(c, Vector2(12, 0))
	var id := spawn_deacon(c, Vector2(0, 0), 4, 2.0, 1.5)
	var info: Dictionary = c.enemy_info(id)
	check(is_equal_approx(info["max_hp"], float(d["hp"]) * 2.0) and is_equal_approx(info["damage"], float(d["damage"]) * 1.5) and info["radius"] == float(d["radius"]) and info["level"] == 4,
		"deacon: hp, damage, radius and level from the def and the spawn")
	var spd := float(info["speed"])
	check(spd >= float(d["speed"]) * 0.92 - 1e-6 and spd <= float(d["speed"]) * 1.08 + 1e-6, "deacon: speed %.2f within the +-8%% roll of %.1f" % [spd, float(d["speed"])])
	silence(c, id)
	var log := []
	# Walking in: full speed, until the target is band_far away.
	var xs := []
	for i in 400:
		run(c, 1, log)
		var p: Vector2 = c.enemy_info(id)["pos"]
		xs.append(p.x)
		if Vector2(12, 0).distance_to(p) <= band_far and i > 10:
			break
	var moving := 0
	var step_ok := true
	for i in range(40, mini(100, xs.size() - 1)):
		step_ok = step_ok and absf((xs[i + 1] - xs[i]) - spd * DT) < 2e-4
		moving += 1
	check(moving > 20 and step_ok, "deacon: walks in at full speed (%.2f m/s) while the target is farther than %.1f m" % [spd, band_far])
	run(c, 60, log)
	var rest: Vector2 = c.enemy_info(id)["pos"]
	var dist := Vector2(12, 0).distance_to(rest)
	check(dist <= band_far + 1e-3 and dist > band_far - spd * DT * 1.5, "deacon: stops %.2f m from the target (%.1f - one step)" % [dist, band_far])
	run(c, 60, log)
	check(Vector2(c.enemy_info(id)["pos"]).distance_to(rest) < 1e-4, "deacon: stands still between %.0f and %.1f m" % [near, band_far])
	var yaw := float(c.enemy_info(id)["yaw"])
	check(absf(angle_difference(yaw, atan2(12.0 - rest.x, 0.0 - rest.y))) < 0.02, "deacon: and faces the target")
	check(c.enemy_info(id)["state"] == CHASE and of(log, EV_ATTACK, id).is_empty(), "deacon: silenced, it never swings")
	# Backing off: the hero walks in to 2 m; it retreats at BACK_OFF_SPEED x its speed until 4 m, and no farther.
	c.set_external(h, Vector2(rest.x + 2.0, rest.y), true)
	var from := Vector2(c.enemy_info(id)["pos"]).x
	run(c, 1, log)
	var x1 := Vector2(c.enemy_info(id)["pos"]).x
	check(absf((from - x1) - spd * float(K["BACK_OFF_SPEED"]) * DT) < 2e-4, "deacon: backs off at %.1f x its speed (%.4f m a tick)" % [float(K["BACK_OFF_SPEED"]), from - x1])
	run(c, 200, log)
	var back := Vector2(c.enemy_info(id)["pos"])
	var d2 := back.distance_to(Vector2(rest.x + 2.0, rest.y))
	check(d2 >= near - 1e-3 and d2 < near + spd * float(K["BACK_OFF_SPEED"]) * DT * 1.5, "deacon: stops backing off at %.2f m (%.1f m)" % [d2, near])
	var again := Vector2(c.enemy_info(id)["pos"])
	run(c, 30, log)
	check(Vector2(c.enemy_info(id)["pos"]).distance_to(again) < 1e-4, "deacon: and stands there")


# ------------------------------------------------------------------------------------------------------------------ the deacon: the curse

## The curse is the plain blow: when the cooldown is up and the target is within attackRange (6 m) it winds up for windupMs (telegraph "curse" at the
## target) and one blow of the def's damage lands on the target if it is within attackRange x STRIKE_REACH_MULT + STRIKE_REACH_PAD of the body at that moment.
func deacon_curse() -> void:
	var d := def("deacon")
	var range_ := float(d["attackRange"])
	var windup := float(d["windupMs"]) / 1000.0
	var reach := range_ * float(K["STRIKE_REACH_MULT"]) + float(K["STRIKE_REACH_PAD"])
	var c := make(41)
	var h := hero(c, Vector2(5, 0))
	var id := spawn_deacon(c, Vector2(0, 0))
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var log := []
	run(c, 600, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_CURSE)
	var attack := of(log, EV_ATTACK, id)
	check(tell.size() >= 1 and attack.size() >= 1, "curse: a curse telegraph and a swing")
	if tell.is_empty():
		return
	var k0 := int(tell[0]["tick"])
	check(of(log, EV_TELEGRAPH, id, TELL_RAISE).is_empty() and of(log, EV_CUE, id).is_empty(), "curse: no corpse and no ally, so nothing but the curse")
	check(k0 == to_zero(cd0), "curse: the first swing comes on the tick the cooldown is up, the target in range (tick %d)" % k0)
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[2], 5.0) and is_equal_approx(f[3], 0.0) and f[4] == 0.0 and is_equal_approx(f[5], windup), "curse: the telegraph is aimed at the target and lasts the wind-up (%.2f s)" % f[5])
	check(attack[0]["ints"][0] == 0 and is_equal_approx(attack[0]["floats"][2], windup), "curse: the swing is the plain blow")
	var ks := k0 + to_reach(windup)
	var hits := of(log, EV_HIT, id)
	check(hits.size() >= 1 and int(hits[0]["tick"]) == ks and hits[0]["ints"][0] == h and hits[0]["ints"][1] == 0 and hits[0]["floats"][0] == float(d["damage"]),
		"curse: the blow lands %d ticks (%.2f s) later for %d, melee, on the target" % [ks - k0, windup, int(d["damage"])])
	var cooldown := float(d["cooldownMs"]) / 1000.0
	check(tell.size() >= 2 and int(tell[1]["tick"]) == ks + to_zero(cooldown), "curse: the next one a cooldown (%.1f s) after the blow (tick %d)" % [cooldown, int(tell[1]["tick"]) if tell.size() > 1 else -1])
	# The reach is measured at the blow, from the body: the target who steps back to the edge of it is still cursed, one who is past it is not.
	for trial in [[reach - 0.2, true], [reach + 0.2, false]]:
		var e := make(42)
		var hh := hero(e, Vector2(5, 0))
		var did := spawn_deacon(e, Vector2(0, 0))
		var lg := []
		for i in 600:
			run(e, 1, lg)
			if not of(lg, EV_TELEGRAPH, did, TELL_CURSE).is_empty():
				break
		var p: Vector2 = e.enemy_info(did)["pos"]
		e.set_external(hh, Vector2(p.x + float(trial[0]), p.y), true)
		var rest := []
		run(e, to_reach(windup) + 2, rest)
		var got := of(rest, EV_HIT, did)
		check(got.size() == (1 if trial[1] else 0), "curse: a target %.2f m away at the blow is %s (the reach is %.2f m)" % [float(trial[0]), "hit" if trial[1] else "missed", reach])


# ------------------------------------------------------------------------------------------------------------------ the deacon: raise

## RAISE: with the cooldown up, a corpse within CORPSE_RANGE (any area) is channelled for windupMs (telegraph "raise": from the deacon to the corpse); at the
## end the corpse is consumed ("raised") and a Risen stands on it, rising, with the deacon's level and hp / damage multipliers (the wave director's `_risen_for`).
func deacon_raise() -> void:
	var d := def("deacon")
	var rs := def("risen")
	var windup := float(d["windupMs"]) / 1000.0
	var c := make(51)
	hero(c, FAR)
	var id := spawn_deacon(c, Vector2(0, 0), 7, 2.5, 1.75)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var far := corpse(c, Vector2(0, -6.0))
	var near := corpse(c, Vector2(3, 4))      # 5 m: the nearest, and in another area than the deacon's
	var log := []
	var k0 := to_zero(cd0)
	run_to(c, k0 - 1, log)
	check(of(log, EV_STATE, id).is_empty(), "raise: nothing happens while the cooldown runs (%d ticks)" % (k0 - 1))
	run_to(c, k0, log)
	check(first_tick(state_edges(log, id, ATTACK)) == k0, "raise: the channel starts on the tick the cooldown is up (tick %d), with no target" % k0)
	var tell := of(log, EV_TELEGRAPH, id, TELL_RAISE)
	check(tell.size() == 1 and of(log, EV_TELEGRAPH, id, TELL_CURSE).is_empty(), "raise: a raise telegraph, not a curse")
	if tell.is_empty():
		return
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[0], 0.0) and is_equal_approx(f[1], 0.0) and is_equal_approx(f[2], 3.0) and is_equal_approx(f[3], 4.0) and f[4] == 0.0 and is_equal_approx(f[5], windup),
		"raise: from the deacon to the nearest corpse (3, 4), for the %.1f s channel" % windup)
	var attack := of(log, EV_ATTACK, id)
	check(attack.size() == 1 and is_equal_approx(attack[0]["floats"][0], 3.0) and is_equal_approx(attack[0]["floats"][1], 4.0) and is_equal_approx(attack[0]["floats"][2], windup), "raise: and the swing is aimed at the corpse")
	var ks := k0 + to_reach(windup)
	run_to(c, ks - 1, log)
	check(c.corpse_count() == 2 and c.enemy_count() == 1, "raise: during the channel the corpse is still there and nothing has risen")
	run_to(c, ks, log)
	var consumed := of(log, EV_CORPSE_CONSUMED)
	var gone := of(log, EV_CORPSE_GONE)
	check(consumed.size() == 1 and consumed[0]["id"] == near and consumed[0]["ints"][0] == 1 and consumed[0]["ints"][1] == CR_RAISED and int(consumed[0]["tick"]) == ks, "raise: the corpse is consumed, reason raised, at the end of the channel (tick %d)" % ks)
	check(gone.size() == 1 and gone[0]["id"] == near and gone[0]["ints"][0] == CR_RAISED and c.reason_name(CR_RAISED) == "raised" and c.corpse_count() == 1, "raise: and it is gone; the far corpse is left")
	var sp := of(log, EV_SPAWNED)
	check(sp.size() == 2 and c.def_name(sp[1]["ints"][0]) == "risen" and int(sp[1]["tick"]) == ks, "raise: a Risen is spawned on that tick")
	if sp.size() < 2:
		return
	var rid: int = sp[1]["id"]
	var ri: Dictionary = c.enemy_info(rid)
	check(sp[1]["ints"][1] == 7 and not bool(ri["elite"]) and ri["level"] == 7 and c.area_name(sp[1]["ints"][3]) == "ossuary", "raise: at the deacon's level (7), not elite, in its area")
	check(is_equal_approx(ri["max_hp"], float(rs["hp"]) * 2.5) and is_equal_approx(ri["damage"], float(rs["damage"]) * 1.75) and is_equal_approx(sp[1]["floats"][2], float(rs["hp"]) * 2.5),
		"raise: with its multipliers (hp x2.5 = %.0f, damage x1.75 = %.1f)" % [ri["max_hp"], ri["damage"]])
	check(is_equal_approx(sp[1]["floats"][0], 3.0) and is_equal_approx(sp[1]["floats"][1], 4.0) and ri["state"] == RISING, "raise: where the corpse lay, rising")
	check(c.enemy_count() == 2 and Array(c.enemy_ids()) == [id, rid], "raise: and it is in the table at the end of that tick, after the deacon")
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), float(d["cooldownMs"]) / 1000.0), "raise: the cooldown is the def's %.1f s from the end of the channel" % (float(d["cooldownMs"]) / 1000.0))
	# The swing ends 0.3 s later (idle: no target); the next raise comes one cooldown after the first, for the next corpse (6 m away).
	run_to(c, ks + to_reach(0.3), log)
	check(c.enemy_info(id)["state"] == IDLE, "raise: the deacon is idle again after the 0.3 s recovery")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	run_to(c, ks + to_zero(cooldown), log)
	var second := of(log, EV_TELEGRAPH, id, TELL_RAISE)
	check(second.size() == 2 and int(second[1]["tick"]) == ks + to_zero(cooldown) and is_equal_approx(second[1]["floats"][3], -6.0), "raise: the next one a cooldown later, for the other corpse (tick %d)" % (ks + to_zero(cooldown)))
	check(far > 0 and c.corpse_count() == 1, "raise: (the far corpse is still there, the one now in the channel)")


## The edges of RAISE: the range (8 m, inclusive, the corpse's own distance), a corpse gone in the channel, and a stun that cancels it.
func deacon_raise_edges() -> void:
	var d := def("deacon")
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var rng_ := float(K["CORPSE_RANGE"])
	# Past the range nothing is raised, however long it waits; a corpse at exactly the range is.
	var c := make(52)
	hero(c, FAR)
	var id := spawn_deacon(c, Vector2(0, 0))
	corpse(c, Vector2(rng_ + 0.01, 0))
	var log := []
	run(c, 600, log)
	check(of(log, EV_STATE, id).is_empty(), "raise: a corpse %.2f m away is out of reach (%.0f m) for 10 s" % [rng_ + 0.01, rng_])
	corpse(c, Vector2(0, -rng_))
	run(c, 20, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_RAISE)
	check(tell.size() == 1 and is_equal_approx(tell[0]["floats"][3], -rng_), "raise: and one exactly %.0f m away is taken, at the next scan" % rng_)
	# The corpse goes in the channel: nothing rises, the cooldown is spent all the same.
	var e := make(53)
	hero(e, FAR)
	var did := spawn_deacon(e, Vector2(0, 0))
	var cid := corpse(e, Vector2(2, 2))
	var lg := []
	for i in 400:
		run(e, 1, lg)
		if not of(lg, EV_TELEGRAPH, did, TELL_RAISE).is_empty():
			break
	var k0 := first_tick(of(lg, EV_TELEGRAPH, did, TELL_RAISE))
	run_to(e, k0 + 30, lg)
	check(e.corpse_consume(cid, 0, "consumed"), "raise: a rite spends the corpse in the channel")
	var spawned := of(lg, EV_SPAWNED).size()
	run_to(e, k0 + to_reach(windup) + 3, lg)
	check(of(lg, EV_SPAWNED).size() == spawned and e.enemy_count() == 1, "raise: the channel ends and nothing rises")
	check(of(lg, EV_CORPSE_CONSUMED).size() == 1 and of(lg, EV_CORPSE_CONSUMED)[0]["ints"][1] != CR_RAISED, "raise: the only consume is the rite's")
	var left := cooldown
	for i in 3:
		left -= DT
	check(float(e.enemy_info(did)["attack_cd"]) == left, "raise: and the cooldown starts anyway (%.2f s left three ticks after)" % float(e.enemy_info(did)["attack_cd"]))
	# A stun mid-channel cancels it (the corpse stays); the same corpse is raised when the deacon is up again.
	var s := make(54)
	hero(s, FAR)
	var sid := spawn_deacon(s, Vector2(0, 0))
	var scorpse := corpse(s, Vector2(2, 2))
	var sl := []
	for i in 400:
		run(s, 1, sl)
		if not of(sl, EV_TELEGRAPH, sid, TELL_RAISE).is_empty():
			break
	var s0 := first_tick(of(sl, EV_TELEGRAPH, sid, TELL_RAISE))
	run_to(s, s0 + 30, sl)
	s.stun(sid, 1.0)
	drain(s, sl)
	# The scans go on every SCAN_S through the channel and the flinch (they spend their turn on a busy body), so the raise starts again at the first scan after the flinch.
	var n := to_zero(float(K["SCAN_S"]))
	var flinch_end := s0 + 30 + to_reach(1.0)
	var again_at := s0 + n * int(ceil(float(flinch_end - s0) / float(n)))
	run_to(s, again_at + 1, sl)
	check(s.corpse_count() == 1 and s.enemy_count() == 1 and of(sl, EV_CORPSE_CONSUMED).is_empty(), "raise: a stun in the channel cancels it: the corpse stays, nothing rises")
	var again := of(sl, EV_TELEGRAPH, sid, TELL_RAISE)
	check(again.size() == 2 and int(again[1]["tick"]) == again_at, "raise: and it starts again at the first scan after the flinch (tick %d; the flinch ends at %d, the scans are %d ticks apart from %d)" % [again_at, flinch_end, n, s0])
	if again.size() == 2:
		run_to(s, again_at + to_reach(windup), sl)
		check(of(sl, EV_CORPSE_CONSUMED).size() == 1 and of(sl, EV_CORPSE_CONSUMED)[0]["id"] == scorpse and s.enemy_count() == 2, "raise: and the second channel raises it")


## Two deacons channel the same corpse: the field's consume is atomic, so one Risen rises and the other channel ends with nothing (its cooldown spent).
func deacon_two_on_one_corpse() -> void:
	var windup := float(def("deacon")["windupMs"]) / 1000.0
	var c := make(55)
	hero(c, FAR)
	var a := spawn_deacon(c, Vector2(-1, 0), 2, 1.0, 1.0)
	var b := spawn_deacon(c, Vector2(1, 0), 2, 1.0, 1.0)
	corpse(c, Vector2(0, 3))
	var log := []
	run(c, to_zero(1.5) + to_reach(windup) * 2 + 40, log)
	var tells := of(log, EV_TELEGRAPH, 0, TELL_RAISE)
	var first_two := tells.filter(func(e: Dictionary) -> bool: return int(e["tick"]) < to_zero(1.5) + to_reach(windup))
	check(first_two.size() == 2 and first_two[0]["id"] != first_two[1]["id"], "two deacons: both start a channel on the one corpse (%d)" % first_two.size())
	var risen := of(log, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return c.def_name(e["ints"][0]) == "risen")
	check(risen.size() == 1 and of(log, EV_CORPSE_CONSUMED).size() == 1, "two deacons: one corpse consumed, one Risen (%d)" % risen.size())
	check(c.enemy_info(a)["state"] != ATTACK and c.enemy_info(b)["state"] != ATTACK and float(c.enemy_info(a)["attack_cd"]) > 0.0 and float(c.enemy_info(b)["attack_cd"]) > 0.0,
		"two deacons: both are done, both on their cooldown (the one that lost the corpse spent it too)")


# ------------------------------------------------------------------------------------------------------------------ the deacon: Sanctify

## SANCTIFY: the most wounded living ally of another kind within SANCTIFIED.range that is not blessed gets `sanctified` (damage taken x damageTakenMult for
## durationS); the deacon's cooldown becomes cooldown x cooldownMult; the cue names the ally. Deacons and the fallen are not allies, nor the unhurt.
func deacon_sanctify() -> void:
	var d := def("deacon")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var sanct_cd := cooldown * float(S["cooldownMult"])
	var c := make(61)
	hero(c, FAR)
	var id := spawn_deacon(c, Vector2(0, 0))
	var unhurt: int = c.spawn_enemy("robber", Vector2(1, 1), 1, 1.0, 1.0, false, "ossuary", false)
	var mild: int = c.spawn_enemy("robber", Vector2(-2, 1), 1, 1.0, 1.0, false, "ossuary", false)
	var most: int = c.spawn_enemy("robber", Vector2(3, -2), 1, 1.0, 1.0, false, "ossuary", false)
	var beyond: int = c.spawn_enemy("robber", Vector2(float(S["range"]) + 0.5, 0), 1, 1.0, 1.0, false, "ossuary", false)
	var other: int = spawn_deacon(c, Vector2(0, -3))
	var golem: int = c.spawn_enemy("golem", Vector2(-3, -3), 1, 1.0, 1.0, false, "ossuary", false)
	wound(c, mild, 0.4)       # 60 % left
	wound(c, most, 0.7)       # 30 %
	wound(c, beyond, 0.9)     # the most wounded of all, but out of range
	wound(c, other, 0.85)     # a deacon: never an ally
	wound(c, golem, 0.5)      # 50 %: another kind, an ally
	silence(c, other)         # (so that it does not bless, raise or curse in this scene)
	var k0 := to_zero(float(c.enemy_info(id)["attack_cd"]))
	var log := []
	drain(c, log)
	run_to(c, k0 - 1, log)
	check(of(log, EV_CUE, id).is_empty(), "sanctify: nothing before the cooldown is up")
	run_to(c, k0, log)
	var cue := of(log, EV_CUE, id, CUE_SANCTIFY)
	check(cue.size() == 1 and int(cue[0]["tick"]) == k0, "sanctify: the cue on the tick the cooldown is up (tick %d)" % k0)
	if cue.is_empty():
		return
	var p: Vector2 = c.enemy_info(most)["pos"]
	check(is_equal_approx(cue[0]["floats"][0], p.x) and is_equal_approx(cue[0]["floats"][1], p.y), "sanctify: it names the most wounded ally in range (not the unhurt, the far, the other deacon, or the milder wounds)")
	check(c.status_stacks(most, "sanctified") == 1.0 and [mild, golem, beyond, unhurt, other].all(func(i: int) -> bool: return c.status_stacks(i, "sanctified") == 0.0), "sanctify: and only it is blessed")
	check(is_equal_approx(float(c.enemy_info(most)["taken_mult"]), float(S["damageTakenMult"])), "sanctify: damage taken x%.1f" % float(S["damageTakenMult"]))
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), sanct_cd), "sanctify: the deacon's cooldown is %.1f x %.1f = %.2f s" % [cooldown, float(S["cooldownMult"]), sanct_cd])
	check(c.enemy_info(id)["state"] == IDLE and of(log, EV_ATTACK, id).is_empty(), "sanctify: it is no swing: the deacon does not leave its state")
	# The next blessing a cooldown later goes to the next most wounded that is not blessed (the golem at 50 %); the first is still blessed.
	var n := to_zero(sanct_cd)
	run_to(c, k0 + n, log)
	var cue2 := of(log, EV_CUE, id, CUE_SANCTIFY)
	var pg: Vector2 = c.enemy_info(golem)["pos"]
	check(cue2.size() == 2 and int(cue2[1]["tick"]) == k0 + n, "sanctify: the next one a cooldown (%.2f s, %d ticks) later" % [sanct_cd, n])
	check(cue2.size() == 2 and is_equal_approx(cue2[1]["floats"][0], pg.x) and c.status_stacks(golem, "sanctified") == 1.0 and c.status_stacks(most, "sanctified") == 1.0 and c.status_stacks(mild, "sanctified") == 0.0,
		"sanctify: it goes to the next most wounded unblessed body, whatever its kind")
	# The blessing lasts durationS (the status steps in 0.1 s) and is then free to be given again.
	run_to(c, k0 + 2 * n, log)
	var cue3 := of(log, EV_CUE, id, CUE_SANCTIFY)
	var gone := of(log, EV_STATUS_EXPIRED, most)
	var want := int(float(S["durationS"]) / DT)
	var after := int(gone[0]["tick"]) - k0 if not gone.is_empty() else -1
	check(gone.size() == 1 and after >= want - 8 and after <= want + 14, "sanctify: it ends %d ticks after it was given (%.1f s = %d ticks, the status steps every 0.1 s)" % [after, float(S["durationS"]), want])
	check(cue3.size() == 3 and is_equal_approx(cue3[2]["floats"][0], p.x) and c.status_stacks(most, "sanctified") == 1.0, "sanctify: so the third goes to the first again, the most wounded unblessed")
	# A blow on a blessed body costs damageTakenMult of itself.
	var before := float(c.enemy_info(most)["hp"])
	c.damage(most, 10.0, 0, false)
	check(is_equal_approx(before - float(c.enemy_info(most)["hp"]), 10.0 * float(S["damageTakenMult"])), "sanctify: a blow of 10 costs %.0f while blessed" % (10.0 * float(S["damageTakenMult"])))



## Sanctify's edges: the range (6 m, from centre to centre), the health fraction (wounded below 0.999), ties go to the first in spawn order, the fallen are not
## allies, an elite deacon's cooldown is the def's, not its quicker one.
func deacon_sanctify_edges() -> void:
	var d := def("deacon")
	var sanct_cd := float(d["cooldownMs"]) / 1000.0 * float(S["cooldownMult"])
	var rng_ := float(S["range"])
	var c := make(62)
	hero(c, FAR)
	var id := spawn_deacon(c, Vector2(0, 0))
	var out: int = c.spawn_enemy("robber", Vector2(rng_ + 0.1, 0), 1, 1.0, 1.0, false, "ossuary", false)
	var scratch: int = c.spawn_enemy("robber", Vector2(0, 2), 1, 1.0, 1.0, false, "ossuary", false)
	wound(c, out, 0.5)
	c.damage(scratch, 0.04, 0, false)   # 99.94 % of 68: not wounded enough (the threshold is below 0.999)
	var log := []
	run(c, 600, log)
	check(of(log, EV_CUE, id).is_empty(), "sanctify: nothing for 10 s: one ally is %.1f m away (the range is %.0f m), the other lost 0.06%% of its health" % [rng_ + 0.1, rng_])
	c.damage(scratch, 0.06, 0, false)   # 99.85 %
	run(c, 20, log)
	var cue := of(log, EV_CUE, id, CUE_SANCTIFY)
	check(cue.size() == 1 and c.status_stacks(scratch, "sanctified") == 1.0, "sanctify: a body just under the threshold is blessed at the next scan")
	# Ties: two allies on the same fraction, the first spawned is blessed; the dead are skipped.
	var e := make(63)
	hero(e, FAR)
	var eid := spawn_deacon(e, Vector2(0, 0))
	var dead: int = e.spawn_enemy("robber", Vector2(1, 0), 1, 1.0, 1.0, false, "ossuary", false)
	var t1: int = e.spawn_enemy("robber", Vector2(-1, 0), 1, 1.0, 1.0, false, "ossuary", false)
	var t2: int = e.spawn_enemy("robber", Vector2(0, 1), 1, 1.0, 1.0, false, "ossuary", false)
	wound(e, t1, 0.5)
	wound(e, t2, 0.5)
	e.damage(dead, 1.0e6, 0, false)
	for cid in e.corpse_ids():
		e.corpse_consume(cid, 0, "consumed")    # its corpse would be raised first
	var lg := []
	drain(e, lg)
	run(e, 700, lg)
	var cues := of(lg, EV_CUE, eid, CUE_SANCTIFY)
	check(not cues.is_empty() and e.status_stacks(t1, "sanctified") == 1.0 and e.status_stacks(dead, "sanctified") == 0.0, "sanctify: the fallen are skipped, and a tie goes to the first in spawn order")
	check(cues.size() >= 2 and e.status_stacks(t2, "sanctified") == 1.0, "sanctify: the second goes to the other")
	# An elite deacon: its own cooldown is x0.8 (and the wind-up x0.85), but Sanctify's is the def's cooldown x the factor.
	var f := make(64)
	hero(f, FAR)
	var elite := spawn_deacon(f, Vector2(0, 0), 1, 1.0, 1.0, true)
	var ally: int = f.spawn_enemy("robber", Vector2(2, 0), 1, 1.0, 1.0, false, "ossuary", false)
	wound(f, ally, 0.5)
	var k0 := to_zero(float(f.enemy_info(elite)["attack_cd"]))
	var fl := []
	run_to(f, k0, fl)
	check(of(fl, EV_CUE, elite, CUE_SANCTIFY).size() == 1 and is_equal_approx(float(f.enemy_info(elite)["attack_cd"]), sanct_cd), "sanctify: an elite deacon's cooldown is the def's x factor = %.2f s, not its quicker one" % sanct_cd)


# ------------------------------------------------------------------------------------------------------------------ the deacon: the order, the cadence

## The order is the script's: the curse comes from the state, so a target in range is cursed before anything else; a deacon whose target is out of range
## (or that has none) raises first, and Sanctify comes next, once the raise's cooldown is spent.
func deacon_order() -> void:
	var d := def("deacon")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var windup := float(d["windupMs"]) / 1000.0
	# A target in curse range: the curse, whatever else could be done.
	var c := make(71)
	hero(c, Vector2(5, 0))
	var id := spawn_deacon(c, Vector2(0, 0))
	corpse(c, Vector2(0, 3))
	var ally: int = c.spawn_enemy("robber", Vector2(-2, 0), 1, 1.0, 1.0, false, "ossuary", false)
	wound(c, ally, 0.5)
	var log := []
	for i in 600:
		run(c, 1, log)
		if not state_edges(log, id, ATTACK).is_empty():
			break
	check(of(log, EV_TELEGRAPH, id, TELL_CURSE).size() == 1 and of(log, EV_TELEGRAPH, id, TELL_RAISE).is_empty() and c.corpse_count() == 1 and of(log, EV_CUE, id).is_empty(),
		"order: a target in range is cursed before a corpse is raised or an ally blessed")
	# A target out of curse range (12 m: it walks in, and is farther than 6 m for the first seconds): the raise comes first, even with an ally to bless.
	var e := make(72)
	hero(e, Vector2(12, 0))
	var eid := spawn_deacon(e, Vector2(0, 0))
	corpse(e, Vector2(0, 3))
	var eally: int = e.spawn_enemy("robber", Vector2(-2, 0), 1, 1.0, 1.0, false, "ossuary", false)
	wound(e, eally, 0.5)
	var k0 := to_zero(float(e.enemy_info(eid)["attack_cd"]))
	var lg := []
	run_to(e, k0, lg)
	check(first_tick(of(lg, EV_TELEGRAPH, eid, TELL_RAISE)) == k0 and of(lg, EV_CUE, eid).is_empty() and of(lg, EV_TELEGRAPH, eid, TELL_CURSE).is_empty(),
		"order: with the target out of curse range it raises first, even with an ally to bless (tick %d)" % k0)
	# No target at all: the raise, then the blessing one cooldown after it (the ally stunned in place).
	var f := make(73)
	hero(f, FAR)
	var fid := spawn_deacon(f, Vector2(0, 0))
	corpse(f, Vector2(0, 3))
	var fally: int = f.spawn_enemy("robber", Vector2(-2, 0), 1, 1.0, 1.0, false, "ossuary", false)
	wound(f, fally, 0.5)
	var j0 := to_zero(float(f.enemy_info(fid)["attack_cd"]))
	var fl := []
	run_to(f, j0, fl)
	check(first_tick(of(fl, EV_TELEGRAPH, fid, TELL_RAISE)) == j0 and of(fl, EV_CUE, fid).is_empty(), "order: with no target either: the raise first (tick %d)" % j0)
	var ks := j0 + to_reach(windup)
	var then := ks + to_zero(cooldown)
	run_to(f, then - 1, fl)
	check(of(fl, EV_CUE, fid).is_empty(), "order: the blessing waits for the cooldown the raise set")
	run_to(f, then, fl)
	var cue := of(fl, EV_CUE, fid, CUE_SANCTIFY)
	check(cue.size() == 1 and int(cue[0]["tick"]) == then and f.status_stacks(fally, "sanctified") == 1.0, "order: and then blesses the ally (tick %d)" % then)



## The scan runs every SCAN_S while the cooldown is up (a scan that finds nothing spends its turn): a corpse laid between two scans is raised at the next one.
func deacon_scan_cadence() -> void:
	var c := make(81)
	hero(c, FAR)
	var id := spawn_deacon(c, Vector2(0, 0))
	var k0 := to_zero(float(c.enemy_info(id)["attack_cd"]))
	var log := []
	run_to(c, k0 + 3, log)          # the scan at k0 found nothing
	corpse(c, Vector2(2, 0))
	var n := to_zero(float(K["SCAN_S"]))
	run_to(c, k0 + n - 1, log)
	check(of(log, EV_STATE, id).is_empty(), "cadence: a corpse laid 3 ticks after a scan is not seen before the next scan")
	run_to(c, k0 + n, log)
	check(first_tick(state_edges(log, id, ATTACK)) == k0 + n, "cadence: it is raised %d ticks (%.2f s) after that scan (tick %d)" % [n, float(K["SCAN_S"]), k0 + n])
	# Several scans later, the same.
	var e := make(82)
	hero(e, FAR)
	var eid := spawn_deacon(e, Vector2(0, 0))
	var j0 := to_zero(float(e.enemy_info(eid)["attack_cd"]))
	var lg := []
	run_to(e, j0 + 4 * n + 5, lg)
	corpse(e, Vector2(2, 0))
	run_to(e, j0 + 5 * n, lg)
	check(first_tick(state_edges(lg, eid, ATTACK)) == j0 + 5 * n, "cadence: scans keep their period (%d ticks) while nothing is found" % n)


## Silence stops all three (a silenced scan spends its turn; the curse is not started), and does not cancel a swing already begun. Stun cancels the swing.
func deacon_silence_and_stun() -> void:
	var d := def("deacon")
	var windup := float(d["windupMs"]) / 1000.0
	var n := to_zero(float(K["SCAN_S"]))
	# Silenced: no curse in range, no raise, no blessing for 10 s; unsilenced, the curse is at once.
	var c := make(91)
	var h := hero(c, Vector2(5, 0))
	var id := spawn_deacon(c, Vector2(0, 0))
	corpse(c, Vector2(0, 3))
	var ally: int = c.spawn_enemy("robber", Vector2(-2, 0), 1, 1.0, 1.0, false, "ossuary", false)
	wound(c, ally, 0.5)
	silence(c, id)
	var log := []
	run(c, 600, log)
	check(state_edges(log, id, ATTACK).is_empty() and of(log, EV_CUE, id).is_empty() and c.corpse_count() == 1, "silence: no curse, no raise, no blessing for 10 s")
	check(c.remove_status(id, "silence"), "silence: it lifts")
	run(c, 1, log)
	var t0 := tick
	check(first_tick(state_edges(log, id, ATTACK)) == t0 and of(log, EV_TELEGRAPH, id, TELL_CURSE).size() == 1, "silence: the curse starts on the next tick (the cooldown was up)")
	# A swing begun before the silence lands all the same.
	silence(c, id)
	var ks := t0 + to_reach(windup)
	run_to(c, ks, log)
	var hits := of(log, EV_HIT, id)
	check(hits.size() == 1 and hits[0]["ints"][0] == h and int(hits[0]["tick"]) == ks, "silence: a curse already winding up lands on tick %d" % ks)
	# Without a target: the silenced scans spent their turns, so the first scan after the silence is the next one on the old rhythm.
	var e := make(92)
	hero(e, FAR)
	var eid := spawn_deacon(e, Vector2(0, 0))
	corpse(e, Vector2(0, 3))
	silence(e, eid)
	var k0 := to_zero(float(e.enemy_info(eid)["attack_cd"]))
	var lg := []
	run_to(e, k0 + 3 * n + 4, lg)
	check(state_edges(lg, eid, ATTACK).is_empty(), "silence: a silenced deacon with a corpse beside it does nothing")
	e.remove_status(eid, "silence")
	run_to(e, k0 + 4 * n - 1, lg)
	check(state_edges(lg, eid, ATTACK).is_empty(), "silence: freed between two scans it waits for the next")
	run_to(e, k0 + 4 * n, lg)
	check(first_tick(state_edges(lg, eid, ATTACK)) == k0 + 4 * n, "silence: and acts at the next scan (tick %d: the scans are %d ticks apart from tick %d)" % [k0 + 4 * n, n, k0])
	# Stun (the flinch): nothing starts in it, and the cooldown does not run in it.
	var s := make(93)
	hero(s, FAR)
	var sid := spawn_deacon(s, Vector2(0, 0))
	corpse(s, Vector2(0, 3))
	var cd0 := float(s.enemy_info(sid)["attack_cd"])
	s.stun(sid, 2.0)
	var sl := []
	drain(s, sl)
	run(s, to_reach(2.0) - 1, sl)
	check(s.enemy_info(sid)["state"] == HURT and state_edges(sl, sid, ATTACK).is_empty() and float(s.enemy_info(sid)["attack_cd"]) == cd0, "stun: a flinching deacon starts nothing, and its cooldown stands still (%.2f s)" % cd0)
	run_to(s, to_reach(2.0) + to_zero(cd0), sl)
	check(first_tick(state_edges(sl, sid, ATTACK)) == to_reach(2.0) + to_zero(cd0), "stun: after the flinch the cooldown runs and the raise starts the tick it is up (tick %d)" % (to_reach(2.0) + to_zero(cd0)))



## An elite deacon: the wind-up is x0.85, the cooldown x0.8, and the Risen it raises is a plain one with the multipliers of the spawn (not the elite's health).
func deacon_elite() -> void:
	var d := def("deacon")
	var rs := def("risen")
	var windup := float(d["windupMs"]) / 1000.0 * ELITE_WINDUP
	var cooldown := float(d["cooldownMs"]) / 1000.0 * ELITE_COOLDOWN
	var c := make(101)
	hero(c, FAR)
	var id := spawn_deacon(c, Vector2(0, 0), 5, 3.0, 2.0, true)
	corpse(c, Vector2(2, 2))
	var k0 := to_zero(float(c.enemy_info(id)["attack_cd"]))
	var log := []
	run_to(c, k0, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_RAISE)
	check(tell.size() == 1 and is_equal_approx(tell[0]["floats"][5], windup), "elite: the channel is %.3f s (x%.2f)" % [windup, ELITE_WINDUP])
	var ks := k0 + to_reach(windup)
	run_to(c, ks, log)
	var sp := of(log, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return c.def_name(e["ints"][0]) == "risen")
	check(sp.size() == 1 and int(sp[0]["tick"]) == ks, "elite: the Risen rises on tick %d" % ks)
	if sp.is_empty():
		return
	var ri: Dictionary = c.enemy_info(sp[0]["id"])
	check(not bool(ri["elite"]) and ri["level"] == 5 and is_equal_approx(ri["max_hp"], float(rs["hp"]) * 3.0) and is_equal_approx(ri["damage"], float(rs["damage"]) * 2.0),
		"elite: the Risen is plain, at level 5, with the spawn's multipliers (hp x3 = %.0f, damage x2 = %.0f), not the elite's" % [ri["max_hp"], ri["damage"]])
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "elite: the cooldown after the raise is %.1f s (x%.1f)" % [cooldown, ELITE_COOLDOWN])


# ------------------------------------------------------------------------------------------------------------------ the wire

## A guest's puppet shows the deacon: its raise and curse telegraphs (derived from the snapshot's ATTACK edge: bit 5 of the record says which), the corpse it
## spent and the Risen it raised (reliable events), Sanctify's cue and the blessing on the body.
func deacon_on_the_wire() -> void:
	var d := def("deacon")
	var windup := float(d["windupMs"]) / 1000.0
	# A raise.
	var host := make(111)
	host.set_replication(true)
	hero(host, FAR)
	var id := spawn_deacon(host, Vector2(0, 0), 3, 2.0, 1.5)
	var cid := corpse(host, Vector2(3, 4))
	var guest := puppet()
	var hl := []
	var gl := []
	var t := join(host, guest, hl, gl)
	var k0 := to_zero(float(host.enemy_info(id)["attack_cd"]))
	t = lockstep(host, guest, hl, gl, t, k0 + to_reach(windup) + 60)
	var ht := of(hl, EV_TELEGRAPH, id, TELL_RAISE)
	var gt := of(gl, EV_TELEGRAPH, id, TELL_RAISE)
	check(ht.size() == 1 and gt.size() == 1 and of(gl, EV_TELEGRAPH, id, TELL_CURSE).is_empty(), "wire: the guest sees the raise telegraph once, and no curse (host %d, guest %d)" % [ht.size(), gt.size()])
	if gt.size() == 1:
		var f: PackedFloat32Array = gt[0]["floats"]
		check(absf(f[2] - 3.0) < 0.02 and absf(f[3] - 4.0) < 0.02 and f[4] == 0.0 and f[5] >= 0.05 and f[5] <= windup + 1e-4, "wire: aimed at the corpse, for what is left of the %.1f s (%.2f s)" % [windup, f[5]])
		check(int(gt[0]["tick"]) - int(ht[0]["tick"]) <= 6, "wire: and within two snapshots of the host's (%d ticks later)" % (int(gt[0]["tick"]) - int(ht[0]["tick"])))
	var consumed := of(gl, EV_CORPSE_CONSUMED, cid)
	var gone := of(gl, EV_CORPSE_GONE, cid)
	check(consumed.size() == 1 and gone.size() == 1 and gone[0]["ints"][0] == CR_RAISED, "wire: the guest sees the corpse consumed, raised")
	var host_risen := of(hl, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return host.def_name(e["ints"][0]) == "risen")
	var guest_risen := of(gl, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return guest.def_name(e["ints"][0]) == "risen")
	check(host_risen.size() == 1 and guest_risen.size() == 1 and guest_risen[0]["id"] == host_risen[0]["id"], "wire: and the Risen, with the host's id")
	if guest_risen.size() == 1:
		var gi: Dictionary = guest.enemy_info(guest_risen[0]["id"])
		check(gi.get("level", 0) == 3 and is_equal_approx(float(gi["max_hp"]), float(host.enemy_info(guest_risen[0]["id"])["max_hp"])), "wire: at the deacon's level, with the host's health")
	# A curse.
	var h2 := make(112)
	h2.set_replication(true)
	hero(h2, Vector2(5, 0))
	var did := spawn_deacon(h2, Vector2(0, 0))
	var g2 := puppet()
	var hl2 := []
	var gl2 := []
	t = join(h2, g2, hl2, gl2)
	lockstep(h2, g2, hl2, gl2, t, to_zero(1.5) + to_reach(windup) + 30)
	var curse_g := of(gl2, EV_TELEGRAPH, did, TELL_CURSE)
	check(curse_g.size() == 1 and of(gl2, EV_TELEGRAPH, did, TELL_RAISE).is_empty() and of(hl2, EV_TELEGRAPH, did, TELL_CURSE).size() == 1, "wire: a curse reaches the guest as a curse (%d)" % curse_g.size())
	if curse_g.size() == 1:
		check(absf(curse_g[0]["floats"][2] - 5.0) < 0.02 and absf(curse_g[0]["floats"][3]) < 0.02, "wire: aimed at the target")
	check(of(hl2, EV_HIT, did).size() == 1 and of(gl2, EV_HIT).is_empty(), "wire: the blow on the hero is the host's alone")
	# Sanctify: the cue, once, and the blessing on the guest's body.
	var h3 := make(113)
	h3.set_replication(true)
	hero(h3, FAR)
	var sid := spawn_deacon(h3, Vector2(0, 0))
	var sally: int = h3.spawn_enemy("robber", Vector2(-2, 0), 1, 1.0, 1.0, false, "ossuary", false)
	wound(h3, sally, 0.5)
	var g3 := puppet()
	var hl3 := []
	var gl3 := []
	t = join(h3, g3, hl3, gl3)
	var j0 := to_zero(float(h3.enemy_info(sid)["attack_cd"]))
	var g3b := puppet()   # a second guest, to be offered a cue of a kind this build does not have
	g3b.apply_reliable(h3.baseline())
	g3b.apply_snapshot(h3.snapshot(t))
	t = lockstep2(h3, g3, g3b, hl3, gl3, t, j0 - 1)
	var refused := false
	while t < j0 + 12:
		t += 1
		h3.step(DT)
		for e in events(h3):
			e["tick"] = t
			hl3.append(e)
		g3.step(DT)
		g3b.step(DT)
		if t % 3 == 0:
			var rel: PackedByteArray = h3.take_reliable()
			if rel.size() > 0:
				var at := cue_byte(rel, sid)
				if at >= 0 and not refused:
					var bad := rel.duplicate()
					bad[at] = 0x28    # cue kind 20 (zigzag 40)
					refused = not g3b.apply_reliable(bad) and "world" in str(g3b.replication_error())
				g3.apply_reliable(rel)
				if not refused:
					g3b.apply_reliable(rel)
			var snap: PackedByteArray = h3.snapshot(t)
			g3.apply_snapshot(snap)
		for e in events(g3):
			e["tick"] = t
			gl3.append(e)
		events(g3b)
	check(refused, "wire: a guest refuses a cue of a kind it does not know (%s)" % g3b.replication_error())
	var cue_h := of(hl3, EV_CUE, sid, CUE_SANCTIFY)
	var cue_g := of(gl3, EV_CUE, sid, CUE_SANCTIFY)
	check(cue_h.size() == 1 and cue_g.size() == 1 and absf(cue_g[0]["floats"][0] - cue_h[0]["floats"][0]) < 1e-4 and absf(cue_g[0]["floats"][1] - cue_h[0]["floats"][1]) < 1e-4, "wire: Sanctify's cue reaches the guest once, at the same place (%d, %d)" % [cue_h.size(), cue_g.size()])
	check(h3.status_stacks(sally, "sanctified") == 1.0 and g3.status_stacks(sally, "sanctified") == 1.0 and is_equal_approx(float(g3.enemy_info(sally)["taken_mult"]), float(h3.enemy_info(sally)["taken_mult"])),
		"wire: the blessed body carries the status on the guest too")
	check(g3.enemy_info(sid).get("def", "") == "deacon" and is_equal_approx(float(g3.enemy_info(sid)["max_hp"]), float(h3.enemy_info(sid)["max_hp"])), "wire: and the deacon on the guest is the deacon")
	# The tables the two sides must share include the new behaviour: a guest that runs the deacon as a plain melee body refuses the host's messages.
	var odd: RefCounted = ClassDB.instantiate("DmCore")
	var changed: Dictionary = content["ENEMIES"].duplicate(true)
	changed["deacon"]["behavior"] = "melee"
	odd.load_enemy_defs(changed)
	odd.load_tuning(content)
	odd.load_status_defs(DmStatusRules.build(DmCoreData.json(godot_dir.path_join("data/content/abilities.json")), statuses, content))
	odd.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	odd.set_puppet(true)
	check(not odd.apply_snapshot(h3.snapshot(900)) and "data" in str(odd.replication_error()), "wire: a guest with the deacon as a melee body refuses the host's snapshot (%s)" % odd.replication_error())


## The index of the cue-kind byte (the int 3, Sanctify, zigzag 6) of body `id`'s cue record in a reliable batch: type 8, the id, one int and three floats, then the int. -1 when there is none.
func cue_byte(batch: PackedByteArray, id: int) -> int:
	for i in range(8, batch.size() - 4):
		if batch[i] == EV_CUE and batch[i + 1] == id and batch[i + 2] == 0x13 and batch[i + 3] == 0x06:
			return i + 3
	return -1


## lockstep for two guests (the second takes the same traffic).
func lockstep2(host: RefCounted, a: RefCounted, b: RefCounted, hl: Array, gl: Array, from_tick: int, to_tick: int) -> int:
	var t := from_tick
	while t < to_tick:
		t += 1
		host.step(DT)
		for e in events(host):
			e["tick"] = t
			hl.append(e)
		a.step(DT)
		b.step(DT)
		if t % 3 == 0:
			var rel: PackedByteArray = host.take_reliable()
			if rel.size() > 0:
				a.apply_reliable(rel)
				b.apply_reliable(rel)
			var snap: PackedByteArray = host.snapshot(t)
			a.apply_snapshot(snap)
			b.apply_snapshot(snap)
		for e in events(a):
			e["tick"] = t
			gl.append(e)
		events(b)
	return t


## The host runs 6 ticks, then the guest takes its first batch and snapshot; returns the tick reached.
func join(host: RefCounted, guest: RefCounted, hl: Array, gl: Array) -> int:
	var t := 0
	while t < 6:
		t += 1
		host.step(DT)
		for e in events(host):
			e["tick"] = t
			hl.append(e)
	var ok: bool = guest.apply_reliable(host.take_reliable()) and guest.apply_snapshot(host.snapshot(t))
	check(ok, "wire: a guest takes the host's first batch and snapshot (%s)" % guest.replication_error())
	for e in events(guest):
		e["tick"] = t
		gl.append(e)
	return t


## Steps the host and the guest as the game does (a batch and a snapshot every 3rd tick), logging both sides' events by tick; returns the tick reached.
func lockstep(host: RefCounted, guest: RefCounted, hl: Array, gl: Array, from_tick: int, to_tick: int) -> int:
	var t := from_tick
	while t < to_tick:
		t += 1
		host.step(DT)
		for e in events(host):
			e["tick"] = t
			hl.append(e)
		guest.step(DT)
		if t % 3 == 0:
			var rel: PackedByteArray = host.take_reliable()
			if rel.size() > 0:
				guest.apply_reliable(rel)
			guest.apply_snapshot(host.snapshot(t))
		for e in events(guest):
			e["tick"] = t
			gl.append(e)
	return t


func puppet() -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	DmCoreData.load_all(c, godot_dir)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_puppet(true)
	return c


# ------------------------------------------------------------------------------------------------------------------ the roster and a replay

## The whole Ossuary roster (its enemy table and its procession themes, lead included) is made by the core, the models are drawn by the crowd, and a seeded
## run replays event for event.
func the_roster_and_a_replay() -> void:
	var areas := DmCoreData.json(godot_dir.path_join("data/content/areas.json"))
	var ids := {}
	for e in areas["AREAS"]["ossuary"]["enemies"]:
		ids[String(e["id"])] = true
	for th in content["WAVE_THEMES"]["ossuary"]:
		for e in th["roster"]:
			ids[String(e["id"])] = true
		if th.get("lead") != null:
			ids[String(th["lead"])] = true
	var missing := []
	for id: String in ids:
		if not DmWaveDirector.runs_on_core(id):
			missing.append(id)
	check(ids.has("deacon") and ids.has("golem") and missing.is_empty(), "roster: every kind of the Ossuary's waves and processions runs on the core (%d kinds, missing %s)" % [ids.size(), str(missing)])
	var looks := DmCoreData.json("res://crowd/crowd_looks.json")
	var drawn := true
	for id: String in ["deacon", "golem"]:
		var slug := String(looks["enemy_model"].get(id, ""))
		drawn = drawn and slug != "" and FileAccess.file_exists("res://assets/slice/models/%s/character.glb" % slug)
	check(drawn and looks["casters"].has("deacon") and not looks["casters"].has("golem"), "roster: the crowd draws them (the deacon's model, the golem's, the deacon as a caster)")
	# A seeded fight of the kinds together replays event for event.
	var logs := []
	for round in 2:
		var c := make(121)
		hero(c, Vector2(0, 0))
		hero(c, Vector2(2, -3))
		spawn_deacon(c, Vector2(9, 3), 4, 1.5, 1.2)
		spawn_deacon(c, Vector2(-10, 4), 4, 1.5, 1.2, true)
		c.spawn_enemy("golem", Vector2(-9, -8), 4, 1.5, 1.2, false, "ossuary", false)
		for i in 6:
			c.spawn_enemy("robber" if i % 2 == 0 else "hound", Vector2(12 - i * 4, 11), 4, 1.5, 1.2, false, "ossuary", false)
		corpse(c, Vector2(5, 5))
		corpse(c, Vector2(-5, 2))
		var rec := PackedInt32Array()
		var recf := PackedFloat32Array()
		for i in 1500:
			c.step(DT)
			var raw: Array = c.take_events()
			rec.append_array(raw[0])
			recf.append_array(raw[1])
			if i == 400:
				for id in c.enemy_ids():
					if c.enemy_info(id)["def"] == "robber":
						c.damage(id, 25.0, 0, false)
		logs.append([rec, recf, c.enemy_count(), c.corpse_count()])
	check(logs[0][0] == logs[1][0] and logs[0][1] == logs[1][1] and logs[0][0].size() > 200, "replay: a seeded fight of 2 deacons, a golem and a crowd replays event for event (%d ints)" % logs[0][0].size())
