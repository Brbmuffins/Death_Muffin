extends SceneTree
## The kinds the other areas add to the combat core, against today's rules (godot/enemies): so far the Marrow Ossuary's two, the Bone Golem and the
## Crypt Deacon, the Drowned Nave's five, the Censer Bearer, Lich Acolyte, Belfry Gargoyle, Bell-Sworn Templar and Choir Wraith, the Sanctum's and Cloister's three and the Cinder Pyre's
## and the Mourning Fen's eight (each later group's section opens with its own banner, at the end of the file). Later area groups append their kinds here.
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
## The Sanctum's and Cloister's three (a section per kind, after the Nave's):
##   - the seraph (dm_enemy_clst_seraph.gd, dm_state_clst_kite.gd): the Deacon's walk with its own numbers, the curse (the acolyte's), and the ward: the tick it fires on (the cooldown the last
##     tick left), who is a candidate (range, the fallen, the rising and the underground, the blessed, a body of its own kind, the unhurt), who is picked (the most wounded, up to maxTargets, ties
##     as Godot's own sort_custom leaves them, checked against the engine's on random lists up to 100 bodies), the cue and the status, the cooldown it spends, the retry, silence, a stun, and
##     the curse that comes first when a target is in reach;
##   - the plague doctor (dm_enemy_clst_caster.gd, attack flask): the caster set's silence-aware walk, the flask (the ring at the aim fixed at the wind-up, who it reaches, the damage kind toxic),
##     the toxic pool it leaves (radius, seconds, pulses, damage a pulse), a stun, an elite, the toxic corpse;
##   - the flagellant (flagellant.tscn, the plain dm_enemy.gd): frenzy below half health (the status, the factors, the tick it starts on), the quicker blows and feet, a melee body otherwise;
##   - the wire (the flask's ring and pool, the ward's cues and blessings, the frenzy), the rosters of the Sanctum, the Coliseum and the Cloister, and a seeded replay.
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
	fen = DmCoreData.json(godot_dir.path_join("data/content/fen.json"))
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
	cloister_setup()
	cloister_defs()
	seraph_walk()
	seraph_curse()
	seraph_ward()
	seraph_ward_gates()
	seraph_ward_cadence()
	seraph_ward_ties()
	seraph_ward_sort_matches_godot()
	plague_walk()
	plague_flask()
	plague_flask_edges()
	plague_pool()
	plague_corpse_and_elite()
	flagellant_frenzy()
	flagellant_blows()
	cloister_on_the_wire()
	cloister_rosters_and_a_replay()
	pf_names_defs_and_numbers()
	husk_embers()
	husk_melee()
	priest_coal()
	priest_walk()
	hound_and_leech()
	slag_slam_and_pool()
	hag_hex()
	hag_aim()
	wisp_pulse()
	wisp_lure()
	sexton_chain()
	sexton_pull_limits()
	sexton_gates()
	sexton_slam_and_corpses()
	sexton_hexed()
	pf_stun_cancels()
	pf_on_the_wire()
	pf_roster_and_a_replay()
	keep.clear()
	if fails == 0:
		print("PASS core_kinds %d checks" % checks)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ names

## The tables GDScript decodes events with end in the new names, append only, and the scripts' constants are the ones this suite reads.
func names_and_tables() -> void:
	check(DmCoreEvents.TELLS.size() >= 9 and DmCoreEvents.TELLS[TELL_SLAM] == &"slam" and DmCoreEvents.TELLS[TELL_RAISE] == &"raise" and DmCoreEvents.TELLS[TELL_CURSE] == &"curse"
		and DmCoreEvents.TELLS[TELL_SCREAM] == &"scream" and DmCoreEvents.TELLS[TELL_DIVE] == &"dive", "the telegraph names: raise and curse appended after toll, then scream and dive (append only)")
	check(DmCoreEvents.CUES.size() >= 7 and DmCoreEvents.CUES[CUE_SLAM] == &"slam" and DmCoreEvents.CUES[CUE_SANCTIFY] == &"sanctify" and DmCoreEvents.CUES[CUE_SHIELD_BLOCK] == &"shield_block"
		and DmCoreEvents.CUES[CUE_UNBIND] == &"unbind" and DmCoreEvents.CUES[CUE_SCREAM] == &"scream", "the cue names: sanctify appended after dig_in, then shield_block, unbind and scream")
	check(DmCoreEvents.BLOWS.size() >= 7 and DmCoreEvents.BLOWS[BLOW_SLAM] == &"slam" and DmCoreEvents.BLOWS[BLOW_CURSE] == &"curse" and DmCoreEvents.BLOWS[BLOW_SCREAM] == &"scream"
		and DmCoreEvents.BLOWS[BLOW_DIVE] == &"dive", "the blow names: curse, scream and dive appended after slam")
	check(K.has("CORPSE_RANGE") and K.has("BACK_OFF_DIST") and K.has("BACK_OFF_SPEED") and K.has("SCAN_S") and K.has("STRIKE_REACH_MULT") and K.has("EXTRA_RING"),
		"the scripts' own constants are read (%s)" % str(K.keys()))
	var c := make()
	check(String(c.version()) == "dmcore 0.13", "the core's version names this step")
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
	check(dir.makes("deacon") and dir.makes("wraith") and not dir.makes("censer") and DmWaveDirector.runs_on_core("censer") and dir.makes("seraph"), "roster: the director's `off` leaves the censer out; the core still runs it")
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


# ================================================================================================================== the Sanctum's and Cloister's three
#
# The Weeping Seraph (godot/enemies/kinds/dm_enemy_clst_seraph.gd on DmEnemyClstCaster, walking with dm_state_clst_kite.gd), the Plague Doctor (dm_enemy_clst_caster.gd, attack "flask") and the
# Flagellant (flagellant.tscn: the plain dm_enemy.gd, and the status set's frenzy). Numbers come from enemies.json (WARD, PLAGUE_FLASK, FRENZY) and the scripts' const lines; the expected ticks
# from mirrors of the scripts' arithmetic.

const SANCTUM := "sanctum"
const CLOISTER := "cloister"
const COLISEUM := "coliseum"
const CLOISTER_KINDS: Array[String] = ["seraph", "flagellant", "plague_doctor"]
const SERAPH_KITE: Array[float] = [0.0, 0.5, 4.0, 0.7]   ## dm_enemy_clst_seraph.gd kite_params(): cast pad, near pad, back-off distance, back-off speed (pinned against the file)
const BLOW_FLASK := 7
const TELL_FLASK := 9
const CUE_FLASK := 7
const HK_TOXIC := 1
const ZONE_TOXIC := 1
const EV_ZONE := 10
const EV_ZONE_PULSE := 11
const EV_ZONE_GONE := 12
const CK_TOXIC := 3
const CK_RESONANT := 2

var KS: Dictionary    ## dm_enemy_clst_seraph.gd's const lines (WARD_RETRY_S)
var W: Dictionary     ## enemies.json WARD
var PF: Dictionary    ## enemies.json PLAGUE_FLASK
var FR: Dictionary    ## enemies.json FRENZY


func cloister_setup() -> void:
	KS = DmCoreData.consts(godot_dir, ["enemies/kinds/dm_enemy_clst_seraph.gd"])
	W = content["WARD"]
	PF = content["PLAGUE_FLASK"]
	FR = content["FRENZY"]


func spawn_seraph(c: RefCounted, at: Vector2, level := 1, hp_mult := 1.0, dmg_mult := 1.0, elite := false, rising := false) -> int:
	return c.spawn_enemy("seraph", at, level, hp_mult, dmg_mult, elite, SANCTUM, rising)


func spawn_doctor(c: RefCounted, at: Vector2, level := 1, hp_mult := 1.0, dmg_mult := 1.0, elite := false) -> int:
	return c.spawn_enemy("plague_doctor", at, level, hp_mult, dmg_mult, elite, CLOISTER, false)


## An ally for the ward: a robber that does no damage and stays where it is.
func ally(c: RefCounted, at: Vector2, wounded := 0.0, def_id := "robber", rising := false) -> int:
	var id: int = c.spawn_enemy(def_id, at, 1, 1.0, 0.0, false, SANCTUM, rising)
	if wounded > 0.0:
		wound(c, id, wounded)
	return id


## The ticks the seraph's ward fires on, from the cooldown it spawned with: the check comes before the base's tick, so it sees the cooldown the last tick left (one tick after it reached
## 0), spends `cooldown`, and that tick's own share still comes off it.
func ward_ticks(cd0: float, cooldown: float, n: int) -> Array:
	var out := []
	var t := to_zero(cd0) + 1
	for i in n:
		out.append(t)
		t += to_zero(cooldown - DT) + 1
	return out


func cloister_defs() -> void:
	var el: Dictionary = content["ELITE"]
	for id in CLOISTER_KINDS:
		var d := def(id)
		var c := make(401)
		hero(c, FAR)
		var e: int = c.spawn_enemy(id, Vector2(0, 0), 6, 2.0, 1.5, false, SANCTUM, false)
		var info: Dictionary = c.enemy_info(e)
		check(is_equal_approx(info["max_hp"], float(d["hp"]) * 2.0) and is_equal_approx(info["damage"], float(d["damage"]) * 1.5) and info["radius"] == float(d["radius"])
			and is_equal_approx(info["windup_s"], float(d["windupMs"]) / 1000.0) and info["level"] == 6 and info["area"] == SANCTUM,
			"%s: hp, damage, radius and wind-up from the def, the spawn's multipliers and level" % id)
		var spd := float(info["speed"])
		check(spd >= float(d["speed"]) * 0.92 - 1e-6 and spd <= float(d["speed"]) * 1.08 + 1e-6, "%s: speed %.2f within the +-8%% roll of %.1f" % [id, spd, float(d["speed"])])
		var ee: int = c.spawn_enemy(id, Vector2(5, 5), 1, 1.0, 1.0, true, SANCTUM, false)
		var ei: Dictionary = c.enemy_info(ee)
		check(is_equal_approx(ei["max_hp"], float(d["hp"]) * float(el["hpMult"])) and is_equal_approx(ei["windup_s"], float(d["windupMs"]) / 1000.0 * ELITE_WINDUP) and is_equal_approx(ei["damage"], float(d["damage"]) * float(el["damageMult"])),
			"%s: an elite has x%.1f health, x%.1f damage and a x%.2f wind-up" % [id, float(el["hpMult"]), float(el["damageMult"]), ELITE_WINDUP])
	var t: Dictionary = make().tuning()
	check(t["WARD.range"] == float(W["range"]) and t["WARD.maxTargets"] == float(W["maxTargets"]) and t["PLAGUE_FLASK.radius"] == float(PF["radius"]) and t["PLAGUE_FLASK.poolS"] == float(PF["poolS"])
		and t["PLAGUE_FLASK.poolDpsMult"] == float(PF["poolDpsMult"]), "the Cloister's numbers are enemies.json's: WARD (range %.1f, %d targets), PLAGUE_FLASK (radius %.1f, pool %.0f s, x%.2f)" % [float(W["range"]), int(W["maxTargets"]), float(PF["radius"]), float(PF["poolS"]), float(PF["poolDpsMult"])])
	# The scripts' own numbers: the seraph's walk is [0, 0.5, 4, 0.7] on the cloister casters' state, which is the Deacon's state with other names; the plague doctor walks as the acolyte does.
	var seraph_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/kinds/dm_enemy_clst_seraph.gd"))
	var kite_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/states/dm_state_clst_kite.gd"))
	var support_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/states/dm_state_cath_support.gd"))
	var caster_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/kinds/dm_enemy_clst_caster.gd"))
	check(seraph_src.contains("return [0.0, 0.5, 4.0, 0.7]") and seraph_src.contains("attack_kind = \"curse\"") and KS.has("WARD_RETRY_S") and float(KS["WARD_RETRY_S"]) == 0.25,
		"the seraph's script: walk [0, 0.5, 4, 0.7], the curse as its blow, a retry of %.2f s" % float(KS.get("WARD_RETRY_S", -1.0)))
	check(kite_src.contains("if d <= enemy.attack_range - cast_pad and enemy.attack_cd <= 0.0 and not silenced():") and kite_src.contains("if d > enemy.attack_range - near_pad:") and kite_src.contains("elif d < back_dist:")
		and support_src.contains("if enemy.attack_cd <= 0.0 and d <= enemy.attack_range and not (enemy as DmEnemyDeacon).silenced():") and support_src.contains("if d > enemy.attack_range - 0.5:") and support_src.contains("elif d < BACK_OFF_DIST:")
		and float(K["BACK_OFF_DIST"]) == SERAPH_KITE[2] and float(K["BACK_OFF_SPEED"]) == SERAPH_KITE[3],
		"the seraph's walk [cast at attackRange, walk in beyond - 0.5, back off under 4 m at 0.7] is the Deacon's keep-away (dm_state_cath_support.gd), one body of code for both")
	check(caster_src.contains("return [0.5, 1.5, 3.5, 0.8]") and caster_src.contains("CLST_FALLBACK") and caster_src.contains("elif attack_kind == \"curse\":") and caster_src.contains("if attack_kind == \"flask\":"),
		"the plague doctor's script: the caster set's walk [0.5, 1.5, 3.5, 0.8] and the flask as its blow")
	var flag_scene: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/flagellant.tscn"))
	var ge: Dictionary = def("flagellant")
	check(not flag_scene.contains("script =") and flag_scene.contains("def_id = \"flagellant\"") and bool(ge.get("frenzy", false)) and String(ge["behavior"]) == "melee" and ge.get("attack") == null,
		"the flagellant is the plain base (no script of its own): a melee body whose def says frenzy")
	check(float(FR["atFrac"]) == 0.5 and float(FR["moveMult"]) == 1.45 and float(FR["attackRateMult"]) == 1.6, "frenzy: below %.0f%% health, x%.2f feet, x%.1f blows (enemies.json FRENZY)" % [float(FR["atFrac"]) * 100.0, float(FR["moveMult"]), float(FR["attackRateMult"])])
	check(DmCoreEvents.TELLS.size() >= 10 and DmCoreEvents.TELLS[TELL_FLASK] == &"flask" and DmCoreEvents.CUES.size() >= 8 and DmCoreEvents.CUES[CUE_FLASK] == &"flask" and DmCoreEvents.BLOWS.size() >= 8 and DmCoreEvents.BLOWS[BLOW_FLASK] == &"flask",
		"flask is a telegraph, a cue and a blow, appended after dive, scream and dive (append only)")


# ------------------------------------------------------------------------------------------------------------------ the seraph: walking, the curse

## The walk (dm_state_clst_kite with [0, 0.5, 4, 0.7]): walk in beyond attackRange - 0.5, cast at attackRange, back off under 4 m at 0.7 x. Silenced here so that nothing else moves it.
func seraph_walk() -> void:
	var d := def("seraph")
	var range_ := float(d["attackRange"])
	var cast_at := range_ - SERAPH_KITE[0]
	var walk_in := range_ - SERAPH_KITE[1]
	var back := SERAPH_KITE[2]
	var back_speed := SERAPH_KITE[3]
	var c := make(411)
	var h := hero(c, Vector2(12, 0))
	var id := spawn_seraph(c, Vector2(0, 0))
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
	check(step_ok, "seraph: walks in at full speed (%.2f m/s) while the target is farther than %.1f m" % [spd, walk_in])
	run(c, 60, log)
	var rest: Vector2 = c.enemy_info(id)["pos"]
	var dist := Vector2(12, 0).distance_to(rest)
	check(dist <= walk_in + 1e-3 and dist > walk_in - spd * DT * 1.5, "seraph: stops %.2f m from the target (%.1f - one step)" % [dist, walk_in])
	run(c, 60, log)
	var yaw := float(c.enemy_info(id)["yaw"])
	check(Vector2(c.enemy_info(id)["pos"]).distance_to(rest) < 1e-4 and c.enemy_info(id)["state"] == CHASE and of(log, EV_ATTACK, id).is_empty() and absf(angle_difference(yaw, atan2(12.0 - rest.x, 0.0 - rest.y))) < 0.02,
		"seraph: stands still, facing the target, between %.0f and %.1f m; silenced it never casts" % [back, walk_in])
	c.set_external(h, Vector2(rest.x + 2.0, rest.y), true)
	var from := Vector2(c.enemy_info(id)["pos"]).x
	run(c, 1, log)
	var x1 := Vector2(c.enemy_info(id)["pos"]).x
	check(absf((from - x1) - spd * back_speed * DT) < 2e-4, "seraph: backs off at %.1f x its speed (%.4f m a tick)" % [back_speed, from - x1])
	run(c, 200, log)
	var d2 := Vector2(c.enemy_info(id)["pos"]).distance_to(Vector2(rest.x + 2.0, rest.y))
	check(d2 >= back - 1e-3 and d2 < back + spd * back_speed * DT * 1.5, "seraph: stops backing off at %.2f m (%.1f m)" % [d2, back])
	# The cast gate: rooted, so it cannot close in; a target on attackRange is cast at, one 2 cm past it is not.
	for trial in [[cast_at, true], [cast_at + 0.02, false]]:
		var e := make(412)
		hero(e, Vector2(float(trial[0]), 0))
		var eid := spawn_seraph(e, Vector2(0, 0))
		root(e, eid)
		var lg := []
		run(e, 600, lg)
		check(of(lg, EV_ATTACK, eid).is_empty() == (not bool(trial[1])), "seraph: a target %.2f m away is %s (it casts at attackRange - %.1f = %.1f m)" % [float(trial[0]), "cast at" if trial[1] else "not cast at", SERAPH_KITE[0], cast_at])


## The curse is the acolyte's (dm_enemy_clst_caster.gd): the telegraph ring on the target, windupMs later a blow of the def's damage, kind curse, on the CURRENT target within the sim's reach
## of the body; the cooldown starts at the blow. With a target in reach the curse comes first: the ward never gets the cooldown.
func seraph_curse() -> void:
	var d := def("seraph")
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var reach := float(d["attackRange"]) * float(K["STRIKE_REACH_MULT"]) + float(K["STRIKE_REACH_PAD"])
	var c := make(421)
	var h := hero(c, Vector2(5, 0))
	var id := spawn_seraph(c, Vector2(0, 0))
	var friend := ally(c, Vector2(-3, 0))     # unhurt, in range: a candidate for the ward all the same
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var log := []
	run(c, 1500, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_CURSE)
	var att := of(log, EV_ATTACK, id)
	check(tell.size() >= 3 and att.size() >= 3, "seraph: a curse telegraph and a swing, over and over (%d)" % tell.size())
	if tell.size() < 3:
		return
	var k0 := int(tell[0]["tick"])
	check(k0 == to_zero(cd0), "seraph: the first curse comes on the tick the cooldown is up (tick %d)" % k0)
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[2], 5.0) and is_equal_approx(f[3], 0.0) and f[4] == 0.0 and is_equal_approx(f[5], windup), "seraph: the ring is on the target and lasts the wind-up (%.2f s)" % f[5])
	check(att[0]["ints"][0] == BLOW_CURSE and is_equal_approx(att[0]["floats"][2], windup), "seraph: the swing is a curse")
	var ks := k0 + to_reach(windup)
	var hits := of(log, EV_HIT, id)
	check(hits.size() >= 1 and int(hits[0]["tick"]) == ks and hits[0]["ints"][0] == h and hits[0]["ints"][1] == HK_CURSE and hits[0]["floats"][0] == float(d["damage"]),
		"seraph: the blow lands %d ticks (%.2f s) later for %d, kind curse, on the target" % [ks - k0, windup, int(d["damage"])])
	check(int(tell[1]["tick"]) == ks + to_zero(cooldown), "seraph: the next one a cooldown (%.1f s) after the blow (tick %d)" % [cooldown, int(tell[1]["tick"])])
	check(of(log, EV_CUE, id).is_empty() and c.status_stacks(friend, "sanctified") == 0.0, "seraph: with a target in reach the ward never gets its cooldown: nobody was blessed in 25 s, three curses")
	# The reach is measured at the blow, from the body (the acolyte's rule).
	for trial in [[reach - 0.2, true], [reach + 0.2, false]]:
		var e := make(422)
		var hh := hero(e, Vector2(5, 0))
		var did := spawn_seraph(e, Vector2(0, 0))
		var lg := []
		for i in 700:
			run(e, 1, lg)
			if not of(lg, EV_TELEGRAPH, did, TELL_CURSE).is_empty():
				break
		var p: Vector2 = e.enemy_info(did)["pos"]
		e.set_external(hh, Vector2(p.x + float(trial[0]), p.y), true)
		var rest := []
		run(e, to_reach(windup) + 2, rest)
		check(of(rest, EV_HIT, did).size() == (1 if trial[1] else 0), "seraph: a target %.2f m away at the blow is %s (the reach is %.3f m)" % [float(trial[0]), "cursed" if trial[1] else "missed", reach])
	# Silence holds the curse back, a stun cancels it.
	var s := make(423)
	hero(s, Vector2(5, 0))
	var sid := spawn_seraph(s, Vector2(0, 0))
	silence(s, sid)
	var sl := []
	run(s, 600, sl)
	check(of(sl, EV_ATTACK, sid).is_empty() and s.enemy_info(sid)["state"] == CHASE, "seraph: a silenced seraph does not cast in 10 s, with the target in reach")
	check(s.remove_status(sid, "silence"), "seraph: silence lifts")
	run(s, 1, sl)
	check(first_tick(state_edges(sl, sid, ATTACK)) == tick and of(sl, EV_TELEGRAPH, sid, TELL_CURSE).size() == 1, "seraph: the curse starts on the next tick (the cooldown was up)")
	run(s, 20, sl)
	s.stun(sid, 2.0)
	drain(s, sl)
	run(s, to_reach(windup) + 4, sl)
	check(of(sl, EV_HIT, sid).is_empty() and s.enemy_info(sid)["state"] == HURT, "seraph: a stun in the wind-up cancels the curse (nothing lands)")


# ------------------------------------------------------------------------------------------------------------------ the seraph: the ward

