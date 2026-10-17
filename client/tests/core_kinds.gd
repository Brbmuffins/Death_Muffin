extends SceneTree
## The kinds the other areas add to the combat core, against today's rules (godot/enemies): so far the Marrow Ossuary's two, the Bone Golem and the
## Crypt Deacon, and the Drowned Nave's five, the Censer Bearer, Lich Acolyte, Belfry Gargoyle, Bell-Sworn Templar and Choir Wraith. Later area groups append their kinds here.
##   - the golem (dm_enemy_hazard.gd, the sac's script): its slam (radius, wind-up, cooldown, damage, the aim fixed at the wind-up's start, who it reaches), its
##     stats and the three corpses it falls into;
##   - the deacon (dm_enemy_deacon.gd, dm_state_cath_support.gd): the keep-away walk, the curse (wind-up, reach at the blow, damage), the raise (the corpse chosen,
##     the 1.5 s channel, the atomic consume, the Risen with the body's level and multipliers, nothing when the corpse is gone, one Risen for two deacons),
##     Sanctify (the most wounded unblessed ally of another kind in range, the status, its 5 s, the cooldown factor, the cue), the order of the three, the scan
##     cadence, silence and stun, an elite deacon;
##   - the wire: a guest's puppet shows the deacon's telegraphs and Sanctify, and the Risen it raised;
##   - the roster: the whole Ossuary roster runs on the core, and a seeded run replays bit for bit.
## The Nave (a section per kind, after the Ossuary's):
##   - the censer (dm_enemy_censer.gd): the one-second pulse, who it reaches (the radius, itself, the rising, not the fallen), the haste (x1.3 feet, x1.25 blows, 1.5 s), its own
##     blows hasted by its own incense, a melee body otherwise;
##   - the acolyte (dm_enemy_clst_acolyte.gd, dm_state_clst_kite.gd): the caster set's walk, the cast gate, the curse (wind-up, the homing reach, kind curse), silence that holds the
##     cast back, and Unbind (a thrall KILLED in range after the acolyte's look, the cue, the delay, the Risen with the acolyte's level and multipliers, the cooldown, the cap of four);
##   - the gargoyle (dm_enemy_gargoyle.gd, dm_state_cath_dive_chase.gd, dm_state_cath_dive.gd): the dive (range window, sight line, the aim fixed at the start, hanging still then the
##     ease-in drop, the blow in the radius, the grounded spell, a stun), the bite inside the window;
##   - the templar (dm_enemy_clst_templar.gd): the shield's arc, who it stops, Fracture, DoT ticks, the glance cue and its rate, a melee body with a resonant corpse;
##   - the wraith (dm_enemy_wraith.gd, DmEnemyCaster): the scream ring at the aim fixed at the wind-up's start, the caster set's walk, no silence check, no corpse;
##   - the wire: a guest sees the dive, the scream, the curse, Unbind's cue and its Risen, the glance and the incense; the roster and a seeded replay of the five.
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
const HK_CURSE := 5
const NAVE := "nave"
const NAVE_KINDS: Array[String] = ["censer", "acolyte", "gargoyle", "templar", "wraith"]
const KITE_PARAMS: Array[float] = [0.5, 1.5, 3.5, 0.8]   ## dm_enemy_clst_caster.gd kite_params(): cast pad, near pad, back-off distance, back-off speed (pinned against the file)
const TELL_SLAM := 1
const TELL_RAISE := 5
const TELL_CURSE := 6
const TELL_SCREAM := 7
const TELL_DIVE := 8
const BLOW_SLAM := 3
const BLOW_CURSE := 4
const BLOW_SCREAM := 5
const BLOW_DIVE := 6
const CUE_SLAM := 0
const CUE_SANCTIFY := 3
const CUE_SHIELD_BLOCK := 4
const CUE_UNBIND := 5
const CUE_SCREAM := 6
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
const SCRIPTS: Array[String] = ["enemies/dm_enemy.gd", "enemies/kinds/dm_enemy_deacon.gd", "enemies/states/dm_state_cath_support.gd", "next/corpses/dm_corpse_field.gd",
	"enemies/kinds/dm_enemy_clst_acolyte.gd", "enemies/kinds/dm_enemy_clst_templar.gd", "enemies/kinds/dm_enemy_wraith.gd", "enemies/states/dm_state_cath_dive_chase.gd",
	"enemies/states/dm_state_attack.gd", "enemies/states/dm_state_rising.gd"]

var fails := 0
var checks := 0
var verbose := false
var godot_dir: String
var content: Dictionary
var statuses: Dictionary
var K: Dictionary        ## the scripts' `const` lines (CORPSE_RANGE, BACK_OFF_DIST, SCAN_S, STRIKE_REACH_MULT, WATCH_S, LOS_S ...)
var KITE: Dictionary     ## dm_state_kite.gd's (the caster set's BACK_OFF_DIST and BACK_OFF_SPEED; the deacon's own, in K, are different)
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
	KITE = DmCoreData.consts(godot_dir, ["enemies/states/dm_state_kite.gd"])
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
	nave_defs()
	censer_pulse()
	censer_haste_in_play()
	censer_melee()
	acolyte_kite()
	acolyte_curse()
	acolyte_silence_and_stun()
	acolyte_unbind()
	acolyte_unbind_edges()
	gargoyle_dive()
	gargoyle_aim_and_stun()
	gargoyle_edges_and_sight()
	gargoyle_sight_on_the_navmesh()
	templar_shield()
	templar_glance_cue()
	templar_fights()
	wraith_scream()
	wraith_walk()
	wraith_no_corpse()
	nave_on_the_wire()
	the_nave_roster_and_a_replay()
	keep.clear()
	if fails == 0:
		print("PASS core_kinds %d checks" % checks)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ names

## The tables GDScript decodes events with end in the new names, append only, and the scripts' constants are the ones this suite reads.
func names_and_tables() -> void:
	check(DmCoreEvents.TELLS.size() == 9 and DmCoreEvents.TELLS[TELL_SLAM] == &"slam" and DmCoreEvents.TELLS[TELL_RAISE] == &"raise" and DmCoreEvents.TELLS[TELL_CURSE] == &"curse"
		and DmCoreEvents.TELLS[TELL_SCREAM] == &"scream" and DmCoreEvents.TELLS[TELL_DIVE] == &"dive", "the telegraph names: raise and curse appended after toll, then scream and dive (append only)")
	check(DmCoreEvents.CUES.size() == 7 and DmCoreEvents.CUES[CUE_SLAM] == &"slam" and DmCoreEvents.CUES[CUE_SANCTIFY] == &"sanctify" and DmCoreEvents.CUES[CUE_SHIELD_BLOCK] == &"shield_block"
		and DmCoreEvents.CUES[CUE_UNBIND] == &"unbind" and DmCoreEvents.CUES[CUE_SCREAM] == &"scream", "the cue names: sanctify appended after dig_in, then shield_block, unbind and scream")
	check(DmCoreEvents.BLOWS.size() == 7 and DmCoreEvents.BLOWS[BLOW_SLAM] == &"slam" and DmCoreEvents.BLOWS[BLOW_CURSE] == &"curse" and DmCoreEvents.BLOWS[BLOW_SCREAM] == &"scream"
		and DmCoreEvents.BLOWS[BLOW_DIVE] == &"dive", "the blow names: curse, scream and dive appended after slam")
	check(K.has("CORPSE_RANGE") and K.has("BACK_OFF_DIST") and K.has("BACK_OFF_SPEED") and K.has("SCAN_S") and K.has("STRIKE_REACH_MULT") and K.has("EXTRA_RING"),
		"the scripts' own constants are read (%s)" % str(K.keys()))
	var c := make()
	check(String(c.version()) == "dmcore 0.9", "the core's version names this step")
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


# ================================================================================================================== the Drowned Nave
#
# Its five kinds (godot/enemies/kinds: dm_enemy_censer, dm_enemy_clst_acolyte, dm_enemy_gargoyle, dm_enemy_clst_templar, dm_enemy_wraith; the states dm_state_clst_kite,
# dm_state_cath_dive_chase, dm_state_cath_dive and the base classes DmEnemyClstCaster and DmEnemyCaster). Numbers come from enemies.json and the scripts' const lines;
# the expected ticks from mirrors of the scripts' arithmetic.

## A hero-proof body: a robber that does no damage and stays where it is (nobody near it to fight).
func harmless(c: RefCounted, at: Vector2, rising := false) -> int:
	return c.spawn_enemy("robber", at, 1, 1.0, 0.0, false, NAVE, rising)


func root(c: RefCounted, id: int) -> void:
	c.apply_status(id, "root", 0, 1.0, 1000.0)


## The seconds left on a body's status (DmCore.statuses: id, stacks and tenths of a second per status), or -1.0 when it has none.
func status_left(c: RefCounted, id: int, name: String) -> float:
	var sid := DmStatusRules.IDS.find(name)
	var b: PackedByteArray = c.statuses(id)
	for i in range(0, b.size(), 4):
		if int(b[i]) == sid:
			return float(int(b[i + 2]) | (int(b[i + 3]) << 8)) / 10.0
	return -1.0


## Ticks until a countdown that starts at `v` and loses DT x `rate` a tick (a double, as the brain subtracts it) is <= 0.
func to_zero_rate(v: float, rate: float) -> int:
	var n := 0
	while v > 0.0:
		v -= DT * rate
		n += 1
	return n


## A thrall of the hero's that stays where it is: stunned for good (so it never gets past its rise: it can fall, and be claimed, but nobody targets it), a lot of health, no
## damage. `hold` false leaves it free, to rise and take its seat (the caller stuns it then).
func thrall(c: RefCounted, owner: int, at: Vector2, hp := 1.0e6, hold := true) -> int:
	var t: int = c.raise_thrall({"kind": "warrior", "hp": hp, "maxHp": hp, "damage": 0.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false, "allyHeal": 0.0}, owner, at, 0.0, 99.0)
	if hold:
		c.stun(t, 1.0e6)
	return t


func spawn_acolyte(c: RefCounted, at: Vector2, level := 1, hp_mult := 1.0, dmg_mult := 1.0, elite := false, rising := false) -> int:
	return c.spawn_enemy("acolyte", at, level, hp_mult, dmg_mult, elite, NAVE, rising)


