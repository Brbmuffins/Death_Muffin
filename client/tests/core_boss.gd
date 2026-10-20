extends SceneTree
## What the bosses call on the combat core beyond damage and queries (native/src/core/niche.cpp, boss.cpp; client/README.md "The bosses"), against today's code:
##   - the Skull Niche (archive/old-game:godot/enemies/kinds/dm_enemy_niche.gd, the Bone Abbess's shrines): a body that only stands. Its def, the rise (dm_state_rising.gd), no target, no walk, no blow,
##     no stagger (a hit, a stun, a stun status), a hit while it rises refused, never moved (a hero's body, a raised wall), not in the crowd's spacing, thralls and statuses reach it,
##     it falls with no corpse and is removed 4 s later;
##   - a body's health (`set_enemy_hp`, DmBossNodeWorld.set_enemy_hp): the hp and maximum, the refusals, a puppet refused;
##   - a boss's hostile zone (`add_zone`, DmHostileZone.spawn with the boss as the source): toxic rot and burning ground and their sources, a pulse every second on the heroes and
##     thralls within radius + 0.45 (dps x 1 s, the hit kinds burn and toxic), the lifetime, the query the Plague Saint stands in (`zones`), a puppet refused;
##   - the wire: a guest sees the niche with the maximum the boss gave it (also after a late join and a lost batch), its hp as a fraction, its death, the zones as events.
## The expected ticks come from mirrors of today's arithmetic (clocks that gain 1/60 s a tick in doubles); the numbers from today's data and scripts' const lines (the niche's health and radius, a corpse's rupture, a walker's speed are read from the data).
## Seeded, no navmesh. Run: godot --headless --path client --script res://tests/core_boss.gd [-- --verbose]

const EV_SPAWNED := 1
const EV_STATE := 2
const EV_DAMAGED := 3
const EV_DIED := 4
const EV_REMOVED := 5
const EV_ATTACK := 6
const EV_TELEGRAPH := 7
const EV_HIT := 9
const EV_ZONE := 10
const EV_ZONE_PULSE := 11
const EV_ZONE_GONE := 12
const EV_STATUS_DOT := 15
const EV_CORPSE_ADDED := 18
const EV_THRALL_DAMAGED := 25
const RISING := 0
const IDLE := 1
const HURT := 4
const DEAD := 6
const HK_TOXIC := 1
const HK_BURN := 2
const ZK_DUST := 0
const ZK_TOXIC := 1
const ZK_EMBER := 2
const DT := 1.0 / 60.0
const AREA := "ossuary"
const FAR := Vector2(40.0, 0.0)
## The old game's scripts whose `const` lines this suite reads, kept as text (a ".txt" added, so Godot never parses them).
const OLD := "res://tests/fixtures/old_game/"
const SCRIPTS: Array[String] = ["enemies/states/dm_state_rising.gd.txt", "enemies/dm_hostile_zone.gd.txt", "next/corpses/dm_corpse_field.gd.txt"]

var fails := 0
var checks := 0
var verbose := false
var data_dir: String   ## this project's data/ (res://): the same files the game loads
var content: Dictionary
var abilities: Dictionary
var K: Dictionary        ## the scripts' `const` lines (RISE_TIME, TICK_S, TARGET_PAD)
var tick := 0
var NH := 0.0            ## the Skull Niche's health in enemies.json
var NR := 0.0            ## and its radius


func check(ok: bool, what: String) -> void:
	checks += 1
	if ok and verbose:
		print("ok   " + what)
	if not ok:
		fails += 1
		printerr("FAIL core_boss: " + what)


func def(id: String) -> Dictionary:
	return content["ENEMIES"][id]


func make(seed_: int = 11) -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	c.set_seed(seed_)
	DmCoreData.load_all(c, data_dir)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_wander(false)
	tick = 0
	return c


func puppet() -> RefCounted:
	var c: RefCounted = ClassDB.instantiate("DmCore")
	DmCoreData.load_all(c, data_dir)
	c.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	c.set_puppet(true)
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