## The ward: when the cooldown (seen as the last tick left it) is up and the body is neither winding up, flinching, fallen nor rising and not silenced, it blesses the WARD.maxTargets most wounded
## living bodies within WARD.range that are not blessed already: the status `sanctified`, a cue each, the cooldown spent.
func seraph_ward() -> void:
	var d := def("seraph")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var S2: Dictionary = statuses["SANCTIFIED"]
	var rng_ := float(W["range"])
	var c := make(431)
	hero(c, FAR)
	var id := spawn_seraph(c, Vector2(0, 0))
	wound(c, id, 0.99)       # (itself: the most wounded of all, and still not a candidate)
	var ring := []
	var wounds := [0.10, 0.50, 0.30, 0.70, 0.20, 0.60]      # health fractions 0.9 0.5 0.7 0.3 0.8 0.4
	for k in 6:
		var a := float(k) * TAU / 6.0
		ring.append(ally(c, Vector2(3.0 * cos(a), 3.0 * sin(a)), wounds[k]))
	var edge := ally(c, Vector2(0, -rng_), 0.95)           # exactly on the range: a candidate, and the most wounded
	var beyond := ally(c, Vector2(rng_ + 0.1, 0), 0.97)    # a little past it
	var other := spawn_seraph(c, Vector2(-4.5, -2.0))      # a body of its own kind is a candidate (the Deacon's rule excludes its kind, the seraph's does not)
	wound(c, other, 0.75)
	silence(c, other)                                       # (so that it does not ward, curse or move in this scene)
	var dead := ally(c, Vector2(-2, 4), 1.0)               # fallen: health 0, the most wounded of all, and not a candidate
	c.damage(dead, 1.0e6, 0, false)
	var pre := ally(c, Vector2(4.0, -3.0), 0.99)           # blessed already: skipped, however wounded
	c.apply_status(pre, "sanctified", 0, 1.0, 1000.0)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var w1: int = ward_ticks(cd0, cooldown, 2)[0]
	var w2: int = ward_ticks(cd0, cooldown, 2)[1]
	var log := []
	drain(c, log)
	run_to(c, w1 - 1, log)
	check(of(log, EV_CUE, id).is_empty(), "ward: nothing before the cooldown is up (tick %d)" % (w1 - 1))
	run_to(c, w1, log)
	var cues := of(log, EV_CUE, id, CUE_SANCTIFY)
	check(cues.size() == int(W["maxTargets"]) and cues.all(func(e: Dictionary) -> bool: return int(e["tick"]) == w1), "ward: %d cues, all on the tick after the cooldown was seen up (tick %d: the check comes before the tick's own share comes off)" % [cues.size(), w1])
	var want: Array = [edge, other, ring[3], ring[5]]       # the most wounded first
	var got := []
	for e in cues:
		for cand in ring + [edge, other, beyond, pre, dead, id]:
			var p: Vector2 = c.enemy_info(cand)["pos"]
			if absf(p.x - e["floats"][0]) < 1e-3 and absf(p.y - e["floats"][1]) < 1e-3:
				got.append(cand)
	check(got == want, "ward: it blesses the most wounded first: the one on the range's edge, the other seraph, then two of the ring (%s)" % str(got))
	var only := true
	for cand in want:
		only = only and c.status_stacks(cand, "sanctified") == 1.0
	for cand in [ring[0], ring[1], ring[2], ring[4], beyond, dead, id]:
		only = only and c.status_stacks(cand, "sanctified") == 0.0
	check(only, "ward: those four are blessed, not the milder wounds, the one a hair past the range, the fallen, the blessed (its own) or the seraph itself")
	check(is_equal_approx(float(c.enemy_info(ring[3])["taken_mult"]), float(S2["damageTakenMult"])) and absf(status_left(c, ring[3], "sanctified") - float(S2["durationS"])) < 0.15,
		"ward: damage taken x%.1f for %.0f s" % [float(S2["damageTakenMult"]), float(S2["durationS"])])
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown - DT) and c.enemy_info(id)["state"] == IDLE and of(log, EV_ATTACK, id).is_empty() and of(log, EV_TELEGRAPH, id).is_empty(),
		"ward: the cooldown is spent (%.2f s, less the tick's own share), and it is no swing: the seraph does not leave its state" % cooldown)
	check(is_equal_approx(float(c.enemy_info(id)["hp"]), 120.0 * 0.01), "ward: (the seraph itself was left alone: it is wounded to %.1f)" % float(c.enemy_info(id)["hp"]))
	# The next ward a cooldown later, on the tick after it ran out; the first four's blessing has run out by then, so it is the same four again.
	run_to(c, w2 - 1, log)
	check(of(log, EV_CUE, id, CUE_SANCTIFY).size() == 4, "ward: no second ward before the cooldown (%.1f s) is up" % cooldown)
	run_to(c, w2, log)
	var cues2 := of(log, EV_CUE, id, CUE_SANCTIFY)
	check(cues2.size() == 8 and cues2.slice(4).all(func(e: Dictionary) -> bool: return int(e["tick"]) == w2), "ward: the second ward comes on tick %d, a cooldown (%d ticks) later, and blesses four again" % [w2, w2 - w1])
	var again := true
	for cand in want:
		again = again and c.status_stacks(cand, "sanctified") == 1.0
	check(again and c.status_stacks(pre, "sanctified") == 1.0, "ward: the same four, whose blessing had run out (the blessed one it skipped still carries its own)")
	# A blow on a blessed body costs damageTakenMult of itself.
	var before := float(c.enemy_info(ring[3])["hp"])
	c.damage(ring[3], 10.0, 0, false)
	check(is_equal_approx(before - float(c.enemy_info(ring[3])["hp"]), 10.0 * float(S2["damageTakenMult"])), "ward: a blow of 10 costs %.0f while blessed" % (10.0 * float(S2["damageTakenMult"])))


## Gates and edges: the range is inclusive; the fallen, the rising and the underground are not candidates; a body of any health is (the unhurt too, first in spawn order on a tie); with nobody to
## bless the seraph looks again WARD_RETRY_S later; silence, a flinch and a swing hold the ward back; an elite spends its own quicker cooldown.
func seraph_ward_gates() -> void:
	var d := def("seraph")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var retry := float(KS["WARD_RETRY_S"])
	var rng_ := float(W["range"])
	# The range, from centre to centre, inclusive: 5.5 m is in, 5.52 m is out.
	var c := make(441)
	hero(c, FAR)
	var id := spawn_seraph(c, Vector2(0, 0))
	var in_ := ally(c, Vector2(rng_, 0))
	var out := ally(c, Vector2(-rng_ - 0.02, 0))
	var log := []
	run_to(c, ward_ticks(float(c.enemy_info(id)["attack_cd"]), cooldown, 1)[0], log)
	check(c.status_stacks(in_, "sanctified") == 1.0 and c.status_stacks(out, "sanctified") == 0.0, "ward: a body %.2f m away is in the range, one %.2f m away is not (the range is %.1f m)" % [rng_, rng_ + 0.02, rng_])
	# Unhurt allies are blessed too, and a tie goes to the first in spawn order.
	var e := make(442)
	hero(e, FAR)
	var eid := spawn_seraph(e, Vector2(0, 0))
	var six := []
	for k in 6:
		var a := float(k) * TAU / 6.0
		six.append(ally(e, Vector2(2.5 * cos(a), 2.5 * sin(a))))
	run_to(e, ward_ticks(float(e.enemy_info(eid)["attack_cd"]), cooldown, 1)[0], [])
	var blessed := six.map(func(i: int) -> float: return e.status_stacks(i, "sanctified"))
	check(blessed == [1.0, 1.0, 1.0, 1.0, 0.0, 0.0], "ward: six unhurt allies on the same health: the first four spawned are blessed (%s)" % str(blessed))
	# Underground and rising bodies are skipped, and nothing to bless is a retry WARD_RETRY_S later.
	var f := make(443)
	hero(f, FAR)
	var fid := spawn_seraph(f, Vector2(0, 0))
	var mole := ally(f, Vector2(2, 0), 0.0, "ghoul", true)
	check(f.enemy_info(mole)["state"] == 8, "ward: (a rising ghoul starts underground)")
	var fl := []
	var w1: int = ward_ticks(float(f.enemy_info(fid)["attack_cd"]), cooldown, 1)[0]
	run_to(f, w1 - 3, fl)
	var riser := ally(f, Vector2(-2, 0), 0.0, "robber", true)
	run_to(f, w1, fl)
	check(of(fl, EV_CUE, fid).is_empty() and f.status_stacks(mole, "sanctified") == 0.0 and f.status_stacks(riser, "sanctified") == 0.0 and f.enemy_info(riser)["state"] == RISING,
		"ward: an underground ghoul and a rising body are not candidates: nothing was blessed")
	check(is_equal_approx(float(f.enemy_info(fid)["ward_t"]), retry) and float(f.enemy_info(fid)["attack_cd"]) <= 0.0, "ward: with nobody to bless it looks again in %.2f s, and keeps the cooldown it did not spend" % retry)
	# The scans come every WARD_RETRY_S (15 or 16 ticks); the riser is blessed at the first one after it has risen (the check comes before the state changes), the mole never.
	var step := to_zero(retry)
	var scans := []
	var t_scan := w1
	for i in 40:
		scans.append(t_scan)
		t_scan += step
	var risen_at := (w1 - 3) + to_reach(float(K["RISE_TIME"]))        # the tick on which it stops rising: the check of that tick still sees it rising
	var want_scan := 0
	for s_ in scans:
		if s_ > risen_at:
			want_scan = s_
			break
	run_to(f, want_scan - 1, fl)
	check(f.status_stacks(riser, "sanctified") == 0.0, "ward: and not before its scan (tick %d)" % (want_scan - 1))
	run_to(f, want_scan, fl)
	check(f.status_stacks(riser, "sanctified") == 1.0 and f.status_stacks(mole, "sanctified") == 0.0 and of(fl, EV_CUE, fid, CUE_SANCTIFY).size() == 1 and int(of(fl, EV_CUE, fid, CUE_SANCTIFY)[0]["tick"]) == want_scan,
		"ward: the body that has risen is blessed at the first scan after it (tick %d: scans every %d ticks from tick %d), the ghoul under the ground never" % [want_scan, step, w1])
	# Silence holds the ward back; it fires on the tick after the silence lifts.
	var g := make(444)
	hero(g, FAR)
	var gid := spawn_seraph(g, Vector2(0, 0))
	var ga := ally(g, Vector2(2.5, 0), 0.5)
	silence(g, gid)
	var gl := []
	run(g, 600, gl)
	check(of(gl, EV_CUE, gid).is_empty() and g.status_stacks(ga, "sanctified") == 0.0, "ward: a silenced seraph blesses nobody in 10 s, however long its cooldown has been up")
	check(g.remove_status(gid, "silence"), "ward: silence lifts")
	var t0 := tick
	run(g, 1, gl)
	check(of(gl, EV_CUE, gid, CUE_SANCTIFY).size() == 1 and int(of(gl, EV_CUE, gid, CUE_SANCTIFY)[0]["tick"]) == t0 + 1, "ward: and the ward comes on the next tick")
	# A flinch holds it back: a stun between the tick the cooldown ran out and the tick the ward would have fired.
	var h2 := make(445)
	hero(h2, FAR)
	var hid := spawn_seraph(h2, Vector2(0, 0))
	var ha := ally(h2, Vector2(2.5, 0), 0.5)
	var k := to_zero(float(h2.enemy_info(hid)["attack_cd"]))
	var hl := []
	run_to(h2, k, hl)
	h2.stun(hid, 3.0)
	drain(h2, hl)
	run_to(h2, k + to_reach(3.0), hl)
	check(of(hl, EV_CUE, hid).is_empty() and h2.enemy_info(hid)["state"] == IDLE and h2.status_stacks(ha, "sanctified") == 0.0, "ward: a seraph flinching (HURT) for 3 s blesses nobody, though its cooldown is up, until it is up again")
	run(h2, 1, hl)
	check(of(hl, EV_CUE, hid, CUE_SANCTIFY).size() == 1 and int(of(hl, EV_CUE, hid, CUE_SANCTIFY)[0]["tick"]) == k + to_reach(3.0) + 1, "ward: and it blesses on the tick after it is up (tick %d)" % (k + to_reach(3.0) + 1))
	# A target out of reach and allies near: the ward comes first, and the curse waits for the cooldown it spent; a target in reach: the curse comes first (seraph_curse).
	var i3 := make(446)
	var hh := hero(i3, Vector2(9, 0))
	var iid := spawn_seraph(i3, Vector2(0, 0))
	root(i3, iid)
	var ia := ally(i3, Vector2(-2.5, 0), 0.5)
	var cd0 := float(i3.enemy_info(iid)["attack_cd"])
	var il := []
	var w: int = ward_ticks(cd0, cooldown, 2)[0]
	run_to(i3, w, il)
	check(i3.status_stacks(ia, "sanctified") == 1.0 and of(il, EV_TELEGRAPH, iid).is_empty() and i3.enemy_info(iid)["state"] == CHASE, "ward: a target 9 m away (out of reach, rooted): the ward comes first, and no curse")
	i3.set_external(hh, Vector2(5, 0), true)
	run_to(i3, w + to_zero(cooldown - DT), il)
	var curse := of(il, EV_TELEGRAPH, iid, TELL_CURSE)
	check(curse.size() == 1 and int(curse[0]["tick"]) == w + to_zero(cooldown - DT), "ward: and with the target in reach the curse waits for the cooldown the ward spent (tick %d)" % (w + to_zero(cooldown - DT)))
	# An elite spends its own quicker cooldown (x0.8) and winds up x0.85.
	var j := make(447)
	hero(j, FAR)
	var jid := spawn_seraph(j, Vector2(0, 0), 1, 1.0, 1.0, true)
	var ja := ally(j, Vector2(2.5, 0), 0.5)
	var ecd := cooldown * ELITE_COOLDOWN
	var jt: int = ward_ticks(float(j.enemy_info(jid)["attack_cd"]), ecd, 1)[0]
	run_to(j, jt, [])
	check(j.status_stacks(ja, "sanctified") == 1.0 and is_equal_approx(float(j.enemy_info(jid)["attack_cd"]), ecd - DT), "ward: an elite seraph's cooldown is its own x%.1f = %.2f s" % [ELITE_COOLDOWN, ecd])


## The retry cadence, from the script's own constant (the scan finds nobody, a body appears, the next scan finds it).
func seraph_ward_cadence() -> void:
	var d := def("seraph")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var retry := float(KS["WARD_RETRY_S"])
	var c := make(451)
	hero(c, FAR)
	var id := spawn_seraph(c, Vector2(0, 0))
	var w1: int = ward_ticks(float(c.enemy_info(id)["attack_cd"]), cooldown, 1)[0]
	var log := []
	run_to(c, w1, log)
	check(is_equal_approx(float(c.enemy_info(id)["ward_t"]), retry), "cadence: the first scan found nobody and set the retry to %.2f s" % retry)
	run_to(c, w1 + 3, log)
	var late := ally(c, Vector2(3, 0), 0.4)
	var n := to_zero(retry)
	run_to(c, w1 + n - 1, log)
	check(c.status_stacks(late, "sanctified") == 0.0, "cadence: a body that arrived 3 ticks after the scan is not blessed before the next scan")
	run_to(c, w1 + n, log)
	var cue := of(log, EV_CUE, id, CUE_SANCTIFY)
	check(cue.size() == 1 and int(cue[0]["tick"]) == w1 + n and c.status_stacks(late, "sanctified") == 1.0, "cadence: it is blessed %d ticks (%.2f s) after the scan that found nobody (tick %d)" % [n, retry, w1 + n])
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown - DT), "cadence: and the cooldown is spent")
	# The scan runs every tick the seraph acts: a seraph that is busy for the whole retry scans at once when it is free.
	var e := make(452)
	hero(e, FAR)
	var eid := spawn_seraph(e, Vector2(0, 0))
	var wb: int = ward_ticks(float(e.enemy_info(eid)["attack_cd"]), cooldown, 1)[0]
	run_to(e, wb, [])
	e.stun(eid, 2.0)       # flinching through several scans
	var cand := ally(e, Vector2(3, 0), 0.4)
	run_to(e, wb + to_reach(2.0), [])
	check(e.status_stacks(cand, "sanctified") == 0.0, "cadence: a flinching seraph does not scan")
	var lg := []
	run(e, 1, lg)
	check(e.status_stacks(cand, "sanctified") == 1.0, "cadence: it scans on the first tick it is free (the retry ran out while it flinched)")


## Many candidates on the same health: more than sixteen, and Godot's sort is no longer stable, so which of them is blessed depends on its algorithm. A grid of bodies, three levels
## of health, in a spawn order; the expectation is the engine's own `Array.sort_custom` on the same list.
func seraph_ward_ties() -> void:
	var d := def("seraph")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var matches := 0
	var trials := 0
	var unstable := 0       # lists where the engine's four are not the first four of a stable sort: the proof that the order of equals matters here
	for n in [5, 12, 16, 17, 18, 24, 33, 50]:
		for variant in 2:
			var c := make(460 + n * 3 + variant)
			hero(c, FAR)
			var id := spawn_seraph(c, Vector2(0, 0))
			var spots := ward_grid(n)
			var rng := RandomNumberGenerator.new()
			rng.seed = 9000 + n * 7 + variant
			var levels := [0.0, 0.3, 0.6] if variant == 0 else [0.2, 0.2, 0.2, 0.5]      # (the second variant: almost all tied)
			var ids := []
			for s in spots:
				ids.append(ally(c, s, float(levels[rng.randi() % levels.size()])))
			var list := []
			for i in ids:
				list.append({"id": i, "frac": float(c.enemy_info(i)["hp"]) / float(c.enemy_info(i)["max_hp"])})
			list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["frac"] < b["frac"])
			var expect := list.slice(0, int(W["maxTargets"])).map(func(x: Dictionary) -> int: return x["id"])
			expect.sort()
			var stable := list.duplicate()
			stable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["frac"] < b["frac"] or (a["frac"] == b["frac"] and ids.find(a["id"]) < ids.find(b["id"])))
			var stable4 := stable.slice(0, int(W["maxTargets"])).map(func(x: Dictionary) -> int: return x["id"])
			stable4.sort()
			if stable4 != expect:
				unstable += 1
			var w1: int = ward_ticks(float(c.enemy_info(id)["attack_cd"]), cooldown, 1)[0]
			run_to(c, w1, [])
			var blessed := []
			for i in ids:
				if c.status_stacks(i, "sanctified") == 1.0:
					blessed.append(i)
			blessed.sort()
			trials += 1
			if blessed == expect:
				matches += 1
			else:
				printerr("tie trial n=%d variant=%d: core %s, engine %s" % [n, variant, str(blessed), str(expect)])
	check(matches == trials and unstable >= 1, "ward: with 5 to 50 candidates and ties, the four blessed are the ones Godot's own sort_custom puts first (%d of %d lists; in %d of them that is not what a stable sort gives)" % [matches, trials, unstable])


## `n` spots on a grid 1.2 m apart inside the ward's range (no two bodies close enough to be pushed), nearest the seraph first, in a fixed shuffle.
func ward_grid(n: int) -> Array:
	var all := []
	for gx in range(-4, 5):
		for gz in range(-4, 5):
			var p := Vector2(gx, gz) * 1.2
			if p.length() > 1.5 and p.length() < float(W["range"]) - 0.2:
				all.append(p)
	all.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.length() < b.length() if absf(a.length() - b.length()) > 1e-6 else (a.x < b.x if a.x != b.x else a.y < b.y))
	var pick := all.slice(0, n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77 + n
	for i in range(pick.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp = pick[i]
		pick[i] = pick[j]
		pick[j] = tmp
	return pick


## The core's reproduction of Godot's sort against the engine's, on more lists: heights from a few levels so that ties are everywhere, sizes up to 100, seraphs with the whole table around them.
func seraph_ward_sort_matches_godot() -> void:
	var d := def("seraph")
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var matches := 0
	var trials := 0
	var unstable := 0
	for round in 24:
		var n := 17 + (round * 7) % 40 + (round / 8) * 20
		var c := make(480 + round)
		hero(c, FAR)
		var id := spawn_seraph(c, Vector2(0, 0))
		var spots := ward_grid(mini(n, 56))
		var rng := RandomNumberGenerator.new()
		rng.seed = 31337 + round
		var levels: Array = [[0.0, 0.25, 0.5, 0.75], [0.1, 0.1, 0.1, 0.1, 0.9], [0.0, 0.5], [0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.31, 0.29]][round % 4]
		var ids := []
		for s in spots:
			ids.append(ally(c, s, float(levels[rng.randi() % levels.size()])))
		var list := []
		for i in ids:
			list.append({"id": i, "frac": float(c.enemy_info(i)["hp"]) / float(c.enemy_info(i)["max_hp"])})
		list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["frac"] < b["frac"])
		var expect := list.slice(0, int(W["maxTargets"])).map(func(x: Dictionary) -> int: return x["id"])
		expect.sort()
		var stable := list.duplicate()
		stable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["frac"] < b["frac"] or (a["frac"] == b["frac"] and ids.find(a["id"]) < ids.find(b["id"])))
		var stable4 := stable.slice(0, int(W["maxTargets"])).map(func(x: Dictionary) -> int: return x["id"])
		stable4.sort()
		if stable4 != expect:
			unstable += 1
		run_to(c, ward_ticks(float(c.enemy_info(id)["attack_cd"]), cooldown, 1)[0], [])
		var blessed := []
		for i in ids:
			if c.status_stacks(i, "sanctified") == 1.0:
				blessed.append(i)
		blessed.sort()
		trials += 1
		if blessed == expect:
			matches += 1
		else:
			printerr("sort trial round=%d n=%d: core %s, engine %s" % [round, ids.size(), str(blessed), str(expect)])
	check(matches == trials and unstable >= 3, "ward: on %d more lists of 17 to 56 candidates with heavy ties, the blessed four are the engine's sort_custom's first four (%d of %d; a stable sort would have chosen otherwise in %d)" % [trials, matches, trials, unstable])


