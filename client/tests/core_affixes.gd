extends SceneTree
## Elite affixes in the combat core against DmAffixSet (archive/old-game:godot/next/affixes/dm_affix_set.gd): the bell's countdown, ring and toll, Hungering's
## meals, the shroud's 0.1 s check and Miasma hold, Vengeful's Risen inside the kill, all paused while the body cannot act. The expected
## ticks come from mirrors of today's arithmetic (the functions named *_mirror), not from hand-picked numbers.
## Run: godot --headless --path client --script res://tests/core_affixes.gd

const EV_SPAWNED := 1
const EV_STATE := 2
const EV_DIED := 4
const EV_TELEGRAPH := 7
const EV_TARGET_HIT := 9
const EV_CORPSE_CONSUMED := 19
const EV_THRALL_DAMAGED := 25
const EV_AFFIX := 32
const TELL_TOLL := 4
const HK_TOLL := 6
const CR_DEVOURED := 5
const AM_TELL := 0
const AM_TOLL := 1
const AM_HUNGERING := 2
const AM_VENGEFUL := 3
const AM_UNVEIL := 4
const RISING := 0
const IDLE := 1
const HURT := 4
const BURROW := 8
const DT := 1.0 / 60.0

var fails := 0
var checks := 0
var data := {}
var T: Dictionary   # AFFIX_TUNING
var tick := 0
var risen_n := 0    # how many Risen a Vengeful elite bursts into (AFFIX_TUNING.vengeful.risen)


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL core_affixes: " + what)


func load_json(name: String) -> Dictionary:
	var f := FileAccess.open("res://data/content/%s.json" % name, FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func make() -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(11)
	c.load_enemy_defs(data["enemies"]["ENEMIES"])
	c.load_tuning(data["enemies"])
	c.load_status_defs(DmStatusRules.build(data["abilities"], data["statuses"], data["enemies"]))
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	tick = 0
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


## Steps n ticks; every event is labelled with the tick it happened on. Events from calls between ticks count toward the next tick.
func run(c: RefCounted, n: int, log: Array) -> void:
	for i in n:
		tick += 1
		c.step(DT)
		for e in events(c):
			e["tick"] = tick
			log.append(e)


func drain(c: RefCounted, log: Array) -> void:
	for e in events(c):
		e["tick"] = tick + 1
		log.append(e)


func of(log: Array, type: int, id: int = 0, k: int = -1) -> Array:
	return log.filter(func(e: Dictionary) -> bool: return e["type"] == type and (id == 0 or e["id"] == id) and (k < 0 or e["ints"][0] == k))


func ticks_of(list: Array) -> Array:
	return list.map(func(e: Dictionary) -> int: return int(e["tick"]))


## The body's state after each tick 0..n (from its STATE events), for "does it act on tick i".
func states(log: Array, id: int, first: int, n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n + 1)
	var s := first
	var k := 0
	for i in range(0, n + 1):
		while k < log.size() and int(log[k]["tick"]) <= i:
			if log[k]["type"] == EV_STATE and log[k]["id"] == id:
				s = log[k]["ints"][1]
			k += 1
		out[i] = s
	return out


func acting(st: PackedInt32Array) -> Callable:
	return func(i: int) -> bool: return st[i] != RISING and st[i] != HURT and st[i] != BURROW


# ============================================================================================ mirrors of DmAffixSet

## _physics_process + _tick_bell on the ticks the body acts: the ticks of each tell and each toll.
func bell_mirror(n: int, acts: Callable) -> Dictionary:
	var B: Dictionary = T["bellTolled"]
	var t := 0.0
	var cd := -1.0
	var at := -1.0
	var tells := []
	var tolls := []
	for i in range(1, n + 1):
		if not acts.call(i):
			continue
		t += DT
		if at >= 0.0:
			if t >= at:
				at = -1.0
				tolls.append(i)
			continue
		cd = (float(B["intervalS"]) if cd < 0.0 else cd) - DT
		if cd > 0.0:
			continue
		cd = float(B["intervalS"])
		at = t + float(B["windupS"])
		tells.append(i)
	return {"tells": tells, "tolls": tolls}


## _tick_hunger's countdown: the ticks it looks for a corpse. `eats` says whether the look on tick i finds one.
func hunger_mirror(n: int, eats: Callable) -> Array:
	var H: Dictionary = T["hungering"]
	var cd := -1.0
	var looks := []
	for i in range(1, n + 1):
		cd = (float(H["intervalS"]) if cd < 0.0 else cd) - DT
		if cd > 0.0:
			continue
		looks.append(i)
		cd = float(H["intervalS"]) if eats.call(i) else 0.5
	return looks


## _physics_process's shroud countdown and _tick_shroud: whether the shroud is on after each tick, given the clock of the last Miasma cover.
func shroud_mirror(n: int, cover_after_tick: Array) -> PackedByteArray:
	var on := PackedByteArray()
	on.resize(n + 1)
	var st := 0.0
	var clock := 0.0
	var miasma := -1.0e9
	var has := false
	for i in range(1, n + 1):
		clock += DT
		st -= DT
		if st <= 0.0:
			st = 0.1
			var in_cloud := clock - miasma < 0.35
			if in_cloud == has:
				has = not in_cloud
		on[i] = 1 if has else 0
		if cover_after_tick.has(i):
			miasma = clock
	return on


# ============================================================================================ tests

func _init() -> void:
	for n in ["enemies", "abilities", "statuses"]:
		data[n] = load_json(n)
	T = data["enemies"]["AFFIX_TUNING"]
	risen_n = int(T["vengeful"]["risen"])
	spawn_data()
	bell()
	bell_paused()
	bell_thrall()
	hunger()
	shroud()
	vengeful()
	vengeful_dot()
	plain()
	if fails == 0:
		print("PASS core_affixes %d checks" % checks)
	quit(1 if fails > 0 else 0)


func spawn_data() -> void:
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["hungering", "vengeful"]))
	var ev := of(events(c), EV_SPAWNED)
	check(ev.size() == 1 and ev[0]["ints"].size() == 5 and ev[0]["ints"][4] == 0b1010, "spawned event carries the affix bits (hungering 2, vengeful 8)")
	check(c.enemy_info(e)["affixes"] == PackedStringArray(["hungering", "vengeful"]), "enemy_info lists the affixes in AFFIX_ORDER")
	check(c.version() == "dmcore 0.17", "core version")