func nave_defs() -> void:
	var el: Dictionary = content["ELITE"]
	for id in NAVE_KINDS:
		var d := def(id)
		var c := make(201)
		hero(c, FAR)
		var e: int = c.spawn_enemy(id, Vector2(0, 0), 6, 2.0, 1.5, false, NAVE, false)
		var info: Dictionary = c.enemy_info(e)
		check(is_equal_approx(info["max_hp"], float(d["hp"]) * 2.0) and is_equal_approx(info["damage"], float(d["damage"]) * 1.5) and info["radius"] == float(d["radius"])
			and is_equal_approx(info["windup_s"], float(d["windupMs"]) / 1000.0) and info["level"] == 6 and info["area"] == NAVE,
			"%s: hp, damage, radius and wind-up from the def, the spawn's multipliers and level" % id)
		var spd := float(info["speed"])
		check(spd >= float(d["speed"]) * 0.92 - 1e-6 and spd <= float(d["speed"]) * 1.08 + 1e-6, "%s: speed %.2f within the +-8%% roll of %.1f" % [id, spd, float(d["speed"])])
		var ee: int = c.spawn_enemy(id, Vector2(5, 5), 1, 1.0, 1.0, true, NAVE, false)
		var ei: Dictionary = c.enemy_info(ee)
		check(is_equal_approx(ei["max_hp"], float(d["hp"]) * float(el["hpMult"])) and is_equal_approx(ei["windup_s"], float(d["windupMs"]) / 1000.0 * ELITE_WINDUP) and is_equal_approx(ei["damage"], float(d["damage"]) * float(el["damageMult"])),
			"%s: an elite has x%.1f health, x%.1f damage and a x%.2f wind-up" % [id, float(el["hpMult"]), float(el["damageMult"]), ELITE_WINDUP])
	var t: Dictionary = make().tuning()
	var C: Dictionary = content["CENSER"]
	var U: Dictionary = content["UNBIND"]
	var S2: Dictionary = content["TEMPLAR_SHIELD"]
	check(t["CENSER.radius"] == float(C["radius"]) and t["CENSER.hasteS"] == float(C["hasteS"]) and t["SCREAM.radius"] == float(content["SCREAM"]["radius"])
		and t["TEMPLAR_SHIELD.halfArcDeg"] == float(S2["halfArcDeg"]) and t["TEMPLAR_SHIELD.passThrough"] == float(S2["passThrough"])
		and t["UNBIND.range"] == float(U["range"]) and t["UNBIND.delayS"] == float(U["delayS"]) and t["UNBIND.cooldownS"] == float(U["cooldownS"]) and t["UNBIND.maxAlive"] == float(U["maxAlive"]),
		"the Nave's numbers are enemies.json's: CENSER, SCREAM, TEMPLAR_SHIELD, UNBIND")
	var kite: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/kinds/dm_enemy_clst_caster.gd"))
	var censer_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/kinds/dm_enemy_censer.gd"))
	var kite_state: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/states/dm_state_kite.gd"))
	check(kite.contains("return [0.5, 1.5, 3.5, 0.8]") and kite_state.contains("d <= enemy.attack_range - 0.5 and enemy.attack_cd <= 0.0") and kite_state.contains("d > enemy.attack_range - 1.5") and censer_src.contains("_aura_cd = 1.0")
		and float(KITE["BACK_OFF_DIST"]) == 3.5 and float(KITE["BACK_OFF_SPEED"]) == 0.8,
		"the walk of the caster set [cast at attackRange - 0.5, walk in beyond - 1.5, back off under 3.5 m at 0.8] and the censer's one-second pulse are the scripts' own numbers")
	check(K.has("WATCH_S") and K.has("BLOCK_FX_GAP_MS") and K.has("LOS_S") and K.has("RECOVER_TIME") and K.has("HOVER") and K.has("RISE_TIME"), "the Nave's scripts' own constants are read (%s)" % str(K.keys()))


# ------------------------------------------------------------------------------------------------------------------ the censer