# ------------------------------------------------------------------------------------------------------------------ the plague doctor

## The caster set's walk (dm_state_clst_kite with [0.5, 1.5, 3.5, 0.8], silence-aware): walk in beyond attackRange - 1.5, cast at attackRange - 0.5, back off at 0.8 x under 3.5 m.
func plague_walk() -> void:
	var d := def("plague_doctor")
	var range_ := float(d["attackRange"])
	var cast_at := range_ - float(KITE_PARAMS[0])
	var walk_in := range_ - float(KITE_PARAMS[1])
	var back := float(KITE_PARAMS[2])
	var back_speed := float(KITE_PARAMS[3])
	var c := make(491)
	var h := hero(c, Vector2(14, 0))
	var id := spawn_doctor(c, Vector2(0, 0))
	var spd := float(c.enemy_info(id)["speed"])
	silence(c, id)
	var log := []
	var xs := []
	for i in 500:
		run(c, 1, log)
		var p: Vector2 = c.enemy_info(id)["pos"]
		xs.append(p.x)
		if Vector2(14, 0).distance_to(p) <= walk_in and i > 10:
			break
	var step_ok := true
	for i in range(40, mini(100, xs.size() - 1)):
		step_ok = step_ok and absf((xs[i + 1] - xs[i]) - spd * DT) < 2e-4
	check(step_ok, "plague doctor: walks in at full speed (%.2f m/s) while the target is farther than %.1f m" % [spd, walk_in])
	run(c, 60, log)
	var rest: Vector2 = c.enemy_info(id)["pos"]
	var dist := Vector2(14, 0).distance_to(rest)
	check(dist <= walk_in + 1e-3 and dist > walk_in - spd * DT * 1.5, "plague doctor: stops %.2f m from the target (%.1f - one step)" % [dist, walk_in])
	run(c, 60, log)
	check(Vector2(c.enemy_info(id)["pos"]).distance_to(rest) < 1e-4 and c.enemy_info(id)["state"] == CHASE and of(log, EV_ATTACK, id).is_empty(), "plague doctor: stands still between %.1f and %.1f m, and silenced it never casts" % [back, walk_in])
	c.set_external(h, Vector2(rest.x + 2.0, rest.y), true)
	var from := Vector2(c.enemy_info(id)["pos"]).x
	run(c, 1, log)
	var x1 := Vector2(c.enemy_info(id)["pos"]).x
	check(absf((from - x1) - spd * back_speed * DT) < 2e-4, "plague doctor: backs off at %.1f x its speed (%.4f m a tick)" % [back_speed, from - x1])
	run(c, 200, log)
	var d2 := Vector2(c.enemy_info(id)["pos"]).distance_to(Vector2(rest.x + 2.0, rest.y))
	check(d2 >= back - 1e-3 and d2 < back + spd * back_speed * DT * 1.5, "plague doctor: stops backing off at %.2f m (%.1f m)" % [d2, back])
	# The cast gate: rooted; a target on attackRange - 0.5 is cast at, one 2 cm past it is not.
	for trial in [[cast_at, true], [cast_at + 0.02, false]]:
		var e := make(492)
		hero(e, Vector2(float(trial[0]), 0))
		var eid := spawn_doctor(e, Vector2(0, 0))
		root(e, eid)
		var lg := []
		run(e, 600, lg)
		check(of(lg, EV_ATTACK, eid).is_empty() == (not bool(trial[1])), "plague doctor: a target %.2f m away is %s (it casts at attackRange - %.1f = %.1f m)" % [float(trial[0]), "cast at" if trial[1] else "not cast at", float(KITE_PARAMS[0]), cast_at])


## The flask: with the cooldown up and the target within attackRange - 0.5 it winds up for windupMs (telegraph "flask": a ring of PLAGUE_FLASK.radius on the aim fixed at the start), and at the
## end everything within the radius of the aim takes the body's damage (hit kind toxic), a toxic pool is left there and the flask's cue is told. The next one comes a cooldown after the blow.
func plague_flask() -> void:
	var d := def("plague_doctor")
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var r := float(PF["radius"])
	var c := make(501)
	var h := hero(c, Vector2(6, 0))
	var id := spawn_doctor(c, Vector2(0, 0), 3, 2.0, 1.5)
	var dmg := float(d["damage"]) * 1.5
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var log := []
	run(c, 900, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_FLASK)
	var att := of(log, EV_ATTACK, id)
	check(tell.size() >= 3 and att.size() >= 3, "flask: a telegraph and a swing, over and over (%d)" % tell.size())
	if tell.size() < 3:
		return
	var k0 := int(tell[0]["tick"])
	check(k0 == to_zero(cd0), "flask: the first comes on the tick the cooldown is up (tick %d)" % k0)
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[0], 0.0) and is_equal_approx(f[1], 0.0) and is_equal_approx(f[2], 6.0) and is_equal_approx(f[3], 0.0) and is_equal_approx(f[4], r) and is_equal_approx(f[5], windup),
		"flask: a ring of %.1f m on the target's place, from the body, for the %.1f s wind-up" % [r, windup])
	check(att[0]["ints"][0] == BLOW_FLASK and is_equal_approx(att[0]["floats"][0], 6.0) and is_equal_approx(att[0]["floats"][2], windup), "flask: the swing is a flask, aimed at the target")
	var ks := k0 + to_reach(windup)
	var hits := of(log, EV_HIT, id).filter(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], dmg))
	check(hits.size() >= 1 and int(hits[0]["tick"]) == ks and hits[0]["ints"][0] == h and hits[0]["ints"][1] == HK_TOXIC,
		"flask: the blow lands %d ticks (%.1f s) later for %.1f, kind toxic, on the target" % [ks - k0, windup, dmg])
	var zones := of(log, EV_ZONE)
	check(zones.size() >= 1 and int(zones[0]["tick"]) == ks and zones[0]["ints"][0] == ZONE_TOXIC and zones[0]["ints"][1] == id and is_equal_approx(zones[0]["floats"][0], 6.0) and is_equal_approx(zones[0]["floats"][1], 0.0)
		and is_equal_approx(zones[0]["floats"][2], r) and is_equal_approx(zones[0]["floats"][3], float(PF["poolS"])),
		"flask: and a toxic pool at the aim, %.1f m wide, for %.0f s (the zone is the doctor's)" % [r, float(PF["poolS"])])
	var cue := of(log, EV_CUE, id, CUE_FLASK)
	check(cue.size() >= 1 and int(cue[0]["tick"]) == ks and is_equal_approx(cue[0]["floats"][0], 6.0) and is_equal_approx(cue[0]["floats"][2], r), "flask: and the cue at the aim")
	var at_ks := log.filter(func(e: Dictionary) -> bool: return int(e["tick"]) == ks and ((e["type"] == EV_HIT and e["id"] == id) or e["type"] == EV_ZONE or (e["type"] == EV_CUE and e["id"] == id)))
	check(at_ks.map(func(e: Dictionary) -> int: return e["type"]) == [EV_HIT, EV_ZONE, EV_CUE], "flask: in that order on the tick: the hit, the pool, the cue")
	check(int(tell[1]["tick"]) == ks + to_zero(cooldown), "flask: the next one a cooldown (%.1f s) after the blow (tick %d)" % [cooldown, int(tell[1]["tick"])])


## The edges of the ring: the aim is fixed when the wind-up starts (a target that steps out is not hit, one at the edge is), no reach condition at the blow, heroes and thralls alike, a stun
## in the wind-up cancels it, silence stops the cast but not one begun.
func plague_flask_edges() -> void:
	var d := def("plague_doctor")
	var windup := float(d["windupMs"]) / 1000.0
	var r := float(PF["radius"])
	var pool_reach := r + 0.45
	for trial in [[1.75, true, true], [1.85, false, true], [2.3, false, false]]:     # [offset from the aim, direct hit, pool pulses]
		var c := make(511)
		var h := hero(c, Vector2(6, 0))
		var id := spawn_doctor(c, Vector2(0, 0))
		var log := []
		for i in 900:
			run(c, 1, log)
			if not of(log, EV_TELEGRAPH, id, TELL_FLASK).is_empty():
				break
		silence(c, id)       # (no second flask in this trial)
		c.set_external(h, Vector2(6.0 + float(trial[0]), 0), true)
		var rest := []
		run(c, to_reach(windup) + 2 + 130, rest)
		var direct := of(rest, EV_HIT, id).filter(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], 13.0))
		var pulse := of(rest, EV_HIT, id).filter(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], 13.0 * float(PF["poolDpsMult"])))
		check(direct.size() == (1 if trial[1] else 0) and (pulse.size() >= 1) == bool(trial[2]),
			"flask: a target %.2f m from the aim when the flask lands is %s directly (the ring is %.1f m) and %s by the pool (it reaches %.2f m)"
			% [float(trial[0]), "hit" if trial[1] else "missed", r, "pulsed" if trial[2] else "left alone", pool_reach])
	# The aim is fixed at the wind-up's start: a target that walks 5 m away is not followed (and no reach is asked of the blow).
	var e := make(512)
	var he := hero(e, Vector2(6, 0))
	var eid := spawn_doctor(e, Vector2(0, 0))
	var el := []
	for i in 900:
		run(e, 1, el)
		if not of(el, EV_TELEGRAPH, eid, TELL_FLASK).is_empty():
			break
	silence(e, eid)
	e.set_external(he, Vector2(11, 0), true)
	var rest2 := []
	run(e, to_reach(windup) + 2, rest2)
	var z2 := of(rest2, EV_ZONE)
	check(of(rest2, EV_HIT, eid).is_empty() and z2.size() == 1 and z2[0]["ints"][1] == eid and is_equal_approx(z2[0]["floats"][0], 6.0), "flask: a target who walked 5 m off is not followed: the flask lands at the old aim (6, 0)")
	# Two heroes in the ring: both are hit, in the order of the heroes; and a thrall too.
	var g := make(513)
	var h1 := hero(g, Vector2(6, 0))
	var h2 := hero(g, Vector2(6.8, 0.8))
	var owner := h2        # (a thrall far from its owner is carried to it)
	var th: int = g.raise_thrall({"kind": "warrior", "hp": 1000.0, "maxHp": 1000.0, "damage": 0.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false, "allyHeal": 0.0}, owner, Vector2(5.4, 0.9), 0.0, 99.0)
	var gl := []
	run(g, 60, gl)         # (a thrall rises in 0.9 s)
	g.stun(th, 1.0e6)
	var did := spawn_doctor(g, Vector2(0, 0))
	for i in 900:
		run(g, 1, gl)
		if not of(gl, EV_TELEGRAPH, did, TELL_FLASK).is_empty():
			break
	var tp: Vector2 = g.thrall_info(th)["pos"]
	check(tp.distance_to(Vector2(6, 0)) <= r and g.thrall_info(th)["state"] != 0, "flask: (the thrall stands in the ring, risen: %.2f m from the aim)" % tp.distance_to(Vector2(6, 0)))
	var thp := float(g.thrall_info(th)["hp"])
	var gr := []
	run(g, to_reach(windup) + 1, gr)
	var gh := of(gr, EV_HIT, did).filter(func(e2: Dictionary) -> bool: return is_equal_approx(e2["floats"][0], 13.0))
	check(gh.size() == 2 and gh[0]["ints"][0] == h1 and gh[1]["ints"][0] == h2 and is_equal_approx(thp - float(g.thrall_info(th)["hp"]), 13.0),
		"flask: both heroes in the ring are hit (in order), and the thrall costs %.0f health" % (thp - float(g.thrall_info(th)["hp"])))
	# A stun in the wind-up cancels the flask: no hit, no pool, no cue; silence stops the cast but not one begun.
	var s := make(514)
	hero(s, Vector2(6, 0))
	var sid := spawn_doctor(s, Vector2(0, 0))
	var sl := []
	for i in 900:
		run(s, 1, sl)
		if not of(sl, EV_TELEGRAPH, sid, TELL_FLASK).is_empty():
			break
	run(s, 20, sl)
	s.stun(sid, 2.0)
	drain(s, sl)
	var cut := []
	run(s, to_reach(windup) + 4, cut)
	check(of(cut, EV_HIT, sid).is_empty() and of(cut, EV_ZONE).is_empty() and of(cut, EV_CUE, sid).is_empty() and s.enemy_info(sid)["state"] == HURT, "flask: a stun in the wind-up cancels it: no hit, no pool, no cue")
	var q := make(515)
	var hq := hero(q, Vector2(6, 0))
	var qid := spawn_doctor(q, Vector2(0, 0))
	silence(q, qid)
	var ql := []
	run(q, 600, ql)
	check(of(ql, EV_ATTACK, qid).is_empty() and q.enemy_info(qid)["state"] == CHASE, "flask: a silenced doctor does not cast in 10 s, with the target in reach")
	check(q.remove_status(qid, "silence"), "flask: silence lifts")
	run(q, 1, ql)
	var t0 := tick
	check(first_tick(state_edges(ql, qid, ATTACK)) == t0 and of(ql, EV_TELEGRAPH, qid, TELL_FLASK).size() == 1, "flask: the flask starts on the next tick (the cooldown was up)")
	silence(q, qid)
	var kq := t0 + to_reach(windup)
	run_to(q, kq, ql)
	check(of(ql, EV_HIT, qid).size() == 1 and of(ql, EV_HIT, qid)[0]["ints"][0] == hq and int(of(ql, EV_HIT, qid)[0]["tick"]) == kq, "flask: a flask already winding up lands all the same, on tick %d" % kq)


## The pool: PLAGUE_FLASK.poolS seconds, a pulse every second (DmHostileZone, the dust cloud's clock) of damage x poolDpsMult for everything within radius + 0.45, kind toxic, then it is gone.
func plague_pool() -> void:
	var d := def("plague_doctor")
	var windup := float(d["windupMs"]) / 1000.0
	var r := float(PF["radius"])
	var pool_s := float(PF["poolS"])
	var per_pulse := float(d["damage"]) * float(PF["poolDpsMult"])
	var c := make(521)
	var h := hero(c, Vector2(6, 0))
	var id := spawn_doctor(c, Vector2(0, 0))
	var log := []
	for i in 900:
		run(c, 1, log)
		if not of(log, EV_TELEGRAPH, id, TELL_FLASK).is_empty():
			break
	var ks := tick + to_reach(windup)
	silence(c, id)
	run_to(c, ks + 400, log)
	var zones := of(log, EV_ZONE)
	check(zones.size() == 1, "pool: one pool for the one flask")
	if zones.is_empty():
		return
	# Mirror of DmHostileZone._physics_process: age gains a tick, and at lifetime it goes; the first pulse clock starts at the period; each tick takes a tick off it.
	var pulses_at := []
	var gone_at := -1
	var age := 0.0
	var tk := -1.0
	for j in 1000:
		age += DT
		if age >= pool_s:
			gone_at = ks + j
			break
		if tk < 0.0:
			tk = 1.0
		tk -= DT
		if tk <= 0.0:
			tk = 1.0
			pulses_at.append(ks + j)
	var zid: int = zones[0]["id"]
	var got_pulses := of(log, EV_ZONE_PULSE, zid).map(func(e: Dictionary) -> int: return int(e["tick"]))
	check(got_pulses == pulses_at, "pool: it pulses on ticks %s (every second from the second after the flask), the engine-side mirror says %s" % [str(got_pulses), str(pulses_at)])
	var pulse_hits := of(log, EV_HIT, id).filter(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], per_pulse))
	check(pulse_hits.size() == pulses_at.size() and pulse_hits.all(func(e: Dictionary) -> bool: return e["ints"][0] == h and e["ints"][1] == HK_TOXIC),
		"pool: each pulse costs %.2f (damage %d x %.2f), kind toxic, from the doctor (%d pulses)" % [per_pulse, int(d["damage"]), float(PF["poolDpsMult"]), pulse_hits.size()])
	var gone := of(log, EV_ZONE_GONE, zid)
	check(gone.size() == 1 and int(gone[0]["tick"]) == gone_at, "pool: and it is gone on tick %d, %d ticks (%.0f s) after the flask" % [gone_at, gone_at - ks, pool_s])
	# A pool pulses for every target in its reach (radius + 0.45 = 2.25 m from the aim), a direct hit only within the ring (1.8 m): a hero 2.2 m off is pulsed and not struck, one 2.3 m off is left alone.
	var e := make(522)
	var a := hero(e, Vector2(6, 0))
	var near := hero(e, Vector2(6.0 + r + 0.4, 0))
	var wide := hero(e, Vector2(6.0 + r + 0.5, 0))
	var did := spawn_doctor(e, Vector2(0, 0))
	var el := []
	for i in 900:
		run(e, 1, el)
		if not of(el, EV_TELEGRAPH, did, TELL_FLASK).is_empty():
			break
	silence(e, did)
	e.set_external(a, Vector2(40, 40), true)        # the target steps far away: only the pool is left to meet
	var rest := []
	run(e, to_reach(windup) + 130, rest)
	var near_hits := of(rest, EV_HIT, did).filter(func(x: Dictionary) -> bool: return x["ints"][0] == near)
	var wide_hits := of(rest, EV_HIT, did).filter(func(x: Dictionary) -> bool: return x["ints"][0] == wide)
	check(near_hits.size() == 2 and near_hits.all(func(x: Dictionary) -> bool: return is_equal_approx(x["floats"][0], per_pulse)) and wide_hits.is_empty() and of(rest, EV_HIT, did).filter(func(x: Dictionary) -> bool: return x["ints"][0] == a).is_empty(),
		"pool: a hero %.1f m off the aim takes the pulses (%d) and not the blow, one %.1f m off neither: the pool reaches %.2f m, the ring %.1f" % [r + 0.4, near_hits.size(), r + 0.5, r + 0.45, r])


## An elite doctor winds up x0.85, cools down x0.8, and its pool is its own (stronger) damage x poolDpsMult; a fallen one leaves a toxic corpse (which bursts into a pool of its own after 5 s).
func plague_corpse_and_elite() -> void:
	var d := def("plague_doctor")
	var windup := float(d["windupMs"]) / 1000.0 * ELITE_WINDUP
	var cooldown := float(d["cooldownMs"]) / 1000.0 * ELITE_COOLDOWN
	var el: Dictionary = content["ELITE"]
	var c := make(531)
	var h := hero(c, Vector2(6, 0))
	var id := spawn_doctor(c, Vector2(0, 0), 1, 1.0, 1.0, true)
	var edmg := float(d["damage"]) * float(el["damageMult"])
	var log := []
	run(c, 700, log)
	var tell := of(log, EV_TELEGRAPH, id, TELL_FLASK)
	check(tell.size() >= 2 and is_equal_approx(tell[0]["floats"][5], windup), "elite doctor: the flask's wind-up is x%.2f (%.3f s)" % [ELITE_WINDUP, windup])
	var ks := int(tell[0]["tick"]) + to_reach(windup)
	check(tell.size() >= 2 and int(tell[1]["tick"]) == ks + to_zero(cooldown), "elite doctor: the next flask a cooldown of x%.1f (%.2f s) after the blow" % [ELITE_COOLDOWN, cooldown])
	var hit := of(log, EV_HIT, id)
	check(not hit.is_empty() and is_equal_approx(hit[0]["floats"][0], edmg) and hit[0]["ints"][0] == h, "elite doctor: the blow is its own damage (x%.1f = %.1f)" % [float(el["damageMult"]), edmg])
	var pulse := hit.filter(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], edmg * float(PF["poolDpsMult"])))
	check(not pulse.is_empty(), "elite doctor: and its pool pulses for %.2f" % (edmg * float(PF["poolDpsMult"])))
	# The corpses: a doctor's is toxic, the seraph's resonant, the flagellant's normal.
	for trial in [["plague_doctor", CK_TOXIC], ["seraph", CK_RESONANT], ["flagellant", 0]]:
		var e := make(532)
		var he := hero(e, FAR)
		var bid: int = e.spawn_enemy(String(trial[0]), Vector2(0, 0), 1, 1.0, 1.0, false, CLOISTER, false)
		e.damage(bid, 1.0e6, he, false)
		var added := of(events(e), EV_CORPSE_ADDED)
		check(added.size() == 1 and added[0]["ints"][0] == int(trial[1]) and e.def_name(added[0]["ints"][1]) == String(trial[0]), "%s: it falls into a corpse of kind %d (%s in the def)" % [trial[0], int(trial[1]), String(def(String(trial[0]))["corpse"])])
		if trial[0] == "plague_doctor":
			var lg := []
			run(e, 5 * 60 + 30, lg)
			var burst := of(lg, EV_ZONE)
			check(burst.size() == 1 and burst[0]["ints"][0] == ZONE_TOXIC and burst[0]["ints"][1] == 0, "plague doctor: its corpse bursts after 5 s into a toxic pool of its own (no source)")


# ------------------------------------------------------------------------------------------------------------------ the flagellant

## Ticks until the swing a flagellant begins with `cd0` on the clock, when frenzy set in after tick `onset` (blows hurry x rate from the next tick on): the cooldown loses DT a tick, DT x rate after.
func swing_start(cd0: float, onset: int, rate: float) -> int:
	var v := cd0
	var t := 0
	while v > 0.0:
		t += 1
		v -= DT * (rate if t > onset else 1.0)
	return t