func events_tagged(c: RefCounted) -> Array:
	var out := []
	for e in events(c):
		e["tick"] = tick
		out.append(e)
	return out


func of(log: Array, type: int, id: int = 0) -> Array:
	return log.filter(func(e: Dictionary) -> bool: return e["type"] == type and (id == 0 or e["id"] == id))


## Ticks until a clock that gains DT a tick (DmEnemyState.t += dt) has reached `limit`.
func to_reach(limit: float) -> int:
	var t := 0.0
	var n := 0
	while t < limit:
		t += DT
		n += 1
	return n


func niche(c: RefCounted, at: Vector2, rising := true, hp_mult := 1.0) -> int:
	return c.spawn_enemy("niche", at, 1, hp_mult, 1.0, false, AREA, rising)


func _init() -> void:
	verbose = "--verbose" in OS.get_cmdline_user_args()
	data_dir = "res://"
	content = DmCoreData.json(data_dir.path_join("data/content/enemies.json"))
	abilities = DmCoreData.json(data_dir.path_join("data/content/abilities.json"))
	K = DmCoreData.consts(OLD, SCRIPTS)
	NH = float(def("niche")["hp"])
	NR = float(def("niche")["radius"])
	names_and_defs()
	niche_rises_and_stands()
	niche_takes_blows_without_a_flinch()
	niche_falls()
	niche_is_not_moved_nor_in_the_crowd()
	niche_statuses_and_thralls()
	set_hp()
	zones_hurt()
	zones_edges()
	on_the_wire()
	if fails == 0:
		print("PASS core_boss %d checks" % checks)
	quit(1 if fails > 0 else 0)



# ------------------------------------------------------------------------------------------------------------------ names and the def

func names_and_defs() -> void:
	check(DmCoreEvents.ZONE_KINDS.size() == 3 and DmCoreEvents.ZONE_KINDS[ZK_DUST] == &"dust" and DmCoreEvents.ZONE_KINDS[ZK_TOXIC] == &"toxic" and DmCoreEvents.ZONE_KINDS[ZK_EMBER] == &"ember",
		"the zone names: ember appended after dust and toxic (append only)")
	check(K.has("RISE_TIME") and K.has("TICK_S") and K.has("TARGET_PAD"), "the scripts' own constants are read (%s)" % str(K.keys()))
	var d := def("niche")
	check(bool(d["inert"]) and d["behavior"] == "support" and d["corpse"] == "none" and String(d["modelSlug"]) != "",
		"the Skull Niche: support, inert, no corpse, a model")
	check(DmWaveDirector.runs_on_core("niche") and not DmWaveDirector.CORE_KINDS.has("niche"), "the director makes it for a boss (a boss-only kind), never in a wave")
	var c := make()
	var id := niche(c, Vector2(5, 5))
	var i: Dictionary = c.enemy_info(id)
	check(i["def"] == "niche" and i["state"] == RISING and is_equal_approx(float(i["hp"]), NH) and is_equal_approx(float(i["max_hp"]), NH) and is_equal_approx(float(i["radius"]), NR),
		"a niche spawns rising with the def's health and radius")


# ------------------------------------------------------------------------------------------------------------------ rise, stand