## The ticks of a few bell cycles (interval + wind-up), so a scenario sees several rings whatever the tuning.
func bell_run() -> int:
	return ceili((float(T["bellTolled"]["intervalS"]) + float(T["bellTolled"]["windupS"])) * 60.0 * 2.5) + 60


func bell() -> void:
	var n := bell_run()
	var c := make()
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, Vector2(0, 0), true)
	var far: int = c.add_external(0, 0.4, 1.0)
	c.set_external(far, Vector2(0, 25), true)
	var e: int = c.spawn_enemy("robber", Vector2(2, 0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["bellTolled"]))
	var log := []
	drain(c, log)
	run(c, n, log)
	var st := states(log, e, IDLE, n)
	var m := bell_mirror(n, acting(st))
	var tells := ticks_of(of(log, EV_AFFIX, e, AM_TELL))
	var tolls := ticks_of(of(log, EV_AFFIX, e, AM_TOLL))
	check(tells.size() >= 2 and tells == m["tells"], "the bell rings on today's ticks %s (got %s)" % [str(m["tells"]), str(tells)])
	check(tolls.size() >= 2 and tolls == m["tolls"], "and sounds windupS later on %s (got %s)" % [str(m["tolls"]), str(tolls)])
	var tg := of(log, EV_TELEGRAPH, e, TELL_TOLL)
	check(ticks_of(tg) == tells, "each ring is a toll telegraph")
	check(not tg.is_empty() and is_equal_approx(tg[0]["floats"][4], float(T["bellTolled"]["r"])) and is_equal_approx(tg[0]["floats"][5], float(T["bellTolled"]["windupS"])) \
		and tg[0]["floats"][0] == tg[0]["floats"][2] and tg[0]["floats"][1] == tg[0]["floats"][3], "the telegraph: from = aim = where the body stood, the ring's r and wind-up")
	var dmg := float(c.enemy_info(e)["damage"]) * float(T["bellTolled"]["damageMult"])
	var hits := log.filter(func(x: Dictionary) -> bool: return x["type"] == EV_TARGET_HIT and x["ints"][1] == HK_TOLL)
	check(ticks_of(hits) == tolls, "the hero inside the ring is hit once per toll")
	check(hits.all(func(x: Dictionary) -> bool: return x["ints"][0] == h and is_equal_approx(x["floats"][0], dmg)), "for damage x damageMult (%.2f), kind toll; the far hero never" % dmg)
	var toll := of(log, EV_AFFIX, e, AM_TOLL)
	check(not toll.is_empty() and toll[0]["floats"][0] == tg[0]["floats"][0] and is_equal_approx(toll[0]["floats"][4], float(T["bellTolled"]["r"])), "the toll sounds where the ring was drawn")