## Frenzy (the def's `frenzy`, the status set's rule): below FRENZY.atFrac of its health (strictly) the Flagellant has the status `frenzy` for good, x1.45 feet and x1.6 blows; the status set checks it
## at its own 0.1 s step.
func flagellant_frenzy() -> void:
	var c := make(541)
	hero(c, FAR)
	var id: int = c.spawn_enemy("flagellant", Vector2(0, 0), 1, 1.0, 1.0, false, CLOISTER, false)
	var max_hp := float(c.enemy_info(id)["max_hp"])
	var log := []
	check(max_hp == float(def("flagellant")["hp"]), "frenzy: the flagellant has %.0f health" % max_hp)
	c.damage(id, max_hp * float(FR["atFrac"]), 0, false)        # exactly half: not below it
	run(c, 30, log)
	check(float(c.enemy_info(id)["hp"]) == max_hp * float(FR["atFrac"]) and c.status_stacks(id, "frenzy") == 0.0 and of(log, EV_STATUS_CHANGED, id).is_empty()
		and float(c.enemy_info(id)["speed_mult"]) == 1.0 and float(c.enemy_info(id)["attack_rate_mult"]) == 1.0, "frenzy: at exactly half health (%.0f) it is calm" % float(c.enemy_info(id)["hp"]))
	c.damage(id, 0.01, 0, false)
	var t0 := tick
	drain(c, log)
	run(c, 8, log)
	var ch := of(log, EV_STATUS_CHANGED, id)
	check(ch.size() == 1 and first_tick(ch) > t0 and first_tick(ch) <= t0 + 7 and c.status_stacks(id, "frenzy") == 1.0, "frenzy: a hair below half it is frenzied within one status step (0.1 s: tick %d, %d ticks after the blow)" % [first_tick(ch), first_tick(ch) - t0])
	check(is_equal_approx(float(c.enemy_info(id)["speed_mult"]), float(FR["moveMult"])) and is_equal_approx(float(c.enemy_info(id)["attack_rate_mult"]), float(FR["attackRateMult"])),
		"frenzy: x%.2f feet and x%.1f blows" % [float(FR["moveMult"]), float(FR["attackRateMult"])])
	run(c, 20 * 60, log)
	check(c.status_stacks(id, "frenzy") == 1.0 and of(log, EV_STATUS_EXPIRED, id).is_empty(), "frenzy: it does not run out")
	# An elite's half is half of its own (larger) health.
	var e := make(542)
	hero(e, FAR)
	var eid: int = e.spawn_enemy("flagellant", Vector2(0, 0), 1, 1.0, 1.0, true, CLOISTER, false)
	var emax := float(e.enemy_info(eid)["max_hp"])
	e.damage(eid, emax * 0.5 - 1.0, 0, false)     # one hit point over half
	run(e, 20, [])
	check(e.status_stacks(eid, "frenzy") == 0.0, "frenzy: an elite at %.1f of %.1f is calm" % [float(e.enemy_info(eid)["hp"]), emax])
	e.damage(eid, 1.5, 0, false)
	run(e, 20, [])
	check(e.status_stacks(eid, "frenzy") == 1.0, "frenzy: and at %.1f it is frenzied (half is %.1f)" % [float(e.enemy_info(eid)["hp"]), emax * 0.5])
	# The feet: a frenzied body closes in at x1.45, a calm one at its own speed.
	for trial in [[0.0, 1.0], [0.6, float(FR["moveMult"])]]:
		var w := make(543)
		hero(w, Vector2(14, 0))
		var wid: int = w.spawn_enemy("flagellant", Vector2(0, 0), 1, 1.0, 1.0, false, CLOISTER, false)
		if trial[0] > 0.0:
			wound(w, wid, float(trial[0]))
		var spd := float(w.enemy_info(wid)["speed"])
		var xs := []
		var wl := []
		for i in 100:
			run(w, 1, wl)
			xs.append(Vector2(w.enemy_info(wid)["pos"]).x)
		var ok := true
		for i in range(30, 90):
			ok = ok and absf((xs[i + 1] - xs[i]) - spd * float(trial[1]) * DT) < 2e-4
		check(ok, "frenzy: %s it walks at x%.2f its speed (%.2f m/s)" % ["wounded" if trial[0] > 0.0 else "calm", float(trial[1]), spd * float(trial[1])])


## The blows: a melee body of 12 damage, a 0.38 s wind-up and 1.1 s cooldown from the def; frenzy lets the cooldown run x1.6 as fast (the next swing begins a cooldown at that rate after the
## blow), the wind-up and the recovery are as they were.
func flagellant_blows() -> void:
	var d := def("flagellant")
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	for frenzied in [false, true]:
		var rate := float(FR["attackRateMult"]) if frenzied else 1.0
		var c := make(551)
		var h := hero(c, Vector2(1.0, 0))
		var id: int = c.spawn_enemy("flagellant", Vector2(0, 0), 1, 1.0, 1.0, false, CLOISTER, false)
		if frenzied:
			wound(c, id, 0.6)
		var cd0 := float(c.enemy_info(id)["attack_cd"])
		var log := []
		run(c, 900, log)
		var hits := of(log, EV_HIT, id)
		var att := of(log, EV_ATTACK, id)
		check(hits.size() >= 5 and att.size() >= 5 and of(log, EV_TELEGRAPH, id).is_empty(), "%s flagellant: five blows, and a plain swing has no telegraph (%d)" % ["frenzied" if frenzied else "calm", hits.size()])
		if hits.size() < 5:
			continue
		var onset := first_tick(of(log, EV_STATUS_CHANGED, id)) if frenzied else 0
		var k0 := swing_start(cd0, onset, rate)
		check(first_tick(att) == k0 and att[0]["ints"][0] == 0 and is_equal_approx(att[0]["floats"][2], windup), "%s flagellant: the first swing begins on tick %d (the cooldown, hurried from tick %d), %.2f s wind-up" % ["frenzied" if frenzied else "calm", k0, onset + 1, windup])
		var ks := k0 + to_reach(windup)
		var ok: bool = int(hits[0]["tick"]) == ks and hits[0]["ints"][0] == h and hits[0]["ints"][1] == 0 and hits[0]["floats"][0] == float(d["damage"])
		var gap := to_zero_rate(cooldown, rate) + to_reach(windup)
		for i in range(1, 5):
			ok = ok and int(hits[i]["tick"]) - int(hits[i - 1]["tick"]) == gap
		check(ok, "%s flagellant: a blow for %d on tick %d, then one every %d ticks (a cooldown of %.1f s at x%.1f = %d ticks, and the %.2f s wind-up)" % ["frenzied" if frenzied else "calm", int(d["damage"]), ks, gap, cooldown, rate, to_zero_rate(cooldown, rate), windup])


# ------------------------------------------------------------------------------------------------------------------ the wire

## A guest sees the flask (its ring derived from the snapshot's ATTACK edge, its pool and cue as events), the seraph's curse, the ward's cues and blessings, and the frenzy; the data the two
## sides must share include the seraph's ward and the flask's radius.
func cloister_on_the_wire() -> void:
	# The flask: telegraph, pool, cue.
	var d := def("plague_doctor")
	var windup := float(d["windupMs"]) / 1000.0
	var r := float(PF["radius"])
	var host := make(601)
	host.set_replication(true)
	hero(host, Vector2(6, 0))
	var id := spawn_doctor(host, Vector2(0, 0), 3, 2.0, 1.5)
	var guest := puppet()
	var hl := []
	var gl := []
	var t := join(host, guest, hl, gl)
	var k0 := to_zero(float(host.enemy_info(id)["attack_cd"]))
	t = lockstep(host, guest, hl, gl, t, k0 + to_reach(windup) + 150)
	var ht := of(hl, EV_TELEGRAPH, id, TELL_FLASK)
	var gt := of(gl, EV_TELEGRAPH, id, TELL_FLASK)
	check(ht.size() == 1 and gt.size() == 1, "wire: the guest sees the flask's telegraph once (host %d, guest %d)" % [ht.size(), gt.size()])
	if gt.size() == 1:
		var f: PackedFloat32Array = gt[0]["floats"]
		check(absf(f[2] - 6.0) < 0.02 and absf(f[3]) < 0.02 and is_equal_approx(f[4], r) and f[5] >= 0.05 and f[5] <= windup + 1e-4, "wire: aimed at the target, %.1f m wide, for what is left of the %.1f s (%.2f s)" % [r, windup, f[5]])
		check(int(gt[0]["tick"]) - int(ht[0]["tick"]) <= 6, "wire: within two snapshots of the host's (%d ticks later)" % (int(gt[0]["tick"]) - int(ht[0]["tick"])))
	check(of(gl, EV_ATTACK, id).size() == 1 and of(gl, EV_ATTACK, id)[0]["ints"][0] == BLOW_FLASK, "wire: and its swing is a flask on the guest")
	var hz := of(hl, EV_ZONE)
	var gz := of(gl, EV_ZONE)
	check(hz.size() == 1 and gz.size() == 1 and gz[0]["ints"][0] == ZONE_TOXIC and gz[0]["ints"][1] == id and absf(gz[0]["floats"][0] - 6.0) < 1e-4 and is_equal_approx(gz[0]["floats"][2], r),
		"wire: the pool reaches the guest once, toxic, at the aim, with the doctor as its source")
	check(of(gl, EV_ZONE_PULSE).size() == of(hl, EV_ZONE_PULSE).size() and of(gl, EV_ZONE_PULSE).size() >= 2 and of(gl, EV_ZONE_GONE).size() == of(hl, EV_ZONE_GONE).size(), "wire: and its pulses and its end (%d pulses)" % of(gl, EV_ZONE_PULSE).size())
	check(of(gl, EV_CUE, id, CUE_FLASK).size() == 1 and of(hl, EV_CUE, id, CUE_FLASK).size() == 1, "wire: and the flask's cue")
	check(of(hl, EV_HIT, id).size() >= 1 and of(gl, EV_HIT).is_empty(), "wire: the blow on the hero is the host's alone")
	# The seraph's curse reaches the guest as a curse.
	var s := make(602)
	s.set_replication(true)
	hero(s, Vector2(5, 0))
	var sid := spawn_seraph(s, Vector2(0, 0), 2)
	var sg := puppet()
	var sl := []
	var sgl := []
	t = join(s, sg, sl, sgl)
	t = lockstep(s, sg, sl, sgl, t, to_zero(float(s.enemy_info(sid)["attack_cd"])) + 12)
	var cg := of(sgl, EV_TELEGRAPH, sid, TELL_CURSE)
	check(cg.size() == 1 and of(sl, EV_TELEGRAPH, sid, TELL_CURSE).size() == 1 and absf(cg[0]["floats"][2] - 5.0) < 0.02 and of(sgl, EV_ATTACK, sid)[0]["ints"][0] == BLOW_CURSE and sg.enemy_info(sid).get("def", "") == "seraph",
		"wire: the seraph's curse reaches the guest as a curse ring on the target")
	# The ward: the cues and the blessings.
	var w := make(603)
	w.set_replication(true)
	hero(w, FAR)
	var wid := spawn_seraph(w, Vector2(0, 0))
	var three := [ally(w, Vector2(3, 0), 0.5), ally(w, Vector2(-3, 0), 0.3), ally(w, Vector2(0, 3), 0.1)]
	var wg := puppet()
	var wl := []
	var wgl := []
	t = join(w, wg, wl, wgl)
	t = lockstep(w, wg, wl, wgl, t, ward_ticks(float(w.enemy_info(wid)["attack_cd"]), float(def("seraph")["cooldownMs"]) / 1000.0, 1)[0] + 12)
	var hc := of(wl, EV_CUE, wid, CUE_SANCTIFY)
	var gc := of(wgl, EV_CUE, wid, CUE_SANCTIFY)
	check(hc.size() == 3 and gc.size() == 3, "wire: the ward's three cues reach the guest once each (host %d, guest %d)" % [hc.size(), gc.size()])
	var same := gc.size() == 3
	for k in gc.size():
		same = same and absf(gc[k]["floats"][0] - hc[k]["floats"][0]) < 1e-3 and absf(gc[k]["floats"][1] - hc[k]["floats"][1]) < 1e-3
	check(same, "wire: in the host's order, at the same places")
	var on_guest := three.all(func(i: int) -> bool: return wg.status_stacks(i, "sanctified") == 1.0 and is_equal_approx(float(wg.enemy_info(i)["taken_mult"]), float(statuses["SANCTIFIED"]["damageTakenMult"])))
	check(on_guest and wg.status_stacks(wid, "sanctified") == 0.0, "wire: the three blessed bodies carry the status on the guest too, with its multiplier; the seraph does not")
	# The frenzy.
	var fz := make(604)
	fz.set_replication(true)
	hero(fz, FAR)
	var fid: int = fz.spawn_enemy("flagellant", Vector2(0, 0), 1, 1.0, 1.0, false, CLOISTER, false)
	var fg := puppet()
	var fl := []
	var fgl := []
	t = join(fz, fg, fl, fgl)
	wound(fz, fid, 0.6)
	t = lockstep(fz, fg, fl, fgl, t, t + 30)
	check(fz.status_stacks(fid, "frenzy") == 1.0 and fg.status_stacks(fid, "frenzy") == 1.0 and is_equal_approx(float(fg.enemy_info(fid)["speed_mult"]), float(FR["moveMult"]))
		and is_equal_approx(float(fg.enemy_info(fid)["attack_rate_mult"]), float(FR["attackRateMult"])), "wire: the frenzy reaches the guest, with its factors")
	# A guest that does not share the data refuses the host's messages: the seraph's ward, the flask's radius, the doctor's blow.
	for change in [["seraph", "ward"], ["plague_doctor", "flask radius"], ["plague_doctor", "attack"]]:
		var odd: RefCounted = ClassDB.instantiate("DmCore")
		var defs: Dictionary = content["ENEMIES"].duplicate(true)
		var tun_content: Dictionary = content.duplicate(true)
		match String(change[1]):
			"ward":
				defs["seraph"].erase("ward")
			"flask radius":
				tun_content["PLAGUE_FLASK"]["radius"] = 2.4
			"attack":
				defs["plague_doctor"]["attack"] = "curse"
		odd.load_enemy_defs(defs)
		odd.load_tuning(tun_content)
		odd.load_status_defs(DmStatusRules.build(DmCoreData.json(godot_dir.path_join("data/content/abilities.json")), statuses, content))
		odd.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
		odd.set_puppet(true)
		check(not odd.apply_snapshot(w.snapshot(900)) and "data" in str(odd.replication_error()), "wire: a guest with another %s of the %s refuses the host's snapshot (%s)" % [change[1], change[0], odd.replication_error()])


# ------------------------------------------------------------------------------------------------------------------ the rosters and a replay

## The whole rosters of the Bell Sanctum, the Bone Coliseum and the Plague Cloister (their enemy tables and the Sanctum's procession themes, leads included) are made by the core, the models are
## drawn by the crowd, and a seeded run replays event for event.
func cloister_rosters_and_a_replay() -> void:
	var areas := DmCoreData.json(godot_dir.path_join("data/content/areas.json"))
	for area in [SANCTUM, COLISEUM, CLOISTER]:
		var ids := {}
		for e in areas["AREAS"][area]["enemies"]:
			ids[String(e["id"])] = true
		for th in content["WAVE_THEMES"].get(area, []):
			for e in th["roster"]:
				ids[String(e["id"])] = true
			if th.get("lead") != null:
				ids[String(th["lead"])] = true
		var missing := []
		for id: String in ids:
			if not DmWaveDirector.runs_on_core(id):
				missing.append(id)
		check(missing.is_empty() and ids.size() >= 5, "roster: every kind of the %s's waves and processions runs on the core (%d kinds, missing %s)" % [area, ids.size(), str(missing)])
		if area == SANCTUM or area == COLISEUM:
			check(ids.has("seraph"), "roster: the %s has the Weeping Seraph" % area)
		else:
			check(ids.has("plague_doctor") and ids.has("flagellant"), "roster: the %s has the Plague Doctor and the Flagellant" % area)
	var looks := DmCoreData.json("res://crowd/crowd_looks.json")
	var drawn := true
	for id in CLOISTER_KINDS:
		var slug := String(looks["enemy_model"].get(id, ""))
		drawn = drawn and slug != "" and FileAccess.file_exists("res://assets/slice/models/%s/character.glb" % slug)
	check(drawn and looks["casters"].has("seraph") and looks["casters"].has("plague_doctor") and not looks["casters"].has("flagellant") and float(def("seraph")["flying"]) == 0.7 and looks["wings"].has("weeping_seraph"),
		"roster: the crowd draws them (their models; the seraph and the doctor as casters, the seraph hovering at %.1f m with its wings)" % float(def("seraph")["flying"]))
	var dir := DmWaveDirector.new()
	check(CLOISTER_KINDS.all(func(k: String) -> bool: return dir.makes(k)) and not dir.makes("pyre_priest_that_does_not_exist"), "roster: the director makes all three")
	dir.free()
	var logs := []
	for round in 2:
		var c := make(611)
		var h1 := hero(c, Vector2(0, 0))
		hero(c, Vector2(2, -3))
		thrall(c, h1, Vector2(-2, 2), 400.0)
		spawn_seraph(c, Vector2(9, 3), 4, 1.5, 1.2)
		spawn_seraph(c, Vector2(-10, 4), 4, 1.5, 1.2, true)
		spawn_doctor(c, Vector2(-9, -8), 4, 1.5, 1.2)
		spawn_doctor(c, Vector2(8, -9), 4, 1.5, 1.2, true)
		for i in 3:
			c.spawn_enemy("flagellant", Vector2(12 - i * 6, 12), 4, 1.5, 1.2, i == 2, CLOISTER, false)
		for i in 6:
			c.spawn_enemy("robber" if i % 2 == 0 else "hound", Vector2(12 - i * 4, 13), 4, 1.5, 1.2, false, SANCTUM, false)
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
					elif c.enemy_info(id)["def"] == "flagellant":
						c.damage(id, 60.0, 0, true)
		logs.append([rec, recf, c.enemy_count(), c.corpse_count()])
	check(logs[0][0] == logs[1][0] and logs[0][1] == logs[1][1] and logs[0][0].size() > 300, "replay: a seeded fight of the seraphs, the doctors, the flagellants and a crowd replays event for event (%d ints)" % logs[0][0].size())


# ================================================================================================================== the Cinder Pyre and the Mourning Fen
#
# Their eight kinds, the "pf" family of godot/enemies/kinds: dm_enemy_pf_melee (the Cinder Husk), dm_enemy_pf_flanker (the Cinderhound, the Mire Leech), dm_enemy_pf_caster (the Pyre
# Priest, the Bog Hag, the Fen Wisp), dm_enemy_pf_hazard (the Slag Brute, the Drowned Sexton), dm_pf_util and the states dm_state_pf_hook_chase and dm_state_pf_lure_kite.
#   - the Husk: a melee body that bursts into a burning pool (EMBER_DEATH) where it falls, after `died`; nothing when it leaves alive;
#   - the Priest: the caster set's walk, the coal (EMBER_BOLT: the ring at the aim fixed at the wind-up, kind ember, and the pool), the blow softened by Bone Hex;
#   - the Hound: a flanker (a swift corpse, no pool); the Leech: a flanker whose bite is toxic, with no corpse;
#   - the Slag Brute: the slam of the hazards with a burning pool on the aim (SLAG_POOL), which Bone Hex does not soften;
#   - the Hag: the hex (HAG_HEX) aimed at the thickest knot of thralls, thralls cursed, heroes chilled; the Wisp: the pulse (WISP_PULSE), the chill, the retreat toward the lure;
#   - the Sexton: the chain (SEXTON_HOOK: the window, the clear line, its own cooldown, the strip, the pull and the root, never a thrall), the slam otherwise;
#   - the wire: a guest sees the coal, the hex, the pulse and the chain, the pools and the chain's cue; what a hero is made to suffer besides damage stays the host's;
#   - the rosters: the whole Pyre and Fen waves run on the core, the models are drawn, and a seeded run replays bit for bit.

const PYRE := "pyre"
const FEN := "fen"
const PF_KINDS: Array[String] = ["cinder_husk", "pyre_priest", "cinderhound", "slag_brute", "bog_hag", "drowned_sexton", "fen_wisp", "mire_leech"]
const PF_EV_ZONE := 10
const PF_EV_ZONE_PULSE := 11
const PF_EV_ZONE_GONE := 12
const PF_EV_EFFECT := 33
const PF_TELL_EMBER := 10
const PF_TELL_HEX := 11
const PF_TELL_PULSE := 12
const PF_TELL_HOOK := 13
const PF_BLOW_EMBER := 8
const PF_BLOW_HEX := 9
const PF_BLOW_PULSE := 10
const PF_BLOW_HOOK := 11
const PF_CUE_HOOK := 8
const PF_ZONE_EMBER := 2
const PF_HK_MELEE := 0
const PF_HK_TOXIC := 1
const PF_HK_BURN := 2
const PF_HK_EMBER := 3
const PF_HK_DUST := 4
const PF_TE_CHILL := 0
const PF_TE_ROOT := 1
const PF_TE_PULL := 2
const PF_CK_NORMAL := 0
const PF_CK_SWIFT := 1
const PF_CK_RESONANT := 2
const PF_CK_NONE := 4

var fen: Dictionary       ## fen.json (HAG_HEX, WISP_PULSE, SEXTON_HOOK, FEN_LURE)


## A body that does no damage and stays where it is: a stand-in for "something else in the area", in the Pyre.
func pf_dummy(c: RefCounted, at: Vector2) -> int:
	return c.spawn_enemy("robber", at, 1, 1.0, 0.0, false, PYRE, false)


## Ticks in which a hostile zone pulses: a mirror of DmHostileZone._physics_process (age gains DT a tick, the zone ends when it reaches its life; the first countdown starts at
## the first tick and a pulse is the tick it falls to zero).
func pf_pulse_ticks(lifetime: float, period: float) -> Array:
	var out := []
	var age := 0.0
	var cd := -1.0
	var k := 0
	while true:
		k += 1
		age += DT
		if age >= lifetime:
			break
		if cd < 0.0:
			cd = period
		cd -= DT
		if cd <= 0.0:
			cd = period
			out.append(k)
	return out


## The ticks (counted from the log's first tick) of the hits a zone dealt to hero `who`, with their damage and kind.
func pf_zone_hits(log: Array, source: int, who: int) -> Array:
	return log.filter(func(e: Dictionary) -> bool: return e["type"] == EV_HIT and e["id"] == source and e["ints"][0] == who)