## DmStateRising: 1.1 s, then idle for good. A hero beside it does nothing to it (it never targets); it never moves, swings, telegraphs or hits.
func niche_rises_and_stands() -> void:
	var c := make()
	var h := hero(c, Vector2(1.2, 0))
	var id := niche(c, Vector2(0, 0))
	var log := []
	run(c, 300, log)
	var edges := of(log, EV_STATE, id)
	var up := to_reach(float(K["RISE_TIME"]))
	check(edges.size() == 1 and edges[0]["ints"] == PackedInt32Array([RISING, IDLE]) and int(edges[0]["tick"]) == up, "it stands up at tick %d (the rise) and that is its only state change (%d)" % [up, edges.size()])
	check(of(log, EV_ATTACK, id).is_empty() and of(log, EV_TELEGRAPH, id).is_empty() and of(log, EV_HIT, id).is_empty(), "it never starts a swing, telegraphs or hits (a hero 1.2 m away, 5 s)")
	var i: Dictionary = c.enemy_info(id)
	check(i["state"] == IDLE and Vector2(i["pos"]).distance_to(Vector2(0, 0)) < 1e-6 and int(i["target"]) == 0, "it stands where it was made, with no target")
	check(c.enemy_ground_speeds()[0] == 0.0, "and its ground speed is zero")
	# not rising: idle at once
	var c2 := make()
	hero(c2, FAR)
	var id2 := niche(c2, Vector2(0, 0), false)
	var log2 := []
	run(c2, 30, log2)
	check(c2.enemy_info(id2)["state"] == IDLE and of(log2, EV_STATE, id2).is_empty(), "spawned standing (not rising) it is idle with no state change")
	check(h > 0, "(the hero is an external)")


# ------------------------------------------------------------------------------------------------------------------ blows

## DmEnemyNiche.take_damage: the base's refusals (dead, rising), damage taken, no stagger, no aggro; stun does nothing.
func niche_takes_blows_without_a_flinch() -> void:
	var c := make()
	var h := hero(c, Vector2(3, 0))
	var id := niche(c, Vector2(0, 0))
	var log := []
	run(c, 5, log)
	var blow := NH * 0.2   # blows that never kill it
	var r: Dictionary = c.damage(id, blow, h)
	check(float(r["dealt"]) == 0.0 and not bool(r["killed"]) and is_equal_approx(float(c.enemy_info(id)["hp"]), NH), "a hit while it rises is refused (nothing dealt)")
	run(c, 100, log)
	check(c.enemy_info(id)["state"] == IDLE, "(it stands)")
	log.clear()
	r = c.damage(id, blow, h)
	run(c, 3, log)
	var i: Dictionary = c.enemy_info(id)
	check(float(r["dealt"]) == blow and not bool(r["killed"]) and is_equal_approx(float(i["hp"]), NH - blow) and i["state"] == IDLE, "a hit takes its blow and it stays idle (no flinch)")
	check(of(log, EV_DAMAGED, id).size() == 1 and of(log, EV_STATE, id).is_empty() and int(i["target"]) == 0, "the core announces the damage, no state change, and it does not aggro its attacker")
	c.damage(id, NH * 0.1, h, true)
	check(c.enemy_info(id)["state"] == IDLE, "a second hit with the stagger allowed changes nothing either")
	c.stun(id, 2.0)
	check(c.enemy_info(id)["state"] == IDLE, "a stun does nothing")
	c.apply_status(id, "stun", h, 1.0, 5.0)
	run(c, 20, log)
	check(c.enemy_info(id)["state"] == IDLE and of(log, EV_STATE, id).is_empty(), "nor does the stun status (the status is on it, the body does not flinch)")
	var big: Dictionary = c.damage(id, 0.0, h)
	check(float(big["dealt"]) == 0.0, "a blow of zero is refused as everywhere")


## It crumbles when killed: died event, no corpse, gone 4 s later like any body.
func niche_falls() -> void:
	var c := make()
	var h := hero(c, FAR)
	var id := niche(c, Vector2(0, 0), false)
	var log := []
	run(c, 3, log)
	var r: Dictionary = c.damage(id, 1.0e9, h)
	run(c, 2, log)
	check(bool(r["killed"]) and float(r["dealt"]) == 1.0e9 and c.enemy_info(id)["state"] == DEAD, "a lethal blow kills it at once (the reply says so)")
	var died := of(log, EV_DIED, id)
	check(died.size() == 1 and c.def_name(died[0]["ints"][0]) == "niche" and died[0]["ints"][4] == h, "one died event, naming niche and the killer")
	check(of(log, EV_CORPSE_ADDED).is_empty() and c.corpse_count() == 0, "and no corpse (def corpse none)")
	check(c.damage(id, 5.0, h)["dealt"] == 0.0, "a fallen niche takes no more blows")
	run(c, 4 * 60 + 10, log)
	var gone := of(log, EV_REMOVED, id)
	check(gone.size() == 1 and gone[0]["ints"].is_empty() and c.enemy_info(id).is_empty() and c.enemy_count() == 0, "the body is removed with the next tick after its 4 s, like any body (a plain removal)")
	# a niche that leaves alive (the boss falls) is removed at once, silently
	var c2 := make()
	hero(c2, FAR)
	var id2 := niche(c2, Vector2(0, 0), false)
	var log2 := []
	run(c2, 5, log2)
	check(c2.remove_enemy(id2) and c2.enemy_count() == 0, "a standing niche can be removed alive (the Abbess falls: no death, no corpse, no credit)")
	run(c2, 2, log2)
	var rem := of(log2, EV_REMOVED, id2)
	check(rem.size() == 1 and rem[0]["ints"] == PackedInt32Array([1]) and of(log2, EV_DIED).is_empty(), "with the removal event that says it was alive")


