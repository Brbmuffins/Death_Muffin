extends SceneTree
## Necromancer combat feel on the rebuild (godot/next/feel + gestures + runes + hitstop). godot --headless --path godot --script res://tests/next_feel/run.gd
##   A chase to range, then attack     B hold repeat cadence = the rite's cooldown     C queued cast fires after the lock     D shift-cast in place
##   E held number key repeats         F gesture once per cast (host + ENet client)    G hitstop on an elite death, off under reduce_motion
##   H runes reach the caster and change outcomes (Impaling marrow spear, Hollow Choir litany)     I latency + per-frame cost

const DT := 1.0 / 60.0
var PORT := DmTestPorts.free_port()

var passed := 0
var failed := 0
var g: DmNextGame
var api: DmApi
var character: Dictionary
var hero: DmHeroBody
var caster: DmRiteCaster
var _ids := 0


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


## A brain-off, soaking enemy (no nav, stands still) registered with the director like a spawned one.
func foe(at: Vector3, def_id := "robber") -> DmEnemy:
	var e: DmEnemy = load("res://enemies/%s.tscn" % def_id).instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.def_id = def_id
	e.hp_mult = 1000.0
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


## Cast events seen by the owner's caster since the last reset: [{rite, t, ms}] (ms = the host clock when it arrived).
var seen: Array = []


