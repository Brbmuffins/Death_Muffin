extends SceneTree
## Easy auto-combat + standing mouse-aim + rite shakes on the rebuilt client. godot --headless --path client --script res://tests/auto_combat_play/run.gd
## The enemies are static bodies of the combat core (stunned for an hour, harmless), as tests/rites.gd has them; the hostile pool is the core host's `zone` event.
##   A gate (character flag, setting)    B target priority + a rite rotation    C corpse rites    D dodges a hostile pool / boss telegraph feed
##   E yields to deliberate input        F standing mouse-aim facing            G shake once per cast for every rite that shook before
##   H per-frame cost, auto-combat on vs off    I the Reaper plays too    J walks round the graves between it and an enemy instead of parking in a pocket of them

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var hero: DmHeroBody
var caster: DmRiteCaster
var auto: DmNextAutoCombat
var host: DmCoreHost
var core: DmCore
var _ids := 0
var seen: Array = []
var shakes: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


## The line test of a hero that cannot see what is in his way: every line is clear.
class BlindNav extends DmAutoNav:
	func clear_line(_ax: float, _az: float, _bx: float, _bz: float, _r: float = 0.45) -> bool:
		queries["lines"] += 1
		return true


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


## A static enemy of the core: stunned for an hour (it stands where it is), harmless, with health to spare. Returns its id.
func foe(at: Vector3, def_id := "robber", elite := false) -> int:
	var id := host.spawn_enemy(def_id, at, 1, 1000.0, 0.0, elite, "graves", false)
	core.stun(id, 3600.0)
	return id


func eid(e: int) -> int:
	return e


func pos_of(e: int) -> Vector3:
	return host.enemy_position(e)


func reset_hero(at: Vector3) -> void:
	g.input.combat.clear()
	g.session.request_move_dir(Vector3.ZERO)
	hero.teleport(at)
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.p["rootedUntil"] = 0.0
	hero.heal(1e6)
	seen.clear()
	shakes.clear()
	auto.mem.clear()
	auto.last_action = null


func casts_of(rite: String) -> int:
	return seen.filter(func(s: Dictionary) -> bool: return s["rite"] == rite and s["t"] == "cast").size()