## A hero's body, a raised wall, a walking body and the crowd's spacing leave it where it is; nothing else's walk is bent by it.
func niche_is_not_moved_nor_in_the_crowd() -> void:
	var c := make()
	var h := hero(c, Vector2(0.2, 0.1))   # standing on it
	var id := niche(c, Vector2(0, 0), false)
	var wall: int = c.add_obstacle(Vector2(-3, 0), Vector2(3, 0), 1.0)   # a wall raised on it
	var log := []
	run(c, 60, log)
	check(Vector2(c.enemy_info(id)["pos"]) == Vector2(0, 0), "a hero standing on it and a wall raised through it do not move it")
	c.remove_obstacle(wall)
	# a robber that walks past: with the niche in its way or far off, the walk is the same bit for bit
	var tracks := []
	for with_niche in [true, false]:
		var d := make(31)
		hero(d, Vector2(6, 0))
		var n := niche(d, Vector2(-1, 0) if with_niche else Vector2(-50, 50), false)
		var rob: int = d.spawn_enemy("robber", Vector2(-8, 0.3), 1, 1.0, 1.0, false, AREA, false)
		var track := []
		var walk := ceili(ceili((8.0 + 1.5) / float(def("robber")["speed"]) * 60.0) / 20.0) * 20   # long enough to walk past the niche's place, in whole samples
		for i in walk:
			d.step(DT)
			d.take_events()
			if i % 20 == 19:
				track.append(Vector2(d.enemy_info(rob)["pos"]))
		tracks.append(track)
		check(Vector2(d.enemy_info(n)["pos"]) == (Vector2(-1, 0) if with_niche else Vector2(-50, 50)), "(the niche did not move)")
	check(tracks[0] == tracks[1], "a robber walking through the niche's place walks as if it were not there (it is no avoidance agent, enemies' masks do not include its layer)")
	check(tracks[0][0].x < -1.0 and tracks[0][tracks[0].size() - 1].x > 0.0, "(and it got past: %s -> %s)" % [str(tracks[0][0]), str(tracks[0][tracks[0].size() - 1])])
	check(h > 0, "(hero)")