## A held thrall of `owner`: it rises, is stunned where it stands and put at `at` (it never moves), so that it counts as a target and a victim.
func pf_thralls(c: RefCounted, owner: int, spots: Array, hp := 100.0) -> Array:
	var ids := []
	for at in spots:
		ids.append(c.raise_thrall({"kind": "warrior", "hp": hp, "maxHp": hp, "damage": 0.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false, "allyHeal": 0.0}, owner, at, 0.0, 99.0))
	var log := []
	run(c, to_reach(0.9) + 2, log)
	for i in ids.size():
		c.stun(ids[i], 1.0e6)
		c.set_thrall_pos(ids[i], spots[i])
	drain(c, log)
	return ids


func pf_names_defs_and_numbers() -> void:
	check(DmCoreEvents.TELLS.size() >= 14 and DmCoreEvents.TELLS[PF_TELL_EMBER] == &"ember" and DmCoreEvents.TELLS[PF_TELL_HEX] == &"hex" and DmCoreEvents.TELLS[PF_TELL_PULSE] == &"pulse"
		and DmCoreEvents.TELLS[PF_TELL_HOOK] == &"hook", "the telegraph names: ember, hex, pulse and hook appended after flask (append only)")
	check(DmCoreEvents.BLOWS.size() >= 12 and DmCoreEvents.BLOWS[PF_BLOW_EMBER] == &"ember" and DmCoreEvents.BLOWS[PF_BLOW_HEX] == &"hex" and DmCoreEvents.BLOWS[PF_BLOW_PULSE] == &"pulse"
		and DmCoreEvents.BLOWS[PF_BLOW_HOOK] == &"hook", "the blow names: ember, hex, pulse and hook appended after flask")
	check(DmCoreEvents.CUES.size() >= 9 and DmCoreEvents.CUES[PF_CUE_HOOK] == &"hook" and DmCoreEvents.ZONE_KINDS.size() >= 3 and DmCoreEvents.ZONE_KINDS[PF_ZONE_EMBER] == &"ember"
		and DmCoreEvents.TARGET_EFFECT == PF_EV_EFFECT and DmCoreEvents.EFFECTS == [&"chill", &"root", &"pull"], "the cue hook, the zone kind ember and the hero effects chill, root, pull are appended")
	var el: Dictionary = content["ELITE"]
	for id in PF_KINDS:
		var d := def(id)
		var c := make(401)
		hero(c, FAR)
		var area := FEN if id in ["bog_hag", "drowned_sexton", "fen_wisp", "mire_leech"] else PYRE
		var e: int = c.spawn_enemy(id, Vector2(0, 0), 6, 2.0, 1.5, false, area, false)
		var info: Dictionary = c.enemy_info(e)
		check(is_equal_approx(info["max_hp"], float(d["hp"]) * 2.0) and is_equal_approx(info["damage"], float(d["damage"]) * 1.5) and info["radius"] == float(d["radius"])
			and is_equal_approx(info["windup_s"], float(d["windupMs"]) / 1000.0) and info["level"] == 6 and info["area"] == area,
			"%s: hp, damage, radius and wind-up from the def, the spawn's multipliers and level" % id)
		var spd := float(info["speed"])
		check(spd >= float(d["speed"]) * 0.92 - 1e-6 and spd <= float(d["speed"]) * 1.08 + 1e-6, "%s: speed %.2f within the +-8%% roll of %.1f" % [id, spd, float(d["speed"])])
		var ee: int = c.spawn_enemy(id, Vector2(5, 5), 1, 1.0, 1.0, true, area, false)
		var ei: Dictionary = c.enemy_info(ee)
		check(is_equal_approx(ei["max_hp"], float(d["hp"]) * float(el["hpMult"])) and is_equal_approx(ei["windup_s"], float(d["windupMs"]) / 1000.0 * ELITE_WINDUP) and is_equal_approx(ei["damage"], float(d["damage"]) * float(el["damageMult"])),
			"%s: an elite has x%.1f health, x%.1f damage and a x%.2f wind-up" % [id, float(el["hpMult"]), float(el["damageMult"]), ELITE_WINDUP])
	var t: Dictionary = make().tuning()
	var EB: Dictionary = content["EMBER_BOLT"]
	var ED: Dictionary = content["EMBER_DEATH"]
	var SP: Dictionary = content["SLAG_POOL"]
	var HX: Dictionary = fen["HAG_HEX"]
	var WP: Dictionary = fen["WISP_PULSE"]
	var SH: Dictionary = fen["SEXTON_HOOK"]
	check(t["EMBER_BOLT.radius"] == float(EB["radius"]) and t["EMBER_BOLT.poolS"] == float(EB["poolS"]) and t["EMBER_BOLT.poolDpsMult"] == float(EB["poolDpsMult"])
		and t["EMBER_DEATH.radius"] == float(ED["radius"]) and t["EMBER_DEATH.poolS"] == float(ED["poolS"]) and t["EMBER_DEATH.poolDpsMult"] == float(ED["poolDpsMult"])
		and t["SLAG_POOL.poolS"] == float(SP["poolS"]) and t["SLAG_POOL.poolDpsMult"] == float(SP["poolDpsMult"]), "the Pyre's numbers are enemies.json's: EMBER_BOLT, EMBER_DEATH, SLAG_POOL")
	check(t["HAG_HEX.radius"] == float(HX["radius"]) and t["HAG_HEX.durationS"] == float(HX["durationS"]) and t["HAG_HEX.blowMult"] == float(HX["blowMult"]) and is_equal_approx(t["HAG_HEX.chillS"], float(HX["chillMs"]) / 1000.0)
		and t["HAG_HEX.thrallDamageMult"] == float(HX["thrallDamageMult"]) and t["WISP_PULSE.radius"] == float(WP["radius"]) and is_equal_approx(t["WISP_PULSE.chillS"], float(WP["chillMs"]) / 1000.0)
		and t["SEXTON_HOOK.minRange"] == float(SH["minRange"]) and t["SEXTON_HOOK.range"] == float(SH["range"]) and t["SEXTON_HOOK.halfWidth"] == float(SH["halfWidth"])
		and t["SEXTON_HOOK.cooldownS"] == float(SH["cooldownS"]) and t["SEXTON_HOOK.pullM"] == float(SH["pullM"]) and t["SEXTON_HOOK.blowMult"] == float(SH["blowMult"])
		and is_equal_approx(t["SEXTON_HOOK.rootS"], float(SH["rootMs"]) / 1000.0) and t["FEN_LURE.x"] == float(fen["FEN_LURE"]["x"]) and t["FEN_LURE.z"] == float(fen["FEN_LURE"]["z"]),
		"the Fen's numbers are fen.json's: HAG_HEX, WISP_PULSE, SEXTON_HOOK, FEN_LURE")
	# The scripts' own literals (the chain's strip, the drag's limits, the lure's heading) are the ones the core compiles in.
	var hazard_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/kinds/dm_enemy_pf_hazard.gd"))
	var util_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/kinds/dm_pf_util.gd"))
	var lure_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/states/dm_state_pf_lure_kite.gd"))
	var caster_src: String = FileAccess.get_file_as_string(godot_dir.path_join("enemies/kinds/dm_enemy_pf_caster.gd"))
	check(hazard_src.contains('var reach := float(H["range"]) + 0.6') and hazard_src.contains('var half := float(H["halfWidth"]) + 0.3') and hazard_src.contains("hook_cd -= delta")
		and util_src.contains("maxf(0.0, len - 1.6)") and util_src.contains("if step > 0.05:") and lure_src.contains("(ax * 0.55 + lx / ll * 0.45) * 3.0") and lure_src.contains("steer_to(goal, BACK_OFF_SPEED)")
		and caster_src.contains("if flat_dist_to(t) > attack_range:") and caster_src.contains("if cnt > best_n:"), "the late scripts' own literals (the strip's 0.6 and 0.3, the pull's 1.6 and 0.05, the lure's 0.55, 0.45 and 3 m, the hex's reach and knot) are the ones compiled in")
	check(lure_src.contains("extends DmStateKite") and float(KITE["BACK_OFF_DIST"]) == 3.5 and float(KITE["BACK_OFF_SPEED"]) == 0.8, "the lure kite is dm_state_kite with another back-off (the walk's 3.5 m and 0.8 x are dm_state_kite's)")


# ------------------------------------------------------------------------------------------------------------------ the Cinder Husk

## It falls into a burning pool: EMBER_DEATH radius for poolS seconds at 0.3 x its damage a second, where it fell, owned by it, told after `died`; it hurts once a second (as burn)
## whoever stands within radius + 0.45 m; a body that leaves alive (a boss's add) leaves no pool.
func husk_embers() -> void:
	var d := def("cinder_husk")
	var ED: Dictionary = content["EMBER_DEATH"]
	var r := float(ED["radius"])
	var c := make(411)
	var far := hero(c, FAR)
	var inside := hero(c, Vector2(5.0 + r - 0.5, 5.0))
	var out := hero(c, Vector2(5.0 + r + 0.45 + 0.05, 5.0))    # just outside the pool and its 0.45 m of a body
	var rim := hero(c, Vector2(5.0, 5.0 + r + 0.45 - 0.02))    # just inside it
	var id: int = c.spawn_enemy("cinder_husk", Vector2(5, 5), 4, 2.0, 1.5, false, PYRE, false)
	events(c)
	c.damage(id, 1.0e9, far, false)
	var log := []
	drain(c, log)
	var died := of(log, EV_DIED, id)
	var zones := of(log, PF_EV_ZONE)
	check(died.size() == 1 and zones.size() == 1 and log.find(zones[0]) > log.find(died[0]), "husk: one pool, told after `died`")
	if zones.is_empty():
		return
	var z: Dictionary = zones[0]
	var dmg := float(d["damage"]) * 1.5
	check(z["ints"][0] == PF_ZONE_EMBER and z["ints"][1] == id and is_equal_approx(z["floats"][0], 5.0) and is_equal_approx(z["floats"][1], 5.0) and is_equal_approx(z["floats"][2], r) and is_equal_approx(z["floats"][3], float(ED["poolS"])),
		"husk: a pool of kind ember, owned by the husk, at its place, r %.1f for %.0f s" % [r, float(ED["poolS"])])
	var zid: int = z["id"]
	var dps := dmg * float(ED["poolDpsMult"])
	run(c, 200, log)
	var ticks := pf_pulse_ticks(float(ED["poolS"]), 1.0)
	var mine := pf_zone_hits(log, id, inside)
	check(mine.size() == ticks.size() and mine.size() >= 2 and mine.all(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], dps) and e["ints"][1] == PF_HK_BURN),
		"husk: %d burns of %.2f (0.3 x %.0f x the spawn's 1.5) as burn, once a second for %.0f s" % [ticks.size(), dps, float(d["damage"]), float(ED["poolS"])])
	check(mine.map(func(e: Dictionary) -> int: return int(e["tick"])) == ticks, "husk: on ticks %s" % str(ticks))
	check(pf_zone_hits(log, id, out).is_empty() and pf_zone_hits(log, id, rim).size() == ticks.size() and pf_zone_hits(log, id, far).is_empty(), "husk: the rim (radius + 0.45 m) burns, a hero a step beyond it does not")
	check(of(log, PF_EV_ZONE_PULSE, zid).size() == ticks.size() and of(log, PF_EV_ZONE_GONE, zid).size() == 1, "husk: a pulse event each second, and the zone is gone at its end")
	# An elite doubles... x1.5 on top; its pool follows the body's damage.
	var e2 := make(412)
	var f2 := hero(e2, FAR)
	var eid: int = e2.spawn_enemy("cinder_husk", Vector2(0, 0), 1, 1.0, 2.0, true, PYRE, false)
	events(e2)
	e2.damage(eid, 1.0e9, f2, false)
	var l2 := []
	drain(e2, l2)
	var ez := of(l2, PF_EV_ZONE)
	check(ez.size() == 1, "husk: an elite falls into a pool too")
	var elog := []
	hero(e2, Vector2(0.3, 0))
	run(e2, 70, elog)
	var eh := of(elog, EV_HIT, eid)
	check(not eh.is_empty() and is_equal_approx(eh[0]["floats"][0], float(d["damage"]) * 2.0 * float(content["ELITE"]["damageMult"]) * float(ED["poolDpsMult"])), "husk: its pool follows level and elite damage (%.2f)" % (eh[0]["floats"][0] if not eh.is_empty() else -1.0))
	# A body that leaves alive (a boss's adds go with the boss) leaves nothing.
	var g := make(413)
	hero(g, FAR)
	var gid: int = g.spawn_enemy("cinder_husk", Vector2(3, 3), 1, 1.0, 1.0, false, PYRE, false)
	events(g)
	check(g.remove_enemy(gid), "husk: removed alive")
	var gl := []
	drain(g, gl)
	check(of(gl, PF_EV_ZONE).is_empty() and of(gl, EV_DIED).is_empty(), "husk: and no pool, no death")


## Otherwise a melee body: no telegraph, the blow after its wind-up for the def's damage as melee, hasted by nothing.
func husk_melee() -> void:
	var d := def("cinder_husk")
	var c := make(414)
	var h := hero(c, Vector2(3, 0))
	var id: int = c.spawn_enemy("cinder_husk", Vector2(0, 0), 1, 1.0, 1.0, false, PYRE, false)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var log := []
	run(c, 400, log)
	var att := of(log, EV_ATTACK, id)
	check(not att.is_empty() and att[0]["ints"][0] == 0 and of(log, EV_TELEGRAPH, id).is_empty() and int(att[0]["tick"]) >= to_zero(cd0), "husk: a plain swing with no telegraph, not before its cooldown (tick %d of %d)" % [int(att[0]["tick"]) if not att.is_empty() else -1, to_zero(cd0)])
	var hits := of(log, EV_HIT, id)
	check(not hits.is_empty() and int(hits[0]["tick"]) == int(att[0]["tick"]) + to_reach(float(d["windupMs"]) / 1000.0) and hits[0]["floats"][0] == float(d["damage"]) and hits[0]["ints"][1] == PF_HK_MELEE and hits[0]["ints"][0] == h,
		"husk: it lands %.1f s later for %d, as melee" % [float(d["windupMs"]) / 1000.0, int(d["damage"])])
	check(c.enemy_info(id)["state"] != DEAD and is_equal_approx(float(d["cooldownMs"]) / 1000.0, 1.2), "husk: the cooldown is the def's %.1f s" % [float(d["cooldownMs"]) / 1000.0])


# ------------------------------------------------------------------------------------------------------------------ the Pyre Priest

## The caster set (dm_state_kite: cast at attackRange - 0.5, walk in beyond - 1.5, no silence check) with a coal: the ring of EMBER_BOLT.radius at the place its target stood when the wind-up
## began, everything inside it takes the blow as "ember" at the end of it, and the ground burns there (a pool, 0.4 x the blow a second for poolS). Stepping out of the ring dodges the blow, not the pool.
func priest_coal() -> void:
	var d := def("pyre_priest")
	var EB: Dictionary = content["EMBER_BOLT"]
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var r := float(EB["radius"])
	var cast_at := float(d["attackRange"]) - 0.5
	for stay in [true, false]:
		var c := make(421)
		var a := hero(c, Vector2(14, 0))
		var b := hero(c, Vector2(14.0 + r - 0.05, 0))     # inside the ring, behind the target
		var o := hero(c, Vector2(14.0 + r + 0.05, 0))     # just outside it
		var th: int = pf_thralls(c, a, [Vector2(14, -1.5)])[0]
		var log := []
		var id: int = c.spawn_enemy("pyre_priest", Vector2(0, 0), 1, 1.0, 1.0, false, PYRE, false)
		drain(c, log)
		var xs: Array = []
		var k0 := -1
		for i in 900:
			run(c, 1, log)
			xs.append(Vector2(c.enemy_info(id)["pos"]))
			if not of(log, EV_TELEGRAPH, id, PF_TELL_EMBER).is_empty():
				k0 = tick
				break
		check(k0 > 0, "coal: it casts")
		if k0 < 0:
			return
		var tell := of(log, EV_TELEGRAPH, id, PF_TELL_EMBER)
		var f: PackedFloat32Array = tell[0]["floats"]
		var from: Vector2 = xs[xs.size() - 2]
		check(absf(f[0] - from.x) < 1e-5 and is_equal_approx(f[2], 14.0) and is_equal_approx(f[3], 0.0) and is_equal_approx(f[4], r) and is_equal_approx(f[5], windup), "coal: a ring of %.1f m on the target for %.2f s" % [r, windup])
		var d_start := Vector2(14, 0).distance_to(xs[xs.size() - 2])
		check(d_start <= cast_at and d_start > cast_at - float(c.enemy_info(id)["speed"]) * DT * 1.5, "coal: cast from %.2f m (attackRange - 0.5 = %.1f)" % [d_start, cast_at])
		var att := of(log, EV_ATTACK, id)
		check(att.size() == 1 and att[0]["ints"][0] == PF_BLOW_EMBER, "coal: the swing is a coal")
		if not stay:
			c.set_external(a, Vector2(14.0 + 4.0, 0), true)    # steps out of the ring
		var ks := k0 + to_reach(windup)
		run_to(c, ks - 1, log)
		check(of(log, EV_HIT, id).is_empty() and of(log, PF_EV_ZONE).is_empty() and float(c.thrall_info(th)["hp"]) == 100.0, "coal: nothing lands before the wind-up ends")
		run_to(c, ks, log)
		var hits := of(log, EV_HIT, id).filter(func(e: Dictionary) -> bool: return int(e["tick"]) == ks)
		var got := hits.map(func(e: Dictionary) -> int: return e["ints"][0])
		got.sort()
		var want: Array = [a, b] if stay else [b]
		want.sort()
		check(got == want and hits.all(func(e: Dictionary) -> bool: return e["floats"][0] == float(d["damage"]) and e["ints"][1] == PF_HK_EMBER),
			"coal: %s: the ring takes the heroes inside it (%s) for %d as ember on tick %d, not the one just outside it" % ["standing in it" if stay else "stepping out", str(got), int(d["damage"]), ks])
		check(is_equal_approx(float(c.thrall_info(th)["hp"]), 100.0 - float(d["damage"])), "coal: and a thrall inside it (%.0f of 100 left)" % float(c.thrall_info(th)["hp"]))
		var zones := of(log, PF_EV_ZONE)
		check(zones.size() == 1 and int(zones[0]["tick"]) == ks and zones[0]["ints"][0] == PF_ZONE_EMBER and zones[0]["ints"][1] == id and is_equal_approx(zones[0]["floats"][0], 14.0)
			and is_equal_approx(zones[0]["floats"][1], 0.0) and is_equal_approx(zones[0]["floats"][2], r) and is_equal_approx(zones[0]["floats"][3], float(EB["poolS"])), "coal: the ground burns at the aim (r %.1f for %.0f s), told after the blows" % [r, float(EB["poolS"])])
		check(log.find(zones[0]) > log.find(hits[hits.size() - 1]), "coal: (after the last blow in the buffer)")
		check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "coal: the cooldown is %.1f s from the blow" % cooldown)
		run_to(c, ks + 250, log)      # (the pool's four seconds; the next coal is a cooldown and a wind-up away)
		var dps := float(d["damage"]) * float(EB["poolDpsMult"])
		var ticks := pf_pulse_ticks(float(EB["poolS"]), 1.0)
		var burns := pf_zone_hits(log, id, b).filter(func(e: Dictionary) -> bool: return e["ints"][1] == PF_HK_BURN)
		check(burns.size() == ticks.size() and burns.all(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], dps)), "coal: the pool burns the hero in it %d times for %.1f (0.4 x %d)%s" % [ticks.size(), dps, int(d["damage"]), " (the one who stepped out was spared the blow, not the ground)" if not stay else ""])
	# Bone Hex softens the coal and its pool (DmPfUtil.blow: the body's damage x its status set's damage dealt); the pool is made of the softened blow.
	var h := make(422)
	var hh := hero(h, Vector2(8, 0))
	var hid: int = h.spawn_enemy("pyre_priest", Vector2(0, 0), 1, 1.0, 1.0, false, PYRE, false)
	h.apply_status(hid, "hex", 0, 1.0, 1000.0)
	var soft := float(statuses["BONE_HEX"]["damageMult"])
	check(is_equal_approx(h.damage_dealt_mult(hid), soft), "coal: Bone Hex is x%.2f on what it deals" % soft)
	var hl := []
	run(h, to_zero(float(h.enemy_info(hid)["attack_cd"])) + to_reach(windup) + 70, hl)
	var hb := of(hl, EV_HIT, hid)
	check(not hb.is_empty() and is_equal_approx(hb[0]["floats"][0], float(d["damage"]) * soft) and hb[0]["ints"][0] == hh, "coal: a hexed priest's coal is %.2f, not %d" % [hb[0]["floats"][0] if not hb.is_empty() else -1.0, int(d["damage"])])
	var pb := hb.filter(func(e: Dictionary) -> bool: return e["ints"][1] == PF_HK_BURN)
	check(not pb.is_empty() and is_equal_approx(pb[0]["floats"][0], float(d["damage"]) * soft * float(EB["poolDpsMult"])), "coal: and its pool %.2f a second" % [pb[0]["floats"][0] if not pb.is_empty() else -1.0])
	# Silence does not stop it: its walk is dm_state_kite, which does not look (the cloister casters' does).
	var s := make(423)
	hero(s, Vector2(6, 0))
	var sid: int = s.spawn_enemy("pyre_priest", Vector2(0, 0), 1, 1.0, 1.0, false, PYRE, false)
	silence(s, sid)
	var sl := []
	run(s, 400, sl)
	check(not of(sl, EV_TELEGRAPH, sid, PF_TELL_EMBER).is_empty(), "coal: a silenced priest still throws (its walk does not look)")