func clear_foes() -> void:
	for id in core.enemy_ids():
		host.remove_enemy(int(id))
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	for id in core.thrall_ids():
		core.kill_thrall(id, "crumbled")


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("auto%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(0)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false, "hud": true})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	await ticks(3)
	caster = hero.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	caster.event_played.connect(func(ev: Dictionary) -> void: seen.append({"rite": String(ev["rite"]), "t": String(ev["t"]), "ev": ev}))
	caster.shake_requested.connect(func(a: float) -> void: shakes.append(a))
	auto = g.input.auto
	var store: DmSettings = g.ui_host.settings_store
	var base := Vector3(0, 0, -18)
	check(hero.family == "necromancer" and auto.game == g, "setup: a necromancer, the adapter is wired (%s)" % hero.family)

	# ---- A: the gate
	reset_hero(base)
	var e1 := foe(base + Vector3(0, 0, -6))
	check(not store.can_use_auto_combat() or not bool(store.values["auto_combat"]), "A: auto-combat starts off")
	store.update({"difficulty": "easy", "auto_combat": true})
	check(not bool(store.values["auto_combat"]), "A: a character without the access flag cannot turn it on (the store refuses)")
	await ticks(90)
	check(auto.stats["casts"] == 0 and seen.is_empty(), "A: gate closed = no auto cast, no walk (%d casts)" % auto.stats["casts"])
	store.set_active_character(int(g.character.get("id", 1)), true)
	store.update({"difficulty": "hard", "auto_combat": true})
	check(not bool(store.values["auto_combat"]), "A: allowed but not Easy = off")
	await ticks(60)
	check(auto.stats["casts"] == 0, "A: not on Easy = nothing")
	store.update({"difficulty": "easy", "auto_combat": true})
	check(bool(store.values["auto_combat"]) and auto.allowed(), "A: the access flag + Easy lets it on")
	check(await until(func() -> bool: return casts_of("bone_needle") >= 1, 3.0), "A: gate open = it engages (Bone Needle at the enemy)")
	store.update({"auto_combat": false})
	seen.clear()
	await ticks(60)
	check(seen.filter(func(s: Dictionary) -> bool: return s["t"] == "cast").is_empty(), "A: setting off again = it stops")
	store.update({"auto_combat": true})

	# ---- B: target priority (nearest) and a rotation
	clear_foes()
	await ticks(3)
	reset_hero(base)
	var near := foe(base + Vector3(0, 0, -5))
	var far := foe(base + Vector3(3, 0, -9))
	await until(func() -> bool: return auto.last_action != null, 2.0)
	var la: Variant = auto.last_action
	check(la != null and la["target"].get("enemyId") == eid(near), "B: the nearest enemy is the target (got %s, near %d)" % [str(la), eid(near)])
	check(auto.mem.get("targetId") == eid(near), "B: the target is remembered (sticky): %s" % str(auto.mem.get("targetId")))
	var pack: Array = []
	for i in 6:
		pack.append(foe(base + Vector3(float(i % 3) * 1.2 - 1.2, 0, -6.0 - float(i / 3) * 1.2)))
	seen.clear()
	await ticks(300)
	var rites := {}
	for s in seen:
		if s["t"] == "cast":
			rites[s["rite"]] = true
	check(rites.size() >= 2 and rites.has("bone_needle"), "B: it rotates rites over a pack (%s)" % [str(rites.keys())])
	var d_pack := hero.position.distance_to(pos_of(near))
	var cast_reach := float(DmAbilities.def("bone_needle")["range"]) + 1.0
	check(d_pack <= cast_reach and d_pack >= 1.0, "B: it holds a casting distance (%.1f m of %.1f)" % [d_pack, cast_reach])
	check(auto.stats["moves"] >= 0 and hero.position.distance_to(base) < 30.0, "B: stayed in the arena")

	# ---- C: corpse rites
	clear_foes()
	await ticks(3)
	reset_hero(base)
	var decoy := foe(base + Vector3(0, 0, -7))
	for i in 3:
		host.corpses.add_corpse(base.x + 2.0 + float(i), base.z + 1.0, "normal", "robber", false, 0.0, 1.0, "graves")
	var n0 := host.thrall_count(hero.core_id)
	check(await until(func() -> bool: return casts_of("exhume") >= 1, 4.0) and host.thrall_count(hero.core_id) > n0, "C: a corpse and an empty legion = it Exhumes (thralls %d -> %d)" % [n0, host.thrall_count(hero.core_id)])

	# ---- D: dodge
	clear_foes()
	await ticks(3)
	reset_hero(base)
	reset_hero(Vector3(0, 0, -6))
	var zone := Vector3(0.0, 0.0, -5.5)   # a hostile pool of radius 3 m, as the core host announces one (`zone`: id, kind, source, x, z, radius, seconds)
	host.zone.emit(777, 0, 0, zone.x, zone.z, 3.0, 12.0)
	var out_r := 3.0 + DmNextAutoCombat.ZONE_PAD
	check(await until(func() -> bool: return Vector2(hero.position.x - zone.x, hero.position.z - zone.z).length() > out_r + 0.2, 4.0), "D: it steps out of a hostile pool (%.1f m from its centre)" % Vector2(hero.position.x - zone.x, hero.position.z - zone.z).length())
	host.zone_gone.emit(777)
	await ticks(30)
	var bhost: DmBossHost = g.bosses
	bhost.fx.play({"t": "boss", "kind": "toll", "boss": "prelate", "x": 5.0, "z": 5.0, "ms": 2000.0, "r": 4.0})
	var tl := auto.telegraphs.active(DmNextAutoCombat.clock_ms())   # the adapter's clock is the physics ticks' milliseconds (dm_next_auto.gd), not the wall clock
	check(tl.size() == 1 and tl[0]["k"] == "circle", "D: a boss telegraph reaches the dodge list through DmBossFx.played (%d)" % tl.size())
	auto.telegraphs.clear()
	var step: Variant = DmAutoDodge.dodge_step({"x": 5.0, "z": 5.0}, DmAutoDodge.hazards_from_boss_event({"kind": "toll", "boss": "prelate", "x": 5.0, "z": 5.0, "ms": 2000.0, "r": 4.0}, 0.0), null, 0.0, {})
	check(step != null, "D: the dodge step leaves a telegraph (the shared DmAutoDodge)")

	# ---- E: yields to deliberate input
	clear_foes()
	await ticks(3)
	reset_hero(base)
	var e2 := foe(base + Vector3(0, 0, -6))
	g.input.combat.target_id = eid(e2)
	g.input.combat.stand = true
	var a0: int = auto.stats["casts"]
	await ticks(40)
	check(auto.stats["yields"] > 0 and auto.stats["casts"] == a0 or casts_of("bone_needle") >= 0, "E: a click target is the player's, not auto's")
	g.input.combat.clear()
	hero.set_move_target(base + Vector3(8, 0, 0))
	a0 = auto.stats["casts"]
	await ticks(30)
	check(auto.stats["casts"] == a0 and hero.has_target, "E: a walk in progress is left alone")
	await until(func() -> bool: return not hero.has_target, 4.0)
	check(await until(func() -> bool: return auto.stats["casts"] > a0, 3.0), "E: after the walk, auto resumes")

	# ---- F: standing mouse-aim facing
	clear_foes()
	await ticks(3)
	store.update({"auto_combat": false})
	reset_hero(base)
	await ticks(3)
	var cb: DmCombatInput = g.input.combat
	check(cb.stand_face(base + Vector3(10, 0, 0), false), "F: the cursor to the east turns the standing hero")
	await ticks(3)
	check(absf(angle_difference(hero.yaw, PI / 2.0)) < 0.01 and absf(hero.rotation.y - hero.yaw) < 0.01, "F: yaw %.2f faces east (%.2f)" % [hero.yaw, PI / 2.0])
	check(not cb.stand_face(base + Vector3(10, 0, 0), false), "F: the same aim sends nothing again")
	check(not cb.stand_face(base + Vector3(0.1, 0, 0), false), "F: a cursor on top of the hero is ignored (pad)")
	check(not cb.stand_face(base + Vector3(-10, 0, 0), true), "F: auto-combat's own target wins over the cursor")
	hero.set_move_target(base + Vector3(0, 0, 12))
	check(not cb.stand_face(base + Vector3(-10, 0, 0), false), "F: not while walking")
	await until(func() -> bool: return not hero.has_target, 4.0)
	await ticks(5)
	var pos := hero.position
	check(cb.stand_face(pos + Vector3(-10, 0, 0), false), "F: standing again, it turns")
	await ticks(3)
	check(absf(angle_difference(hero.yaw, -PI / 2.0)) < 0.01 and hero.position.distance_to(pos) < 0.01, "F: faced west without moving")
	var foeS := foe(hero.position + Vector3(0, 0, 6))
	g.session.request_face(-PI / 2.0)
	caster.request_cast("bone_needle", pos_of(foeS), eid(foeS))
	await ticks(2)
	check(absf(angle_difference(hero.yaw, 0.0)) < 0.05, "F: casting at an enemy to the south turns the standing hero (%.2f)" % hero.yaw)
	cb.clear()

	# ---- G: shakes
	var table := {"marrow_spear": 3, "exhume": 1, "grave_step": 1, "grave_frost": 1, "bone_prison": 1, "bone_mantle": 1, "black_litany": 1, "ivory_cleave": 1,
		"carrion_seed": 1, "corpse_explosion": 1}   # the old client's shake sites per rite, recorded before DmAbilitySystem was removed 2026-10-09 (marrow_spear: arrive / ring / impale)
	for kn in ["shield_bash", "grave_slam", "oath_unbroken"]:
		check(not DmRiteRegistry.has(kn), "G: %s has no rebuild module (a knight rite)" % kn)
	for rite in table:
		var path := "res://next/rites/rite_%s.gd" % rite
		check(FileAccess.file_exists(path) and FileAccess.get_file_as_string(path).contains("shake_requested.emit"), "G: %s requests a shake" % rite)
	clear_foes()
	await ticks(3)
	for rite in ["grave_step", "grave_frost", "bone_prison", "bone_mantle", "black_litany", "ivory_cleave", "carrion_seed", "corpse_explosion", "marrow_spear"]:
		reset_hero(base)
		clear_foes()
		await ticks(2)
		var tx := foe(base + Vector3(0, 0, -3))
		foe(base + Vector3(1, 0, -3.5))
		foe(base + Vector3(-1, 0, -3.2))
		for i in 4:
			host.corpses.add_corpse(base.x + 1.5 + float(i) * 0.6, base.z - 2.0, "normal", "robber", false, 0.0, 1.0, "graves")
		await ticks(2)
		caster.request_cast(rite, base + Vector3(0, 0, -3), eid(tx))
		await until(func() -> bool: return casts_of(rite) >= 1 or seen.any(func(s: Dictionary) -> bool: return s["rite"] == rite), 1.0)
		await ticks(40)
		check(casts_of(rite) + seen.filter(func(s: Dictionary) -> bool: return s["rite"] == rite).size() > 0 and shakes.size() >= 1, "G: casting %s requested a camera shake (%d request(s) %s)" % [rite, shakes.size(), str(shakes)])
	g.camera.reduced_motion = true
	var tr0: float = g.camera._trauma
	caster.shake_requested.emit(0.2)
	check(g.camera._trauma == tr0, "G: reduce_motion still drops the shake")
	g.camera.reduced_motion = false

	# ---- H: decisions are throttled
	clear_foes()
	await ticks(3)
	reset_hero(base)
	for i in 14:
		foe(base + Vector3(float(i % 5) * 2.0 - 4.0, 0, -9.0 - float(i / 5) * 2.0))
	for i in 20:
		host.corpses.add_corpse(base.x + float(i) - 10.0, base.z + 4.0, "normal", "robber", false, 0.0, 1.0, "graves")
	store.update({"auto_combat": true})
	await ticks(240)   # the first casts of each rite pay their one-off effect set-up: count the steady state
	var st0: Dictionary = auto.stats.duplicate()
	await ticks(180)
	var decisions: int = auto.stats["actions"] - int(st0["actions"])
	var due := 3000.0 / ACT_MS()   # (one decision every ACT_MS: a quarter of that to a quarter more is throttled and working)
	check(float(decisions) > due * 0.25 and float(decisions) < due * 1.25, "H: decisions are throttled (%d in 3 s, ~every %.0f ms)" % [decisions, ACT_MS()])

	# ---- J: graves in the way. Auto steered straight at the nearest enemy and parked in the pocket between two graves; now it looks along the line, asks the navmesh for the way round
	# and walks it. The places are the Graves' own: two graves close enough that the navmesh closes the gap between them, the hero on one side and an enemy out of reach on the other.
	store.update({"auto_combat": true})
	var pockets := graves_pockets(3, float(DmAbilities.def("bone_needle")["range"]))
	check(pockets.size() == 3, "J: the Graves hold graves close enough to make pockets (%d found)" % pockets.size())
	var reach_j := float(DmAbilities.def("bone_needle")["range"])
	for i in pockets.size():
		var at: Vector3 = pockets[i][0]
		var to: Vector3 = pockets[i][1]
		clear_foes()
		await ticks(3)
		reset_hero(at)
		await ticks(3)
		var far_foe := foe(to)
		var ticks0: int = auto.stats["ticks"]
		auto.nav.queries["lines"] = 0
		auto.nav.queries["paths"] = 0
		var got_in := await until(func() -> bool: return hero.position.distance_to(pos_of(far_foe)) <= reach_j, 12.0)
		var d_j := hero.position.distance_to(pos_of(far_foe))
		check(got_in, "J: pocket %d: it walked round the graves to its casting distance (%.1f m of %.1f, from %.1f m)" % [i + 1, d_j, reach_j, at.distance_to(to)])
		check(await until(func() -> bool: return casts_of("bone_needle") >= 1, 3.0), "J: pocket %d: ...and cast at the enemy from there" % [i + 1])
		var span_ms := float(auto.stats["ticks"] - ticks0) * DmNextAutoCombat.MOVE_MS
		var q: Dictionary = auto.nav.queries
		check(int(q["paths"]) >= 1 and int(q["lines"]) <= int(ceilf(span_ms / DmAutoCombat.SIGHT_MS)) + 2 and int(q["paths"]) <= int(ceilf(span_ms / DmAutoCombat.ROUTE_MS)) + 2, "J: pocket %d: it asked the navmesh for a path (%d) and looked along the line at most every %.0f ms (%d looks in %.0f ms), never per frame" % [i + 1, int(q["paths"]), DmAutoCombat.SIGHT_MS, int(q["lines"]), span_ms])

	if not pockets.is_empty():
		var a: Vector3 = pockets[0][0]
		var b: Vector3 = pockets[0][1]
		var open_to := a   # (the longest case of a look: a line all of whose samples are on the navmesh)
		for k in 16:
			var cand := a + Vector3(sin(TAU * float(k) / 16.0), 0.0, cos(TAU * float(k) / 16.0)) * a.distance_to(b)
			if auto.nav.clear_line(a.x, a.z, cand.x, cand.z):
				open_to = cand
				break
		var t0 := Time.get_ticks_usec()
		for i in 50:
			auto.nav.clear_line(a.x, a.z, open_to.x, open_to.z)
		var t1 := Time.get_ticks_usec()
		for i in 50:
			auto.nav.find_path(a.x, a.z, b.x, b.z)
		var t2 := Time.get_ticks_usec()
		print("INFO J: a look along a clear %.0f m line %.0f us, a path round the graves %.0f us (at most %.1f looks and %.2f paths a second while closing)" % [a.distance_to(open_to), float(t1 - t0) / 50.0, float(t2 - t1) / 50.0, 1000.0 / DmAutoCombat.SIGHT_MS, 1000.0 / DmAutoCombat.ROUTE_MS])
	# ...and a walk that goes nowhere takes the path whatever the line test says: the line test is blinded (always "clear") in the first pocket, so the hero walks into it and stands
	if not pockets.is_empty():
		var real_nav := auto.nav
		var blind := BlindNav.new()
		blind.world = g.world
		auto.nav = blind
		clear_foes()
		await ticks(3)
		reset_hero(pockets[0][0])
		await ticks(3)
		var stuck0: int = auto.stats["stuck"]
		var blind_foe := foe(pockets[0][1])
		var stuck_out := await until(func() -> bool: return hero.position.distance_to(pos_of(blind_foe)) <= reach_j, 12.0)
		check(auto.stats["stuck"] > stuck0 and blind.queries["paths"] >= 1, "J: a walk that gets nowhere for a while is noticed (%d stuck) and asks for the path (%d)" % [auto.stats["stuck"] - stuck0, blind.queries["paths"]])
		check(stuck_out, "J: ...and the path takes the hero out of the pocket to its casting distance (%.1f m of %.1f)" % [hero.position.distance_to(pos_of(blind_foe)), reach_j])
		auto.nav = real_nav

	# ---- I: the Reaper plays too (a second game, her own account)
	var arena := Vector3(0, 0, -6)   # open ground near the start (the Graves' far end has walls the walk catches on)
	store.update({"auto_combat": false})
	g.queue_free()
	await ticks(3)
	var r2 := await api.register("reap%d" % (Time.get_ticks_usec() % 100000), "q@example.com", "pw1234")
	api.set_token(r2.data["token"])
	var c2 := await api.load_or_create_character(11)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c2.data, api, {"dressing": false, "persist": false, "waves": false, "hud": true})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	await ticks(3)
	caster = hero.get_node("Rites") as DmRiteCaster
	seen.clear()
	caster.event_played.connect(func(ev: Dictionary) -> void: seen.append({"rite": String(ev["rite"]), "t": String(ev["t"]), "ev": ev}))
	auto = g.input.auto
	store = g.ui_host.settings_store
	check(hero.family == "reaper", "I: the second hero is the Reaper (%s)" % hero.family)
	store.set_active_character(int(g.character.get("id", 1)), true)
	store.update({"difficulty": "easy", "auto_combat": true})
	check(bool(store.values["auto_combat"]) and auto.allowed(), "I: the gate opens for her too")
	var seen_rite := func(rite: String) -> bool: return seen.any(func(s: Dictionary) -> bool: return s["rite"] == rite)
	reset_hero(arena)
	caster.p["souls"] = 0
	var lone := foe(arena + Vector3(0, 0, -7))
	check(await until(func() -> bool: return seen_rite.call("scythe_sweep"), 8.0), "I: with an empty bag she walks in and swings Scythe Sweep (%d moves)" % auto.stats["moves"])
	check(hero.position.distance_to(pos_of(lone)) < 6.0, "I: she closed to melee (%.1f m)" % hero.position.distance_to(pos_of(lone)))
	clear_foes()
	await ticks(3)
	reset_hero(arena)
	var full_bag := int(caster.p["soulsMax"])
	caster.p["souls"] = full_bag
	for i in 7:
		foe(arena + Vector3(cos(float(i)) * 2.4, 0, sin(float(i)) * 2.4 - 1.0))
	check(await until(func() -> bool: return seen_rite.call("soul_burst") or seen_rite.call("reap") or seen_rite.call("harvest_spin"), 4.0), "I: a full bag among a pack is spent on a rite (%s)" % str(seen.map(func(s: Dictionary) -> String: return s["rite"])))
	check(int(caster.p["souls"]) < full_bag, "I: the souls were paid (%s left of %d)" % [str(caster.p["souls"]), full_bag])
	clear_foes()
	await ticks(3)
	reset_hero(arena)
	caster.p["souls"] = int(DmAbilities.def("wraith_walk")["soulCost"]) * 2   # (enough to pay for it)
	hero.p["hp"] = hero.max_hp * 0.2   # the body mirrors p each tick
	var chaser := foe(arena + Vector3(0, 0, -2.5))
	check(await until(func() -> bool: return seen_rite.call("wraith_walk"), 4.0), "I: low on health with a foe on her she Wraith Walks away")
	await ticks(40)
	check(hero.position.distance_to(pos_of(chaser)) > 5.0, "I: ...and ends up clear of it (%.1f m)" % hero.position.distance_to(pos_of(chaser)))

	print("%d passed, %d failed" % [passed, failed])
	print("%s auto_combat_play %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(0 if failed == 0 else 1)


## Places the navmesh closes between two graves of the Graves, from the world's own data: [from, to] pairs with the hero's side 3 m from the middle of two graves less than 3.2 m apart, the enemy's
## side `reach + 6` m on the other side, both on the navmesh, the straight line between them cut by the graves and a way round that is no more than half as long again. The first `n`.
func graves_pockets(n: int, reach: float) -> Array:
	auto.nav.world = g.world
	var circles: Array = []
	for p in DmData.world()["props"]:
		var o: Variant = p.get("obstacle")
		if String(p.get("area", "")) == "graves" and o != null and String(o["kind"]) == "circle":
			circles.append(Vector2(float(o["x"]), float(o["z"])))
	var out: Array = []
	for i in circles.size():
		for j in range(i + 1, circles.size()):
			var a: Vector2 = circles[i]
			var b: Vector2 = circles[j]
			if a.distance_to(b) > 3.2:
				continue
			var mid: Vector2 = (a + b) * 0.5
			var side: Vector2 = (b - a).orthogonal().normalized()
			for sign_ in [1.0, -1.0]:
				var here: Vector2 = mid + side * 3.0 * sign_
				var there: Vector2 = mid - side * (reach + 6.0) * sign_
				if not on_ground(here) or not on_ground(there) or auto.nav.clear_line(here.x, here.y, there.x, there.y):
					continue
				var path := g.world.nav_path(Vector3(here.x, 0.0, here.y), Vector3(there.x, 0.0, there.y))
				var long_ := 0.0
				for k in range(1, path.size()):
					long_ += path[k - 1].distance_to(path[k])
				if long_ > 0.0 and long_ <= here.distance_to(there) * 1.5:
					out.append([Vector3(here.x, 0.0, here.y), Vector3(there.x, 0.0, there.y)])
					if out.size() >= n:
						return out
	return out


func on_ground(pt: Vector2) -> bool:
	var q: Vector3 = g.world.nav_closest(Vector3(pt.x, 0.0, pt.y))
	return Vector2(q.x - pt.x, q.z - pt.y).length() < 0.05


func ACT_MS() -> float:
	return DmNextAutoCombat.ACT_MS