## Every second the censer's incense hastes every enemy within CENSER.radius that is not fallen (itself, the rising too), refreshing hasteS; the first pulse comes the
## first tick it is not rising; a rising censer pulses when it has risen; the fallen censer stops; the haste outlasts its last pulse by hasteS.
func censer_pulse() -> void:
	var C: Dictionary = content["CENSER"]
	var r := float(C["radius"])
	var haste := float(C["hasteS"])
	var c := make(211)
	hero(c, FAR)
	var id: int = c.spawn_enemy("censer", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var inside := harmless(c, Vector2(3, 0))
	var edge := harmless(c, Vector2(r, 0))             # exactly on the radius: inside (<=)
	var past := harmless(c, Vector2(r + 0.05, 0))
	var far := harmless(c, Vector2(0, -9))
	var rising := harmless(c, Vector2(0, 2), true)     # a body rising out of the ground is hasted too: only the fallen are not
	var fallen := harmless(c, Vector2(2, 2))
	c.damage(fallen, 1.0e6, 0, false)
	var log := []
	drain(c, log)
	run(c, 1, log)
	var hasted := func(i: int) -> bool: return c.status_stacks(i, "incensed") == 1.0
	check([id, inside, edge, rising].all(hasted), "censer: its first pulse, on the first tick, reaches itself and the bodies within %.0f m (one on the radius, one still rising)" % r)
	check(not hasted.call(past) and not hasted.call(far) and not hasted.call(fallen), "censer: and not the one %.2f m away, the one 9 m away, or the fallen" % (r + 0.05))
	var left := status_left(c, inside, "incensed")
	check(left >= haste - 0.2 and left <= haste + 1e-9, "censer: the haste lasts hasteS = %.1f s (%.1f s left)" % [haste, left])
	var info: Dictionary = c.enemy_info(inside)
	check(is_equal_approx(info["speed_mult"], float(C["moveMult"])) and is_equal_approx(info["attack_rate_mult"], float(C["attackRateMult"])), "censer: x%.1f the feet, x%.2f the blows" % [float(C["moveMult"]), float(C["attackRateMult"])])
	# One second apart: a body that comes within reach between two pulses is hasted at the next one.
	var n1 := to_zero(1.0)
	var late := harmless(c, Vector2(0, 3))
	run_to(c, n1, log)
	check(c.status_stacks(late, "incensed") == 0.0, "censer: a body that came near after the first pulse has nothing on tick %d" % n1)
	run_to(c, 1 + n1, log)
	check(c.status_stacks(late, "incensed") == 1.0, "censer: the second pulse is one second (%d ticks) after the first: tick %d" % [n1, 1 + n1])
	var late2 := harmless(c, Vector2(0, -3))
	run_to(c, 2 * n1, log)
	check(c.status_stacks(late2, "incensed") == 0.0, "censer: and the third is one second after the second")
	run_to(c, 1 + 2 * n1, log)
	check(c.status_stacks(late2, "incensed") == 1.0, "censer: (tick %d)" % (1 + 2 * n1))
	# The censer falls: nothing is hasted after it, and what it hasted ends hasteS after its last pulse.
	var p3 := tick
	c.damage(id, 1.0e6, 0, false)
	drain(c, log)
	var late3 := harmless(c, Vector2(1, 1))
	run_to(c, p3 + 2 * n1 + 5, log)
	check(c.status_stacks(late3, "incensed") == 0.0, "censer: a fallen censer pulses no more")
	var gone := of(log, EV_STATUS_EXPIRED, inside)
	var want := int(haste / DT)
	var after := int(gone[0]["tick"]) - p3 if not gone.is_empty() else -1
	check(gone.size() == 1 and after >= want - 8 and after <= want + 14, "censer: what it hasted ends %d ticks after its last pulse (%.1f s = %d ticks, the status steps every 0.1 s)" % [after, haste, want])
	check(is_equal_approx(float(c.enemy_info(inside)["speed_mult"]), 1.0) and is_equal_approx(float(c.enemy_info(inside)["attack_rate_mult"]), 1.0), "censer: and the feet and blows are the body's own again")
	# A censer that rises pulses the tick it has risen (the first tick it is not RISING), not before.
	var rc := make(212)
	hero(rc, FAR)
	var rid: int = rc.spawn_enemy("censer", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, true)
	var sib := harmless(rc, Vector2(2, 0))
	var lg := []
	var k_up := to_reach(float(K["RISE_TIME"]))
	run_to(rc, k_up - 1, lg)
	check(rc.status_stacks(sib, "incensed") == 0.0 and rc.enemy_info(rid)["state"] == RISING, "censer: while it is rising it pulses nothing (tick %d)" % (k_up - 1))
	run_to(rc, k_up, lg)
	check(first_tick(state_edges(lg, rid, IDLE)) == k_up and rc.status_stacks(sib, "incensed") == 1.0 and rc.status_stacks(rid, "incensed") == 1.0, "censer: it has risen on tick %d (%.1f s) and pulses on it" % [k_up, float(K["RISE_TIME"])])


## What the haste does in play: the feet cover x1.3 the ground a tick, and the attack cooldown runs x1.25.
func censer_haste_in_play() -> void:
	var C: Dictionary = content["CENSER"]
	var c := make(213)
	hero(c, Vector2(2, 14))
	c.spawn_enemy("censer", Vector2(0, -3), 1, 1.0, 0.0, false, NAVE, false)
	var rid := harmless(c, Vector2(2, 0))
	var log := []
	run(c, 5, log)
	var cd5 := float(c.enemy_info(rid)["attack_cd"])
	run(c, 1, log)
	var cd6 := float(c.enemy_info(rid)["attack_cd"])
	check(absf((cd5 - cd6) - DT * float(C["attackRateMult"])) < 1e-9, "censer: a hasted body's cooldown runs x%.2f (%.6f s a tick)" % [float(C["attackRateMult"]), cd5 - cd6])
	run(c, 14, log)
	var spd := float(c.enemy_info(rid)["speed"])
	var p0: Vector2 = c.enemy_info(rid)["pos"]
	run(c, 1, log)
	var p1: Vector2 = c.enemy_info(rid)["pos"]
	check(absf((p1.y - p0.y) - spd * float(C["moveMult"]) * DT) < 1e-4 and c.enemy_info(rid)["state"] == CHASE, "censer: and it walks x%.1f as fast (%.4f m a tick, %.4f unhasted)" % [float(C["moveMult"]), p1.y - p0.y, spd * DT])


## It is a melee body (a robber's rules on its numbers) that incenses itself: its own cooldown runs x1.25 from the tick after its first pulse.
func censer_melee() -> void:
	var d := def("censer")
	var C: Dictionary = content["CENSER"]
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var rate := float(C["attackRateMult"])
	var reach := float(d["attackRange"]) * float(K["STRIKE_REACH_MULT"]) + float(K["STRIKE_REACH_PAD"])
	var c := make(214)
	var h := hero(c, Vector2(1.0, 0))
	var id: int = c.spawn_enemy("censer", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var v := cd0 - DT      # tick 1: the cooldown loses a plain tick (the pulse that hastes the body comes after its brain)
	var k0 := 1
	while v > 0.0:
		v -= DT * rate
		k0 += 1
	var log := []
	run(c, 400, log)
	var att := of(log, EV_ATTACK, id)
	check(att.size() >= 2 and int(att[0]["tick"]) == k0 and att[0]["ints"][0] == 0, "censer: its first swing is the plain blow on the tick its cooldown (%.2f s, hasted by its own incense from tick 2) is up: tick %d" % [cd0, k0])
	var ks := k0 + to_reach(windup)
	var hits := of(log, EV_HIT, id)
	check(hits.size() >= 2 and int(hits[0]["tick"]) == ks and hits[0]["ints"][0] == h and hits[0]["ints"][1] == 0 and hits[0]["floats"][0] == float(d["damage"]),
		"censer: the blow lands %d ticks (%.2f s) later for %d, melee" % [ks - k0, windup, int(d["damage"])])
	check(of(log, EV_TELEGRAPH, id).is_empty(), "censer: a plain swing has no telegraph")
	var k1 := ks + to_zero_rate(cooldown, rate)
	check(att.size() >= 2 and int(att[1]["tick"]) == k1, "censer: the next swing is one cooldown (%.1f s / %.2f = %d ticks) after the blow: tick %d" % [cooldown, rate, k1 - ks, int(att[1]["tick"]) if att.size() > 1 else -1])
	# The reach is measured at the blow: a target past attackRange x 1.35 + 0.4 when it lands is not hit.
	var e := make(215)
	var hh := hero(e, Vector2(1.0, 0))
	var eid: int = e.spawn_enemy("censer", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var lg := []
	for i in 400:
		run(e, 1, lg)
		if not of(lg, EV_ATTACK, eid).is_empty():
			break
	e.set_external(hh, Vector2(reach + 0.2, 0), true)
	var rest := []
	run(e, to_reach(windup) + 2, rest)
	check(of(rest, EV_HIT, eid).is_empty(), "censer: a target %.2f m away at the blow is missed (the reach is %.2f m)" % [reach + 0.2, reach])


# ------------------------------------------------------------------------------------------------------------------ the acolyte: kiting, the curse

## The caster set's walk (dm_state_clst_kite, parameters [0.5, 1.5, 3.5, 0.8]): walk in beyond attackRange - 1.5, cast at attackRange - 0.5, back off at 0.8 x under 3.5 m.
func acolyte_kite() -> void:
	var d := def("acolyte")
	var range_ := float(d["attackRange"])
	var cast_at := range_ - float(KITE_PARAMS[0])
	var walk_in := range_ - float(KITE_PARAMS[1])
	var back := float(KITE_PARAMS[2])
	var back_speed := float(KITE_PARAMS[3])
	var c := make(221)
	var h := hero(c, Vector2(12, 0))
	var id := spawn_acolyte(c, Vector2(0, 0))
	var spd := float(c.enemy_info(id)["speed"])
	silence(c, id)
	var log := []
	var xs := []
	for i in 400:
		run(c, 1, log)
		var p: Vector2 = c.enemy_info(id)["pos"]
		xs.append(p.x)
		if Vector2(12, 0).distance_to(p) <= walk_in and i > 10:
			break
	var step_ok := true
	for i in range(40, mini(100, xs.size() - 1)):
		step_ok = step_ok and absf((xs[i + 1] - xs[i]) - spd * DT) < 2e-4
	check(step_ok, "acolyte: walks in at full speed (%.2f m/s) while the target is farther than %.1f m" % [spd, walk_in])
	run(c, 60, log)
	var rest: Vector2 = c.enemy_info(id)["pos"]
	var dist := Vector2(12, 0).distance_to(rest)
	check(dist <= walk_in + 1e-3 and dist > walk_in - spd * DT * 1.5, "acolyte: stops %.2f m from the target (%.1f - one step)" % [dist, walk_in])
	run(c, 60, log)
	check(Vector2(c.enemy_info(id)["pos"]).distance_to(rest) < 1e-4 and c.enemy_info(id)["state"] == CHASE and of(log, EV_ATTACK, id).is_empty(), "acolyte: stands still between %.1f and %.1f m, and silenced it never casts" % [back, walk_in])
	c.set_external(h, Vector2(rest.x + 2.0, rest.y), true)
	var from := Vector2(c.enemy_info(id)["pos"]).x
	run(c, 1, log)
	var x1 := Vector2(c.enemy_info(id)["pos"]).x
	check(absf((from - x1) - spd * back_speed * DT) < 2e-4, "acolyte: backs off at %.1f x its speed (%.4f m a tick)" % [back_speed, from - x1])
	run(c, 200, log)
	var d2 := Vector2(c.enemy_info(id)["pos"]).distance_to(Vector2(rest.x + 2.0, rest.y))
	check(d2 >= back - 1e-3 and d2 < back + spd * back_speed * DT * 1.5, "acolyte: stops backing off at %.2f m (%.1f m)" % [d2, back])
	# The cast gate: rooted, so it cannot close in; a target on attackRange - 0.5 is cast at, one 2 cm past it is not.
	for trial in [[cast_at, true], [cast_at + 0.02, false]]:
		var e := make(222)
		hero(e, Vector2(float(trial[0]), 0))
		var eid := spawn_acolyte(e, Vector2(0, 0))
		root(e, eid)
		var lg := []
		run(e, 600, lg)
		check(of(lg, EV_ATTACK, eid).is_empty() == (not bool(trial[1])), "acolyte: a target %.2f m away is %s (it casts at attackRange - %.1f = %.1f m)" % [float(trial[0]), "cast at" if trial[1] else "not cast at", float(KITE_PARAMS[0]), cast_at])


## The curse: with the cooldown up and the target within attackRange - 0.5 it winds up for windupMs (telegraph "curse" on the target), and a blow of the def's damage, hit kind
## curse, lands on the CURRENT target if it is within attackRange x 1.35 + 0.4 of the body at that moment (walking out of the ring does not dodge it).
func acolyte_curse() -> void:
	var d := def("acolyte")
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var reach := float(d["attackRange"]) * float(K["STRIKE_REACH_MULT"]) + float(K["STRIKE_REACH_PAD"])
	var c := make(231)
	var h := hero(c, Vector2(5, 0))
	var id := spawn_acolyte(c, Vector2(0, 0))
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var log := []
	run(c, 700, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_CURSE)
	var att := of(log, EV_ATTACK, id)
	check(tell.size() >= 2 and att.size() >= 2, "acolyte: a curse telegraph and a swing, more than once")
	if tell.size() < 2:
		return
	var k0 := int(tell[0]["tick"])
	check(k0 == to_zero(cd0), "acolyte: the first curse comes on the tick the cooldown is up (tick %d)" % k0)
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[2], 5.0) and is_equal_approx(f[3], 0.0) and f[4] == 0.0 and is_equal_approx(f[5], windup), "acolyte: the ring is on the target and lasts the wind-up (%.2f s)" % f[5])
	check(att[0]["ints"][0] == BLOW_CURSE and is_equal_approx(att[0]["floats"][2], windup), "acolyte: the swing is a curse")
	var ks := k0 + to_reach(windup)
	var hits := of(log, EV_HIT, id)
	check(hits.size() >= 1 and int(hits[0]["tick"]) == ks and hits[0]["ints"][0] == h and hits[0]["ints"][1] == HK_CURSE and hits[0]["floats"][0] == float(d["damage"]),
		"acolyte: the blow lands %d ticks (%.2f s) later for %d, kind curse, on the target" % [ks - k0, windup, int(d["damage"])])
	check(int(tell[1]["tick"]) == ks + to_zero(cooldown), "acolyte: the next one a cooldown (%.1f s) after the blow (tick %d)" % [cooldown, int(tell[1]["tick"])])
	# The reach is measured at the blow, from the body: the target who walks to the edge of it is still cursed, one who is past it is not.
	for trial in [[reach - 0.2, true], [reach + 0.2, false]]:
		var e := make(232)
		var hh := hero(e, Vector2(5, 0))
		var did := spawn_acolyte(e, Vector2(0, 0))
		var lg := []
		for i in 700:
			run(e, 1, lg)
			if not of(lg, EV_TELEGRAPH, did, TELL_CURSE).is_empty():
				break
		var p: Vector2 = e.enemy_info(did)["pos"]
		e.set_external(hh, Vector2(p.x + float(trial[0]), p.y), true)
		var rest := []
		run(e, to_reach(windup) + 2, rest)
		check(of(rest, EV_HIT, did).size() == (1 if trial[1] else 0), "acolyte: a target %.2f m away at the blow is %s (the reach is %.2f m)" % [float(trial[0]), "cursed" if trial[1] else "missed", reach])


## Silence stops the cast (a silenced scan never starts one; the cloister casters' state checks it) and not a swing begun; stun cancels the swing.
func acolyte_silence_and_stun() -> void:
	var d := def("acolyte")
	var windup := float(d["windupMs"]) / 1000.0
	var c := make(234)
	var h := hero(c, Vector2(5, 0))
	var id := spawn_acolyte(c, Vector2(0, 0))
	silence(c, id)
	var log := []
	run(c, 600, log)
	check(of(log, EV_ATTACK, id).is_empty() and c.enemy_info(id)["state"] == CHASE, "silence: a silenced acolyte does not cast in 10 s, with the target in range")
	check(c.remove_status(id, "silence"), "silence: it lifts")
	run(c, 1, log)
	var t0 := tick
	check(first_tick(state_edges(log, id, ATTACK)) == t0 and of(log, EV_TELEGRAPH, id, TELL_CURSE).size() == 1, "silence: the curse starts on the next tick (the cooldown was up)")
	silence(c, id)
	var ks := t0 + to_reach(windup)
	run_to(c, ks, log)
	var hits := of(log, EV_HIT, id)
	check(hits.size() == 1 and hits[0]["ints"][0] == h and int(hits[0]["tick"]) == ks, "silence: a curse already winding up lands all the same, on tick %d" % ks)
	# A stun in the wind-up cancels the curse (and starts no cooldown).
	var e := make(235)
	hero(e, Vector2(5, 0))
	var eid := spawn_acolyte(e, Vector2(0, 0))
	var lg := []
	for i in 700:
		run(e, 1, lg)
		if not of(lg, EV_TELEGRAPH, eid, TELL_CURSE).is_empty():
			break
	var s0 := tick
	run(e, 20, lg)
	e.stun(eid, 2.0)
	drain(e, lg)
	run(e, to_reach(windup) + 4, lg)
	check(of(lg, EV_HIT, eid).is_empty() and e.enemy_info(eid)["state"] == HURT, "stun: a stun in the wind-up cancels the curse (nothing lands at tick %d)" % (s0 + to_reach(windup)))


# ------------------------------------------------------------------------------------------------------------------ the acolyte: Unbind

## UNBIND: a thrall of the player's that is KILLED within UNBIND.range of an acolyte that has looked at it is claimed (one acolyte per fall), UNBIND.delayS later a Risen
## climbs out of the place with the acolyte's level and multipliers; the cue says where; UNBIND.cooldownS between claims; at most UNBIND.maxAlive claimed Risen alive or pending.
func acolyte_unbind() -> void:
	var U: Dictionary = content["UNBIND"]
	var rs := def("risen")
	var delay := float(U["delayS"])
	var cooldown := float(U["cooldownS"])
	var rng_ := float(U["range"])
	var max_alive := int(U["maxAlive"])
	var c := make(241)
	var h := hero(c, FAR)
	var a := spawn_acolyte(c, Vector2(0, 0), 5, 2.0, 1.5)
	root(c, a)
	silence(c, a)
	var t_blind := thrall(c, h, Vector2(1, 1))
	var log := []
	check(Array(c.unbind_info(a)["seen"]).is_empty(), "unbind: before its first look the acolyte has seen no thrall")
	c.kill_thrall(t_blind, "killed")
	drain(c, log)
	check(of(log, EV_CUE, a).is_empty() and Array(c.unbind_info(a)["pending"]).is_empty(), "unbind: a thrall that fell before the acolyte had looked is not claimed")
	var t_crumb := thrall(c, h, Vector2(2, 0))
	var t_far := thrall(c, h, Vector2(rng_ + 0.05, 0))
	var t_sac := thrall(c, h, Vector2(0, 2))
	var t_ok := thrall(c, h, Vector2(2, 3))
	var t_two := thrall(c, h, Vector2(-2, 3))
	var spare := []
	for i in 8:
		spare.append(thrall(c, h, Vector2(-3 + float(i) * 0.4, -2)))
	run(c, 40, log)       # the acolyte looks every WATCH_S (0.5 s)
	var seen := Array(c.unbind_info(a)["seen"])
	check(seen.size() == 13 and seen.has(t_ok) and not seen.has(t_blind), "unbind: it has looked at the thralls alive: %d (not the one that fell)" % seen.size())
	drain(c, log)
	c.kill_thrall(t_crumb, "crumbled")
	c.kill_thrall(t_sac, "sacrificed")
	c.kill_thrall(t_far, "killed")
	drain(c, log)
	check(of(log, EV_CUE, a).is_empty() and Array(c.unbind_info(a)["pending"]).is_empty() and float(c.unbind_info(a)["cooldown"]) <= 0.0,
		"unbind: a crumbled or sacrificed thrall, and one killed %.2f m away (the range is %.0f m), are not claimed" % [rng_ + 0.05, rng_])
	# A killed one within range: claimed. The cue is at its place; the cooldown starts; the fall is waiting.
	var T0 := tick
	c.kill_thrall(t_ok, "killed")
	c.kill_thrall(t_two, "killed")      # at once, in the cooldown: not claimed
	drain(c, log)
	var cue := of(log, EV_CUE, a, CUE_UNBIND)
	check(cue.size() == 1 and is_equal_approx(cue[0]["floats"][0], 2.0) and is_equal_approx(cue[0]["floats"][1], 3.0), "unbind: a killed thrall within range is claimed: the cue names its place (2, 3)")
	var ui: Dictionary = c.unbind_info(a)
	check(Array(ui["pending"]).size() == 1 and is_equal_approx(float(ui["cooldown"]), cooldown), "unbind: the fall is waiting and the cooldown is %.1f s; the second fall, at once, is not claimed" % cooldown)
	# The Risen climbs out delayS later, rising, with the acolyte's level, area and multipliers (a plain body).
	var n1 := to_zero(delay)
	run_to(c, T0 + n1 - 1, log)
	check(of(log, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return c.def_name(e["ints"][0]) == "risen").is_empty(), "unbind: nothing climbs out before %.1f s" % delay)
	run_to(c, T0 + n1, log)
	var sp := of(log, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return c.def_name(e["ints"][0]) == "risen")
	check(sp.size() == 1 and int(sp[0]["tick"]) == T0 + n1, "unbind: a Risen climbs out %d ticks (%.1f s) after the claim" % [n1, delay])
	if sp.size() != 1:
		return
	var rid: int = sp[0]["id"]
	var ri: Dictionary = c.enemy_info(rid)
	check(sp[0]["ints"][1] == 5 and not bool(ri["elite"]) and c.area_name(sp[0]["ints"][3]) == NAVE and ri["state"] == RISING, "unbind: at the acolyte's level (5), in its area, rising, not elite")
	check(is_equal_approx(ri["max_hp"], float(rs["hp"]) * 2.0) and is_equal_approx(ri["damage"], float(rs["damage"]) * 1.5), "unbind: with the acolyte's multipliers (hp x2 = %.0f, damage x1.5 = %.0f)" % [ri["max_hp"], ri["damage"]])
	check(is_equal_approx(sp[0]["floats"][0], 2.0) and is_equal_approx(sp[0]["floats"][1], 3.0) and Array(c.unbind_info(a)["pending"]).is_empty() and Array(c.unbind_info(a)["unbound"]) == [rid],
		"unbind: where the thrall fell, and the acolyte counts it")
	# The cooldown: a fall one tick before it is over is not claimed; the next tick it is.
	var n4 := to_zero(cooldown)
	run_to(c, T0 + n4 - 1, log)
	c.kill_thrall(spare[0], "killed")
	drain(c, log)
	check(Array(c.unbind_info(a)["pending"]).is_empty(), "unbind: %d ticks (%.1f s) after a claim the cooldown is still on" % [n4 - 1, cooldown])
	run_to(c, T0 + n4, log)
	c.kill_thrall(spare[1], "killed")
	drain(c, log)
	check(Array(c.unbind_info(a)["pending"]).size() == 1, "unbind: and %d ticks after it, it is over: the next fall is claimed" % n4)
	# Four claims over time: four Risen; the fifth fall is not claimed; a Risen that falls frees a slot.
	for k in 2:
		run(c, n4, log)
		c.kill_thrall(spare[2 + k], "killed")
		drain(c, log)
	run(c, n1 + 2, log)
	var ub: Array = Array(c.unbind_info(a)["unbound"])
	check(ub.size() == max_alive and Array(c.unbind_info(a)["pending"]).is_empty(), "unbind: %d claimed Risen alive, none waiting" % ub.size())
	run(c, n4, log)
	var cues_before := of(log, EV_CUE, a, CUE_UNBIND).size()
	c.kill_thrall(spare[4], "killed")
	drain(c, log)
	check(of(log, EV_CUE, a, CUE_UNBIND).size() == cues_before and Array(c.unbind_info(a)["pending"]).is_empty(), "unbind: at most %d claimed Risen alive per acolyte: the fifth fall is not claimed" % max_alive)
	c.damage(int(ub[0]), 1.0e6, 0, false)
	c.kill_thrall(spare[5], "killed")
	drain(c, log)
	check(Array(c.unbind_info(a)["pending"]).size() == 1 and of(log, EV_CUE, a, CUE_UNBIND).size() == cues_before + 1, "unbind: a freed slot (a Risen fell) can be claimed again")


## The edges: the range is inclusive, one claim per fall across acolytes (each ready one in turn), a rising or fallen acolyte claims nothing and does not look, and a thrall
## raised after a look is seen at the next one, WATCH_S later.
func acolyte_unbind_edges() -> void:
	var U: Dictionary = content["UNBIND"]
	var rng_ := float(U["range"])
	# The range is a distance from the acolyte's centre to the fall, inclusive.
	for trial in [[rng_, true], [rng_ + 0.02, false]]:
		var c := make(251)
		var h := hero(c, FAR)
		var a := spawn_acolyte(c, Vector2(0, 0))
		root(c, a)
		silence(c, a)
		var t := thrall(c, h, Vector2(float(trial[0]), 0))
		run(c, 40, [])
		c.kill_thrall(t, "killed")
		check(Array(c.unbind_info(a)["pending"]).size() == (1 if trial[1] else 0), "unbind: a fall %.2f m away is %s (the range is %.0f m, inclusive)" % [float(trial[0]), "claimed" if trial[1] else "not claimed", rng_])
	# Two acolytes in range of two falls: each fall is claimed once, and the second goes to the acolyte that is not on its cooldown.
	var c2 := make(252)
	var h2 := hero(c2, FAR)
	var a1 := spawn_acolyte(c2, Vector2(-1, 0))
	var a2 := spawn_acolyte(c2, Vector2(1, 0))
	for a in [a1, a2]:
		root(c2, a)
		silence(c2, a)
	var f1 := thrall(c2, h2, Vector2(0, 3))
	var f2 := thrall(c2, h2, Vector2(0, -3))
	var lg := []
	run(c2, 40, lg)
	drain(c2, lg)
	c2.kill_thrall(f1, "killed")
	c2.kill_thrall(f2, "killed")
	drain(c2, lg)
	var cues := of(lg, EV_CUE, 0, CUE_UNBIND)
	check(cues.size() == 2 and cues[0]["id"] != cues[1]["id"], "unbind: two falls, two acolytes: each ready one claims one, none claims twice (%s)" % str(cues.map(func(e: Dictionary) -> int: return e["id"])))
	# Rising and fallen acolytes: nothing claimed, and a rising one has not looked at anything yet.
	var c3 := make(253)
	var h3 := hero(c3, FAR)
	var ra := spawn_acolyte(c3, Vector2(0, 0), 1, 1.0, 1.0, false, true)
	var da := spawn_acolyte(c3, Vector2(0, 5))
	root(c3, ra)
	silence(c3, ra)
	root(c3, da)
	silence(c3, da)
	var t3 := thrall(c3, h3, Vector2(2, 2))
	var t4 := thrall(c3, h3, Vector2(2, 6))
	run(c3, 40, [])
	check(c3.enemy_info(ra)["state"] == RISING and Array(c3.unbind_info(ra)["seen"]).is_empty(), "unbind: a rising acolyte looks at nothing")
	check(Array(c3.unbind_info(da)["seen"]).size() == 2, "unbind: (a standing one has)")
	c3.damage(da, 1.0e6, 0, false)
	c3.kill_thrall(t4, "killed")
	check(Array(c3.unbind_info(da)["pending"]).is_empty(), "unbind: a fallen acolyte claims nothing")
	c3.kill_thrall(t3, "killed")
	check(Array(c3.unbind_info(ra)["pending"]).is_empty(), "unbind: nor does a rising one")
	# The look: a thrall raised right after a look is seen at the next one, WATCH_S (0.5 s) later.
	var c4 := make(254)
	var h4 := hero(c4, FAR)
	var a4 := spawn_acolyte(c4, Vector2(0, 0))
	root(c4, a4)
	silence(c4, a4)
	var first := thrall(c4, h4, Vector2(1, 1))
	var look := 0
	for i in 60:
		run(c4, 1, [])
		if Array(c4.unbind_info(a4)["seen"]).has(first):
			look = tick
			break
	var late := thrall(c4, h4, Vector2(2, 1))
	var n := to_zero(float(K["WATCH_S"]))
	run_to(c4, look + n - 1, [])
	check(look > 0 and not Array(c4.unbind_info(a4)["seen"]).has(late), "unbind: a thrall raised after a look is not seen before the next one (tick %d)" % (look + n - 1))
	run_to(c4, look + n, [])
	check(Array(c4.unbind_info(a4)["seen"]).has(late), "unbind: it is seen %d ticks (%.1f s) after the look, on tick %d" % [n, float(K["WATCH_S"]), look + n])


# ------------------------------------------------------------------------------------------------------------------ the gargoyle

## A rooted gargoyle (so that it cannot walk) with a hero 7 m away: with the cooldown up it marks the hero's place, hangs still for the first half of the wind-up, drops onto
## the mark along an ease-in curve, and everything within the dive's radius of it takes the blow as it lands; then it sits grounded for 0.3 s + groundedS and hunts again.
func gargoyle_dive() -> void:
	var d := def("gargoyle")
	var D: Dictionary = d["dive"]
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var radius := float(D["radius"])
	var c := make(261)
	var h := hero(c, Vector2(7, 0))
	var inside := hero(c, Vector2(7, radius - 0.1))     # in the circle, but farther from the gargoyle than the target
	var outside := hero(c, Vector2(7, radius + 0.1))
	var id: int = c.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	root(c, id)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var log := []
	var k0 := to_zero(cd0)
	run_to(c, k0 - 1, log)
	check(of(log, EV_TELEGRAPH, id).is_empty() and not bool(c.enemy_info(id)["diving"]), "dive: nothing while the cooldown runs (%d ticks)" % (k0 - 1))
	run_to(c, k0, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_DIVE)
	check(tell.size() == 1 and int(tell[0]["tick"]) == k0 and bool(c.enemy_info(id)["diving"]), "dive: the telegraph on the tick the cooldown is up (tick %d), and the body is diving" % k0)
	if tell.is_empty():
		return
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[0], 0.0) and is_equal_approx(f[1], 0.0) and is_equal_approx(f[2], 7.0) and is_equal_approx(f[3], 0.0) and is_equal_approx(f[4], radius) and is_equal_approx(f[5], windup),
		"dive: a mark of %.0f m under the hero for the %.1f s wind-up" % [radius, windup])
	var att := of(log, EV_ATTACK, id)
	check(att.size() == 1 and att[0]["ints"][0] == BLOW_DIVE and is_equal_approx(att[0]["floats"][0], 7.0) and is_equal_approx(att[0]["floats"][2], windup), "dive: the swing is a dive, aimed at the hero's place")
	# The path: still for the first half of the wind-up, then from + (aim - from) x k^2 (k the second half's progress), step by step.
	var t := 0.0
	var path_ok := true
	var worst := 0.0
	var ks := k0 + to_reach(windup)
	for k in range(k0 + 1, ks + 1):
		t += DT
		var kk := clampf((t - windup * 0.5) / (windup * 0.5), 0.0, 1.0)
		var want := 7.0 * kk * kk
		run_to(c, k, log)
		var p: Vector2 = c.enemy_info(id)["pos"]
		worst = maxf(worst, absf(p.x - want))
		path_ok = path_ok and absf(p.x - want) < 1e-4 and absf(p.y) < 1e-6
	check(path_ok, "dive: hangs over its start for %.2f s, then drops onto the mark along k^2 (worst %.6f m off)" % [windup * 0.5, worst])
	var hits := of(log, EV_HIT, id)
	var who := {}
	for e in hits:
		who[int(e["ints"][0])] = [e["floats"][0], e["ints"][1], int(e["tick"])]
	check(who.has(h) and who.has(inside) and not who.has(outside) and hits.size() == 2, "dive: the blow reaches the two heroes within %.0f m of the mark, not the one outside (%s)" % [radius, str(who.keys())])
	check(who.has(h) and who[h][0] == float(d["damage"]) and who[h][1] == 0 and who[h][2] == ks, "dive: %d damage, melee, on tick %d (%d ticks after the telegraph)" % [int(d["damage"]), ks, ks - k0])
	var cues := of(log, EV_CUE, id, CUE_SLAM)
	check(cues.size() == 1 and int(cues[0]["tick"]) == ks and is_equal_approx(cues[0]["floats"][0], 7.0) and is_equal_approx(cues[0]["floats"][2], radius), "dive: the stone lands with a slam cue on the mark")
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "dive: the cooldown is the def's %.1f s from the landing" % cooldown)
	# Grounded: still in the swing for 0.3 s + groundedS from the landing, then it hunts.
	var recover := float(K["RECOVER_TIME"]) + float(D["groundedS"])
	var ke := ks + to_reach(recover)
	run_to(c, ke - 1, log)
	check(c.enemy_info(id)["state"] == ATTACK and bool(c.enemy_info(id)["diving"]), "dive: still grounded %.2f s after the landing" % (float(ke - 1 - ks) * DT))
	run_to(c, ke, log)
	check(first_tick(state_edges(log, id, CHASE).filter(func(e: Dictionary) -> bool: return int(e["tick"]) > ks)) == ke and not bool(c.enemy_info(id)["diving"]), "dive: back on the hunt %d ticks (%.1f s = %.1f + %.1f) after the landing, on tick %d" % [ke - ks, recover, float(K["RECOVER_TIME"]), float(D["groundedS"]), ke])
	# The next dive, once the cooldown is over (the hero stepped away to 5 m so that it is within range): the sight line is not cast again before its 0.25 s.
	c.set_external(h, Vector2(12.0, 0), true)
	c.set_external(inside, Vector2(40.0, 40.0), true)      # (the others go far away: the nearest hero is the target)
	c.set_external(outside, Vector2(-40.0, 40.0), true)
	var k2 := ks + to_zero(cooldown)
	run_to(c, k2 - 1, log)
	check(of(log, EV_TELEGRAPH, id, TELL_DIVE).size() == 1, "dive: no second dive before the cooldown is up")
	run_to(c, k2, log)
	var second := of(log, EV_TELEGRAPH, id, TELL_DIVE)
	check(second.size() == 2 and int(second[1]["tick"]) == k2 and is_equal_approx(second[1]["floats"][2], 12.0), "dive: the second dive is a cooldown (%d ticks) after the first landing, on the hero's new place (tick %d)" % [k2 - ks, k2])