## The walk of the caster set for the priest: walk in at full speed beyond attackRange - 1.5, hold between, back off at 0.8 x under 3.5 m.
func priest_walk() -> void:
	var d := def("pyre_priest")
	var walk_in := float(d["attackRange"]) - 1.5
	var windup := float(d["windupMs"]) / 1000.0
	var c := make(424)
	var h := hero(c, Vector2(14.9, 0))
	var id: int = c.spawn_enemy("pyre_priest", Vector2(0, 0), 1, 1.0, 1.0, false, PYRE, false)
	var spd := float(c.enemy_info(id)["speed"])
	var log := []
	run(c, 30, log)
	var p0: Vector2 = c.enemy_info(id)["pos"]
	run(c, 1, log)
	var p1: Vector2 = c.enemy_info(id)["pos"]
	check(absf((p1.x - p0.x) - spd * DT) < 2e-4 and Vector2(14.9, 0).distance_to(p0) > walk_in, "walk: %.4f m a tick (full speed %.4f) while the target is beyond %.1f m" % [p1.x - p0.x, spd * DT, walk_in])
	for i in 600:
		run(c, 1, log)
		if not of(log, EV_TELEGRAPH, id, PF_TELL_EMBER).is_empty():
			break
	var ks := tick + to_reach(windup)
	run_to(c, ks + 80, log)
	var rest: Vector2 = c.enemy_info(id)["pos"]
	var dist := Vector2(14.9, 0).distance_to(rest)
	check(dist <= walk_in + 1e-3 and dist > walk_in - spd * DT * 1.5, "walk: holds at %.2f m (%.1f - one step)" % [dist, walk_in])
	c.set_external(h, Vector2(rest.x + 2.0, rest.y), true)
	var x0 := Vector2(c.enemy_info(id)["pos"]).x
	run(c, 1, log)
	var x1 := Vector2(c.enemy_info(id)["pos"]).x
	check(absf((x0 - x1) - spd * float(KITE["BACK_OFF_SPEED"]) * DT) < 2e-4, "walk: backs off at %.1f x its speed (%.4f m a tick) when the hero comes within 3.5 m" % [float(KITE["BACK_OFF_SPEED"]), x0 - x1])


# ------------------------------------------------------------------------------------------------------------------ the Cinderhound and the Mire Leech

## The flank kinds: the goal is offset sideways by min(3, d x 0.45) beyond 2.5 m (a wide arc to a hero 14 m away), a plain bite after its wind-up with no telegraph; the hound's corpse is
## swift and it leaves no pool; the leech's bite is toxic, it is tiny and leaves no corpse.
func hound_and_leech() -> void:
	for id_name in ["cinderhound", "mire_leech"]:
		var d := def(id_name)
		var area := PYRE if id_name == "cinderhound" else FEN
		var c := make(431)
		var h := hero(c, Vector2(14, 0))
		var id: int = c.spawn_enemy(id_name, Vector2(0, 0), 1, 1.0, 1.0, false, area, false)
		var log := []
		var widest := 0.0
		for i in 900:
			run(c, 1, log)
			widest = maxf(widest, absf(Vector2(c.enemy_info(id)["pos"]).y))
			if not of(log, EV_ATTACK, id).is_empty():
				break
		var att := of(log, EV_ATTACK, id)
		check(widest > 1.0 and widest < 3.2, "%s: flanks wide on the way in (%.2f m off the line, at most min(3, 0.45 d) = 3 m)" % [id_name, widest])
		check(att.size() == 1 and att[0]["ints"][0] == 0 and of(log, EV_TELEGRAPH, id).is_empty(), "%s: a plain swing, no telegraph" % id_name)
		var dd := Vector2(c.enemy_info(id)["pos"]).distance_to(Vector2(14, 0))
		check(dd <= float(d["attackRange"]) + float(K["ATTACK_TRIGGER_PAD"]) + 0.1, "%s: it swings from %.2f m (attack range %.1f + %.2f)" % [id_name, dd, float(d["attackRange"]), float(K["ATTACK_TRIGGER_PAD"])])
		var ks := int(att[0]["tick"]) + to_reach(float(d["windupMs"]) / 1000.0)
		run_to(c, ks, log)
		check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), float(d["cooldownMs"]) / 1000.0), "%s: the cooldown is the def's %.2f s from the blow" % [id_name, float(d["cooldownMs"]) / 1000.0])
		var hits := of(log, EV_HIT, id)
		var want_kind := PF_HK_TOXIC if id_name == "mire_leech" else PF_HK_MELEE
		check(not hits.is_empty() and int(hits[0]["tick"]) == int(att[0]["tick"]) + to_reach(float(d["windupMs"]) / 1000.0) and hits[0]["floats"][0] == float(d["damage"]) and hits[0]["ints"][1] == want_kind and hits[0]["ints"][0] == h,
			"%s: it bites %.2f s later for %d as %s" % [id_name, float(d["windupMs"]) / 1000.0, int(d["damage"]), "toxic (a rot bite)" if want_kind == PF_HK_TOXIC else "melee"])
		# The fall.
		events(c)
		c.damage(id, 1.0e9, h, false)
		var dl := []
		drain(c, dl)
		var corpses := of(dl, EV_CORPSE_ADDED)
		if id_name == "cinderhound":
			check(corpses.size() == 1 and corpses[0]["ints"][0] == PF_CK_SWIFT and of(dl, PF_EV_ZONE).is_empty(), "cinderhound: it falls leaving a swift corpse and no pool")
		else:
			check(corpses.is_empty() and c.corpse_count() == 0 and of(dl, PF_EV_ZONE).is_empty(), "leech: it falls leaving no corpse")


# ------------------------------------------------------------------------------------------------------------------ the Slag Brute

## The slam of the hazards (radius slamRadius, the aim fixed when the wind-up starts) with a burning pool on the aim: SLAG_POOL poolS seconds at 0.3 x its damage a second, of the slam's
## radius, told after the blows and the cue. Its fall is its own corpse and no pool; Bone Hex does not soften the slam or its pool (the hazard's strike uses `damage`).
func slag_slam_and_pool() -> void:
	var d := def("slag_brute")
	var SP: Dictionary = content["SLAG_POOL"]
	var r := float(d["slamRadius"])
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	for hexed in [false, true]:
		var c := make(441)
		var a := hero(c, Vector2(4, 0))
		var inside := hero(c, Vector2(4, r - 0.1))
		var outside := hero(c, Vector2(4, r + 0.1))
		var id: int = c.spawn_enemy("slag_brute", Vector2(0, 0), 1, 1.0, 1.0, false, PYRE, false)
		if hexed:
			c.apply_status(id, "hex", 0, 1.0, 1000.0)
		var log := []
		for i in 1500:
			run(c, 1, log)
			if not of(log, EV_TELEGRAPH, id, TELL_SLAM).is_empty():
				break
		var tell := of(log, EV_TELEGRAPH, id, TELL_SLAM)
		check(tell.size() == 1, "slag: a slam telegraph (hexed %s)" % str(hexed))
		if tell.is_empty():
			return
		var k0 := int(tell[0]["tick"])
		var f: PackedFloat32Array = tell[0]["floats"]
		check(is_equal_approx(f[2], 4.0) and is_equal_approx(f[3], 0.0) and is_equal_approx(f[4], r) and is_equal_approx(f[5], windup), "slag: the circle (r %.1f) at the hero's place for %.1f s" % [r, windup])
		var ks := k0 + to_reach(windup)
		run_to(c, ks, log)
		var hits := of(log, EV_HIT, id)
		var who := {}
		for e in hits:
			who[int(e["ints"][0])] = [e["floats"][0], e["ints"][1], int(e["tick"])]
		check(who.has(a) and who.has(inside) and not who.has(outside) and hits.size() == 2, "slag: the slam reaches the two heroes within %.1f m of the aim, not the one beyond (%s)" % [r, str(who.keys())])
		check(who.has(a) and who[a][0] == float(d["damage"]) and who[a][1] == PF_HK_MELEE and who[a][2] == ks, "slag: %d damage%s, melee, on tick %d" % [int(d["damage"]), " (Bone Hex does not soften it)" if hexed else "", ks])
		var cue := of(log, EV_CUE, id, CUE_SLAM)
		var zones := of(log, PF_EV_ZONE)
		check(cue.size() == 1 and zones.size() == 1 and log.find(zones[0]) > log.find(cue[0]) and log.find(cue[0]) > log.find(hits[hits.size() - 1]), "slag: the blows, the slam cue, then the pool")
		var z: Dictionary = zones[0]
		check(z["ints"][0] == PF_ZONE_EMBER and z["ints"][1] == id and is_equal_approx(z["floats"][0], 4.0) and is_equal_approx(z["floats"][1], 0.0) and is_equal_approx(z["floats"][2], r) and is_equal_approx(z["floats"][3], float(SP["poolS"])),
			"slag: a pool on the aim, r %.1f (the slam's) for %.0f s" % [r, float(SP["poolS"])])
		check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "slag: the cooldown is %.1f s" % cooldown)
		run_to(c, ks + 250, log)      # (the pool's four seconds; the next slam is a cooldown and a wind-up away)
		var dps := float(d["damage"]) * float(SP["poolDpsMult"])
		var ticks := pf_pulse_ticks(float(SP["poolS"]), 1.0)
		var burns := pf_zone_hits(log, id, a).filter(func(e: Dictionary) -> bool: return e["ints"][1] == PF_HK_BURN)
		check(burns.size() == ticks.size() and burns.all(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], dps)), "slag: the pool burns %d times for %.1f (0.3 x %d)" % [ticks.size(), dps, int(d["damage"])])
		check(not pf_zone_hits(log, id, outside).is_empty(), "slag: (and the rim, %.2f m from the centre, burns too)" % (r + 0.1))
		if hexed:
			continue
		# Its fall: a resonant corpse and no pool.
		events(c)
		var before: int = c.corpse_count()
		c.damage(id, 1.0e9, a, false)
		var dl := []
		drain(c, dl)
		var corpses := of(dl, EV_CORPSE_ADDED)
		check(of(dl, PF_EV_ZONE).is_empty() and corpses.size() == 1 and corpses[0]["ints"][0] == PF_CK_RESONANT and c.corpse_count() == before + 1, "slag: it falls leaving a resonant corpse and no pool of its own")


# ------------------------------------------------------------------------------------------------------------------ the Bog Hag

## The hex: the ring of HAG_HEX.radius is aimed at the thrall in the thickest knot of thralls (most living thralls within the radius, itself included) among those within attackRange of the
## hag, the first in raise order on a tie, a far thrall counting as a neighbour but not as a candidate; with none, at the target. At the end of the wind-up everything inside takes
## blowMult x the blow as "curse", thralls are cursed for durationS (and a thrall the blow killed is not), heroes are chilled for chillMs.
func hag_hex() -> void:
	var d := def("bog_hag")
	var H: Dictionary = fen["HAG_HEX"]
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var r := float(H["radius"])
	var c := make(451)
	var a := hero(c, Vector2(1.5, 23))
	var ths := pf_thralls(c, a, [Vector2(0, 22), Vector2(1, 22), Vector2(3.4, 22.5), Vector2(-8, 20)])   # three in a knot (the middle one the centre of it), one out of the hag's reach
	var id: int = c.spawn_enemy("bog_hag", Vector2(0, 14), 1, 1.0, 1.0, false, FEN, false)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var t0 := tick
	var log := []
	run_to(c, t0 + to_zero(cd0), log)
	var tell := of(log, EV_TELEGRAPH, id, PF_TELL_HEX)
	check(tell.size() == 1 and int(tell[0]["tick"]) == t0 + to_zero(cd0), "hex: the telegraph on the tick the cooldown is up (%d ticks after it appeared)" % to_zero(cd0))
	if tell.is_empty():
		return
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[2], 1.0) and is_equal_approx(f[3], 22.0) and is_equal_approx(f[4], r) and is_equal_approx(f[5], windup), "hex: a ring of %.1f m on the thrall at the centre of the knot (1, 22), for %.1f s" % [r, windup])
	var att := of(log, EV_ATTACK, id)
	check(att.size() == 1 and att[0]["ints"][0] == PF_BLOW_HEX and is_equal_approx(att[0]["floats"][0], 1.0) and is_equal_approx(att[0]["floats"][1], 22.0), "hex: the swing is a hex, aimed at the knot")
	check(absf(angle_difference(float(c.enemy_info(id)["yaw"]), atan2(1.0, 8.0))) < 1e-4, "hex: and the hag turns to face it")
	var ks: int = int(tell[0]["tick"]) + to_reach(windup)
	c.set_thrall_pos(ths[0], Vector2(0, 22))
	run_to(c, ks - 1, log)
	check(of(log, EV_HIT, id).is_empty() and of(log, PF_EV_EFFECT).is_empty() and float(c.thrall_info(ths[0])["cursed_t"]) == 0.0, "hex: nothing lands before the wind-up ends")
	run_to(c, ks, log)
	var dmg := float(d["damage"]) * float(H["blowMult"])
	var hits := of(log, EV_HIT, id)
	check(hits.size() == 1 and hits[0]["ints"][0] == a and hits[0]["ints"][1] == HK_CURSE and is_equal_approx(hits[0]["floats"][0], dmg) and int(hits[0]["tick"]) == ks, "hex: the hero in the ring takes %.1f (x%.2f) as curse on tick %d" % [dmg, float(H["blowMult"]), ks])
	for k in 3:
		check(is_equal_approx(float(c.thrall_info(ths[k])["hp"]), 100.0 - dmg), "hex: thrall %d in the ring takes %.1f" % [k + 1, dmg])
		check(is_equal_approx(float(c.thrall_info(ths[k])["cursed_t"]), float(H["durationS"]) - DT), "hex: and is cursed for %.0f s (one tick of it gone: it counts down in its own step)" % float(H["durationS"]))
	check(float(c.thrall_info(ths[3])["hp"]) == 100.0 and float(c.thrall_info(ths[3])["cursed_t"]) == 0.0, "hex: the thrall outside the ring is untouched")
	var fx := of(log, PF_EV_EFFECT, id)
	check(fx.size() == 1 and fx[0]["ints"][0] == a and fx[0]["ints"][1] == PF_TE_CHILL and is_equal_approx(fx[0]["floats"][0], float(H["chillMs"]) / 1000.0) and log.find(fx[0]) > log.find(hits[0]),
		"hex: the hero is chilled for %.1f s (after the blow), the thralls are not" % (float(H["chillMs"]) / 1000.0))
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "hex: the cooldown is %.1f s from the blow" % cooldown)
	# The cursed count runs out in its seconds (the hag falls so that it does not hex again).
	c.damage(id, 1.0e9, a, false)
	run(c, to_reach(float(H["durationS"]) - 0.5), log)
	check(float(c.thrall_info(ths[0])["cursed_t"]) > 0.0, "hex: the curse is still on half a second before its %.0f s are over" % float(H["durationS"]))
	run(c, to_reach(0.5) + 2, log)
	check(float(c.thrall_info(ths[0])["cursed_t"]) == 0.0, "hex: and it is over after %.0f s" % float(H["durationS"]))