## Statuses ride it as they ride any body (its status set is a node of its own today): Withered burns it and the DoT's kill is credited; a thrall hits it as an enemy.
func niche_statuses_and_thralls() -> void:
	var c := make()
	var h := hero(c, FAR)
	var id := niche(c, Vector2(0, 0), false)
	c.set_enemy_hp(id, 5000.0, 5000.0)   # the scenario's own health: the blows below never kill it
	var log := []
	c.apply_status(id, "withered", h, 3.0, 5.0, {"dps": 20.0})
	run(c, 90, log)
	var hp := float(c.enemy_info(id)["hp"])
	check(hp < 5000.0 - 40.0 and c.enemy_info(id)["state"] == IDLE, "Withered burns it (%.1f of 5000 after 1.5 s) and it never flinches" % (5000.0 - hp))
	check(not of(log, EV_STATUS_DOT, id).is_empty(), "the DoT lumps are announced")
	c.apply_status(id, "fracture", h, 1.0, 8.0)
	var before := float(c.enemy_info(id)["hp"])
	c.damage(id, 10.0, h)
	var lost := before - float(c.enemy_info(id)["hp"])
	check(lost > 10.0 and is_equal_approx(lost, 10.0 * float(c.enemy_info(id)["taken_mult"])), "Fracture raises what it takes (%.2f for a 10 blow)" % lost)
	# a thrall picks it as an enemy (it is in the dm_enemy group today)
	var d := make()
	var hd := hero(d, Vector2(-4, 0))
	var nid := niche(d, Vector2(0, 0), false)
	d.set_enemy_hp(nid, 5000.0, 5000.0)
	var th: int = d.raise_thrall({"kind": "warrior", "hp": 500.0, "maxHp": 500.0, "damage": 30.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false, "allyHeal": 0.0},
		hd, Vector2(-1.5, 0), 0.0, 8.0)
	var log2 := []
	run(d, 240, log2)
	var hit := of(log2, EV_DAMAGED, nid)
	check(th > 0 and not hit.is_empty() and hit[0]["ints"][0] == th and float(d.enemy_info(nid)["hp"]) < 5000.0 and d.enemy_info(nid)["state"] == IDLE, "a thrall of the hero's attacks it and hurts it (%d blows)" % hit.size())


# ------------------------------------------------------------------------------------------------------------------ set_enemy_hp

func set_hp() -> void:
	var c := make()
	var h := hero(c, FAR)
	var id := niche(c, Vector2(0, 0), false)
	check(c.set_enemy_hp(id, 340.0, 340.0), "set_enemy_hp answers true for a living body")
	var i: Dictionary = c.enemy_info(id)
	check(is_equal_approx(float(i["hp"]), 340.0) and is_equal_approx(float(i["max_hp"]), 340.0), "the health and the maximum are the boss's (340 of 340)")
	c.damage(id, 40.0, h)
	check(is_equal_approx(float(c.enemy_info(id)["hp"]), 300.0), "a blow takes from it (300 of 340)")
	check(c.set_enemy_hp(id, 1000.0, 600.0) and is_equal_approx(float(c.enemy_info(id)["hp"]), 600.0), "the health is held to the maximum")
	check(not c.set_enemy_hp(id, 10.0, 0.0) and not c.set_enemy_hp(id, 10.0, -5.0) and is_equal_approx(float(c.enemy_info(id)["max_hp"]), 600.0), "a maximum of zero or less is refused")
	check(not c.set_enemy_hp(1 << 28, 10.0, 10.0), "an unknown id is refused")
	c.damage(id, 1.0e9, h)
	check(not c.set_enemy_hp(id, 10.0, 10.0), "a fallen body is refused")
	# an elite or scaled body is set the same way (the Abbess's share of her own health replaces the scaling)
	var scaled := niche(c, Vector2(2, 2), false, 4.0)
	check(is_equal_approx(float(c.enemy_info(scaled)["max_hp"]), NH * 4.0) and c.set_enemy_hp(scaled, 123.0, 123.0) and is_equal_approx(float(c.enemy_info(scaled)["max_hp"]), 123.0), "a body made at 4x the health is given the boss's number instead")
	var p := puppet()
	p.set_enemy_hp(1, 10.0, 10.0)
	check(int(p.replication_stats()["commands_refused"]) == 1, "a puppet core refuses it (the host owns the health)")


# ------------------------------------------------------------------------------------------------------------------ zones

## A mirror of DmHostileZone._physics_process: the ticks (from 1, counted from the tick the zone was made in) it pulses on and the tick it is gone.
func zone_mirror(lifetime: float, period: float) -> Dictionary:
	var age := 0.0
	var t := -1.0
	var pulses := []
	var n := 0
	while n < 20000:
		n += 1
		age += DT
		if age >= lifetime:
			return {"pulses": pulses, "gone": n}
		if t < 0.0:
			t = period
		t -= DT
		if t > 0.0:
			continue
		t = period
		pulses.append(n)
	return {"pulses": pulses, "gone": -1}