## The aim is fixed when the wind-up begins (stepping out of the mark dodges the dive), and a stun mid-dive ends it where the body is.
func gargoyle_aim_and_stun() -> void:
	var d := def("gargoyle")
	var windup := float(d["windupMs"]) / 1000.0
	var radius := float(d["dive"]["radius"])
	var c := make(262)
	var h := hero(c, Vector2(7, 0))
	var near := hero(c, Vector2(7, radius - 0.1))
	var id: int = c.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	root(c, id)
	var log := []
	run_to(c, to_zero(float(c.enemy_info(id)["attack_cd"])), log)
	c.set_external(h, Vector2(7, 5), true)       # steps out
	run(c, to_reach(windup) + 1, log)
	var hits := of(log, EV_HIT, id)
	check(hits.size() == 1 and hits[0]["ints"][0] == near, "dive: the mark stays where it was drawn: the hero who stepped out is not hit, the one who stayed is (%s)" % str(hits.map(func(e: Dictionary) -> int: return e["ints"][0])))
	# Stun at 0.3 s into the wind-up: no landing, no blow, no cooldown; it hangs where it was, and dives again when it is up.
	var s := make(263)
	hero(s, Vector2(7, 0))
	var sid: int = s.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	root(s, sid)
	var sl := []
	var s0 := to_zero(float(s.enemy_info(sid)["attack_cd"]))
	run_to(s, s0 + 18, sl)
	var before: Vector2 = s.enemy_info(sid)["pos"]
	s.stun(sid, 1.0)
	drain(s, sl)
	check(s.enemy_info(sid)["state"] == HURT and not bool(s.enemy_info(sid)["diving"]) and float(s.enemy_info(sid)["attack_cd"]) <= 0.0, "dive: a stun ends the dive and starts no cooldown")
	var flinch_end := s0 + 18 + to_reach(1.0)
	run_to(s, flinch_end + 3, sl)
	check(of(sl, EV_HIT, sid).is_empty() and of(sl, EV_CUE, sid).is_empty() and Vector2(s.enemy_info(sid)["pos"]).distance_to(before) < 1e-6, "dive: nothing landed, and the body is where the stun found it")
	var again := of(sl, EV_TELEGRAPH, sid, TELL_DIVE)
	check(again.size() == 2 and int(again[1]["tick"]) <= flinch_end + 2, "dive: it dives again as soon as it is back on the hunt (tick %d, the flinch ends at %d)" % [int(again[1]["tick"]) if again.size() > 1 else -1, flinch_end])