## A stun (HURT) stops the affix clock: the ring comes exactly as many ticks later as the body spent unable to act.
func bell_paused() -> void:
	var n := bell_run()
	var before := ceili(float(T["bellTolled"]["intervalS"]) * 30.0)   # the stun comes half way to the first ring
	var c := make()
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, Vector2(0, 0), true)
	var e: int = c.spawn_enemy("robber", Vector2(2, 0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["bellTolled"]))
	var log := []
	drain(c, log)
	run(c, before, log)
	c.stun(e, 1.0)
	drain(c, log)
	run(c, n - before, log)
	var st := states(log, e, IDLE, n)
	var hurt := 0
	for i in range(1, n + 1):
		if st[i] == HURT:
			hurt += 1
	var m := bell_mirror(n, acting(st))
	var tells := ticks_of(of(log, EV_AFFIX, e, AM_TELL))
	var free := bell_mirror(n, func(_i: int) -> bool: return true)
	check(hurt >= 59 and tells == m["tells"], "stunned for %d ticks: the ring follows the paused clock %s (got %s)" % [hurt, str(m["tells"]), str(tells)])
	check(not tells.is_empty() and int(tells[0]) - int(free["tells"][0]) == hurt, "and comes exactly %d ticks later than without the stun" % hurt)


func bell_thrall() -> void:
	var c := make()
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, Vector2(0, 0), true)
	var t: int = c.raise_thrall({"kind": "warrior", "maxHp": 5000.0, "damage": 0.0, "attackInterval": 1.0}, h, Vector2(0.6, 0.6), 0.0)
	var e: int = c.spawn_enemy("robber", Vector2(2, 0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["bellTolled"]))
	var log := []
	drain(c, log)
	run(c, bell_run(), log)
	var dmg := float(c.enemy_info(e)["damage"]) * float(T["bellTolled"]["damageMult"])
	var tolls := ticks_of(of(log, EV_AFFIX, e, AM_TOLL))
	var thrall_tolls := of(log, EV_THRALL_DAMAGED, t).filter(func(x: Dictionary) -> bool: return tolls.has(x["tick"]) and x["ints"][0] == e and is_equal_approx(x["floats"][0], dmg))
	check(tolls.size() >= 1 and thrall_tolls.size() == tolls.size(), "a thrall inside the ring takes the toll too (%d of %d)" % [thrall_tolls.size(), tolls.size()])


