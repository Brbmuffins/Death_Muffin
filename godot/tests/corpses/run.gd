extends SceneTree
## DmCorpseField tests (godot/next/corpses). godot --headless --path godot --script res://tests/corpses/run.gd
## A: kinds. B: lifetimes / caps / expiry vs the sim constants. C: toxic rupture. D: pick / consume. E: replication over in-process ENet
## (random high port, 127.0.0.1). F: perf.

var passed := 0
var failed := 0


func ok(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	await _a_kinds()
	_b_lifetimes()
	await _c_toxic()
	_d_pick_consume()
	_g_vfx()
	await _e_replication()
	await _f_perf()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func wait_for(cond: Callable, timeout := 8.0) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < timeout * 1000.0:
		if cond.call():
			return true
		await create_timer(0.05).timeout
	return cond.call()


## A field under a fresh Node3D arena (records only unless `vis`).
func _field(vis := false) -> Array:
	var arena := Node3D.new()
	root.add_child(arena)
	var f := DmCorpseField.new()
	f.name = "Corpses"
	f.visuals = vis
	f.auto_step = false
	f.vfx = RecVfx.new()   # recording stand-in: no real decals in the suite
	arena.add_child(f)
	return [arena, f]


func _enemy(arena: Node, scene: String, pos := Vector3.ZERO, vis := false) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/%s.tscn" % scene).instantiate()
	e.with_visual = vis
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	e.position = pos
	arena.add_child(e)
	return e


func _add(f: DmCorpseField, x: float, z: float, kind := "normal", enemy := "robber", area := "graves") -> DmSimCorpse:
	return f.add_corpse(x, z, kind, enemy, false, 0.0, 1.0, area)


# ---- A ------------------------------------------------------------------------------------------------------------------------------------
func _a_kinds() -> void:
	var af := _field()
	var arena: Node3D = af[0]
	var f: DmCorpseField = af[1]
	var want := {"robber": "normal", "hound": "swift", "penitent": "resonant", "sac": "toxic", "censer": "normal", "moth": "swift", "ghoul": "normal",
		"bat": "none", "risen": "none", "rat": "none"}
	for k in want:
		var e := _enemy(arena, k, Vector3(randf() * 50.0, 0, randf() * 50.0))
		f.track(e, "graves")
		var before := f.count()
		e.take_damage(1e9, null)
		if want[k] == "none":
			ok(f.count() == before, "A: %s leaves no corpse" % k)
		else:
			ok(f.count() == before + 1, "A: %s leaves a corpse" % k)
			var c: DmSimCorpse = f.corpses.values().back()
			ok(c.kind == want[k] and c.enemy == k and c.area == "graves", "A: %s corpse kind %s (got %s)" % [k, want[k], c.kind])
			ok(is_equal_approx(c.scale, e.scale.x) and is_equal_approx(c.x, e.global_position.x), "A: %s corpse carries scale and position" % k)
	# elite flag + deathCorpses (golem / drowned_sexton: extra "risen" corpses on a 1.6 m ring)
	var e2 := _enemy(arena, "robber", Vector3(100, 0, 100))
	e2.elite = true
	e2.def = e2.def.duplicate()
	e2.def["deathCorpses"] = 3
	f.track(e2)
	var n0 := f.count()
	e2.take_damage(1e9, null)
	var extra := f.corpses_in_radius(Vector3(100, 0, 100), 2.0)
	ok(f.count() == n0 + 3 and extra.size() == 3, "A: deathCorpses 3 -> 3 corpses")
	ok(extra.any(func(c): return c.elite) and extra.filter(func(c): return c.enemy == "risen").size() == 2, "A: elite flag kept, extras are risen")
	ok(extra.filter(func(c): return c.enemy == "risen").all(func(c): return absf(Vector2(c.x - 100, c.z - 100).length() - 1.6) < 1e-3), "A: extras lie 1.6 m out")
	arena.queue_free()


# ---- B ------------------------------------------------------------------------------------------------------------------------------------
func _b_lifetimes() -> void:
	var af := _field()
	var f: DmCorpseField = af[1]
	ok(DmSimConsts.CORPSE_LIFETIME == 26.0 and DmSimConsts.MAX_CORPSES == 45 and DmSimConsts.TOXIC_RUPTURE == 5.0, "B: sim constants are 26 / 45 / 5")
	var c := _add(f, 0, 0)
	ok(is_equal_approx(c.expiresAt - c.bornAt, DmSimConsts.CORPSE_LIFETIME), "B: lifetime = CORPSE_LIFETIME")
	f.step(25.9)
	ok(f.get_corpse(c.id) != null, "B: alive at 25.9 s")
	f.step(0.2)
	ok(f.get_corpse(c.id) == null, "B: expired after 26 s")
	f.life_mult = 1.5   # lingering_dead
	var c2 := _add(f, 0, 0)
	ok(is_equal_approx(c2.expiresAt - c2.bornAt, 39.0), "B: lingering_dead x1.5 -> 39 s")
	f.life_mult = 0.75  # thin_graves
	var c3 := _add(f, 1, 0)
	ok(is_equal_approx(c3.expiresAt - c3.bornAt, 19.5), "B: thin_graves x0.75 -> 19.5 s")
	f.life_mult = 1.0
	# echo
	var e := _enemy(af[0], "robber", Vector3(5, 0, 5))
	f.echo_enabled = true
	f.track(e)
	var t0 := f.time
	e.take_damage(1e9, null)
	var echo: DmSimCorpse = null
	for k: DmSimCorpse in f.corpses_in_radius(Vector3(5, 0, 5), 2.0, Callable(), "", true):
		if k.echoOwner != "":
			echo = k
	ok(echo != null and echo.echoOwner == "*" and is_equal_approx(echo.scale, 0.65) and is_equal_approx(echo.expiresAt - t0, 20.0), "B: Veil echo corpse: owner *, scale 0.65, 20 s")
	ok(f.corpses_in_radius(Vector3(5, 0, 5), 2.0).size() == 1, "B: echoes are hidden from normal queries")
	f.echo_enabled = false
	# cap: 45, oldest goes first
	var g := _field()
	var h: DmCorpseField = g[1]
	var gone: Array = []
	h.corpse_gone.connect(func(c, r): gone.append([c.id, r]))
	var first := _add(h, 0, 0)
	for i in 49:
		h.step(0.1)
		_add(h, i, 0)
	ok(h.count() == DmSimConsts.MAX_CORPSES, "B: capped at 45 (got %d)" % h.count())
	ok(gone.size() == 5 and gone[0] == [first.id, "expired"], "B: the 5 oldest were evicted, oldest first, reason expired")
	# expiry is event-driven: nothing due -> step does not touch the corpses
	ok(h._next_due < INF and h._next_due >= h.time, "B: next-due gate armed")
	af[0].queue_free()
	g[0].queue_free()


# ---- C ------------------------------------------------------------------------------------------------------------------------------------
class Tgt:
	extends Node3D
	var hit := 0.0
	var n := 0
	func dm_take_enemy_hit(d: float, _f: Node) -> void:
		hit += d
		n += 1


func _c_toxic() -> void:
	var af := _field()
	var arena: Node3D = af[0]
	var f: DmCorpseField = af[1]
	f.area_level = func(_a): return 5
	var e := _enemy(arena, "sac", Vector3(10, 0, 10))
	f.track(e, "graves")
	e.take_damage(1e9, null)
	var c: DmSimCorpse = f.corpses.values()[0]
	ok(c.kind == "toxic" and is_equal_approx(c.ruptureAt - c.bornAt, 5.0), "C: sac corpse is toxic and ruptures after 5 s")
	var zones: Array = []
	var gone: Array = []
	f.ruptured.connect(func(_c, z): zones.append(z))
	f.corpse_gone.connect(func(_c, r): gone.append(r))
	f.step(4.9)
	ok(f.count() == 1 and zones.is_empty(), "C: intact at 4.9 s")
	f.step(0.2)
	ok(f.count() == 0 and gone == ["burst"] and zones.size() == 1, "C: ruptured at 5 s (reason burst)")
	var z: DmHostileZone = zones[0]
	ok(is_equal_approx(z.radius, 2.4 * c.scale) and is_equal_approx(z.lifetime, 5.0) and is_equal_approx(z.tick_s, 0.4), "C: zone r 2.4 x scale, 5 s, pulse 0.4 s")
	ok(is_equal_approx(z.dps * z.tick_s, 6.0 * DmEnemyStats.damage_scale(5)), "C: pulse damage 6 x damage_scale(level)")
	ok(is_equal_approx(z.position.x, 10.0) and z.is_in_group(&"dm_hostile_zone"), "C: zone sits where the corpse lay")
	# the zone really hurts a target standing in it (real physics frames)
	var t := Tgt.new()
	t.add_to_group(DmEnemy.TARGET_GROUP)
	t.position = Vector3(10.5, 0, 10)
	arena.add_child(t)
	await wait_for(func(): return t.n >= 2, 3.0)
	ok(t.n >= 2 and is_equal_approx(t.hit / t.n, 6.0 * DmEnemyStats.damage_scale(5)), "C: zone pulses hurt a target inside (%d pulses, %.2f each)" % [t.n, t.hit / maxf(1, t.n)])
	arena.queue_free()


# ---- D ------------------------------------------------------------------------------------------------------------------------------------
func _d_pick_consume() -> void:
	var af := _field()
	var f: DmCorpseField = af[1]
	var a := _add(f, 3, 0)
	var b := _add(f, 5, 0)
	var far := _add(f, 30, 0)
	var other := _add(f, 4, 0, "normal", "robber", "fen")
	var from := Vector3(0, 0, 0)
	ok(f.pick_corpse(Vector3(5.2, 0, 0), 2.5, 11.0, from, "graves") == b, "D: nearest to the aim wins")
	ok(f.pick_corpse(Vector3(30, 0, 0), 2.5, 11.0, from, "graves") == a, "D: aim target out of cast range -> fallback nearest to caster")
	ok(f.pick_corpse(Vector3(30, 0, 40), 2.5, 11.0, from, "graves") == a, "D: nothing under the cursor -> nearest to the caster")
	ok(f.pick_corpse(Vector3(4, 0, 0), 0.5, 11.0, from, "graves") != other, "D: other areas are ignored")
	ok(f.pick_corpse(Vector3(0, 0, 25), 2.0, 11.0, Vector3(0, 0, 25), "graves") == null, "D: nothing within 7 m -> null")
	var r := f.corpses_in_radius(from, 6.0, Callable(), "graves")
	ok(r == [a, b], "D: radius query nearest first")
	ok(f.corpses_in_radius(from, 6.0, func(c): return c.x > 4.0, "graves") == [b], "D: filter applied")
	ok(f.corpses_in_radius(from, 100.0).size() == 4 and not f.corpses_in_radius(from, 40.0).has(null), "D: all areas when area is empty")
	# consume: atomic
	var cons: Array = []
	var gone: Array = []
	f.corpse_consumed.connect(func(c, p, why): cons.append([c.id, p, why]))
	f.corpse_gone.connect(func(c, why): gone.append([c.id, why]))
	var r1: bool = f.consume(b.id, 7)
	var r2: bool = f.consume(b.id, 8)
	ok(r1 and not r2, "D: two casters, one corpse: first wins, second gets false")
	ok(cons == [[b.id, 7, "consumed"]] and gone == [[b.id, "consumed"]], "D: one corpse_consumed / corpse_gone")
	ok(f.get_corpse(b.id) == null and f.pick_corpse(Vector3(5, 0, 0), 2.5, 11.0, from, "graves") == a, "D: a consumed corpse can no longer be picked")
	ok(not f.consume(9999, 1), "D: unknown id is refused")
	ok(f.consume(far.id, 1, "litany") and gone.back() == [far.id, "litany"], "D: reason passes through")
	# many consumers in a loop: exactly one success per corpse
	var wins := 0
	for k in 10:
		if f.consume(a.id, k):
			wins += 1
	ok(wins == 1, "D: 10 consumers, 1 winner")
	af[0].queue_free()


# ---- E ------------------------------------------------------------------------------------------------------------------------------------
func _branch(nm: String, vis: bool) -> Array:
	var n := Node.new()
	n.name = nm
	root.add_child(n)
	var mp := SceneMultiplayer.new()
	set_multiplayer(mp, NodePath("/root/" + nm))
	var f := DmCorpseField.new()
	f.name = "Corpses"
	f.visuals = vis
	f.auto_step = false
	f.vfx = RecVfx.new()
	n.add_child(f)
	return [n, f, mp]


func _e_replication() -> void:
	var port := 40000 + randi() % 9999
	var h := _branch("H", false)
	var c1 := _branch("C1", true)
	var hp := ENetMultiplayerPeer.new()
	ok(hp.create_server(port, 4, 0) == OK, "E: server created on %d" % port)
	h[2].multiplayer_peer = hp
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", port)
	c1[2].multiplayer_peer = cp
	var hf: DmCorpseField = h[1]
	var cf: DmCorpseField = c1[1]
	ok(await wait_for(func(): return cp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED), "E: client connected")
	var added: Array = []
	var cgone: Array = []
	cf.corpse_added.connect(func(c): added.append(c.id))
	cf.corpse_gone.connect(func(c, why): cgone.append([c.id, why]))
	ok(hf.is_multiplayer_authority() and not cf.is_multiplayer_authority(), "E: host authoritative, client not")
	var a := _add(hf, 2, 3, "normal", "robber")
	var t := _add(hf, 4, 4, "toxic", "sac")
	ok(await wait_for(func(): return cf.count() == 2), "E: spawn events reach the client")
	var ca := cf.get_corpse(a.id)
	ok(ca != null and ca.kind == "normal" and is_equal_approx(ca.x, 2.0) and is_equal_approx(ca.z, 3.0) and cf.get_corpse(t.id).kind == "toxic", "E: client record matches")
	ok(cf.view_count() == 2 and cf.get_child_count() == 2, "E: client built visuals (body + marks) from the record")
	ok(not cf.consume(a.id, 5) and cf.count() == 2, "E: a client cannot consume")
	# late joiner gets a snapshot
	var c2 := _branch("C2", false)
	var cp2 := ENetMultiplayerPeer.new()
	cp2.create_client("127.0.0.1", port)
	c2[2].multiplayer_peer = cp2
	ok(await wait_for(func(): return c2[1].count() == 2), "E: late joiner receives the live corpses")
	ok(hf.consume(a.id, 1, "consumed"), "E: host consumes")
	ok(await wait_for(func(): return cf.count() == 1 and c2[1].count() == 1 and cgone == [[a.id, "consumed"]]), "E: gone event reaches both clients with its reason")
	ok(cf.fading_count() == 1, "E: client body is fading")
	ok(await wait_for(func(): return cf.fading_count() == 0, 3.0), "E: client body freed after the fade")
	# rupture replicates as burst; the zone exists on the host only
	var zones: Array = []
	hf.ruptured.connect(func(_c, z): zones.append(z))
	hf.step(6.0)
	ok(await wait_for(func(): return cf.count() == 0 and cgone.back() == [t.id, "burst"]), "E: rupture reaches the client as burst")
	ok(zones.size() == 1 and cf.get_parent().get_tree().get_nodes_in_group(&"dm_hostile_zone").size() == 1, "E: one zone (host side only; clients draw the aura)")
	ok(hf.get_parent().get_node_or_null("Corpses") == hf and hf.consume(a.id, 1) == false, "E: late consume of a replicated-gone corpse is false")
	# expiry on the host replicates
	var x := _add(hf, 9, 9)
	await wait_for(func(): return cf.count() == 1)
	hf.step(27.0)
	ok(await wait_for(func(): return cf.count() == 0 and cgone.back() == [x.id, "expired"]), "E: expiry replicates")
	for z in zones:
		if is_instance_valid(z):
			z.queue_free()
	hp.close()
	cp.close()
	cp2.close()
	for b in [h, c1, c2]:
		b[0].queue_free()
	await process_frame


# ---- F ------------------------------------------------------------------------------------------------------------------------------------
func _us(c: Callable, n: int) -> float:
	var t := Time.get_ticks_usec()
	for i in n:
		c.call()
	return float(Time.get_ticks_usec() - t) / float(n)


func _f_perf() -> void:
	var af := _field()
	var f: DmCorpseField = af[1]
	var add_us := _us(func(): f.add_corpse(randf() * 40, randf() * 40, "normal", "robber", false, 0.0, 1.0, "graves"), 40)
	for i in 20:
		f.add_corpse(randf() * 40, randf() * 40, "normal", "robber", false, 0.0, 1.0, "graves")
	ok(f.count() == 45, "F: 45 corpses live")
	var step_idle := _us(func(): f.step(0.0001), 20000)
	# naive per-frame scan of 45 (what the sim does every tick) for the before/after number
	var naive := _us(func():
		for c: DmSimCorpse in f.corpses.values():
			if f.time >= c.ruptureAt or f.time >= c.expiresAt:
				pass, 5000)
	var pick_us := _us(func(): f.pick_corpse(Vector3(20, 0, 20), 2.5, 11.0, Vector3(18, 0, 18), "graves"), 5000)
	var rad_us := _us(func(): f.corpses_in_radius(Vector3(20, 0, 20), 8.0), 5000)
	var cons_us := _us(func(): f.consume(f.corpses.keys()[0], 1), 20)
	print("F: add %.1f us, idle step %.3f us/frame (naive 45-corpse scan %.2f us), pick %.1f us, radius query %.1f us, consume %.1f us" % [add_us, step_idle, naive, pick_us, rad_us, cons_us])
	ok(step_idle < 2.0 and add_us < 200.0 and pick_us < 100.0 and rad_us < 150.0 and cons_us < 200.0, "F: record ops within budget")
	ok(step_idle < naive, "F: due-gated step is cheaper than a per-frame scan")
	af[0].queue_free()
	# 60 corpses with visuals (laid-down bodies): spawn cost, then expiry of all of them, then pooled marks reused
	var bf := _field(true)
	bf[1].vfx = null
	var vf: DmCorpseField = bf[1]
	var t0 := Time.get_ticks_usec()
	for i in 45:
		vf.add_corpse(float(i % 9) * 3.0, float(i / 9) * 3.0, ["normal", "resonant", "toxic"][i % 3], "robber", false, 0.0, 1.0, "graves")
	var vis_us := float(Time.get_ticks_usec() - t0) / 45.0
	var nodes := vf.get_child_count()
	vf.step(30.0)
	await process_frame
	await process_frame
	await vf.get_tree().create_timer(1.2).timeout
	print("F: 45 corpses with laid-down bodies %.0f us each (adopted dying bodies cost none)" % vis_us)
	ok(vf.view_count() == 0 and vf.fading_count() == 0 and nodes == 45 and vf.get_child_count() == 0, "F: every body freed after expiry + fade, _process idle")
	bf[0].queue_free()


# ---- G: effects go through the existing Vfx decals ---------------------------------------------------------------------------------------
class RecVfx:
	extends Node
	var decals: Array = []
	var emits: Array = []
	var killed := 0
	func decal(o: Dictionary) -> Variant:
		var h := RecH.new()
		h.v = self
		decals.append(o)
		return h
	func emit(o: Dictionary) -> void:
		emits.append(o)

class RecH:
	extends RefCounted
	var v
	var alive := true
	func kill() -> void:
		if alive:
			alive = false
			v.killed += 1


func _g_vfx() -> void:
	var af := _field(true)
	var f: DmCorpseField = af[1]
	var rv := RecVfx.new()
	f.vfx = rv
	for i in 12:
		f.add_corpse(float(i), 0, "normal", "robber", false, 0.0, 1.0, "graves")
	ok(rv.decals.size() == DmCorpseField.MARKS_MAX and rv.decals[0]["tex"] == "ring" and rv.decals[0]["duration"] == 26 and rv.decals[0]["color"] == 0xd8cdf2, "G: pale rings capped at 8, the current game's look")
	var r := f.add_corpse(0, 9, "resonant", "penitent", false, 0.0, 1.05, "graves")
	var t := f.add_corpse(0, 12, "toxic", "sac", false, 0.0, 1.2, "graves")
	ok(rv.decals.any(func(d): return d["color"] == 0xc6a4ff and d["pulse"] == 3.0), "G: resonant tell (violet ring) shows past the cap")
	ok(rv.decals.any(func(d): return d["tex"] == "disc" and d["color"] == 0x6f8f3a and is_equal_approx(d["r"], 2.4 * 1.2)), "G: toxic aura disc, r 2.4 x scale")
	var k0 := rv.killed
	f.consume(r.id, 1, "consumed")
	ok(rv.killed == k0 + 1 and rv.emits.size() == 1 and rv.emits[0]["count"] == 22, "G: consumed kills the ring and plays the spirit wisps")
	f.consume(t.id, 1, "litany")
	ok(rv.emits.size() == 2 and rv.emits[1]["count"] == 18, "G: litany wisps")
	var first_id: int = f.corpses.keys()[0]
	f.consume(first_id, 1)
	ok(rv.decals.size() == 10, "G: a freed ring slot does not spawn extra decals by itself")
	af[0].queue_free()