## The distances: a target closer than minRange or farther than range is not dived at (inclusive both ends), a target within bite range is bitten (no telegraph), and the
## sight line is cast at most every LOS_S: a wall between blocks the dive, and it is looked at again 0.25 s later.
func gargoyle_edges_and_sight() -> void:
	var d := def("gargoyle")
	var D: Dictionary = d["dive"]
	var windup := float(d["windupMs"]) / 1000.0
	for trial in [[float(D["minRange"]) - 0.1, false], [float(D["minRange"]), true], [float(D["range"]), true], [float(D["range"]) + 0.05, false]]:
		var c := make(264)
		hero(c, Vector2(float(trial[0]), 0))
		var id: int = c.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
		root(c, id)
		var log := []
		run(c, 400, log)
		check(of(log, EV_TELEGRAPH, id, TELL_DIVE).is_empty() == (not bool(trial[1])), "dive: a target %.2f m away is %s (minRange %.1f, range %.0f)" % [float(trial[0]), "dived at" if trial[1] else "not dived at", float(D["minRange"]), float(D["range"])])
		if float(trial[0]) < float(D["minRange"]) or float(trial[0]) > float(D["range"]):
			check(of(log, EV_ATTACK, id).is_empty(), "dive: and out of bite range (rooted) it does nothing at all")
	# Inside minRange and bite range: the plain bite, no telegraph, its own wind-up, the def's damage.
	var b := make(265)
	var bh := hero(b, Vector2(1.2, 0))
	var bid: int = b.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var bl := []
	var cd0 := float(b.enemy_info(bid)["attack_cd"])
	run(b, 400, bl)
	var att := of(bl, EV_ATTACK, bid)
	check(not att.is_empty() and att[0]["ints"][0] == 0 and of(bl, EV_TELEGRAPH, bid).is_empty() and int(att[0]["tick"]) == to_zero(cd0), "bite: a target at 1.2 m is bitten (a plain swing, no telegraph) on the tick the cooldown is up (%d)" % to_zero(cd0))
	var hits := of(bl, EV_HIT, bid)
	check(not hits.is_empty() and int(hits[0]["tick"]) == int(att[0]["tick"]) + to_reach(windup) and hits[0]["ints"][0] == bh and hits[0]["floats"][0] == float(d["damage"]), "bite: it lands %.1f s later for %d" % [windup, int(d["damage"])])
	# A wall between (the Ossuary Wall as an obstacle): no dive; the sight line is cast again LOS_S later, and the dive comes then.
	var w := make(266)
	hero(w, Vector2(7, 0))
	var wid: int = w.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	root(w, wid)
	var wall: int = w.add_obstacle(Vector2(3.5, -4), Vector2(3.5, 4), 0.5)
	var wl := []
	var w0 := to_zero(float(w.enemy_info(wid)["attack_cd"]))
	run_to(w, w0 + 5, wl)
	check(of(wl, EV_TELEGRAPH, wid).is_empty() and not bool(w.enemy_info(wid)["diving"]), "sight: no dive through a wall")
	check(w.remove_obstacle(wall), "sight: the wall goes")
	var n := to_zero(float(K["LOS_S"]))
	run_to(w, w0 + n - 1, wl)
	check(of(wl, EV_TELEGRAPH, wid).is_empty(), "sight: the line is not cast again before %.2f s: still nothing on tick %d" % [float(K["LOS_S"]), w0 + n - 1])
	run_to(w, w0 + n, wl)
	check(first_tick(of(wl, EV_TELEGRAPH, wid, TELL_DIVE)) == w0 + n, "sight: %d ticks (%.2f s) after the blocked cast it is clear, and the dive begins (tick %d)" % [n, float(K["LOS_S"]), w0 + n])
	# A wall that does not reach the line (it ends before the line passes) does not block it.
	var s2 := make(267)
	hero(s2, Vector2(7, 0))
	var sid2: int = s2.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	root(s2, sid2)
	s2.add_obstacle(Vector2(3.5, 0.6), Vector2(3.5, 6), 0.5)
	var sl2 := []
	run(s2, 400, sl2)
	check(not of(sl2, EV_TELEGRAPH, sid2, TELL_DIVE).is_empty(), "sight: a wall beside the line does not block it")