func zones_hurt() -> void:
	var src := 777   # a boss's external id
	# toxic rot: the Saint's pool
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var th: int = c.raise_thrall({"kind": "warrior", "hp": 1000.0, "maxHp": 1000.0, "damage": 1.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false, "allyHeal": 0.0},
		h, Vector2(1.0, 0), 0.0, 8.0)
	var log := []
	run(c, ceili(float(c.tuning()["THRALL_RISE_TIME"]) * 60.0) + 6, log)   # it rises, then it is stunned so it stands in the pool for good
	c.stun(th, 1000.0)
	var far_h := hero(c, Vector2(9, 0))
	var zid: int = c.add_zone("toxic", Vector2(0, 0), 2.0, 5.0, 12.0, src)
	check(zid > 0, "add_zone answers the zone's id")
	var t0 := tick
	log.clear()
	drain(c, log)
	var ev := of(log, EV_ZONE, zid)
	check(ev.size() == 1 and ev[0]["ints"] == PackedInt32Array([ZK_TOXIC, src]) and ev[0]["floats"] == PackedFloat32Array([0.0, 0.0, 2.0, 5.0]), "the zone event: toxic, the boss's id as the source, x z radius seconds")
	var want := zone_mirror(5.0, float(K["TICK_S"]))
	run(c, 340, log)
	var pulses := of(log, EV_ZONE_PULSE, zid)
	var ticks_of := pulses.map(func(e: Dictionary) -> int: return int(e["tick"]) - t0)
	var n_pulses: int = want["pulses"].size()
	check(ticks_of == want["pulses"] and n_pulses > 0, "it pulses every second, at today's ticks %s" % str(ticks_of))
	var gone := of(log, EV_ZONE_GONE, zid)
	check(gone.size() == 1 and int(gone[0]["tick"]) - t0 == int(want["gone"]), "and is gone at tick %d (5 s)" % int(want["gone"]))
	var hits := of(log, EV_HIT, src)
	var hero_hits := hits.filter(func(e: Dictionary) -> bool: return e["ints"][0] == h)
	check(hero_hits.size() == n_pulses and hero_hits.all(func(e: Dictionary) -> bool: return e["ints"][1] == HK_TOXIC and is_equal_approx(float(e["floats"][0]), 12.0)),
		"the hero in it takes dps x 1 s = 12 each pulse, kind toxic, the boss's id as the source (%d hits)" % hero_hits.size())
	check(of(log, EV_HIT).filter(func(e: Dictionary) -> bool: return e["ints"][0] == far_h).is_empty(), "a hero 9 m off takes nothing")
	var td := of(log, EV_THRALL_DAMAGED, th)
	check(td.size() == n_pulses and td.all(func(e: Dictionary) -> bool: return e["ints"][0] == src and is_equal_approx(float(e["floats"][0]), 12.0)) and is_equal_approx(float(c.thrall_info(th)["hp"]), 1000.0 - 12.0 * n_pulses),
		"a thrall in it takes the same (the core applies it: 1000 -> %d)" % (1000 - 12 * n_pulses))
	# burning ground
	var d := make()
	var hd := hero(d, Vector2(0, 0))
	var eid: int = d.add_zone("ember", Vector2(0, 0), 1.8, 3.0, 20.0, src)
	var log2 := []
	drain(d, log2)
	check(of(log2, EV_ZONE, eid)[0]["ints"] == PackedInt32Array([ZK_EMBER, src]), "an ember zone says ember")
	run(d, 200, log2)
	var ewant := zone_mirror(3.0, float(K["TICK_S"]))
	var eh := of(log2, EV_HIT, src)
	check(eh.size() == ewant["pulses"].size() and eh.all(func(e: Dictionary) -> bool: return e["ints"][0] == hd and e["ints"][1] == HK_BURN and is_equal_approx(float(e["floats"][0]), 20.0)),
		"burning ground hurts as burn, %d pulses of 20 in 3 s" % eh.size())
	# dust, the third kind, hurts as dust
	var dz: int = d.add_zone("dust", Vector2(0, 0), 2.0, 2.0, 5.0, src)
	run(d, 130, log2)
	check(of(log2, EV_HIT, src).filter(func(e: Dictionary) -> bool: return e["ints"][1] == 4).size() == zone_mirror(2.0, float(K["TICK_S"]))["pulses"].size() and dz > 0, "and a dust zone as dust")
	check(d.add_zone("lava", Vector2(0, 0), 1.0, 1.0, 1.0, src) == 0, "an unknown kind makes nothing")


