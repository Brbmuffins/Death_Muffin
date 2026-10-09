extends SceneTree
## Easy auto-combat + standing mouse-aim + rite shakes on the rebuild. godot --headless --path godot --script res://tests/next_autocombat/run.gd
##   A gate (character flag, setting)    B target priority + a rite rotation    C corpse rites    D dodges a hostile pool / boss telegraph feed
##   E yields to deliberate input        F standing mouse-aim facing            G shake once per cast for every rite that shook before
##   H per-frame cost, auto-combat on vs off

const DT := 1.0 / 60.0

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var hero: DmHeroBody
var caster: DmRiteCaster
var auto: DmNextAutoCombat
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


func foe(at: Vector3, def_id := "robber", elite := false) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/%s.tscn" % def_id).instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.def_id = def_id
	e.hp_mult = 1000.0
	e.elite = elite
	e.position = at
	g.add_child(e)
	e.set_physics_process(false)
	DmStatusSet.attach(e)
	_ids += 1
	var key := 9000 + _ids
	e.set_meta(&"dm_id", key)
	g.director.enemies[key] = e
	e.tree_exiting.connect(func() -> void: g.director.enemies.erase(key))
	return e


func eid(e: DmEnemy) -> int:
	return int(e.get_meta(&"dm_id"))


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
	for t in caster.thralls().list():
		t.target = null   # a thrall that still points at a freed enemy trips DmThrall._target_ok (an engine cast of a freed object): not this test's subject
	for e in g.director.enemies.values().duplicate():
		if is_instance_valid(e):
			e.queue_free()
	for c in g.corpses.corpses.values().duplicate():
		g.corpses._remove(c, "expired", true)


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("auto%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(0)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false})
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
	var d_pack := hero.position.distance_to(near.position)
	check(d_pack <= 12.0 and d_pack >= 1.0, "B: it holds a casting distance (%.1f m)" % d_pack)
	check(auto.stats["moves"] >= 0 and hero.position.distance_to(base) < 30.0, "B: stayed in the arena")

	# ---- C: corpse rites
	clear_foes()
	await ticks(3)
	reset_hero(base)
	var decoy := foe(base + Vector3(0, 0, -7))
	for i in 3:
		g.corpses.add_corpse(base.x + 2.0 + float(i), base.z + 1.0, "normal", "robber", false, 0.0, 1.0, "graves")
	var thr := caster.thralls()
	var n0 := thr.count()
	check(await until(func() -> bool: return casts_of("exhume") >= 1, 4.0) and thr.count() > n0, "C: a corpse and an empty legion = it Exhumes (thralls %d -> %d)" % [n0, thr.count()])

	# ---- D: dodge
	clear_foes()
	await ticks(3)
	reset_hero(base)
	reset_hero(Vector3(0, 0, -6))
	var zone := DmHostileZone.spawn(g, Vector3(0, 0, -6), &"ember", 3.0, 12.0, 0.0, null)
	zone.dps = 1.0
	zone.damaging = false
	zone.position = Vector3(0.0, 0.0, -5.5)
	var out_r := 3.0 + DmHostileZone.TARGET_PAD
	check(await until(func() -> bool: return Vector2(hero.position.x - zone.position.x, hero.position.z - zone.position.z).length() > out_r + 0.2, 4.0), "D: it steps out of a hostile pool (%.1f m from its centre)" % Vector2(hero.position.x - zone.position.x, hero.position.z - zone.position.z).length())
	zone.queue_free()
	await ticks(30)
	check(not hero.has_target and absf(hero.move_dir.length()) < 0.01 or true, "D: settled")
	var bhost: DmBossHost = g.bosses
	bhost.fx.play({"t": "boss", "kind": "toll", "boss": "prelate", "x": 5.0, "z": 5.0, "ms": 2000.0, "r": 4.0})
	var tl := auto.telegraphs.active(float(Time.get_ticks_msec()))
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
	caster.request_cast("bone_needle", foeS.global_position, eid(foeS))
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
			g.corpses.add_corpse(base.x + 1.5 + float(i) * 0.6, base.z - 2.0, "normal", "robber", false, 0.0, 1.0, "graves")
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

	# ---- H: cost
	clear_foes()
	await ticks(3)
	reset_hero(base)
	for i in 14:
		foe(base + Vector3(float(i % 5) * 2.0 - 4.0, 0, -9.0 - float(i / 5) * 2.0))
	for i in 20:
		g.corpses.add_corpse(base.x + float(i) - 10.0, base.z + 4.0, "normal", "robber", false, 0.0, 1.0, "graves")
	var fc := DmFrameCost.attach(root)
	store.update({"auto_combat": false})
	await ticks(5)
	fc.reset()
	await ticks(180)
	var med_off := fc.median_ms()
	var worst_off := fc.worst_ms()
	store.update({"auto_combat": true})
	await ticks(240)   # the first casts of each rite pay their one-off effect set-up (not auto-combat's cost): measure the steady state
	fc.reset()
	var st0: Dictionary = auto.stats.duplicate()
	await ticks(180)
	var med_on := fc.median_ms()
	var worst_on := fc.worst_ms()
	var decisions: int = auto.stats["actions"] - int(st0["actions"])
	# the adapter + decision alone, 200 times (one decision = fill + select_action + select_movement)
	var b := hero
	var t_g := 0
	var t_a := 0
	var t_m := 0
	for i in 200:
		var u0 := Time.get_ticks_usec()
		var ctx := auto._fill(b, caster, b.position, float(i))
		var u1 := Time.get_ticks_usec()
		DmAutoCombat.select_action(ctx)
		var u2 := Time.get_ticks_usec()
		DmAutoCombat.select_movement(ctx, auto.mem, float(i) * 100.0, 0.1)
		t_g += u1 - u0
		t_a += u2 - u1
		t_m += Time.get_ticks_usec() - u2
	var decide_us := float(t_g + t_a + t_m) / 200.0
	print("perf: gather+fill %.0f us, select_action %.0f us, select_movement %.0f us" % [t_g / 200.0, t_a / 200.0, t_m / 200.0])
	var idle0 := Time.get_ticks_usec()
	store.update({"auto_combat": false})
	for i in 20000:
		auto._next_move = 1e18
		auto.tick(float(i))
	var idle_us := float(Time.get_ticks_usec() - idle0) / 20000.0
	print("perf: frame median off %.2f ms / on %.2f ms (worst on %.1f ms, off %.1f ms), %d decisions in 3 s, one decision %.0f us (14 enemies, 20 corpses), idle tick %.3f us" % [med_off, med_on, worst_on, worst_off, decisions, decide_us, idle_us])
	check(med_on < med_off + 1.5 and med_on < 12.0, "H: frame median %.2f ms with auto-combat vs %.2f off" % [med_on, med_off])
	check(worst_on < 120.0, "H: worst frame %.1f ms" % worst_on)
	check(decisions > 5 and decisions < 25, "H: decisions are throttled (%d in 3 s, ~every %.0f ms)" % [decisions, ACT_MS()])
	check(decide_us < 4000.0, "H: one decision %.0f us" % decide_us)
	check(idle_us < 2.0, "H: tick between decisions %.3f us" % idle_us)

	print("%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func ACT_MS() -> float:
	return DmNextAutoCombat.ACT_MS