## The navmesh as the world's walls: a gap in it across the line is a wall; a crack under the pad is not; a region switched off (a sealed gate) is one.
func gargoyle_sight_on_the_navmesh() -> void:
	var trials := [["a stretch of 1.2 m with no navmesh across the line", 1.2, true, false], ["a crack of 0.5 m", 0.5, false, false], ["a gate that is shut", 0.0, false, true]]
	for t in trials:
		var gap := float(t[1])
		var c := make(268)
		hero(c, Vector2(7, 0))
		var id: int = c.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
		root(c, id)
		var verts := PackedVector3Array([Vector3(-5, 0, -6), Vector3(3, 0, -6), Vector3(3, 0, 6), Vector3(-5, 0, 6), Vector3(3 + gap, 0, -6), Vector3(12, 0, -6), Vector3(12, 0, 6), Vector3(3 + gap, 0, 6)])
		var polys := PackedInt32Array([4, 0, 1, 2, 3, 4, 4, 5, 6, 7])
		if gap == 0.0:
			verts = PackedVector3Array([Vector3(-5, 0, -6), Vector3(12, 0, -6), Vector3(12, 0, 6), Vector3(-5, 0, 6)])
			polys = PackedInt32Array([4, 0, 1, 2, 3])
		var region: int = c.nav_add_region(verts, polys, true)
		if bool(t[3]):
			c.nav_set_region_enabled(region, false)
			c.nav_add_region(PackedVector3Array([Vector3(-5, 0, -6), Vector3(-4, 0, -6), Vector3(-4, 0, 6), Vector3(-5, 0, 6)]), PackedInt32Array([4, 0, 1, 2, 3]), true)
		var log := []
		run(c, 300, log)
		var blocked := bool(t[2]) or bool(t[3])
		check(of(log, EV_TELEGRAPH, id, TELL_DIVE).is_empty() == blocked, "sight: %s %s the dive" % [t[0], "stops" if blocked else "does not stop"])


# ------------------------------------------------------------------------------------------------------------------ the templar

## What a blow from `from` costs the templar (facing +z at the start), in a fresh core: a hero, a thrall, a boss or another enemy as the source, damage 100.
func glance(from: Vector2, source := "hero", allow := true, status := "", rising := false) -> Dictionary:
	var c := make(271)
	var h := hero(c, FAR)
	var id: int = c.spawn_enemy("templar", Vector2(0, 0), 1, 100.0, 1.0, false, NAVE, rising)
	if status != "":
		c.apply_status(id, status, 0, 1.0, 100.0)
	var src := 0
	match source:
		"hero":
			src = hero(c, from)
		"thrall":
			src = thrall(c, h, from)
		"boss":
			src = c.add_external(1, 1.6, 1.0)
			c.set_external(src, from, true)
		"enemy":
			src = harmless(c, from)
	var before := float(c.enemy_info(id)["hp"])
	var log := []
	drain(c, log)
	var r: Dictionary = c.damage(id, 100.0, src, allow)
	drain(c, log)
	var info: Dictionary = c.enemy_info(id)
	return {"cost": before - float(info["hp"]), "cues": of(log, EV_CUE, id, CUE_SHIELD_BLOCK), "taken": float(info["taken_mult"]), "dealt": float(r["dealt"])}


func at_angle(deg: float, dist := 4.0) -> Vector2:
	return Vector2(sin(deg_to_rad(deg)) * dist, cos(deg_to_rad(deg)) * dist)


## TEMPLAR_SHIELD: a blow from a body within halfArcDeg of where the templar faces passes `passThrough` of its damage; the sides, the back, a Fractured shield, a blow with no
## source body or from a DoT tick (allow_stagger false) pass all of it; the damage taken once, by the base.
func templar_shield() -> void:
	var S2: Dictionary = content["TEMPLAR_SHIELD"]
	var pass_ := float(S2["passThrough"])
	var arc := float(S2["halfArcDeg"])
	var full := 100.0
	var cost := func(spec: Dictionary) -> float: return float(spec["cost"])
	check(is_equal_approx(cost.call(glance(Vector2(0, 4))), full * pass_), "shield: a blow from straight ahead costs %.0f of %.0f" % [full * pass_, full])
	check(is_equal_approx(cost.call(glance(at_angle(arc - 1.0))), full * pass_) and is_equal_approx(cost.call(glance(at_angle(-(arc - 1.0)))), full * pass_), "shield: and from %.0f degrees to either side (the arc is %.0f)" % [arc - 1.0, arc])
	check(is_equal_approx(cost.call(glance(at_angle(arc + 1.0))), full) and is_equal_approx(cost.call(glance(at_angle(-(arc + 1.0)))), full), "shield: %.0f degrees round it takes all of it" % (arc + 1.0))
	check(is_equal_approx(cost.call(glance(at_angle(90.0))), full) and is_equal_approx(cost.call(glance(at_angle(180.0))), full), "shield: and from the side or behind")
	check(is_equal_approx(cost.call(glance(Vector2(0, 0.001))), full), "shield: a blow from a body on top of it has no direction: all of it")
	check(is_equal_approx(cost.call(glance(Vector2(0, 4), "hero", false)), full), "shield: a DoT tick (allow_stagger false, undirected) ignores the shield")
	var c := make(272)
	var id: int = c.spawn_enemy("templar", Vector2(0, 0), 1, 100.0, 1.0, false, NAVE, false)
	var before := float(c.enemy_info(id)["hp"])
	c.damage(id, 100.0, 0, true)
	c.damage(id, 100.0, 9999, true)
	check(is_equal_approx(before - float(c.enemy_info(id)["hp"]), 2.0 * full), "shield: a blow with no source, or from a body that is not there, is not directed")
	var fr := glance(Vector2(0, 4), "hero", true, "fracture")
	check(is_equal_approx(fr["cost"], full * float(fr["taken"])) and float(fr["taken"]) > 1.0 and fr["cues"].is_empty(), "shield: a Fractured templar takes the whole blow x the Fracture multiplier (%.2f), once, and shows no glance" % float(fr["taken"]))
	var sa := glance(Vector2(0, 4), "hero", true, "sanctified")
	check(is_equal_approx(sa["cost"], full * pass_ * float(sa["taken"])) and float(sa["taken"]) < 1.0, "shield: and damage taken still applies after the shield: %.1f = 100 x %.1f x %.1f" % [sa["cost"], pass_, float(sa["taken"])])
	# Whoever the source is: a thrall, a boss or another enemy glances off from the front, not from behind.
	for kind in ["thrall", "boss", "enemy"]:
		check(is_equal_approx(cost.call(glance(Vector2(0, 4), kind)), full * pass_) and is_equal_approx(cost.call(glance(Vector2(0, -4), kind)), full), "shield: a %s in front is stopped, behind it is not" % kind)
	var g := glance(Vector2(0, 4))
	check(is_equal_approx(g["dealt"], full * pass_), "shield: DmCore.damage says it dealt %.0f" % float(g["dealt"]))
	# As today (the shield works before the base's refusals): a rising templar takes nothing but still glances.
	var rg := glance(Vector2(0, 4), "hero", true, "", true)
	check(is_equal_approx(rg["cost"], 0.0) and rg["cues"].size() == 1, "shield: a templar that is still rising takes nothing, and the blow still glances (as today's)")


## Each glance is a cue at the templar's place, at most one every BLOCK_FX_GAP_MS (250 ms of game time).
func templar_glance_cue() -> void:
	var gap := float(K["BLOCK_FX_GAP_MS"]) / 1000.0
	var c := make(273)
	var h := hero(c, Vector2(0, 4))
	var id: int = c.spawn_enemy("templar", Vector2(0, 0), 1, 100.0, 1.0, false, NAVE, false)
	var log := []
	drain(c, log)
	var blow := func() -> void:
		c.damage(id, 10.0, h, true)
		drain(c, log)
	blow.call()                         # clock 0: the first glance always shows
	run(c, 3, log)
	blow.call()
	run(c, 11, log)
	blow.call()                         # 14 ticks = 0.233 s: not yet
	var n := of(log, EV_CUE, id, CUE_SHIELD_BLOCK).size()
	check(n == 1, "glance: four blows in 0.23 s show one glance (%d)" % n)
	run(c, 3, log)
	blow.call()                         # 17 ticks = 0.283 s since the first: the gap is over
	var cues := of(log, EV_CUE, id, CUE_SHIELD_BLOCK)
	check(cues.size() == 2 and gap == 0.25, "glance: the next one a quarter second after the first (%d glances, gap %.2f s)" % [cues.size(), gap])
	var p: Vector2 = c.enemy_info(id)["pos"]
	check(cues.size() == 2 and is_equal_approx(cues[0]["floats"][0], p.x) and is_equal_approx(cues[0]["floats"][1], p.y) and cues[0]["floats"][2] == 0.0, "glance: at the templar's own place")