func zones_edges() -> void:
	var c := make()
	var h := hero(c, Vector2(0, 0))
	var pad := float(K["TARGET_PAD"])
	var r := 2.0
	# a hero just inside radius + 0.45 is hit, just outside is not
	var inside := hero(c, Vector2(r + pad - 0.02, 0))
	var outside := hero(c, Vector2(0, r + pad + 0.02))
	var dead := hero(c, Vector2(0.5, 0.5))
	c.set_external(dead, Vector2(0.5, 0.5), false)
	c.add_zone("toxic", Vector2(0, 0), r, 1.5, 10.0, 5)
	var log := []
	run(c, 70, log)
	var tgt := of(log, EV_HIT, 5).map(func(e: Dictionary) -> int: return e["ints"][0])
	check(tgt.has(h) and tgt.has(inside) and not tgt.has(outside) and not tgt.has(dead), "the reach is radius + 0.45 (%.2f m), the dead are skipped (%s)" % [r + pad, str(tgt)])
	# the query the Saint asks
	var d := make()
	hero(d, FAR)
	d.add_zone("toxic", Vector2(3, 4), 2.4, 2.0, 1.0, 9)
	d.add_zone("toxic", Vector2(-1, 2), 1.0, 0.5, 1.0, 9)
	d.add_zone("ember", Vector2(8, 8), 1.8, 2.0, 1.0, 9)
	var tox: PackedFloat32Array = d.zones("toxic")
	check(tox.size() == 6 and tox[0] == 3.0 and tox[1] == 4.0 and is_equal_approx(tox[2], 2.4) and tox[3] == -1.0 and d.zones("ember").size() == 3 and d.zones("dust").is_empty() and d.zones("nothing").is_empty(),
		"zones(kind) lists the live zones of a kind as x, z, radius, in the order they were made")
	var log2 := []
	run(d, 31, log2)
	check(d.zones("toxic").size() == 3 and d.zones("toxic")[0] == 3.0, "a zone that ran out leaves the list the tick it is gone (%d left)" % (d.zones("toxic").size() / 3))
	run(d, 100, log2)
	check(d.zones("toxic").is_empty() and d.zones("ember").is_empty(), "and none is left after their seconds")
	# a corpse's toxic pool is a zone of the same kind (the Saint stands in a sac's rot too)
	var e := make()
	hero(e, FAR)
	var cid: int = e.corpse_add(Vector2(1, 1), "toxic", "robber", false, 0.0, 1.0, "graves")
	var log3 := []
	run(e, ceili(float(e.tuning()["TOXIC_RUPTURE"]) * 60.0) + 5, log3)
	check(cid > 0 and e.zones("toxic").size() == 3, "a toxic corpse that burst leaves a pool the query sees too")


# ------------------------------------------------------------------------------------------------------------------ the wire

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