func reset_hero(at: Vector3) -> void:
	g.input.combat.clear()
	hero.teleport(at)
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.p["rootedUntil"] = 0.0
	hero.heal(1e6)
	seen.clear()


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("feel%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(0)
	character = c.data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"dressing": false, "persist": false, "waves": false})
	hero = g.local_body()
	await ticks(3)
	caster = hero.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	caster.event_played.connect(func(ev: Dictionary) -> void: seen.append({"rite": String(ev["rite"]), "t": String(ev["t"]), "ms": caster.now_ms, "ev": ev}))
	check(hero.discipline_id == "gravecaller" and g.rite_for_slot(0) == "bone_needle" and g.rite_for_slot(1) == "marrow_spear", "setup: a Gravecaller with the kit loadout (primary %s, slot 1 %s)" % [g.rite_for_slot(0), g.rite_for_slot(1)])
	var combat: DmCombatInput = g.input.combat
	combat.shift_probe = func() -> bool: return false
	var cool := DmWeaponLine.ability_cooldown_ms("bone_needle", float(DmAbilities.def("bone_needle")["cooldownMs"]), caster.p["loadout"], true)

	# ---- A: click a far enemy = walk into range, stop, attack
	reset_hero(Vector3(0, 0, -18))
	var far := foe(Vector3(0, 0, -36))
	var rng := DmWeaponLine.ability_range("bone_needle", float(DmAbilities.def("bone_needle")["range"]), caster.p["loadout"]) + 0.4
	check(hero.position.distance_to(far.position) > rng + 5.0, "A: the enemy starts out of range (%.1f m, range %.1f)" % [hero.position.distance_to(far.position), rng])
	g.input.attack(eid(far), false)
	check(combat.stats["chase_moves"] == 1 and combat.target_id == eid(far), "A: the click took the first chase step immediately")
	check(await until(func() -> bool: return seen.any(func(s: Dictionary) -> bool: return s["rite"] == "bone_needle" and s["t"] == "cast"), 6.0), "A: the hero walked in and cast Bone Needle")
	var d_cast := hero.position.distance_to(far.position)
	check(d_cast <= rng + 0.3 and d_cast > rng - 2.5, "A: it stopped at the edge of range, not on top of the enemy (%.2f m, range %.2f)" % [d_cast, rng])
	check(combat.stats["chase_moves"] <= 3 and combat.stats["stops"] >= 1, "A: the walk was planned once (%d plans), then one stop" % combat.stats["chase_moves"])
	await ticks(20)
	check(not hero.has_target and absf(hero.position.distance_to(far.position) - d_cast) < 0.3, "A: standing while it fires")

	# ---- B: hold = repeat at the rite's cooldown
	seen.clear()
	await ticks(150)
	var casts := seen.filter(func(s: Dictionary) -> bool: return s["rite"] == "bone_needle" and s["t"] == "cast")
	var gaps: Array = []
	for i in range(1, casts.size()):
		gaps.append(float(casts[i]["ms"]) - float(casts[i - 1]["ms"]))
	var gmin := float(gaps.min()) if not gaps.is_empty() else 0.0
	var gmax := float(gaps.max()) if not gaps.is_empty() else 0.0
	check(casts.size() >= 4 and gmin >= cool - 1.0 and gmax <= cool + 120.0, "B: %d primaries in 2.5 s, gaps %.0f..%.0f ms vs the rite's cooldown %.0f ms" % [casts.size(), gmin, gmax, cool])
	g.input.combat.clear()
	g.session.request_move_dir(Vector3.ZERO)

	# ---- C: a cast pressed during another cast's lock is queued and fires after it
	reset_hero(Vector3(0, 0, -18))
	var near := foe(Vector3(0, 0, -25))
	g.input._hover_id = eid(near)
	g.input._aim = near.position
	g.input.cast_at(0, near.position, eid(near), false)     # the lock (60 ms) starts
	g.input.press_hotbar(1)                                  # marrow spear, pressed inside it
	check(combat.stats["queued"] == 1 and not combat.queued.is_empty(), "C: the refused spear was queued")
	check(not seen.any(func(s: Dictionary) -> bool: return s["rite"] == "marrow_spear"), "C: ...and has not fired yet")
	check(await until(func() -> bool: return seen.any(func(s: Dictionary) -> bool: return s["rite"] == "marrow_spear" and s["t"] == "cast"), 1.0), "C: the queued spear fired once the lock ended")
	await ticks(10)
	check(seen.filter(func(s: Dictionary) -> bool: return s["rite"] == "marrow_spear" and s["t"] == "cast").size() == 1 and combat.queued.is_empty(), "C: exactly one spear, the queue is empty")
	# a cooldown longer than the window is NOT queued
	g.input.press_hotbar(1)
	check(combat.queued.is_empty(), "C: a spear on a long cooldown is refused, not queued")

	# ---- D: Shift + click = cast in place, no chase
	reset_hero(Vector3(0, 0, -18))
	combat.stats["chase_moves"] = 0
	var p0 := hero.position
	g.input.attack(eid(far), true)
	await ticks(60)
	check(combat.stats["chase_moves"] == 0 and hero.position.distance_to(p0) < 0.05, "D: shift-click on a far enemy does not walk")
	check(not seen.any(func(s: Dictionary) -> bool: return s["rite"] == "bone_needle" and s["t"] == "cast"), "D: out of range it casts nothing (the host would refuse)")
	g.input.combat.clear()
	var close := foe(Vector3(0, 0, -26))
	g.input.attack(eid(close), true)
	check(await until(func() -> bool: return seen.any(func(s: Dictionary) -> bool: return s["rite"] == "bone_needle" and s["t"] == "cast"), 2.0) and hero.position.distance_to(p0) < 0.05, "D: shift-click in range fires without moving")
	g.input.combat.clear()
	# live shift turns a chase into a stand
	reset_hero(Vector3(0, 0, -18))
	combat.shift_probe = func() -> bool: return true
	g.input.attack(eid(far), false)
	await ticks(30)
	check(hero.position.distance_to(Vector3(0, 0, -18)) < 0.05, "D: holding Shift during a chase stops it")
	combat.shift_probe = func() -> bool: return false
	g.input.combat.clear()

	# ---- E: a held number key repeats when the rite is ready
	reset_hero(Vector3(0, 0, -18))
	g.input._hover_id = eid(near)
	g.input.press_hotbar(3)                                  # miasma (cooldown 7 s) pressed ...
	combat.key_down(3, float(Time.get_ticks_msec()))
	Input.action_press(&"dm_hotbar_3")
	await ticks(60)
	var m1 := seen.filter(func(s: Dictionary) -> bool: return s["rite"] == "miasma" and s["t"] == "cast").size()
	check(m1 == 1, "E: held key on a cooling rite does not spam (%d cast in 1 s)" % m1)
	caster.p["cooldowns"].erase("miasma")                    # ... ready again
	await ticks(30)
	var m2 := seen.filter(func(s: Dictionary) -> bool: return s["rite"] == "miasma" and s["t"] == "cast").size()
	Input.action_release(&"dm_hotbar_3")
	check(m2 == 2 and combat.stats["repeats"] >= 1, "E: the held key cast again the moment it was ready (%d casts, %d repeats)" % [m2, combat.stats["repeats"]])
	await ticks(5)
	check(combat.idle(), "E: releasing the key ends the repeat")

	# ---- F: a gesture per accepted cast
	reset_hero(Vector3(0, 0, -18))
	var g0 := caster.gestures_played
	var ev0 := caster.events_played
	caster.request_cast("bone_needle", near.position, eid(near))
	caster.request_cast("bone_needle", near.position, eid(near))   # refused at once: the lock / cooldown
	await ticks(10)
	check(caster.gestures_played == g0 + 1, "F: one gesture for one cast, none for the refused one (%d)" % (caster.gestures_played - g0))
	check(hero.avatar != null, "F: the hero has an avatar to play it on")
	var missing: Array = []
	for rite in DmRiteGestures.TABLE:
		var row: Array = DmRiteGestures.TABLE[rite]
		if not DmRiteRegistry.has(rite) or not DmAbilities.cast_flow(String(row[2])).has("gestureSeconds"):
			missing.append(rite)
	check(missing.is_empty() and DmRiteGestures.TABLE.size() == DmRiteRegistry.ids().size(), "F: a gesture row for every registered rite (%s missing, %d rows / %d rites)" % [missing, DmRiteGestures.TABLE.size(), DmRiteRegistry.ids().size()])
	check(caster.events_played >= ev0 + 1, "F: events are untouched (the gesture is not an event)")

	# ---- G: hitstop on an elite death, nothing under reduce_motion
	reset_hero(Vector3(0, 0, -18))
	await ticks(30)   # the min gap / budget settle
	var elite := g.director.spawn("robber", Vector3(0, 0, -23), [hero], true)
	await until(func() -> bool: return elite.sm.id() != DmEnemyState.Id.RISING, 6.0)
	var hs0 := g.hitstopper.count
	var froze := [false]
	elite.take_damage(1e9, hero)
	for i in 12:
		await physics_frame
		await process_frame
		froze[0] = froze[0] or g.hitstopper.scale < 1.0 or g.hitstopper.frozen()
	check(g.hitstopper.count == hs0 + 1 and (froze[0] or g.hitstopper.total > 0.0), "G: an elite death near the hero asked for one hitstop (%d, %.0f ms granted)" % [g.hitstopper.count - hs0, g.hitstopper.total * 1000.0])
	check(g.hitstopper.total <= 0.1, "G: hitstop is a micro-freeze, not a pause (%.3f s total)" % g.hitstopper.total)
	await ticks(40)
	g.ui_host.settings_store.update({"reduce_motion": true})
	var hs1 := g.hitstopper.count
	var elite2 := g.director.spawn("robber", Vector3(1, 0, -23), [hero], true)
	await until(func() -> bool: return elite2.sm.id() != DmEnemyState.Id.RISING, 6.0)
	elite2.take_damage(1e9, hero)
	await ticks(10)
	check(g.hitstopper.count == hs1, "G: reduce_motion disables hitstop")
	check(g.camera.reduced_motion, "G: reduce_motion reaches the camera, so rite shake is dropped")
	g.ui_host.settings_store.update({"reduce_motion": false})
	var tr0: float = g.camera._trauma
	caster.shake_requested.emit(0.2)
	check(g.camera._trauma > tr0, "G: a rite's shake request reaches the camera")
	g.hitstopper.reset()

	# ---- H: runes reach the caster and change the outcome
	check(DmAbilities.rune(caster.p, "marrow_spear") == "" and g.rune_sockets(1).is_empty(), "H: no sockets, no runes")
	var inv: DmInventory = g.ui_host.inventory
	inv.slots.append({"slot_index": DmRunes.rune_slot_index("marrow_spear"), "item_id": "rune_impale", "quantity": 1, "equipped": 0})
	inv.slots.append({"slot_index": DmRunes.rune_slot_index("black_litany"), "item_id": "rune_hollow_choir", "quantity": 1, "equipped": 0})
	inv.changed.emit(inv.slots)
	check(DmAbilities.rune(caster.p, "marrow_spear") == "rune_impale" and DmAbilities.rune(caster.p, "black_litany") == "rune_hollow_choir", "H: the caster received the socketed runes (%s)" % [caster.p.get("runes")])
	check(g.rite_build(1)["runes"] == caster.p["runes"], "H: rite_build carries them (a rebuild keeps them)")
	# Impaling: the spear takes only the FIRST enemy in its line and roots it
	reset_hero(Vector3(0, 0, -18))
	var e1 := foe(Vector3(5, 0, -18))
	var e2 := foe(Vector3(9, 0, -18))
	caster.request_cast("marrow_spear", Vector3(9, 0, -18), eid(e2))
	await ticks(45)
	var s1 := DmStatusSet.of(e1)
	var s2 := DmStatusSet.of(e2)
	check(s1 != null and s1.has(&"root") and (s2 == null or not s2.has(&"root")) and e1.hp < e1.max_hp and e2.hp >= e2.max_hp, "H: Impaling marrow spear hits and roots only the first enemy in line (hp %.0f/%.0f, %.0f/%.0f)" % [e1.hp, e1.max_hp, e2.hp, e2.max_hp])
	caster.set_runes({})
	reset_hero(Vector3(0, 0, -18))
	e1.hp = e1.max_hp
	e2.hp = e2.max_hp
	DmStatusSet.of(e1).clear()
	caster.request_cast("marrow_spear", Vector3(9, 0, -18), eid(e2))
	await ticks(45)
	check(not DmStatusSet.of(e1).has(&"root") and e2.hp < e2.max_hp, "H: without the rune the same spear pierces the line and roots nobody")
	caster.set_runes(g.rune_sockets(1))
	# Hollow Choir: the litany spares the legion
	reset_hero(Vector3(0, 0, -18))
	var th := hero.get_node("Thralls") as DmThrallHost
	for t in th.list():
		t.kill("crumbled")
	await ticks(2)
	var spec := {"kind": "warrior", "cap": 4.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0}
	th.raise_bonded(spec)
	th.raise_bonded(spec)
	await ticks(2)
	var n0 := th.count()
	caster.request_cast("black_litany", Vector3.ZERO)
	await ticks(10)
	check(n0 >= 1 and th.count() == n0, "H: Hollow Choir litany spares the thralls (%d -> %d)" % [n0, th.count()])
	caster.set_runes({})
	reset_hero(Vector3(0, 0, -18))
	caster.request_cast("black_litany", Vector3.ZERO)
	await ticks(10)
	check(th.count() == 0, "H: the same litany without the rune sacrifices them (%d left)" % th.count())
	caster.set_runes(g.rune_sockets(1))

	# ---- I: numbers
	reset_hero(Vector3(0, 0, -18))
	for e in [e1, e2, far, near, close]:
		e.queue_free()
	await ticks(3)
	var lat: Array = []
	var tgt := foe(Vector3(0, 0, -34))
	for i in 40:
		reset_hero(Vector3(0, 0, -18))
		var t0 := Time.get_ticks_usec()
		g.input.attack(eid(tgt), false)
		lat.append(float(Time.get_ticks_usec() - t0))
	lat.sort()
	var klat: Array = []
	var near2 := foe(Vector3(0, 0, -24))
	g.input._hover_id = eid(near2)
	for i in 40:
		reset_hero(Vector3(0, 0, -18))
		var t1 := Time.get_ticks_usec()
		g.input.press_hotbar(0)
		klat.append(float(Time.get_ticks_usec() - t1))
	klat.sort()
	g.input.combat.clear()
	print("perf: input -> intent, click-to-chase median %.0f us (p95 %.0f), key-cast median %.0f us (p95 %.0f)" % [lat[20], lat[37], klat[20], klat[37]])
	check(float(lat[20]) < 2000.0 and float(klat[20]) < 2000.0, "I: input -> intent: click-to-chase median %.0f us (p95 %.0f), key-cast median %.0f us (p95 %.0f), same frame" % [lat[20], lat[37], klat[20], klat[37]])
	# per-frame cost of the combat tick: idle (the normal case) and with a chase running
	var tk0 := Time.get_ticks_usec()
	for i in 20000:
		combat.tick(float(i))
	var idle_us := float(Time.get_ticks_usec() - tk0) / 20000.0
	check(idle_us < 2.0, "I: combat.tick idle costs %.3f us per frame" % idle_us)
	reset_hero(Vector3(0, 0, -18))
	g.input.attack(eid(tgt), false)
	var fc := DmFrameCost.attach(root)
	await ticks(5)
	fc.reset()
	await ticks(120)
	var med_on := fc.median_ms()
	var worst_on := fc.worst_ms()
	var steps_on: int = combat.stats["ticks"]
	g.input.combat.clear()
	g.session.request_move_dir(Vector3.ZERO)
	var tk1 := Time.get_ticks_usec()
	for i in 2000:
		combat.target_id = eid(tgt)
		combat.tick(float(i) * 20.0)
	var active_us := float(Time.get_ticks_usec() - tk1) / 2000.0
	combat.clear()
	fc.reset()
	await ticks(120)
	var med_off := fc.median_ms()
	fc.queue_free()
	print("perf: combat.tick idle %.3f us, with a target %.2f us; frame median chasing+casting %.2f ms (worst %.1f) vs idle %.2f ms; %d chase ticks" % [idle_us, active_us, med_on, worst_on, med_off, steps_on])
	check(active_us < 80.0 and med_on < med_off + 3.0, "I: a live chase / repeat adds %.2f ms to the frame median (idle %.2f), tick %.1f us" % [med_on - med_off, med_off, active_us])

	g.queue_free()
	await ticks(3)
	await _client_gestures()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## F (online): the owner's cast over RPC makes ONE gesture on the host and ONE on the client.