## A templar is a melee body (a robber's rules on its numbers) and its corpse is resonant.
func templar_fights() -> void:
	var d := def("templar")
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var c := make(274)
	var h := hero(c, Vector2(0, 1.2))
	var id: int = c.spawn_enemy("templar", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var log := []
	run(c, 500, log)
	var att := of(log, EV_ATTACK, id)
	var k0 := to_zero(cd0)
	check(att.size() >= 2 and int(att[0]["tick"]) == k0 and att[0]["ints"][0] == 0 and of(log, EV_TELEGRAPH, id).is_empty(), "templar: a plain swing on the tick its cooldown is up (%d), no telegraph" % k0)
	var hits := of(log, EV_HIT, id)
	check(hits.size() >= 2 and int(hits[0]["tick"]) == k0 + to_reach(windup) and hits[0]["ints"][0] == h and hits[0]["floats"][0] == float(d["damage"]), "templar: %.2f s later it hits for %d" % [windup, int(d["damage"])])
	check(att.size() >= 2 and int(att[1]["tick"]) == k0 + to_reach(windup) + to_zero(cooldown), "templar: the next swing one cooldown (%.1f s) after the blow" % cooldown)
	events(c)
	c.damage(id, 1.0e6, h, false)
	var added := of(events(c), EV_CORPSE_ADDED)
	check(added.size() == 1 and added[0]["ints"][0] == 2 and c.def_name(added[0]["ints"][1]) == "templar", "templar: it falls into a resonant corpse")


# ------------------------------------------------------------------------------------------------------------------ the wraith

## The wraith is the caster set (dm_state_kite: walk in beyond attackRange - 1.5, cast at attackRange - 0.5, back off under 3.5 m at 0.8) with a scream: a ring of SCREAM.radius at
## the place its target stood when the wind-up began, damage to everything inside (heroes and thralls) when it ends; stepping out of the ring dodges it.
func wraith_scream() -> void:
	var d := def("wraith")
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var r := float(content["SCREAM"]["radius"])
	var cast_at := float(d["attackRange"]) - 0.5      # dm_state_kite: cast at attackRange - 0.5 (pinned in nave_defs)
	for stay in [true, false]:
		var c := make(281)
		var a := hero(c, Vector2(14, 0))
		var b := hero(c, Vector2(14.0 + r - 0.05, 0))     # inside the ring, behind the target
		var o := hero(c, Vector2(14.0 + r + 0.05, 0))     # just outside it
		var th := thrall(c, a, Vector2(14, -1.9), 100.0, false)  # on its seat beside its owner (1.9 m, inside the ring); it rises, then is held
		var log := []
		run(c, to_reach(0.9) + 2, log)
		c.stun(th, 1.0e6)
		var id: int = c.spawn_enemy("wraith", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
		drain(c, log)
		var xs: Array = []
		var k0 := -1
		for i in 700:
			run(c, 1, log)
			xs.append(Vector2(c.enemy_info(id)["pos"]))
			if not of(log, EV_TELEGRAPH, id, TELL_SCREAM).is_empty():
				k0 = tick
				break
		check(k0 > 0, "scream: it casts")
		if k0 < 0:
			return
		var tell := of(log, EV_TELEGRAPH, id, TELL_SCREAM)
		var f: PackedFloat32Array = tell[0]["floats"]
		var from: Vector2 = xs[xs.size() - 2]
		check(absf(f[0] - from.x) < 1e-5 and is_equal_approx(f[2], 14.0) and is_equal_approx(f[3], 0.0) and is_equal_approx(f[4], r) and is_equal_approx(f[5], windup), "scream: song-lines from the singer to a ring of %.1f m on the target for %.2f s" % [r, windup])
		var d_start := Vector2(14, 0).distance_to(xs[xs.size() - 2])
		check(d_start <= cast_at and d_start > cast_at - float(c.enemy_info(id)["speed"]) * DT * 1.5, "scream: cast from %.2f m (attackRange - 0.5 = %.1f)" % [d_start, cast_at])
		var att := of(log, EV_ATTACK, id)
		check(att.size() == 1 and att[0]["ints"][0] == BLOW_SCREAM, "scream: the swing is a scream")
		if not stay:
			c.set_external(a, Vector2(14.0 + 4.0, 0), true)    # steps out of the ring
		var ks := k0 + to_reach(windup)
		run_to(c, ks - 1, log)
		check(of(log, EV_HIT, id).is_empty() and float(c.thrall_info(th)["hp"]) == 100.0, "scream: nothing lands before the wind-up ends")
		run_to(c, ks, log)
		var hits := of(log, EV_HIT, id)
		var got := hits.map(func(e: Dictionary) -> int: return e["ints"][0])
		got.sort()
		var want: Array = [a, b] if stay else [b]
		want.sort()
		check(got == want and hits.all(func(e: Dictionary) -> bool: return e["floats"][0] == float(d["damage"]) and e["ints"][1] == 0 and int(e["tick"]) == ks),
			"scream: %s: the ring takes the heroes inside it (%s) for %d on tick %d, not the one just outside it" % ["standing in it" if stay else "stepping out", str(got), int(d["damage"]), ks])
		check(is_equal_approx(float(c.thrall_info(th)["hp"]), 100.0 - float(d["damage"])), "scream: and a thrall inside it too (%.0f of 100 left)" % float(c.thrall_info(th)["hp"]))
		var cues := of(log, EV_CUE, id, CUE_SCREAM)
		check(cues.size() == 1 and int(cues[0]["tick"]) == ks and is_equal_approx(cues[0]["floats"][0], 14.0) and is_equal_approx(cues[0]["floats"][2], r), "scream: the cue is on the ring (not on the singer)")
		check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "scream: the cooldown is %.1f s from the blow" % cooldown)
		if stay:
			run_to(c, ks + to_zero(cooldown), log)
			var tl := of(log, EV_TELEGRAPH, id, TELL_SCREAM)
			check(tl.size() == 2 and int(tl[1]["tick"]) == ks + to_zero(cooldown), "scream: the next one a cooldown after the blow (tick %d)" % (ks + to_zero(cooldown)))
	# The wraith's state is the plain kite: silence does not stop it (the cloister casters' does).
	var e := make(282)
	hero(e, Vector2(6, 0))
	var eid: int = e.spawn_enemy("wraith", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	silence(e, eid)
	var lg := []
	run(e, 400, lg)
	check(not of(lg, EV_TELEGRAPH, eid, TELL_SCREAM).is_empty(), "scream: a silenced wraith still sings (its walk is dm_state_kite, which does not look)")


## The walk of the caster set: walk in at full speed beyond attackRange - 1.5 m, stand between, back off at 0.8 x under 3.5 m (the scream is cast on the way, at attackRange - 0.5;
## the cooldown it starts keeps the next one away while the walk is measured).
func wraith_walk() -> void:
	var d := def("wraith")
	var walk_in := float(d["attackRange"]) - 1.5
	var windup := float(d["windupMs"]) / 1000.0
	var c := make(284)
	var h := hero(c, Vector2(14.9, 0))
	var id: int = c.spawn_enemy("wraith", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var spd := float(c.enemy_info(id)["speed"])
	var log := []
	run(c, 30, log)
	var p0: Vector2 = c.enemy_info(id)["pos"]
	run(c, 1, log)
	var p1: Vector2 = c.enemy_info(id)["pos"]
	check(absf((p1.x - p0.x) - spd * DT) < 2e-4 and Vector2(14.9, 0).distance_to(p0) > walk_in, "walk: %.4f m a tick (full speed %.4f) while the target is beyond %.1f m" % [p1.x - p0.x, spd * DT, walk_in])
	for i in 400:
		run(c, 1, log)
		if not of(log, EV_TELEGRAPH, id, TELL_SCREAM).is_empty():
			break
	var ks := tick + to_reach(windup)
	run_to(c, ks + 100, log)       # the blow, the 0.3 s recovery, and the walk on from the casting range to the holding one
	var rest: Vector2 = c.enemy_info(id)["pos"]
	var dist := Vector2(14.9, 0).distance_to(rest)
	check(dist <= walk_in + 1e-3 and dist > walk_in - spd * DT * 1.5, "walk: holds at %.2f m (%.1f - one step)" % [dist, walk_in])
	run(c, 20, log)
	check(Vector2(c.enemy_info(id)["pos"]).distance_to(rest) < 1e-4 and c.enemy_info(id)["state"] == CHASE, "walk: and stands still between %.1f and %.1f m" % [float(KITE["BACK_OFF_DIST"]), walk_in])
	# The hero steps in to 2 m (the cooldown, 3.6 s from the blow, is still running): it backs off at 0.8 x its speed until 3.5 m.
	c.set_external(h, Vector2(rest.x + 2.0, rest.y), true)
	var x0 := Vector2(c.enemy_info(id)["pos"]).x
	run(c, 1, log)
	var x1 := Vector2(c.enemy_info(id)["pos"]).x
	check(absf((x0 - x1) - spd * float(KITE["BACK_OFF_SPEED"]) * DT) < 2e-4, "walk: backs off at %.1f x its speed (%.4f m a tick)" % [float(KITE["BACK_OFF_SPEED"]), x0 - x1])
	run(c, 50, log)
	var dd := Vector2(c.enemy_info(id)["pos"]).distance_to(Vector2(rest.x + 2.0, rest.y))
	check(dd >= float(KITE["BACK_OFF_DIST"]) - 1e-3 and dd < float(KITE["BACK_OFF_DIST"]) + spd * float(KITE["BACK_OFF_SPEED"]) * DT * 1.5, "walk: and stops at %.2f m (%.1f m)" % [dd, float(KITE["BACK_OFF_DIST"])])


## It leaves no corpse (def corpse none), where a robber leaves one; the crowd thins it to mist.
func wraith_no_corpse() -> void:
	var c := make(285)
	var h := hero(c, FAR)
	var w: int = c.spawn_enemy("wraith", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var r := harmless(c, Vector2(4, 0))
	events(c)
	c.damage(w, 1.0e6, h, false)
	check(of(events(c), EV_CORPSE_ADDED).is_empty() and c.corpse_count() == 0, "wraith: it dies without a corpse")
	c.damage(r, 1.0e6, h, false)
	check(c.corpse_count() == 1, "wraith: (a robber beside it leaves one)")


# ------------------------------------------------------------------------------------------------------------------ the Nave on the wire

## A guest sees each kind's telegraphs, cues and statuses: the dive (bit 5 of the record), the scream, the curse, Unbind's cue and its Risen, the shield's glance and the incense.
func nave_on_the_wire() -> void:
	# The Gargoyle's dive.
	var d := def("gargoyle")
	var windup := float(d["windupMs"]) / 1000.0
	var radius := float(d["dive"]["radius"])
	var host := make(291)
	host.set_replication(true)
	hero(host, Vector2(7, 0))
	var id: int = host.spawn_enemy("gargoyle", Vector2(0, 0), 3, 2.0, 1.5, false, NAVE, false)
	root(host, id)
	var guest := puppet()
	var hl := []
	var gl := []
	var t := join(host, guest, hl, gl)
	var k0 := to_zero(float(host.enemy_info(id)["attack_cd"]))
	t = lockstep(host, guest, hl, gl, t, k0 + 12)
	var ht := of(hl, EV_TELEGRAPH, id, TELL_DIVE)
	var gt := of(gl, EV_TELEGRAPH, id, TELL_DIVE)
	check(ht.size() == 1 and gt.size() == 1, "wire: the guest sees the dive's telegraph once (host %d, guest %d)" % [ht.size(), gt.size()])
	if gt.size() == 1:
		var f: PackedFloat32Array = gt[0]["floats"]
		check(absf(f[2] - 7.0) < 0.02 and absf(f[3]) < 0.02 and is_equal_approx(f[4], radius) and f[5] >= 0.05 and f[5] <= windup + 1e-4, "wire: aimed at the mark, %.0f m wide, for what is left of the %.1f s (%.2f s)" % [radius, windup, f[5]])
		check(int(gt[0]["tick"]) - int(ht[0]["tick"]) <= 6, "wire: within two snapshots of the host's (%d ticks later)" % (int(gt[0]["tick"]) - int(ht[0]["tick"])))
	check(bool(guest.enemy_info(id)["diving"]) and of(gl, EV_ATTACK, id).size() == 1 and of(gl, EV_ATTACK, id)[0]["ints"][0] == BLOW_DIVE, "wire: and its body is diving on the guest, a dive swing")
	var ks := k0 + to_reach(windup)
	t = lockstep(host, guest, hl, gl, t, ks + 30)
	var pos_h: Vector2 = host.enemy_info(id)["pos"]
	var pos_g: Vector2 = guest.enemy_info(id)["pos"]
	check(pos_h.distance_to(Vector2(7, 0)) < 1e-4 and pos_g.distance_to(pos_h) < 0.35, "wire: the guest's body has come down onto the mark with it (%.2f m apart)" % pos_g.distance_to(pos_h))
	check(bool(guest.enemy_info(id)["diving"]) and of(hl, EV_CUE, id, CUE_SLAM).size() == 1 and of(gl, EV_CUE, id, CUE_SLAM).size() == 1, "wire: grounded, still diving on both, and the slam cue reached the guest once")
	check(of(hl, EV_HIT, id).size() >= 1 and of(gl, EV_HIT).is_empty(), "wire: the blow on the hero is the host's alone")
	var ke := ks + to_reach(float(K["RECOVER_TIME"]) + float(d["dive"]["groundedS"]))
	t = lockstep(host, guest, hl, gl, t, ke + 10)
	check(not bool(guest.enemy_info(id)["diving"]) and not bool(host.enemy_info(id)["diving"]), "wire: and when it hunts again neither is diving")
	# A bite is not a dive on the guest.
	var h2 := make(292)
	h2.set_replication(true)
	hero(h2, Vector2(1.2, 0))
	var bid: int = h2.spawn_enemy("gargoyle", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var g2 := puppet()
	var hl2 := []
	var gl2 := []
	t = join(h2, g2, hl2, gl2)
	lockstep(h2, g2, hl2, gl2, t, to_zero(float(h2.enemy_info(bid)["attack_cd"])) + 20)
	check(of(gl2, EV_TELEGRAPH, bid).is_empty() and of(gl2, EV_ATTACK, bid).size() == 1 and of(gl2, EV_ATTACK, bid)[0]["ints"][0] == 0, "wire: a bite reaches the guest as a plain swing, with no telegraph")
	# The wraith's scream and the cue on the ring.
	var wd := def("wraith")
	var w := make(293)
	w.set_replication(true)
	hero(w, Vector2(6, 0))
	var wid: int = w.spawn_enemy("wraith", Vector2(0, 0), 1, 1.0, 1.0, false, NAVE, false)
	var wg := puppet()
	var wl := []
	var wgl := []
	t = join(w, wg, wl, wgl)
	var wk := to_zero(float(w.enemy_info(wid)["attack_cd"]))
	lockstep(w, wg, wl, wgl, t, wk + to_reach(float(wd["windupMs"]) / 1000.0) + 20)
	var st := of(wgl, EV_TELEGRAPH, wid, TELL_SCREAM)
	check(st.size() == 1 and of(wl, EV_TELEGRAPH, wid, TELL_SCREAM).size() == 1 and absf(st[0]["floats"][4] - float(content["SCREAM"]["radius"])) < 1e-5 and of(wgl, EV_ATTACK, wid)[0]["ints"][0] == BLOW_SCREAM,
		"wire: the scream's ring reaches the guest once, %.1f m wide" % (st[0]["floats"][4] if st.size() > 0 else -1.0))
	check(of(wgl, EV_CUE, wid, CUE_SCREAM).size() == 1, "wire: and its cue")
	# The acolyte's curse, Unbind's cue and the Risen it raised.
	var a := make(294)
	a.set_replication(true)
	var ah := hero(a, Vector2(5, 0))
	var ac := spawn_acolyte(a, Vector2(0, 0), 4, 2.0, 1.5)
	var th := thrall(a, ah, Vector2(-6, 0))      # (farther from the acolyte than the hero is, so that the hero is its target)
	var ag := puppet()
	var al := []
	var agl := []
	t = join(a, ag, al, agl)
	var ak := to_zero(float(a.enemy_info(ac)["attack_cd"]))
	t = lockstep(a, ag, al, agl, t, ak + 12)
	var ct := of(agl, EV_TELEGRAPH, ac, TELL_CURSE)
	check(ct.size() == 1 and of(al, EV_TELEGRAPH, ac, TELL_CURSE).size() == 1 and absf(ct[0]["floats"][2] - 5.0) < 0.02 and of(agl, EV_ATTACK, ac)[0]["ints"][0] == BLOW_CURSE, "wire: the curse's ring reaches the guest once, on the target")
	a.kill_thrall(th, "killed")
	t = lockstep(a, ag, al, agl, t, t + to_zero(1.0) + 12)
	var uc := of(agl, EV_CUE, ac, CUE_UNBIND)
	var risen_h := of(al, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return a.def_name(e["ints"][0]) == "risen")
	var risen_g := of(agl, EV_SPAWNED).filter(func(e: Dictionary) -> bool: return ag.def_name(e["ints"][0]) == "risen")
	check(uc.size() == 1 and absf(uc[0]["floats"][0] + 6.0) < 1e-4, "wire: Unbind's cue reaches the guest once, at the thrall's place")
	check(risen_h.size() == 1 and risen_g.size() == 1 and risen_g[0]["id"] == risen_h[0]["id"] and risen_g[0]["ints"][1] == 4, "wire: and so does the Risen, with the host's id and the acolyte's level")
	# The templar's glance, the censer's incense.
	var s := make(295)
	s.set_replication(true)
	var sh := hero(s, Vector2(0, 4))
	var tid: int = s.spawn_enemy("templar", Vector2(0, 0), 1, 100.0, 1.0, false, NAVE, false)
	var cid: int = s.spawn_enemy("censer", Vector2(8, 0), 1, 1.0, 0.0, false, NAVE, false)
	var rb := harmless(s, Vector2(10, 0))
	var sg := puppet()
	var sl := []
	var sgl := []
	t = join(s, sg, sl, sgl)
	s.damage(tid, 10.0, sh, true)
	drain(s, sl)
	t = lockstep(s, sg, sl, sgl, t, t + 12)
	check(of(sl, EV_CUE, tid, CUE_SHIELD_BLOCK).size() == 1 and of(sgl, EV_CUE, tid, CUE_SHIELD_BLOCK).size() == 1, "wire: the shield's glance reaches the guest once")
	check(s.status_stacks(rb, "incensed") == 1.0 and sg.status_stacks(rb, "incensed") == 1.0 and sg.status_stacks(cid, "incensed") == 1.0 and is_equal_approx(float(sg.enemy_info(rb)["speed_mult"]), float(content["CENSER"]["moveMult"])),
		"wire: and the censer's incense is on the guest's bodies too, with its multipliers")
	# A guest that does not know the dive, or the scream, refuses the host's messages (the defs and the numbers are in the content hash).
	for change in [["gargoyle", "dive radius"], ["wraith", "scream radius"], ["acolyte", "attack"], ["templar", "shield"]]:
		var odd: RefCounted = ClassDB.instantiate("DmCore")
		var defs: Dictionary = content["ENEMIES"].duplicate(true)
		var tun_content: Dictionary = content.duplicate(true)
		match String(change[1]):
			"dive radius":
				defs["gargoyle"]["dive"]["radius"] = 3.0
			"scream radius":
				tun_content["SCREAM"]["radius"] = 3.0
			"attack":
				defs["acolyte"]["attack"] = "cone"
			"shield":
				defs["templar"].erase("shield")
		odd.load_enemy_defs(defs)
		odd.load_tuning(tun_content)
		odd.load_status_defs(DmStatusRules.build(DmCoreData.json(godot_dir.path_join("data/content/abilities.json")), statuses, content))
		odd.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
		odd.set_puppet(true)
		check(not odd.apply_snapshot(s.snapshot(900)) and "data" in str(odd.replication_error()), "wire: a guest with another %s of the %s refuses the host's snapshot (%s)" % [change[1], change[0], odd.replication_error()])


# ------------------------------------------------------------------------------------------------------------------ the roster and a replay

## The whole Nave roster (its enemy table and its procession themes, lead included) is made by the core, the models are drawn by the crowd, and a seeded run replays event for event.
func the_nave_roster_and_a_replay() -> void:
	var areas := DmCoreData.json(godot_dir.path_join("data/content/areas.json"))
	var ids := {}
	for e in areas["AREAS"]["nave"]["enemies"]:
		ids[String(e["id"])] = true
	for th in content["WAVE_THEMES"]["nave"]:
		for e in th["roster"]:
			ids[String(e["id"])] = true
		if th.get("lead") != null:
			ids[String(th["lead"])] = true
	var missing := []
	for id: String in ids:
		if not DmWaveDirector.runs_on_core(id):
			missing.append(id)
	var all_five := true
	for id in NAVE_KINDS:
		all_five = all_five and ids.has(id)
	check(all_five and missing.is_empty(), "roster: every kind of the Nave's waves and processions runs on the core (%d kinds, missing %s)" % [ids.size(), str(missing)])
	var looks := DmCoreData.json("res://crowd/crowd_looks.json")
	var drawn := true
	for id in NAVE_KINDS:
		var slug := String(looks["enemy_model"].get(id, ""))
		var path := "res://assets/slice/models/props/%s.glb" % slug if id == "wraith" else "res://assets/slice/models/%s/character.glb" % slug
		drawn = drawn and slug != "" and FileAccess.file_exists(path)
	check(drawn and looks["casters"].has("acolyte") and looks["casters"].has("wraith") and looks["casters"].has("censer") and not looks["casters"].has("templar") and not looks["casters"].has("gargoyle"),
		"roster: the crowd draws them (their models; the acolyte, wraith and censer as casters)")
	check(looks["mist"].has("wraith") and is_equal_approx(float(looks["hover"]["wraith"]), float(K["HOVER"])) and float(def("gargoyle")["flying"]) == 1.1, "roster: the wraith hovers %.2f m and thins to mist, the gargoyle flies at %.1f m" % [float(K["HOVER"]), float(def("gargoyle")["flying"])])
	# The director can leave a def out as if it had no scene (the parity scenario drops the Bellringers' censer, as today's side does).
	var dir := DmWaveDirector.new()
	dir.off["censer"] = true
	check(dir.makes("deacon") and dir.makes("wraith") and not dir.makes("censer") and DmWaveDirector.runs_on_core("censer") and not dir.makes("seraph"), "roster: the director's `off` leaves the censer out; the core still runs it")
	dir.free()
	var logs := []
	for round in 2:
		var c := make(301)
		var h1 := hero(c, Vector2(0, 0))
		hero(c, Vector2(2, -3))
		thrall(c, h1, Vector2(-2, 2), 400.0)
		thrall(c, h1, Vector2(3, 3), 400.0)
		c.spawn_enemy("censer", Vector2(9, 3), 4, 1.5, 1.2, false, NAVE, false)
		c.spawn_enemy("acolyte", Vector2(-10, 4), 4, 1.5, 1.2, true, NAVE, false)
		c.spawn_enemy("gargoyle", Vector2(-9, -8), 4, 1.5, 1.2, false, NAVE, false)
		c.spawn_enemy("templar", Vector2(8, -9), 4, 1.5, 1.2, false, NAVE, false)
		c.spawn_enemy("wraith", Vector2(12, 11), 4, 1.5, 1.2, false, NAVE, false)
		for i in 6:
			c.spawn_enemy("robber" if i % 2 == 0 else "hound", Vector2(12 - i * 4, 13), 4, 1.5, 1.2, false, NAVE, false)
		var rec := PackedInt32Array()
		var recf := PackedFloat32Array()
		for i in 1800:
			c.step(DT)
			var raw: Array = c.take_events()
			rec.append_array(raw[0])
			recf.append_array(raw[1])
			if i == 400:
				for id in c.enemy_ids():
					if c.enemy_info(id)["def"] == "robber":
						c.damage(id, 25.0, 0, true)
			if i == 700:
				for tid in c.thrall_ids():
					c.kill_thrall(tid, "killed")
		logs.append([rec, recf, c.enemy_count(), c.corpse_count()])
	check(logs[0][0] == logs[1][0] and logs[0][1] == logs[1][1] and logs[0][0].size() > 300, "replay: a seeded fight of the Nave's five kinds and a crowd replays event for event (%d ints)" % logs[0][0].size())