func on_the_wire() -> void:
	var host := make(77)
	host.set_replication(true)
	var h := hero(host, Vector2(4, 0))
	var id := niche(host, Vector2(0, 0), false)
	host.set_enemy_hp(id, 340.0, 340.0)
	var guest := puppet()
	var hl := []
	var gl := []
	var t := join(host, guest, hl, gl)
	var gi: Dictionary = guest.enemy_info(id)
	check(gi.get("def", "") == "niche" and is_equal_approx(float(gi["max_hp"]), 340.0) and is_equal_approx(float(gi["hp"]), 340.0), "wire: the guest has the niche with the maximum the boss gave it (340, not the def's health)")
	host.damage(id, 85.0, h)
	t = lockstep(host, guest, hl, gl, t, t + 9)
	gi = guest.enemy_info(id)
	check(absf(float(gi["hp"]) - 255.0) < 0.02 and is_equal_approx(float(gi["max_hp"]), 340.0), "wire: a blow shows as the fraction of 340 (hp %.2f of 340)" % float(gi["hp"]))
	# a change of the maximum after the guest knew the body
	host.set_enemy_hp(id, 200.0, 200.0)
	t = lockstep(host, guest, hl, gl, t, t + 9)
	gi = guest.enemy_info(id)
	check(is_equal_approx(float(gi["max_hp"]), 200.0) and absf(float(gi["hp"]) - 200.0) < 0.02, "wire: a new maximum travels as a record of its own (hp %.2f of %.0f)" % [float(gi["hp"]), float(gi["max_hp"])])
	# a late guest from the baseline
	var late := puppet()
	check(late.apply_reliable(host.baseline()) and late.apply_snapshot(host.snapshot(t)), "wire: a late guest takes the baseline (%s)" % late.replication_error())
	var li: Dictionary = late.enemy_info(id)
	check(li.get("def", "") == "niche" and is_equal_approx(float(li["max_hp"]), 200.0) and absf(float(li["hp"]) - 200.0) < 0.02, "wire: and knows the maximum from it")
	# a zone and the niche's fall
	var zid: int = host.add_zone("ember", Vector2(2, 2), 1.8, 4.0, 15.0, 31)
	host.damage(id, 9999.0, h)
	t = lockstep(host, guest, hl, gl, t, t + 12)
	var zg := of(gl, EV_ZONE, zid)
	check(zg.size() == 1 and zg[0]["ints"] == PackedInt32Array([ZK_EMBER, 31]) and is_equal_approx(float(zg[0]["floats"][2]), 1.8), "wire: the zone reaches the guest as an event (kind ember, the boss's id; %d)" % zg.size())
	check(of(gl, EV_DIED, id).size() == 1 and guest.enemy_info(id)["state"] == DEAD and of(gl, EV_CORPSE_ADDED).is_empty(), "wire: the niche falls on the guest once, with no corpse")
	check(guest.zones("ember").is_empty(), "wire: a guest has no zones to query (the brains run on the host)")
	# a guest that joins while the zone burns is told of it, with the seconds it has left
	var zlate := puppet()
	check(zlate.apply_reliable(host.baseline()) and zlate.apply_snapshot(host.snapshot(t)), "wire: a late guest takes the baseline while the zone burns")
	var zl := of(events_tagged(zlate), EV_ZONE, zid)
	check(zl.size() == 1 and zl[0]["ints"] == PackedInt32Array([ZK_EMBER, 31]) and float(zl[0]["floats"][3]) > 0.0 and float(zl[0]["floats"][3]) < 4.0, "wire: and is told of it with the seconds it has left (%s)" % str(zl[0]["floats"] if zl.size() == 1 else []))
	var p := puppet()
	check(p.add_zone("toxic", Vector2(0, 0), 1.0, 1.0, 1.0, 1) == 0 and int(p.replication_stats()["commands_refused"]) == 1, "wire: a guest's core refuses to make a zone")
	# a guest with another data table refuses the host (the def's inert flag is part of the hash)
	var odd: RefCounted = ClassDB.instantiate("DmCore")
	var changed: Dictionary = content["ENEMIES"].duplicate(true)
	changed["niche"]["inert"] = false
	odd.load_enemy_defs(changed)
	odd.load_tuning(content)
	odd.load_status_defs(DmStatusRules.build(abilities, DmCoreData.json(data_dir.path_join("data/content/statuses.json")), content))
	odd.set_area_bounds(Vector2(-60, -60), Vector2(60, 60))
	odd.set_puppet(true)
	check(not odd.apply_snapshot(host.snapshot(900)) and "data" in str(odd.replication_error()), "wire: a guest that runs the niche as a plain body refuses the host's snapshot (%s)" % odd.replication_error())