func _client_gestures() -> void:
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	var hg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	var cg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(PORT, 4) == OK, "F2: ENet server on a free port")
	await hg.start(character, api, {"peer": sp, "dressing": false, "waves": false, "hud": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", PORT)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "hud": false, "waves": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "F2: client joined")
	await ticks(60)   # the host attaches a joiner's caster after 0.8 s
	var cb := cg.local_body()
	var cc := cb.get_node("Rites") as DmRiteCaster
	var hc := hg.body_of(cb.owner_peer).get_node("Rites") as DmRiteCaster   # the same body on the host
	check(await until(func() -> bool: return hc.p.size() > 0 and cc != null, 5.0), "F2: both casters up")
	hc.p["stats"]["level"] = 60.0
	var h0 := hc.gestures_played
	var c0 := cc.gestures_played
	cc.request_cast("miasma", Vector3(0, 0, -20))
	check(await until(func() -> bool: return hc.gestures_played == h0 + 1 and cc.gestures_played == c0 + 1, 5.0), "F2: one cast = one gesture on the host (%d) and one on the client (%d)" % [hc.gestures_played - h0, cc.gestures_played - c0])
	await ticks(30)
	check(hc.gestures_played == h0 + 1 and cc.gestures_played == c0 + 1, "F2: and not more later")
	hg.queue_free()
	cg.queue_free()
	await ticks(5)