func hunger() -> void:
	var reach := float(T["hungering"]["reach"])
	var look_s := float(T["hungering"]["intervalS"])
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["hungering"]))
	var max_hp := float(c.enemy_info(e)["max_hp"])
	c.damage(e, max_hp * 0.5, 0, false)
	# the corpses stand inside the reach (nearest one first), one in another area, one beyond it
	var near_x := reach * 0.6
	var near: int = c.corpse_add(Vector2(near_x, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var other: int = c.corpse_add(Vector2(0, reach * 0.4), "normal", "robber", false, 0.0, 1.0, "sanctum")
	var beyond: int = c.corpse_add(Vector2(reach * 1.2, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var log := []
	drain(c, log)
	var first: int = hunger_mirror(ceili(look_s * 60.0) + 60, func(_i: int) -> bool: return true)[0]
	run(c, first + 60, log)
	var heal := minf(max_hp * 0.5, max_hp * float(T["hungering"]["healFrac"]))
	var eat := of(log, EV_AFFIX, e, AM_HUNGERING)
	check(eat.size() == 1 and eat[0]["tick"] == first, "the first meal on today's tick %d (got %s)" % [first, str(ticks_of(eat))])
	var con := of(log, EV_CORPSE_CONSUMED, near)
	check(con.size() == 1 and con[0]["ints"][0] == 1 and con[0]["ints"][1] == CR_DEVOURED, "the nearest corpse in its own area goes, by 1, reason devoured")
	check(not eat.is_empty() and is_equal_approx(eat[0]["floats"][2], near_x) and is_equal_approx(eat[0]["floats"][4], heal), "the moment points at the corpse and says the heal (%.1f)" % heal)
	check(is_equal_approx(float(c.enemy_info(e)["hp"]), max_hp * 0.5 + heal), "health: half + healFrac of max")
	check(of(log, EV_CORPSE_CONSUMED, other).is_empty() and of(log, EV_CORPSE_CONSUMED, beyond).is_empty(), "a corpse in another area or past the reach stays")
	# Nothing in reach at the next look (intervalS later): it looks again every 0.5 s; a corpse laid after that look goes at the first retry.
	var second_look: int = hunger_mirror(first + ceili(look_s * 60.0) + 60, func(i: int) -> bool: return i == first)[1]
	run(c, second_look + 5 - tick, log)
	var added := tick
	var fresh: int = c.corpse_add(Vector2(-reach * 0.8, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	run(c, 100, log)
	var state := {"ate": 0}
	var eats := func(i: int) -> bool:
		var ok: bool = i == first or (i > added and state["ate"] == 0)
		if ok and i != first:
			state["ate"] = i
		return ok
	var looks := hunger_mirror(tick, eats)
	var eat2 := of(log, EV_AFFIX, e, AM_HUNGERING)
	check(eat2.size() == 2 and eat2[1]["tick"] == state["ate"] and looks[looks.find(state["ate"]) - 1] < added and state["ate"] - looks[looks.find(state["ate"]) - 1] <= 31 \
		and of(log, EV_CORPSE_CONSUMED, fresh).size() == 1,
		"retries every 0.5 s: the new corpse goes on tick %d (got %s; looks %s)" % [state["ate"], str(ticks_of(eat2)), str(looks.slice(0, 6))])
	# A body at full health never eats.
	var d := make()
	var full: int = d.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["hungering"]))
	var c2: int = d.corpse_add(Vector2(1, 0), "normal", "robber", false, 0.0, 1.0, "graves")
	var log2 := []
	run(d, ceili(look_s * 60.0) * 2 + 60, log2)
	check(of(log2, EV_AFFIX, full).is_empty() and of(log2, EV_CORPSE_CONSUMED, c2).is_empty(), "at full health the corpse stays")


func shroud() -> void:
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, false, "graves", true, PackedStringArray(["shrouded"]))
	var log := []
	run(c, 1, log)
	check(c.status_stacks(e, "shrouded") == 1.0, "Nightfall's shroud is on from the first tick, even while rising")
	run(c, 79, log)
	check(c.enemy_info(e)["state"] == IDLE, "risen")
	var r: Dictionary = c.damage(e, 10.0, 0, false)
	check(is_equal_approx(float(r["dealt"]), 10.0 * float(T["shrouded"]["damageTakenMult"])), "shrouded: damage taken x 0.5 (dealt %s)" % str(r["dealt"]))
	# A Miasma covers it at 10 Hz from tick 100 to 160, then leaves: the shroud lifts at the next check, returns 0.35 s after the last cover.
	var covers := []
	var seen := PackedByteArray()
	seen.resize(301)
	for i in range(81, 301):
		run(c, 1, log)
		seen[i] = 1 if c.status_stacks(e, "shrouded") > 0.0 else 0
		if i >= 100 and i <= 160 and i % 6 == 4:
			c.cover_miasma(e)
			covers.append(i)
	var want := shroud_mirror(300, covers)
	var same := true
	var off := 0
	for i in range(81, 301):
		same = same and seen[i] == want[i]
		off += 1 - seen[i]
	check(same and off >= 60, "lifted under the cloud and back 0.35 s after, on today's ticks (%d ticks off)" % off)
	c.cover_miasma(e)
	run(c, 7, log)
	r = c.damage(e, 10.0, 0, false)
	check(is_equal_approx(float(r["dealt"]), 10.0), "under the cloud: full damage")
	run(c, 30, log)
	check(c.status_stacks(e, "shrouded") == 1.0, "the cloud left: the shroud is back")
	# Last Light / a Warden sweep: gone for good.
	var before := log.size()
	check(c.strip_shroud(e), "strip_shroud")
	drain(c, log)
	check(c.status_stacks(e, "shrouded") == 0.0 and c.enemy_info(e)["affixes"].is_empty(), "the status and the affix are gone")
	check(of(log.slice(before), EV_AFFIX, e, AM_UNVEIL).size() == 1, "an unveil moment")
	run(c, 120, log)
	check(c.status_stacks(e, "shrouded") == 0.0 and not c.strip_shroud(e), "and never comes back")


func vengeful() -> void:
	var risen_def: Dictionary = data["enemies"]["ENEMIES"]["risen"]
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(5, 5), 4, 2.0, 1.5, true, "graves", false, PackedStringArray(["vengeful"]))
	events(c)
	var r: Dictionary = c.damage(e, 1.0e7, 0)
	var ev := events(c)
	var idx := func(pred: Callable) -> Array:
		var out := []
		for i in ev.size():
			if pred.call(ev[i]):
				out.append(i)
		return out
	var moment: Array = idx.call(func(x: Dictionary) -> bool: return x["type"] == EV_AFFIX and x["ints"][0] == AM_VENGEFUL)
	var spawned: Array = idx.call(func(x: Dictionary) -> bool: return x["type"] == EV_SPAWNED)
	var died: Array = idx.call(func(x: Dictionary) -> bool: return x["type"] == EV_DIED)
	check(r["killed"] and moment.size() == 1 and spawned.size() == risen_n and died.size() == 1, "a Vengeful elite bursts into %d Risen" % risen_n)
	check(moment.size() == 1 and spawned.size() == risen_n and died.size() == 1 and moment[0] < spawned[0] and spawned[-1] < died[0], "inside the kill, in today's order: burst, the Risen, then the death")
	var ids := []
	var ring := true
	var pts := []
	for i in spawned:
		var s: Dictionary = ev[i]
		ids.append(s["id"])
		var p := Vector2(s["floats"][0], s["floats"][1])
		pts.append(p)
		ring = ring and absf(p.distance_to(Vector2(5, 5)) - 1.4) < 1e-4 and c.def_name(s["ints"][0]) == "risen" and Array(s["ints"]).slice(1) == [4, 0, s["ints"][3], 0]
	check(ring and (risen_n < 2 or absf(pts[0].distance_to(pts[1]) - 2.0 * 1.4 * sin(PI / float(risen_n))) < 1e-3), "on a 1.4 m ring (compiled in), evenly spread, level 4, not elite, no affixes")
	var next_ids := []
	for k in risen_n:
		next_ids.append(e + 1 + k)
	check(ids == next_ids, "the next ids")
	check(c.enemy_count() == risen_n + 1, "they are in the table when the call returns (the elite's body lingers)")
	var ri: Dictionary = c.enemy_info(ids[0])
	check(ri["state"] == RISING and ri["area"] == "graves" and is_equal_approx(ri["max_hp"], float(risen_def["hp"]) * 2.0) and is_equal_approx(ri["damage"], float(risen_def["damage"]) * 1.5),
		"rising, in its area, as strong as the elite's multipliers (hp x2, damage x1.5)")
	var d := make()
	var e2: int = d.spawn_enemy("robber", Vector2(5, 5), 4, 2.0, 1.5, true, "graves", false, PackedStringArray(["vengeful"]))
	events(d)
	d.damage(e2, 1.0e7, 0)
	var ev2 := of(events(d), EV_SPAWNED)
	check(ev2.size() == risen_n and ev2[0]["floats"] == ev[spawned[0]]["floats"], "the same seed puts them in the same places")


## Killed by a DoT lump inside the tick (the status code holds references to the body): the Risen still come, after the tick.
func vengeful_dot() -> void:
	var c := make()
	var e: int = c.spawn_enemy("robber", Vector2(0, 0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["vengeful"]))
	c.apply_status(e, "withered", 0, 10.0, 5.0, {"dps": 1000.0, "cap": 10.0})
	var log := []
	drain(c, log)
	run(c, 60, log)
	var died := of(log, EV_DIED, e)
	var sp := of(log, EV_SPAWNED).filter(func(x: Dictionary) -> bool: return x["id"] != e)
	check(died.size() == 1 and sp.size() == risen_n and sp.all(func(x: Dictionary) -> bool: return x["tick"] == died[0]["tick"]), "a DoT kill: the Risen in the same tick")
	check(log.find(sp[-1]) < log.find(died[0]) if sp.size() == risen_n and died.size() == 1 else false, "spawned before the death event")
	run(c, 80, log)
	var up := of(log, EV_STATE).filter(func(x: Dictionary) -> bool: return x["id"] != e and x["ints"][0] == RISING)
	check(up.size() == risen_n, "and they rise (%d)" % up.size())


func plain() -> void:
	var c := make()
	var h: int = c.add_external(0, 0.4, 1.0)
	c.set_external(h, Vector2(0, 0), true)
	c.spawn_enemy("robber", Vector2(2, 0), 1, 1.0, 1.0, false, "graves", false)
	c.spawn_enemy("robber", Vector2(-2, 0), 1, 1.0, 1.0, true, "graves", false)
	var log := []
	run(c, 600, log)
	check(of(log, EV_AFFIX).is_empty() and of(log, EV_TELEGRAPH, 0, TELL_TOLL).is_empty(), "no affix, no rules: a plain body and an elite without affixes")