## The knot: a tie goes to the first thrall raised; a far thrall counts toward a knot but is not itself a candidate; with no thrall in reach the target is the aim; a thrall the hex kills is
## not cursed; a Bone Hex-softened hag hexes softer.
func hag_aim() -> void:
	var d := def("bog_hag")
	var H: Dictionary = fen["HAG_HEX"]
	var reach := float(d["attackRange"])
	# 1. Two equal knots of two: the first thrall raised.
	var c := make(452)
	var a := hero(c, Vector2(5, 30))
	pf_thralls(c, a, [Vector2(0, 22), Vector2(1, 22), Vector2(10, 22), Vector2(9, 22)])
	var id: int = c.spawn_enemy("bog_hag", Vector2(5, 14), 1, 1.0, 1.0, false, FEN, false)
	root(c, id)     # (it stays where it is: the knots are measured from here)
	var log := []
	run(c, to_zero(float(c.enemy_info(id)["attack_cd"])) + 1, log)
	var t1 := of(log, EV_TELEGRAPH, id, PF_TELL_HEX)
	check(t1.size() == 1 and is_equal_approx(t1[0]["floats"][2], 0.0) and is_equal_approx(t1[0]["floats"][3], 22.0), "hex aim: two knots of two: the first thrall raised, at (0, 22) (%s)" % str(t1[0]["floats"].slice(2, 4) if t1.size() == 1 else "none"))
	# 2. A thrall out of reach is a neighbour, not a candidate: the knot at +x has the most thralls though it is raised second.
	var c2 := make(453)
	var a2 := hero(c2, Vector2(0, 30))
	pf_thralls(c2, a2, [Vector2(-9.0, 0), Vector2(9.0, 0), Vector2(11.9, 0)])
	var id2: int = c2.spawn_enemy("bog_hag", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(c2, id2)
	var l2 := []
	run(c2, to_zero(float(c2.enemy_info(id2)["attack_cd"])) + 1, l2)
	var t2 := of(l2, EV_TELEGRAPH, id2, PF_TELL_HEX)
	check(t2.size() == 1 and is_equal_approx(t2[0]["floats"][2], 9.0) and is_equal_approx(t2[0]["floats"][3], 0.0) and Vector2(11.9, 0).length() > reach,
		"hex aim: a thrall at 11.9 m (beyond the hag's %.1f m) counts toward the knot at (9, 0), which has the most, and is not a candidate (%s)" % [reach, str(t2[0]["floats"].slice(2, 4) if t2.size() == 1 else "none")])
	# 3. No thrall within reach: the target.
	var c3 := make(454)
	var a3 := hero(c3, Vector2(0, 9))
	pf_thralls(c3, a3, [Vector2(0, -10.0)])
	var id3: int = c3.spawn_enemy("bog_hag", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(c3, id3)
	var l3 := []
	run(c3, to_zero(float(c3.enemy_info(id3)["attack_cd"])) + 1, l3)
	var t3 := of(l3, EV_TELEGRAPH, id3, PF_TELL_HEX)
	check(t3.size() == 1 and is_equal_approx(t3[0]["floats"][2], 0.0) and is_equal_approx(t3[0]["floats"][3], 9.0), "hex aim: no thrall within reach (the one at 10 m is beyond): the ring is on the hero it hunts (%s)" % str(t3[0]["floats"].slice(2, 4) if t3.size() == 1 else "none"))
	# 4. A thrall the hex kills is not cursed; a hexed hag hexes softer (blowMult x the softened blow).
	var c4 := make(455)
	var a4 := hero(c4, Vector2(0, 30))
	var weak: int = pf_thralls(c4, a4, [Vector2(0, 9)], 3.0)[0]
	var id4: int = c4.spawn_enemy("bog_hag", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	c4.apply_status(id4, "hex", 0, 1.0, 1000.0)
	var l4 := []
	run(c4, to_zero(float(c4.enemy_info(id4)["attack_cd"])) + to_reach(float(d["windupMs"]) / 1000.0) + 2, l4)
	var soft := float(d["damage"]) * float(statuses["BONE_HEX"]["damageMult"]) * float(H["blowMult"])
	var died := of(l4, 26, weak)    # EV_THRALL_DIED
	check(died.size() == 1 and soft > 3.0 and float(c4.thrall_info(weak)["cursed_t"]) == 0.0, "hex aim: a thrall the hex kills (%.2f against 3 health) is not cursed" % soft)
	var c5 := make(456)
	var a5 := hero(c5, Vector2(0, 8))
	var id5: int = c5.spawn_enemy("bog_hag", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	c5.apply_status(id5, "hex", 0, 1.0, 1000.0)
	var l5 := []
	run(c5, to_zero(float(c5.enemy_info(id5)["attack_cd"])) + to_reach(float(d["windupMs"]) / 1000.0) + 2, l5)
	var h5 := of(l5, EV_HIT, id5)
	check(not h5.is_empty() and h5[0]["ints"][0] == a5 and is_equal_approx(h5[0]["floats"][0], soft), "hex aim: a hexed hag's blow on a hero is %.2f (%d x %.2f x %.2f)" % [soft, int(d["damage"]), float(statuses["BONE_HEX"]["damageMult"]), float(H["blowMult"])])


# ------------------------------------------------------------------------------------------------------------------ the Fen Wisp

## The pulse: the ring of WISP_PULSE.radius at the aim fixed at the wind-up, everything inside takes the blow as "dust", heroes are chilled for chillMs (thralls are not), no zone is left.
func wisp_pulse() -> void:
	var d := def("fen_wisp")
	var W: Dictionary = fen["WISP_PULSE"]
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var r := float(W["radius"])
	var cast_at := float(d["attackRange"]) - 0.5
	var c := make(461)
	var a := hero(c, Vector2(14, 0))
	var b := hero(c, Vector2(14.0 + r - 0.05, 0))
	var o := hero(c, Vector2(14.0 + r + 0.05, 0))
	var th: int = pf_thralls(c, a, [Vector2(14, -1.5)])[0]
	var log := []
	var id: int = c.spawn_enemy("fen_wisp", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	drain(c, log)
	var xs: Array = []
	var k0 := -1
	for i in 900:
		run(c, 1, log)
		xs.append(Vector2(c.enemy_info(id)["pos"]))
		if not of(log, EV_TELEGRAPH, id, PF_TELL_PULSE).is_empty():
			k0 = tick
			break
	check(k0 > 0, "pulse: it casts")
	if k0 < 0:
		return
	var f: PackedFloat32Array = of(log, EV_TELEGRAPH, id, PF_TELL_PULSE)[0]["floats"]
	check(is_equal_approx(f[2], 14.0) and is_equal_approx(f[3], 0.0) and is_equal_approx(f[4], r) and is_equal_approx(f[5], windup), "pulse: a ring of %.1f m on the target for %.1f s" % [r, windup])
	var d_start := Vector2(14, 0).distance_to(xs[xs.size() - 2])
	check(d_start <= cast_at and d_start > cast_at - float(c.enemy_info(id)["speed"]) * DT * 1.5, "pulse: cast from %.2f m (attackRange - 0.5 = %.1f)" % [d_start, cast_at])
	check(of(log, EV_ATTACK, id)[0]["ints"][0] == PF_BLOW_PULSE, "pulse: the swing is a pulse")
	var ks := k0 + to_reach(windup)
	run_to(c, ks, log)
	var hits := of(log, EV_HIT, id)
	var got := hits.map(func(e: Dictionary) -> int: return e["ints"][0])
	got.sort()
	check(got == [a, b] and hits.all(func(e: Dictionary) -> bool: return e["floats"][0] == float(d["damage"]) and e["ints"][1] == PF_HK_DUST and int(e["tick"]) == ks) and not got.has(o),
		"pulse: the ring takes the two heroes inside it for %d as dust on tick %d, not the one just outside" % [int(d["damage"]), ks])
	check(is_equal_approx(float(c.thrall_info(th)["hp"]), 100.0 - float(d["damage"])), "pulse: and the thrall inside it (%.0f of 100 left)" % float(c.thrall_info(th)["hp"]))
	var fx := of(log, PF_EV_EFFECT, id)
	var chilled := fx.map(func(e: Dictionary) -> int: return e["ints"][0])
	chilled.sort()
	check(chilled == [a, b] and fx.all(func(e: Dictionary) -> bool: return e["ints"][1] == PF_TE_CHILL and is_equal_approx(e["floats"][0], float(W["chillMs"]) / 1000.0)),
		"pulse: both heroes are chilled for %.1f s, the thrall is not" % (float(W["chillMs"]) / 1000.0))
	check(of(log, PF_EV_ZONE).is_empty() and of(log, EV_CUE, id).is_empty(), "pulse: it leaves no zone, and has no cue")
	check(is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "pulse: the cooldown is %.1f s from the blow" % cooldown)
	check(of(events(c), EV_CORPSE_ADDED).is_empty() and c.corpse_count() == 0, "pulse: (no corpse yet)")
	c.damage(id, 1.0e9, a, false)
	check(of(events(c), EV_CORPSE_ADDED).is_empty() and c.corpse_count() == 0, "pulse: it falls leaving no corpse")


## The lure (dm_state_pf_lure_kite): when its target is inside 3.5 m and the cast is not ready it backs off at 0.8 x its speed toward the open water, the heading 0.55 away from the
## target and 0.45 toward FEN_LURE, not straight away; when the cast is ready it casts; the lure is data.
func wisp_lure() -> void:
	var d := def("fen_wisp")
	var L: Dictionary = fen["FEN_LURE"]
	for lure: Vector2 in [Vector2(float(L["x"]), float(L["z"])), Vector2(44.0, 79.0)]:
		var c := make(462)
		if lure != Vector2(float(L["x"]), float(L["z"])):
			c.load_legion_tuning({"fen": {"FEN_LURE": {"x": lure.x, "z": lure.y}}})
		var h := hero(c, Vector2(2, 0))
		var id: int = c.spawn_enemy("fen_wisp", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
		var cd0 := float(c.enemy_info(id)["attack_cd"])
		var log := []
		var k := -1
		for i in 60:
			run(c, 1, log)
			if c.enemy_info(id)["state"] == CHASE:
				k = tick
				break
		check(k > 0, "lure: it hunts")
		var p0: Vector2 = c.enemy_info(id)["pos"]
		var spd := float(c.enemy_info(id)["speed"])
		run(c, 1, log)
		var p1: Vector2 = c.enemy_info(id)["pos"]
		var away := (p0 - Vector2(2, 0)).normalized()
		var toward := (lure - p0).normalized()
		var heading := (away * 0.55 + toward * 0.45)
		var want := heading.normalized() * spd * float(KITE["BACK_OFF_SPEED"]) * DT
		check((p1 - p0).distance_to(want) < 2e-4, "lure: %s: backs off at %.1f x its speed along %.2f x away + %.2f x toward the lure (%.4f, %.4f against %.4f, %.4f)" % [str(lure), float(KITE["BACK_OFF_SPEED"]), 0.55, 0.45, (p1 - p0).x, (p1 - p0).y, want.x, want.y])
		check(absf((p1 - p0).y) > 0.002 and (p1 - p0).dot(toward) > 0.0 and (p1 - p0).x < 0.0, "lure: not straight away from the hero: it drifts toward the water")
		# The cast comes first when it is ready: the telegraph on the tick the cooldown is up, 2 m from the hero.
		run_to(c, to_zero(cd0), log)
		check(first_tick(of(log, EV_TELEGRAPH, id, PF_TELL_PULSE)) == to_zero(cd0), "lure: and when the cast is ready it casts, however close the hero is (tick %d)" % to_zero(cd0))
		if lure == Vector2(44.0, 79.0):
			check(((p1 - p0).y > 0.0) and (p1 - p0).x < 0.0, "lure: the water is data: another FEN_LURE bends the retreat the other way")


# ------------------------------------------------------------------------------------------------------------------ the Drowned Sexton

## The chain (dm_state_pf_hook_chase, dm_enemy_pf_hazard): a hero between minRange and range away (both inclusive) with a clear line, when the swing's cooldown and the chain's own are both up,
## gets the chain before the slam: a telegraph along the line (range long), the aim fixed at the start, the chain's own cooldown starting then. At the end of the wind-up everything in the
## strip (reach range + 0.6 m, half a width halfWidth + 0.3 m) takes blowMult x the blow; a hero is dragged pullM toward the sexton (never closer than 1.6 m, nothing under 5 cm) and rooted;
## a thrall is hit and never pulled. The cue is told at the aim.
func sexton_chain() -> void:
	var d := def("drowned_sexton")
	var H: Dictionary = fen["SEXTON_HOOK"]
	var windup := float(d["windupMs"]) / 1000.0
	var cooldown := float(d["cooldownMs"]) / 1000.0
	var reach := float(H["range"]) + 0.6
	var half := float(H["halfWidth"]) + 0.3
	var c := make(471)
	var a := hero(c, Vector2(0, 7))                      # the target, 7 m out
	var near := hero(c, Vector2(half - 0.05, 7.01))      # on the edge of the strip
	var off := hero(c, Vector2(half + 0.05, 7.02))       # just beside it
	var behind := hero(c, Vector2(0, reach - 0.05))      # at the far end of the reach
	var past := hero(c, Vector2(0, reach + 0.05))        # just beyond it
	var th: int = pf_thralls(c, a, [Vector2(0, 8)])[0]   # in the strip, but a thrall (and farther than the hero, so the hero stays the target)
	var id: int = c.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(c, id)
	var cd0 := float(c.enemy_info(id)["attack_cd"])
	var t0 := tick
	var log := []
	run_to(c, t0 + to_zero(cd0) - 1, log)
	check(of(log, EV_TELEGRAPH, id).is_empty() and not bool(c.enemy_info(id)["hooking"]), "chain: nothing while the cooldown runs (%d ticks)" % (to_zero(cd0) - 1))
	run_to(c, t0 + to_zero(cd0), log)
	var tell := of(log, EV_TELEGRAPH, id, PF_TELL_HOOK)
	check(tell.size() == 1 and int(tell[0]["tick"]) == t0 + to_zero(cd0) and bool(c.enemy_info(id)["hooking"]), "chain: the telegraph on the tick the cooldown is up (tick %d), and the sexton is hooking" % (t0 + to_zero(cd0)))
	if tell.is_empty():
		return
	var k0 := int(tell[0]["tick"])
	var f: PackedFloat32Array = tell[0]["floats"]
	check(is_equal_approx(f[0], 0.0) and is_equal_approx(f[1], 0.0) and is_equal_approx(f[2], 0.0) and is_equal_approx(f[3], 7.0) and is_equal_approx(f[4], float(H["range"])) and is_equal_approx(f[5], windup),
		"chain: a strip along the line to the hero, %.1f m long, for the swing's %.1f s" % [float(H["range"]), windup])
	var att := of(log, EV_ATTACK, id)
	check(att.size() == 1 and att[0]["ints"][0] == PF_BLOW_HOOK and is_equal_approx(att[0]["floats"][1], 7.0), "chain: the swing is a hook, aimed at the hero's place")
	check(is_equal_approx(float(c.enemy_info(id)["hook_cd"]), float(H["cooldownS"])), "chain: its own cooldown of %.1f s starts at the wind-up" % float(H["cooldownS"]))
	var ks := k0 + to_reach(windup)
	run_to(c, ks - 1, log)
	check(of(log, EV_HIT, id).is_empty() and of(log, PF_EV_EFFECT).is_empty() and float(c.thrall_info(th)["hp"]) == 100.0, "chain: nothing lands before the wind-up ends")
	run_to(c, ks, log)
	var dmg := float(d["damage"]) * float(H["blowMult"])
	var hits := of(log, EV_HIT, id)
	var got := hits.map(func(e: Dictionary) -> int: return e["ints"][0])
	check(got == [a, near, behind] and hits.all(func(e: Dictionary) -> bool: return is_equal_approx(e["floats"][0], dmg) and e["ints"][1] == PF_HK_MELEE and int(e["tick"]) == ks),
		"chain: the strip takes the three heroes in it for %.1f (x%.1f) on tick %d, not the ones beside it or past its reach (%s)" % [dmg, float(H["blowMult"]), ks, str(got)])
	check(not got.has(off) and not got.has(past) and is_equal_approx(float(c.thrall_info(th)["hp"]), 100.0 - dmg), "chain: and the thrall in it too (%.1f of 100 left)" % float(c.thrall_info(th)["hp"]))
	var fx := of(log, PF_EV_EFFECT, id)
	var pulls := {}
	var roots := {}
	for e in fx:
		if e["ints"][1] == PF_TE_PULL:
			pulls[int(e["ints"][0])] = Vector2(e["floats"][1], e["floats"][2])
		elif e["ints"][1] == PF_TE_ROOT:
			roots[int(e["ints"][0])] = e["floats"][0]
	var drag := float(H["pullM"])
	var want_pull := {}
	for who in [[a, Vector2(0, 7)], [near, Vector2(half - 0.05, 7.01)], [behind, Vector2(0, reach - 0.05)]]:
		var p: Vector2 = who[1]
		want_pull[who[0]] = p + (Vector2.ZERO - p) / p.length() * drag
	var pull_ok := pulls.size() == 3
	for who in want_pull:
		pull_ok = pull_ok and pulls.has(who) and pulls[who].distance_to(want_pull[who]) < 1e-3
	check(pull_ok, "chain: each is dragged %.1f m toward the sexton (%s)" % [drag, str(pulls)])
	var root_ok := roots.size() == 3
	for who in roots:
		root_ok = root_ok and is_equal_approx(roots[who], float(H["rootMs"]) / 1000.0)
	check(root_ok and not pulls.has(th) and not roots.has(th) and not roots.has(off), "chain: and rooted for %.1f s; the thrall is neither dragged nor rooted" % (float(H["rootMs"]) / 1000.0))
	# Order: a hero's blow, then its drag, then its root; the cue comes last, on the aim.
	var order_ok := true
	for who in [a, near, behind]:
		var i_hit := -1
		var i_pull := -1
		var i_root := -1
		for i in log.size():
			var e: Dictionary = log[i]
			if e["type"] == EV_HIT and e["ints"][0] == who:
				i_hit = i
			elif e["type"] == PF_EV_EFFECT and e["ints"][0] == who and e["ints"][1] == PF_TE_PULL:
				i_pull = i
			elif e["type"] == PF_EV_EFFECT and e["ints"][0] == who and e["ints"][1] == PF_TE_ROOT:
				i_root = i
		order_ok = order_ok and i_hit >= 0 and i_hit < i_pull and i_pull < i_root
	var cue := of(log, EV_CUE, id, PF_CUE_HOOK)
	check(order_ok and cue.size() == 1 and log.find(cue[0]) == log.size() - 1 and is_equal_approx(cue[0]["floats"][0], 0.0) and is_equal_approx(cue[0]["floats"][1], 7.0) and is_equal_approx(cue[0]["floats"][2], float(H["range"])),
		"chain: blow, drag, root for each, then the hook cue on the aim")
	check(not bool(c.enemy_info(id)["hooking"]) and is_equal_approx(float(c.enemy_info(id)["attack_cd"]), cooldown), "chain: the flag is down at the blow, and the swing's cooldown (%.1f s) starts" % cooldown)
	# The next chain waits for its own cooldown, not the swing's.
	var k2 := k0 + to_zero(float(H["cooldownS"]))
	run_to(c, k2 - 1, log)
	check(of(log, EV_TELEGRAPH, id, PF_TELL_HOOK).size() == 1, "chain: no second chain before its %.1f s are up (swing cooldown %.1f s)" % [float(H["cooldownS"]), cooldown])
	run_to(c, k2, log)
	var second := of(log, EV_TELEGRAPH, id, PF_TELL_HOOK)
	check(second.size() == 2 and int(second[1]["tick"]) == k2, "chain: the second chain at %d ticks (%.1f s) after the first wind-up began (tick %d)" % [k2 - k0, float(H["cooldownS"]), k2])


## The pull's limits: never closer than 1.6 m to the sexton, nothing under 5 cm.
func sexton_pull_limits() -> void:
	var d := def("drowned_sexton")
	var H: Dictionary = fen["SEXTON_HOOK"]
	var c := make(472)
	var a := hero(c, Vector2(0, 6.2))
	var close := hero(c, Vector2(0.0, 3.0))      # in the strip, 3 m out: dragged to 1.6 m, not past it (1.4 m of the 4.5)
	var snug := hero(c, Vector2(0.0, 1.65))      # 1.65 m out: 5 cm to go, which is not enough to move
	var inside := hero(c, Vector2(0.0, 1.7))     # 1.7 m out: 10 cm to the limit
	var id: int = c.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(c, id)
	for h in [close, snug, inside]:      # (the target is the nearest hero: the near ones wait out of the way until the chain has begun, then stand in its strip)
		c.set_external(h, Vector2(30, 30), true)
	var log := []
	run(c, to_zero(float(c.enemy_info(id)["attack_cd"])) + 2, log)
	check(not of(log, EV_TELEGRAPH, id, PF_TELL_HOOK).is_empty(), "pull: the chain begins on the hero at 6.2 m")
	c.set_external(close, Vector2(0.0, 3.0), true)
	c.set_external(snug, Vector2(0.0, 1.65), true)
	c.set_external(inside, Vector2(0.0, 1.7), true)
	run(c, to_reach(float(d["windupMs"]) / 1000.0) + 2, log)
	var pulls := {}
	var roots := {}
	for e in of(log, PF_EV_EFFECT, id):
		if e["ints"][1] == PF_TE_PULL:
			pulls[int(e["ints"][0])] = Vector2(e["floats"][1], e["floats"][2])
		elif e["ints"][1] == PF_TE_ROOT:
			roots[int(e["ints"][0])] = true
	check(pulls.has(close) and pulls[close].distance_to(Vector2(0, 1.6)) < 1e-3, "pull: a hero 3 m out is dragged to 1.6 m from the sexton, not through it (%s)" % str(pulls.get(close)))
	check(pulls.has(inside) and pulls[inside].distance_to(Vector2(0, 1.6)) < 1e-3, "pull: a hero 1.7 m out is dragged the 10 cm that remain")
	check(not pulls.has(snug) and roots.has(snug), "pull: a hero at 1.65 m is not dragged (5 cm is nothing) and is rooted all the same")
	check(pulls.has(a) and pulls[a].distance_to(Vector2(0, 6.2 - float(H["pullM"]))) < 1e-3, "pull: the target, 6.2 m out, is dragged the full %.1f m (to 1.7 m)" % float(H["pullM"]))


## When the chain is not for it: a thrall is never hooked; closer than minRange or farther than range is not; a wall between blocks it; the slam is the swing at close quarters; an
## interrupted chain does not make the next slam a chain.
func sexton_gates() -> void:
	var d := def("drowned_sexton")
	var H: Dictionary = fen["SEXTON_HOOK"]
	var windup := float(d["windupMs"]) / 1000.0
	# The window: both ends inclusive.
	for trial in [[float(H["minRange"]) - 0.1, false], [float(H["minRange"]), true], [float(H["range"]), true], [float(H["range"]) + 0.05, false]]:
		var c := make(473)
		hero(c, Vector2(0, float(trial[0])))
		var id: int = c.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
		root(c, id)
		var log := []
		run(c, 300, log)
		check(of(log, EV_TELEGRAPH, id, PF_TELL_HOOK).is_empty() == (not bool(trial[1])), "chain: a hero %.2f m away is %s (minRange %.1f, range %.1f)" % [float(trial[0]), "hooked" if trial[1] else "not hooked", float(H["minRange"]), float(H["range"])])
		if not bool(trial[1]):
			check(of(log, EV_ATTACK, id).is_empty(), "chain: and out of slam reach (rooted) it does nothing at all")
	# A thrall is never hooked, whatever the distance: only a hero.
	var t := make(474)
	var owner := hero(t, FAR)
	pf_thralls(t, owner, [Vector2(0, 7)])
	var tid: int = t.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(t, tid)
	var tl := []
	run(t, 300, tl)
	check(of(tl, EV_TELEGRAPH, tid).is_empty(), "chain: a thrall 7 m away is never hooked")
	# A wall between (the Ossuary Wall as an obstacle) blocks the line; without it the chain comes.
	var w := make(475)
	hero(w, Vector2(0, 7))
	var wid: int = w.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(w, wid)
	var wall: int = w.add_obstacle(Vector2(-4, 3.5), Vector2(4, 3.5), 0.5)
	var wl := []
	var w0 := to_zero(float(w.enemy_info(wid)["attack_cd"]))
	run_to(w, w0 + 20, wl)
	check(of(wl, EV_TELEGRAPH, wid).is_empty(), "chain: a wall in the line blocks it")
	check(w.remove_obstacle(wall), "chain: the wall goes")
	run(w, 1, wl)
	check(first_tick(of(wl, EV_TELEGRAPH, wid, PF_TELL_HOOK)) == tick, "chain: and the very next tick (nothing caches the line) the chain begins")
	# A wall that is not in the way does not block it, and a wall in the way of one hero only blocks the blow on him (the strip is checked per target).
	var w2 := make(476)
	var wa := hero(w2, Vector2(0, 7))
	var wb := hero(w2, Vector2(1.1, 9.0))      # in the strip, behind a short wall
	var wid2: int = w2.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(w2, wid2)
	w2.add_obstacle(Vector2(0.3, 6.0), Vector2(1.2, 6.0), 0.4)       # across the line to the second hero (it passes x 0.73 at z 6), not across the line up the axis to the first
	var w2l := []
	run(w2, to_zero(float(w2.enemy_info(wid2)["attack_cd"])) + to_reach(windup) + 2, w2l)
	var w2h := of(w2l, EV_HIT, wid2).map(func(e: Dictionary) -> int: return e["ints"][0])
	check(w2h == [wa] and not of(w2l, PF_EV_EFFECT, wid2).filter(func(e: Dictionary) -> bool: return e["ints"][0] == wb).size() > 0, "chain: a wall across one hero's line spares him; the other is hit (%s)" % str(w2h))
	# At close quarters it slams (the plain brute chase); an interrupted chain leaves no hook behind for the slam.
	var s := make(477)
	var sh := hero(s, Vector2(0, 7))
	var sid: int = s.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(s, sid)
	var sl := []
	var s0 := to_zero(float(s.enemy_info(sid)["attack_cd"]))
	run_to(s, s0 + 18, sl)
	check(bool(s.enemy_info(sid)["hooking"]), "chain: (the chain is under way)")
	s.stun(sid, 1.0)
	drain(s, sl)
	check(s.enemy_info(sid)["state"] == HURT and not bool(s.enemy_info(sid)["hooking"]) and float(s.enemy_info(sid)["hook_cd"]) > 6.0, "chain: a stun ends the chain, and its cooldown has been spent all the same")
	var flinch_end := tick + to_reach(1.0)
	s.set_external(sh, Vector2(0, 2.0), true)        # now at slam range
	run_to(s, flinch_end + 5, sl)
	var slam := of(sl, EV_TELEGRAPH, sid, TELL_SLAM)
	check(slam.size() == 1 and of(sl, EV_TELEGRAPH, sid, PF_TELL_HOOK).size() == 1 and of(sl, EV_ATTACK, sid).back()["ints"][0] == BLOW_SLAM, "chain: back on the hunt it slams the hero at 2 m: not a chain (the flag did not survive)")
	if not slam.is_empty():
		check(is_equal_approx(slam[0]["floats"][4], float(d["slamRadius"])) and is_equal_approx(slam[0]["floats"][5], windup), "slam: a ring of %.1f m for %.1f s" % [float(d["slamRadius"]), windup])


## Its slam (r 2.5, 25) when the hero is close and the chain is not for him, and its fall: its own corpse and one risen on the ring (deathCorpses 2).
func sexton_slam_and_corpses() -> void:
	var d := def("drowned_sexton")
	var c := make(478)
	var h := hero(c, Vector2(2.0, 0))
	var id: int = c.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	var log := []
	for i in 600:
		run(c, 1, log)
		if not of(log, EV_HIT, id).is_empty():
			break
	var hits := of(log, EV_HIT, id)
	check(not hits.is_empty() and hits[0]["floats"][0] == float(d["damage"]) and hits[0]["ints"][0] == h and hits[0]["ints"][1] == PF_HK_MELEE and of(log, PF_EV_ZONE).is_empty(),
		"slam: %d damage, melee, and no pool (the sexton's slam leaves none; the Slag Brute's does)" % int(d["damage"]))
	var cue := of(log, EV_CUE, id, CUE_SLAM)
	check(cue.size() == 1 and is_equal_approx(cue[0]["floats"][2], float(d["slamRadius"])), "slam: the cue is the slam's, %.1f m" % float(d["slamRadius"]))
	events(c)
	c.damage(id, 1.0e9, h, false)
	var added := of(events(c), EV_CORPSE_ADDED)
	check(added.size() == int(d["deathCorpses"]) and added.size() == 2 and c.def_name(added[0]["ints"][1]) == "drowned_sexton" and c.def_name(added[1]["ints"][1]) == "risen" and added.all(func(e: Dictionary) -> bool: return e["ints"][0] == PF_CK_NORMAL),
		"sexton: it dies into its own corpse and one risen on the ring (deathCorpses %d), normal" % int(d["deathCorpses"]))


## Bone Hex softens the chain (the blow is the body's damage x its status set's damage dealt, then blowMult), not the slam beside it.
func sexton_hexed() -> void:
	var d := def("drowned_sexton")
	var H: Dictionary = fen["SEXTON_HOOK"]
	var c := make(479)
	var a := hero(c, Vector2(0, 7))
	var id: int = c.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(c, id)
	c.apply_status(id, "hex", 0, 1.0, 1000.0)
	var log := []
	run(c, to_zero(float(c.enemy_info(id)["attack_cd"])) + to_reach(float(d["windupMs"]) / 1000.0) + 2, log)
	var hits := of(log, EV_HIT, id)
	var soft := float(statuses["BONE_HEX"]["damageMult"])
	check(hits.size() == 1 and hits[0]["ints"][0] == a and is_equal_approx(hits[0]["floats"][0], float(d["damage"]) * soft * float(H["blowMult"])), "chain: a hexed sexton's chain is %.3f (%d x %.2f x %.1f)" % [hits[0]["floats"][0] if not hits.is_empty() else -1.0, int(d["damage"]), soft, float(H["blowMult"])])


# ------------------------------------------------------------------------------------------------------------------ the Pyre and the Fen on the wire

## A guest sees each kind's telegraphs, zones and cues: the coal (and its pool), the hex, the pulse, the chain (bit 5 of the record, as the dive is) and its cue, the Husk's embers and the
## Slag Brute's pool as reliable zone events; what a hero is made to suffer besides damage (chill, root, drag) is the host's alone, as the blow is.
func pf_on_the_wire() -> void:
	# The Pyre Priest's coal and its pool.
	var d := def("pyre_priest")
	var EB: Dictionary = content["EMBER_BOLT"]
	var windup := float(d["windupMs"]) / 1000.0
	var host := make(481)
	host.set_replication(true)
	hero(host, Vector2(7, 0))
	var id: int = host.spawn_enemy("pyre_priest", Vector2(0, 0), 3, 2.0, 1.5, false, PYRE, false)
	var guest := puppet()
	var hl := []
	var gl := []
	var t := join(host, guest, hl, gl)
	var k0 := to_zero(float(host.enemy_info(id)["attack_cd"]))
	t = lockstep(host, guest, hl, gl, t, t + k0 + 12)
	var ht := of(hl, EV_TELEGRAPH, id, PF_TELL_EMBER)
	var gt := of(gl, EV_TELEGRAPH, id, PF_TELL_EMBER)
	check(ht.size() == 1 and gt.size() == 1, "wire: the guest sees the coal's telegraph once (host %d, guest %d)" % [ht.size(), gt.size()])
	if gt.size() == 1:
		var f: PackedFloat32Array = gt[0]["floats"]
		check(absf(f[2] - 7.0) < 0.02 and absf(f[3]) < 0.02 and is_equal_approx(f[4], float(EB["radius"])) and f[5] >= 0.05 and f[5] <= windup + 1e-4, "wire: a ring of %.1f m on the hero, for what is left of the %.2f s (%.2f s)" % [float(EB["radius"]), windup, f[5]])
		check(int(gt[0]["tick"]) - int(ht[0]["tick"]) <= 6, "wire: within two snapshots of the host's (%d ticks later)" % (int(gt[0]["tick"]) - int(ht[0]["tick"])))
	check(of(gl, EV_ATTACK, id).size() == 1 and of(gl, EV_ATTACK, id)[0]["ints"][0] == PF_BLOW_EMBER, "wire: and the swing is a coal on the guest")
	t = lockstep(host, guest, hl, gl, t, t + to_reach(windup) + 10)
	var hz := of(hl, PF_EV_ZONE)
	var gz := of(gl, PF_EV_ZONE)
	check(hz.size() == 1 and gz.size() == 1 and gz[0]["id"] == hz[0]["id"] and gz[0]["ints"][0] == PF_ZONE_EMBER and gz[0]["ints"][1] == id and is_equal_approx(gz[0]["floats"][3], float(EB["poolS"])),
		"wire: the pool reaches the guest once, kind ember, with the host's id and its %.0f s" % float(EB["poolS"]))
	check(of(hl, EV_HIT, id).size() >= 1 and of(gl, EV_HIT).is_empty(), "wire: the blow on the hero is the host's alone")
	t = lockstep(host, guest, hl, gl, t, t + 70)
	check(of(gl, PF_EV_ZONE_PULSE, hz[0]["id"]).size() == 1 and of(hl, PF_EV_ZONE_PULSE, hz[0]["id"]).size() == 1, "wire: and so does its first pulse")
	# The Husk's embers and the Slag Brute's pool: a body that falls on the host, a slam on the host.
	var h2 := make(482)
	h2.set_replication(true)
	var f2 := hero(h2, Vector2(4, 0))
	var husk: int = h2.spawn_enemy("cinder_husk", Vector2(12, 12), 1, 1.0, 1.0, false, PYRE, false)
	var slag: int = h2.spawn_enemy("slag_brute", Vector2(0, 0), 1, 1.0, 1.0, false, PYRE, false)
	var g2 := puppet()
	var hl2 := []
	var gl2 := []
	t = join(h2, g2, hl2, gl2)
	h2.damage(husk, 1.0e9, f2, false)
	drain(h2, hl2)
	t = lockstep(h2, g2, hl2, gl2, t, t + to_zero(float(h2.enemy_info(slag)["attack_cd"])) + to_reach(float(def("slag_brute")["windupMs"]) / 1000.0) + 70)
	var hz2 := of(hl2, PF_EV_ZONE)
	var gz2 := of(gl2, PF_EV_ZONE)
	check(hz2.size() == 2 and gz2.size() == 2 and gz2.all(func(e: Dictionary) -> bool: return e["ints"][0] == PF_ZONE_EMBER) and gz2.map(func(e: Dictionary) -> int: return e["ints"][1]) == [husk, slag],
		"wire: the Husk's embers and the Slag Brute's pool reach the guest, in the host's order (%d, %d)" % [hz2.size(), gz2.size()])
	check(of(gl2, EV_DIED, husk).size() == 1 and of(gl2, EV_TELEGRAPH, slag, TELL_SLAM).size() == 1, "wire: and the husk's death and the slam's telegraph")
	# The hex.
	var hd := def("bog_hag")
	var H: Dictionary = fen["HAG_HEX"]
	var h3 := make(483)
	h3.set_replication(true)
	var a3 := hero(h3, Vector2(1.5, 23))
	pf_thralls(h3, a3, [Vector2(0, 22), Vector2(1, 22), Vector2(3.4, 22.5)])
	var hag: int = h3.spawn_enemy("bog_hag", Vector2(0, 14), 1, 1.0, 1.0, false, FEN, false)
	root(h3, hag)
	var g3 := puppet()
	var hl3 := []
	var gl3 := []
	g3.apply_reliable(h3.baseline())
	g3.apply_snapshot(h3.snapshot(tick))
	drain(g3, gl3)
	t = tick
	t = lockstep(h3, g3, hl3, gl3, t, t + to_zero(float(h3.enemy_info(hag)["attack_cd"])) + 12)
	var hx := of(gl3, EV_TELEGRAPH, hag, PF_TELL_HEX)
	check(hx.size() == 1 and of(hl3, EV_TELEGRAPH, hag, PF_TELL_HEX).size() == 1 and absf(hx[0]["floats"][2] - 1.0) < 0.02 and absf(hx[0]["floats"][3] - 22.0) < 0.02 and is_equal_approx(hx[0]["floats"][4], float(H["radius"])) and of(gl3, EV_ATTACK, hag)[0]["ints"][0] == PF_BLOW_HEX,
		"wire: the hex's ring reaches the guest once, %.1f m wide on the thrall at the knot's centre" % float(H["radius"]))
	t = lockstep(h3, g3, hl3, gl3, t, t + to_reach(float(hd["windupMs"]) / 1000.0) + 6)
	check(not of(hl3, PF_EV_EFFECT, hag).is_empty() and of(gl3, PF_EV_EFFECT).is_empty() and of(gl3, EV_HIT).is_empty(), "wire: and the hero's chill is the host's alone, as the blow is (host %d, guest %d)" % [of(hl3, PF_EV_EFFECT, hag).size(), of(gl3, PF_EV_EFFECT).size()])
	# The pulse.
	var wd := def("fen_wisp")
	var h4 := make(484)
	h4.set_replication(true)
	hero(h4, Vector2(6, 0))
	var wisp: int = h4.spawn_enemy("fen_wisp", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	var g4 := puppet()
	var hl4 := []
	var gl4 := []
	t = join(h4, g4, hl4, gl4)
	t = lockstep(h4, g4, hl4, gl4, t, t + to_zero(float(h4.enemy_info(wisp)["attack_cd"])) + 12)
	var pt := of(gl4, EV_TELEGRAPH, wisp, PF_TELL_PULSE)
	check(pt.size() == 1 and of(h4.take_events() if false else hl4, EV_TELEGRAPH, wisp, PF_TELL_PULSE).size() == 1 and is_equal_approx(pt[0]["floats"][4], float(fen["WISP_PULSE"]["radius"])) and of(gl4, EV_ATTACK, wisp)[0]["ints"][0] == PF_BLOW_PULSE,
		"wire: the pulse's ring reaches the guest once, %.1f m wide" % float(fen["WISP_PULSE"]["radius"]))
	# The chain: bit 5 of the record says so, the cue is a reliable event; a slam is not a chain on the guest.
	var sd := def("drowned_sexton")
	var SH: Dictionary = fen["SEXTON_HOOK"]
	var h5 := make(485)
	h5.set_replication(true)
	var a5 := hero(h5, Vector2(0, 7))
	var sext: int = h5.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	root(h5, sext)
	var g5 := puppet()
	var hl5 := []
	var gl5 := []
	t = join(h5, g5, hl5, gl5)
	var s0 := to_zero(float(h5.enemy_info(sext)["attack_cd"]))
	t = lockstep(h5, g5, hl5, gl5, t, t + s0 + 12)
	var ct := of(gl5, EV_TELEGRAPH, sext, PF_TELL_HOOK)
	check(ct.size() == 1 and of(hl5, EV_TELEGRAPH, sext, PF_TELL_HOOK).size() == 1 and of(gl5, EV_TELEGRAPH, sext, TELL_SLAM).is_empty(), "wire: the guest sees the chain's telegraph once, and no slam (host %d, guest %d)" % [of(hl5, EV_TELEGRAPH, sext, PF_TELL_HOOK).size(), ct.size()])
	if ct.size() == 1:
		var f: PackedFloat32Array = ct[0]["floats"]
		check(absf(f[2]) < 0.02 and absf(f[3] - 7.0) < 0.02 and is_equal_approx(f[4], float(SH["range"])) and f[5] >= 0.05 and f[5] <= float(sd["windupMs"]) / 1000.0 + 1e-4, "wire: along the line to the hero, %.1f m long, for what is left of the %.1f s" % [float(SH["range"]), float(sd["windupMs"]) / 1000.0])
	check(bool(g5.enemy_info(sext)["hooking"]) and of(gl5, EV_ATTACK, sext).size() == 1 and of(gl5, EV_ATTACK, sext)[0]["ints"][0] == PF_BLOW_HOOK, "wire: and its body is hooking on the guest, a hook swing")
	t = lockstep(h5, g5, hl5, gl5, t, t + to_reach(float(sd["windupMs"]) / 1000.0) + 12)
	check(of(hl5, EV_CUE, sext, PF_CUE_HOOK).size() == 1 and of(gl5, EV_CUE, sext, PF_CUE_HOOK).size() == 1, "wire: the hook cue reaches the guest once")
	check(of(hl5, EV_HIT, sext).size() == 1 and of(hl5, EV_HIT, sext)[0]["ints"][0] == a5 and of(gl5, EV_HIT).is_empty() and not of(hl5, PF_EV_EFFECT, sext).is_empty() and of(gl5, PF_EV_EFFECT).is_empty(),
		"wire: the blow and the drag and the root on the hero are the host's alone")
	check(not bool(g5.enemy_info(sext)["hooking"]) and not bool(h5.enemy_info(sext)["hooking"]), "wire: and when the chain has flown neither is hooking")
	# The slam of the same body is a slam on the guest.
	var h6 := make(486)
	h6.set_replication(true)
	hero(h6, Vector2(2.0, 0))
	var sl: int = h6.spawn_enemy("drowned_sexton", Vector2(0, 0), 1, 1.0, 1.0, false, FEN, false)
	var g6 := puppet()
	var hl6 := []
	var gl6 := []
	t = join(h6, g6, hl6, gl6)
	t = lockstep(h6, g6, hl6, gl6, t, t + to_zero(float(h6.enemy_info(sl)["attack_cd"])) + 30)
	check(of(gl6, EV_TELEGRAPH, sl, TELL_SLAM).size() == 1 and of(gl6, EV_TELEGRAPH, sl, PF_TELL_HOOK).is_empty() and of(gl6, EV_ATTACK, sl)[0]["ints"][0] == BLOW_SLAM, "wire: a slam at close quarters is a slam on the guest, not a chain")
	# A guest that does not know the Pyre's or the Fen's flags, rings or chain refuses the host's messages (the defs and the numbers are in the content hash).
	var hh := make(487)
	hero(hh, FAR)
	for k in PF_KINDS:
		hh.spawn_enemy(k, Vector2(float(PF_KINDS.find(k)) * 3.0, 0), 1, 1.0, 1.0, false, FEN, false)
	var snap: PackedByteArray = hh.snapshot(900)
	var control: RefCounted = ClassDB.instantiate("DmCore")
	control.load_enemy_defs(content["ENEMIES"])
	control.load_tuning(content)
	control.load_status_defs(DmStatusRules.build(DmCoreData.json(godot_dir.path_join("data/content/abilities.json")), statuses, content))
	control.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	control.set_puppet(true)
	check(control.apply_snapshot(snap), "wire: (a guest with the same data takes the snapshot: %s)" % control.replication_error())
	for change in [["cinder_husk", "emberDeath"], ["slag_brute", "slamPool"], ["drowned_sexton", "hook"], ["fen_wisp", "lure"], ["pyre_priest", "EMBER_BOLT"], ["bog_hag", "HAG_HEX"], ["fen_wisp", "WISP_PULSE"], ["drowned_sexton", "SEXTON_HOOK"]]:
		var odd: RefCounted = ClassDB.instantiate("DmCore")
		var defs: Dictionary = content["ENEMIES"].duplicate(true)
		var tun_content: Dictionary = content.duplicate(true)
		var fen_changed: Dictionary = fen.duplicate(true)
		match String(change[1]):
			"emberDeath", "slamPool", "hook", "lure":
				defs[change[0]].erase(change[1])
			"EMBER_BOLT":
				tun_content["EMBER_BOLT"]["radius"] = 2.5
			"HAG_HEX":
				fen_changed["HAG_HEX"]["radius"] = 4.0
			"WISP_PULSE":
				fen_changed["WISP_PULSE"]["radius"] = 3.0
			"SEXTON_HOOK":
				fen_changed["SEXTON_HOOK"]["range"] = 9.0
		odd.load_enemy_defs(defs)
		odd.load_tuning(tun_content)
		odd.load_legion_tuning({"fen": fen_changed})
		odd.load_status_defs(DmStatusRules.build(DmCoreData.json(godot_dir.path_join("data/content/abilities.json")), statuses, content))
		odd.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
		odd.set_puppet(true)
		check(not odd.apply_snapshot(snap) and "data" in str(odd.replication_error()), "wire: a guest with another %s of the %s refuses the host's snapshot (%s)" % [change[1], change[0], odd.replication_error()])


# ------------------------------------------------------------------------------------------------------------------ the roster and a replay

## The whole Pyre and Fen rosters (their enemy tables and the Fen's procession themes, leads included) are made by the core, the models are drawn by the crowd, and a seeded run replays
## event for event, with the pools and the effects on heroes in it.
func pf_roster_and_a_replay() -> void:
	var areas := DmCoreData.json(godot_dir.path_join("data/content/areas.json"))
	var ids := {}
	for area in [PYRE, FEN]:
		for e in areas["AREAS"][area]["enemies"]:
			ids[String(e["id"])] = true
	for th in content["WAVE_THEMES"][FEN]:
		for e in th["roster"]:
			ids[String(e["id"])] = true
		if th.get("lead") != null:
			ids[String(th["lead"])] = true
	var missing := []
	for id: String in ids:
		if not DmWaveDirector.runs_on_core(id):
			missing.append(id)
	var all_eight := true
	for id in PF_KINDS:
		all_eight = all_eight and ids.has(id)
	check(all_eight and missing.is_empty(), "roster: every kind of the Pyre's and the Fen's waves and processions runs on the core (%d kinds, missing %s)" % [ids.size(), str(missing)])
	var looks := DmCoreData.json("res://crowd/crowd_looks.json")
	var drawn := true
	for id in PF_KINDS:
		var slug := String(looks["enemy_model"].get(id, ""))
		var path := "res://assets/slice/models/props/%s.glb" % slug if id in ["fen_wisp", "mire_leech"] else "res://assets/slice/models/%s/character.glb" % slug
		drawn = drawn and slug != "" and FileAccess.file_exists(path)
	check(drawn and looks["casters"].has("pyre_priest") and looks["casters"].has("bog_hag") and looks["casters"].has("fen_wisp") and not looks["casters"].has("cinder_husk") and not looks["casters"].has("slag_brute"),
		"roster: the crowd draws them (their models; the priest, hag and wisp as casters)")
	check(float(def("fen_wisp")["flying"]) == 1.5 and looks["enemy_glow"].has("fen_wisp"), "roster: the wisp hovers %.1f m and glows" % float(def("fen_wisp")["flying"]))
	var logs := []
	for round in 2:
		var c := make(491)
		var h1 := hero(c, Vector2(0, 0))
		hero(c, Vector2(2, -3))
		pf_thralls(c, h1, [Vector2(-2, 2), Vector2(3, 3)], 400.0)
		var area := FEN
		c.spawn_enemy("cinder_husk", Vector2(9, 3), 4, 1.5, 1.2, false, PYRE, false)
		c.spawn_enemy("pyre_priest", Vector2(-10, 4), 4, 1.5, 1.2, true, PYRE, false)
		c.spawn_enemy("cinderhound", Vector2(-9, -8), 4, 1.5, 1.2, false, PYRE, false)
		c.spawn_enemy("slag_brute", Vector2(8, -9), 4, 1.5, 1.2, false, PYRE, false)
		c.spawn_enemy("bog_hag", Vector2(12, 11), 4, 1.5, 1.2, false, area, false)
		c.spawn_enemy("drowned_sexton", Vector2(-12, 10), 4, 1.5, 1.2, false, area, false)
		c.spawn_enemy("fen_wisp", Vector2(6, 12), 4, 1.5, 1.2, false, area, false)
		for i in 6:
			c.spawn_enemy("mire_leech" if i % 2 == 0 else "cinder_husk", Vector2(12 - i * 4, 13), 4, 1.5, 1.2, false, area, false)
		var rec := PackedInt32Array()
		var recf := PackedFloat32Array()
		for i in 1800:
			c.step(DT)
			var raw: Array = c.take_events()
			rec.append_array(raw[0])
			recf.append_array(raw[1])
			if i == 400:
				for id in c.enemy_ids():
					if c.enemy_info(id)["def"] == "cinder_husk":
						c.damage(id, 25.0, 0, true)
			if i == 700:
				for tid in c.thrall_ids():
					c.kill_thrall(tid, "killed")
		var kinds_seen := {}
		var i2 := 0
		while i2 < rec.size():
			kinds_seen[rec[i2]] = true
			i2 += 4 + rec[i2 + 2]
		logs.append([rec, recf, c.enemy_count(), c.corpse_count(), kinds_seen])
	check(logs[0][0] == logs[1][0] and logs[0][1] == logs[1][1] and logs[0][0].size() > 300, "replay: a seeded fight of the Pyre's and the Fen's eight kinds and a crowd replays event for event (%d ints)" % logs[0][0].size())
	check(logs[0][4].has(PF_EV_ZONE) and logs[0][4].has(PF_EV_EFFECT) and logs[0][4].has(EV_HIT) and logs[0][4].has(EV_TELEGRAPH), "replay: with pools, hero effects, blows and telegraphs in it")


## A stun is a hard interrupt (DmEnemy.stun): a swing in its wind-up is cancelled, so no coal, hex, pulse or slam lands, no pool is made, no chill is given and no cooldown starts.
func pf_stun_cancels() -> void:
	for trial in [["pyre_priest", PYRE, Vector2(7, 0), PF_TELL_EMBER], ["bog_hag", FEN, Vector2(7, 0), PF_TELL_HEX], ["fen_wisp", FEN, Vector2(6, 0), PF_TELL_PULSE], ["slag_brute", PYRE, Vector2(2, 0), TELL_SLAM]]:
		var c := make(495)
		hero(c, trial[2])
		var id: int = c.spawn_enemy(trial[0], Vector2(0, 0), 1, 1.0, 1.0, false, trial[1], false)
		var log := []
		for i in 600:
			run(c, 1, log)
			if not of(log, EV_TELEGRAPH, id, trial[3]).is_empty():
				break
		check(not of(log, EV_TELEGRAPH, id, trial[3]).is_empty(), "%s: it winds up" % trial[0])
		run(c, 15, log)
		c.stun(id, 3.0)
		drain(c, log)
		run(c, to_reach(float(def(trial[0])["windupMs"]) / 1000.0) - 15 + 5, log)      # (five ticks past the moment the blow would have landed; the flinch lasts three seconds)
		check(c.enemy_info(id)["state"] == HURT and of(log, EV_HIT, id).is_empty() and of(log, PF_EV_ZONE).is_empty() and of(log, PF_EV_EFFECT).is_empty() and float(c.enemy_info(id)["attack_cd"]) <= 0.0,
			"%s: a stun in the wind-up cancels the swing: no blow, no pool, no effect, no cooldown" % trial[0])
