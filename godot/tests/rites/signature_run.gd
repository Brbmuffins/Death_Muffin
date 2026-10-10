extends SceneTree
## The four discipline signatures (godot/next/rites: ossuary_wall, command_rend, dirge, plague_bloom) + the discipline mods + the R hotbar slot.
## godot --headless --path godot --script res://tests/rites/signature_run.gd
## A: registry, hotbar R slot, validation, numbers (solo, host stepped by hand). B: the wall blocks a chasing enemy (real physics) and is removed.
## C: rend commands thralls. D: dirge. E: plague bloom + the Rotweaver passive. F: discipline mods on the other rites, one per discipline.
## G: in-process ENet, host + 2 clients (fx once per peer, the wall's ribs on every peer, the collider on the host only). H: the slice (DmNextGame) reads the
## character's discipline and casts its signature from R. I: perf.

var PORT := DmTestPorts.free_port()
var passed := 0
var failed := 0
const DT := 0.02
const OSSUARY := 1
const GRAVECALLER := 2
const MOURNER := 3
const ROTWEAVER := 4


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
	await _part_a()
	await _part_b()
	await _part_c()
	await _part_d()
	await _part_e()
	await _part_f()
	await _part_g()
	await _part_h()
	await _part_i()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func wait_for(cond: Callable, timeout := 8.0) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < timeout * 1000.0:
		if cond.call():
			return true
		await create_timer(0.05).timeout
	return cond.call()


func _half() -> float:
	return 0.5


# ---- doubles -----------------------------------------------------------------------------------------------------------------------------

## DmRiteWorld + the corpse field's owner. `classes` maps a peer to the character class the caster is built from (default Gravecaller).
class World:
	extends Node3D
	var enemies: Array = []
	var corpses: DmCorpseField
	var events: Array = []
	var classes := {}
	var _n := 0

	func add(e: DmEnemy) -> int:
		_n += 1
		e.set_meta("rid", _n)
		enemies.append(e)
		return _n

	func enemies_in_radius(pos: Vector3, r: float) -> Array:
		return enemies.filter(func(e): return is_instance_valid(e) and Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length() <= r)

	func enemy_by_id(id: int) -> Node:
		for e in enemies:
			if is_instance_valid(e) and int(e.get_meta("rid")) == id:
				return e
		return null

	func enemy_id(e: Node) -> int:
		return int(e.get_meta("rid"))

	func area_of(_peer: int) -> String:
		return ""

	func rite_build(peer: int) -> Dictionary:
		var b := DmCharacterBuild.build({"class_index": classes.get(peer, 2), "level": 20}, [], {})
		b["runes"] = {}
		return b

	func on_rite_event(ev: Dictionary) -> void:
		events.append(ev)


class RecMotifs:
	extends RefCounted
	var n := 0
	func bone_splinters(_x, _y, _z, _o) -> void: n += 1
	func rot_spores(_x, _z, _c, _o) -> void: n += 1
	func grave_dirt(_x, _z, _o) -> void: n += 1
	func soul_motes(_x, _z, _c, _o) -> void: n += 1
	func skull_wisps(_x, _z, _c, _o) -> void: n += 1
	func skull_ring(_x, _z, _r, _c, _o) -> void: n += 1
	func spectral_hands(_x, _z, _o) -> void: n += 1
	func spirit_wisps(_x, _z, _c, _o) -> void: n += 1
	func mist_whisper(_x, _z, _c, _o) -> void: n += 1
	func cracked_ground(_x, _z, _r, _c, _o) -> void: n += 1
	func slash_mark(_x, _z, _c, _o) -> void: n += 1


class RecFx:
	extends RefCounted
	var c := {}
	var motifs := RecMotifs.new()
	func _b(k: String) -> void: c[k] = int(c.get(k, 0)) + 1
	func decal(_o) -> Variant: _b("decal"); return null
	func emit(_o) -> void: _b("emit")
	func emit_smoke(_o) -> void: _b("smoke")
	func flash(_o) -> void: _b("flash")
	func play(_id, _p, _o) -> Variant: _b("bb"); return null
	func projectile(_o) -> Variant: _b("projectile"); return null
	func beam(_a, _b2, _c, _w, _d) -> Variant: _b("beam"); return null
	func light_flash(_p, _c, _i, _l) -> void: _b("light")
	func bone_orbit(_o) -> Variant: _b("orbit"); return null


class RecAudio:
	extends RefCounted
	var sfx: Array = []
	func play_sfx(id, _p, _i) -> void: sfx.append(id)
	func loop_sfx(id, _ms, _p, _f) -> void: sfx.append("loop:" + String(id))


class FieldVfx:
	extends Node
	func decal(_o: Dictionary) -> Variant: return null
	func emit(_o: Dictionary) -> void: pass


## A chase target (what DmEnemy.find_target looks for): a Node3D in group dm_target.
class Bait:
	extends Node3D
	var hits := 0
	func dm_alive() -> bool: return true
	func dm_take_enemy_hit(_d: float, _f: Node) -> void: hits += 1


func _robber(w: World, parent: Node, pos: Vector3, hp := 1.0e7) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	e.position = pos
	parent.add_child(e)
	e.hp = hp
	e.max_hp = hp
	w.add(e)
	return e


func _field(w: World) -> DmCorpseField:
	var f := DmCorpseField.new()
	f.name = "Corpses"
	f.visuals = false
	f.auto_step = false
	f.vfx = FieldVfx.new()
	f.add_child(f.vfx)
	w.add_child(f)
	w.corpses = f
	return f


func _stub(c: DmRiteCaster) -> Array:
	var f := RecFx.new()
	var a := RecAudio.new()
	c.fx.fx = f
	c.fx.audio = a
	return [f, a]


func _step(c: DmRiteCaster, secs: float) -> void:
	var f: DmCorpseField = c.world.corpses
	for i in int(round(secs / DT)):
		f.step(DT)
		c.step(DT)
		for e in c.world.enemies:
			var ss := DmStatusSet.of(e) if is_instance_valid(e) else null
			if ss != null:
				ss.advance(DT)


func _corpse(f: DmCorpseField, pos: Vector3) -> DmSimCorpse:
	return f.add_corpse(pos.x, pos.z, "normal", "robber", false, 0.0, 1.0, "")


## One solo session (a body at the origin, a thrall host, a caster at level 20 built from character class `cls`).
func _solo(nm: String, cls := GRAVECALLER) -> Dictionary:
	var h := Node.new()
	h.name = nm
	root.add_child(h)
	var sess := DmSession.new()
	sess.name = "Session"
	h.add_child(sess)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	sess.character_name = "Solo"
	sess.discipline_id = String(DmCharacterBuild.discipline_for(float(cls))["id"])
	var w := World.new()
	w.name = "W"
	w.classes[1] = cls
	h.add_child(w)
	var f := _field(w)
	sess.host(OfflineMultiplayerPeer.new())
	var body := sess.get_body(1)
	body.position = Vector3.ZERO
	DmThrallHost.attach(body, w)
	var c := DmRiteCaster.attach(body, w)
	c.auto_step = false
	c.random = Callable(self, "_half")
	var st := _stub(c)
	await process_frame
	return {"h": h, "sess": sess, "w": w, "f": f, "body": body, "c": c, "fx": st[0], "au": st[1], "thr": body.get_node("Thralls")}


func _teardown(s: Dictionary) -> void:
	var legion: Array = (s["thr"] as DmThrallHost).list().duplicate()
	for t in legion:
		t.kill("crumbled")   # out of the host's list first, then out of the tree (a thrall must not tick on a session that left)
		t.queue_free()
	if not legion.is_empty():
		await process_frame
	for e in (s["w"] as World).enemies:
		if is_instance_valid(e):
			e.free()
	await (s["sess"] as DmSession).leave()
	(s["h"] as Node).queue_free()


func _rejects(c: DmRiteCaster) -> Array:
	var rej: Array = []
	c.cast_rejected.connect(func(r, why): rej.append([r, why]))
	return rej


func _ready_cast(c: DmRiteCaster) -> void:
	c.p["cooldowns"].clear()
	c.p["castUntil"] = 0.0
	c.p["rootedUntil"] = 0.0
	c.p["resource"]["value"] = c.p["resource"]["max"]


func _events(w: World, rite: String, t: String) -> Array:
	return w.events.filter(func(ev): return ev.get("rite") == rite and ev.get("t") == t)


# ---- Part A: registry, hotbar R slot, validation, numbers ----------------------------------------------------------------------------------

func _part_a() -> void:
	var sig: Dictionary = DmContent.kit("necromancer")["signatures"]
	var ids := {"ossuary": "ossuary_wall", "gravecaller": "command_rend", "mourner": "dirge", "rotweaver": "plague_bloom"}
	for d in ids:
		ok(String(sig[d]) == ids[d] and DmRiteRegistry.has(ids[d]) and DmRiteRegistry.module(ids[d]).id == ids[d], "A: %s -> %s registered with its own module" % [d, ids[d]])
		ok(DmRiteHotbar.rite_for_slot(6, "necromancer", d) == ids[d], "A: hotbar slot 6 (R) = %s's signature" % d)
	ok(DmRiteHotbar.rite_for_slot(6) == "" and DmRiteHotbar.rite_for_slot(5) == "corpse_explosion", "A: slot 6 without a discipline is empty, slot 5 is unchanged (RMB)")
	DmNextInput.ensure_actions()
	ok(InputMap.has_action(&"dm_hotbar_6"), "A: R is bound to dm_hotbar_6")

	var s := await _solo("SA", OSSUARY)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var rej := _rejects(c)
	var max_e: float = c.p["stats"]["maxEssence"]
	# level gate
	c.p["stats"]["level"] = 5.0
	c.request_cast("ossuary_wall", Vector3(0, 0, -5))
	ok(rej.size() == 1 and rej[0][1] == "locked" and c.events_played == 0, "A: the signature is locked below level 10 (SIGNATURE_LEVEL)")
	c.p["stats"]["level"] = 20.0
	rej.clear()
	# validation: forged intents, non-finite aim, cooldown, essence
	c.request_cast("ossuary_wall", Vector3(INF, 0, 0), -1, 99)
	c.request_cast("ossuary_wall", Vector3(0, 0, -5), -1, 99)
	ok(c.rejected_intents == 2 and c.events_played == 0, "A: a forged owner / non-finite aim is refused by the host (rejected_intents 2)")
	c.p["resource"]["value"] = 10.0
	c.request_cast("ossuary_wall", Vector3(0, 0, -5))
	ok(rej.size() == 1 and rej[0][1] == "essence" and c.events_played == 0 and w.events.is_empty(), "A: not enough essence: refused (essence), nothing happens")
	c.p["resource"]["value"] = max_e
	rej.clear()
	# numbers: 30 essence, 16 s, 130 ms lock
	var ess0 := c.essence()
	c.request_cast("ossuary_wall", Vector3(0, 0, -5))
	var def := DmAbilities.def("ossuary_wall")
	ok(is_equal_approx(ess0 - c.essence(), 30.0) and is_equal_approx(float(def["essenceCost"]), 30.0), "A: the wall costs 30 essence (%.1f)" % (ess0 - c.essence()))
	ok(is_equal_approx(c.cooldown_left("ossuary_wall"), 16000.0), "A: the wall's cooldown is 16 s")
	rej.clear()
	c.request_cast("ossuary_wall", Vector3(0, 0, -5))
	ok(rej.size() == 1 and (rej[0][1] == "cooldown" or rej[0][1] == "busy"), "A: a second cast is refused while the first runs (%s)" % [rej[0][1] if rej.size() > 0 else "-"])
	var raise_ev: Dictionary = _events(w, "ossuary_wall", "raise")[0]
	var W: Dictionary = DmSimData.SIGNATURE["wall"]
	var wl := Vector2(raise_ev["x1"] - raise_ev["x0"], raise_ev["z1"] - raise_ev["z0"]).length()
	ok(is_equal_approx(wl, float(W["length"])) and is_equal_approx(float(raise_ev["ms"]), float(W["durationS"]) * 1000.0), "A: 7 m long, 6 s (SIGNATURE.wall: %.2f m, %.0f ms)" % [wl, raise_ev["ms"]])
	ok(is_equal_approx(raise_ev["z0"], -5.0) and is_equal_approx(raise_ev["z1"], -5.0) and is_equal_approx(raise_ev["x0"], -3.5) and is_equal_approx(raise_ev["x1"], 3.5), "A: centred on the aim, perpendicular to the cast line")
	# aim beyond the range is pulled back to 10 m
	_ready_cast(c)
	w.events.clear()
	c.request_cast("ossuary_wall", Vector3(0, 0, -30))
	var far: Dictionary = _events(w, "ossuary_wall", "raise")[0]
	ok(is_equal_approx(far["z0"], -float(def["range"])), "A: an aim past the range is pulled back to %.0f m (z %.2f)" % [def["range"], far["z0"]])
	await _teardown(s)

	# command_rend / dirge / bloom: numbers and refusals
	var d := await _solo("SD", MOURNER)
	var cd: DmRiteCaster = d["c"]
	_ready_cast(cd)
	var e0: float = cd.essence()
	cd.request_cast("dirge", Vector3(9, 0, 9))
	ok(is_equal_approx(e0 - cd.essence(), 35.0) and is_equal_approx(cd.cooldown_left("dirge"), 18000.0), "A: dirge costs 35 essence, 18 s cooldown")
	var dev: Dictionary = _events(d["w"], "dirge", "cast")[0]
	ok(is_equal_approx(dev["r"], 6.0) and is_equal_approx(dev["ms"], 4000.0) and is_equal_approx(dev["x"], 0.0) and is_equal_approx(dev["z"], 0.0), "A: dirge is a 6 m circle for 4 s around the caster (the aim is ignored)")
	await _teardown(d)
	var b := await _solo("SB", ROTWEAVER)
	var cb: DmRiteCaster = b["c"]
	_ready_cast(cb)
	var e1: float = cb.essence()
	cb.request_cast("plague_bloom", Vector3(0, 0, 30))
	ok(is_equal_approx(e1 - cb.essence(), 28.0) and is_equal_approx(cb.cooldown_left("plague_bloom"), 12000.0), "A: plague bloom costs 28 essence, 12 s cooldown")
	var bev: Dictionary = _events(b["w"], "plague_bloom", "cast")[0]
	ok(is_equal_approx(bev["z"], -0.0 + 14.0) and is_equal_approx(bev["r"], 2.4) and is_equal_approx(bev["ms"], 8000.0), "A: pulled back to 14 m; radius 2.4, 8 s (z %.2f)" % bev["z"])
	await _teardown(b)
	var g := await _solo("SG", GRAVECALLER)
	var cg: DmRiteCaster = g["c"]
	var rg := _rejects(cg)
	_ready_cast(cg)
	cg.request_cast("command_rend", Vector3(0, 0, 8))
	ok(rg.size() == 1 and rg[0][1] == "no_thralls" and cg.events_played == 0, "A: rend without a legion is refused (no_thralls)")
	ok(is_equal_approx(cg.essence(), float(cg.p["resource"]["max"])) and cg.cooldown_left("command_rend") == 0.0, "A: ... and costs nothing, no cooldown")
	ok(is_equal_approx(float(DmAbilities.def("command_rend")["essenceCost"]), 0.0) and is_equal_approx(float(DmAbilities.def("command_rend")["cooldownMs"]), 9000.0), "A: rend is free (hp is the price), 9 s cooldown")
	await _teardown(g)


# ---- Part B: the wall blocks a chasing enemy, and goes away -------------------------------------------------------------------------------

func _part_b() -> void:
	Engine.time_scale = 4.0
	var s := await _solo("SW", OSSUARY)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	c.auto_step = true
	_ready_cast(c)
	var bait := Bait.new()
	bait.add_to_group(DmEnemy.TARGET_GROUP)
	bait.position = Vector3(0, 0, 3)
	h.add_child(bait)
	var e := _robber(w, h, Vector3(0, 0, -10))
	e.aggro_range = 60.0
	e.leash_range = 100.0
	# a control: with no wall the enemy walks up to the bait
	await _until_physics(func() -> bool: return e.global_position.z > -4.0, 12.0)
	ok(e.global_position.z > -4.0, "B: control: with no wall the chaser closes in on its target (z %.2f)" % e.global_position.z)
	e.global_position = Vector3(0, 0, -10)
	e.stop()
	await _ticks(5)
	c.request_cast("ossuary_wall", Vector3(0, 0, -5))
	var wall := c.get_node_or_null("Wall1")
	ok(wall != null and wall.get_node_or_null("Block") is StaticBody3D and wall.get_node_or_null("Nav") is NavigationObstacle3D, "B: the host's wall is a StaticBody3D + a NavigationObstacle3D")
	var blk := wall.get_node("Block") as StaticBody3D
	var shape := (blk.get_child(0) as CollisionShape3D).shape as BoxShape3D
	ok(blk.collision_layer == DmEnemy.LAYER_PLAYER and (e.collision_mask & blk.collision_layer) != 0, "B: the collider is on a layer enemies collide with")
	ok(is_equal_approx(shape.size.x, 7.0) and is_equal_approx(shape.size.z, 0.8) and shape.size.y > 1.8, "B: collider 7 x 0.8 m, tall (%s)" % shape.size)
	var thr_mask := DmThrall.LAYER_THRALL
	ok((DmEnemy.LAYER_WORLD & blk.collision_layer) == 0 and thr_mask == 8, "B: not the world layer: the thralls (mask world only) walk through")
	ok(c.get_node_or_null("Ribs1") is MultiMeshInstance3D and (c.get_node("Ribs1") as MultiMeshInstance3D).multimesh.instance_count == 15, "B: the ribs are drawn (15 bones for 7 m)")
	var nav := wall.get_node("Nav") as NavigationObstacle3D
	ok(nav.vertices.size() == 4 and nav.avoidance_enabled and not nav.affect_navigation_mesh and nav.height > 1.8, "B: the obstacle has the footprint, avoids, and does not rebake the navmesh")
	# the enemy is held on its side for most of the 6 s
	var max_z := -99.0
	var t_end := Time.get_ticks_msec() + 800
	while Time.get_ticks_msec() < t_end:
		await physics_frame
		max_z = maxf(max_z, e.global_position.z)
	ok(max_z < -5.3, "B: the chaser is stopped at the wall (max z %.2f, wall at -5 +-0.4)" % max_z)
	await _until_physics(func() -> bool: return c.now_ms >= 5500.0, 10.0)
	ok(e.global_position.z < -5.3 and bait.hits == 0, "B: still held 5.5 s in (z %.2f)" % e.global_position.z)
	# it ends: nodes removed everywhere, a `gone` event once, the chaser comes through
	var gone_before := _events(w, "ossuary_wall", "gone").size()
	await _until_physics(func() -> bool: return c.get_node_or_null("Wall1") == null, 4.0)
	ok(c.get_node_or_null("Wall1") == null and c.get_node_or_null("Ribs1") == null, "B: collider, obstacle and ribs are removed when it expires")
	ok(_events(w, "ossuary_wall", "gone").size() == gone_before + 1 and (c.mem("ossuary_wall")["walls"] as Array).is_empty(), "B: one `gone` event, the host forgot the wall")
	await _until_physics(func() -> bool: return e.global_position.z > -4.0, 8.0)
	ok(e.global_position.z > -4.0, "B: with the wall gone the chaser comes through (z %.2f)" % e.global_position.z)
	Engine.time_scale = 1.0
	c.auto_step = false
	await _teardown(s)


func _ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _until_physics(cond: Callable, limit_s: float) -> void:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end and not cond.call():
		await physics_frame


# ---- Part C: Command: Rend ---------------------------------------------------------------------------------------------------------------

func _raise_legion(s: Dictionary, n: int, at := Vector3(0, 0, 3)) -> void:
	var c: DmRiteCaster = s["c"]
	for i in n:
		_corpse(s["f"], at + Vector3(i * 0.5, 0, 0))
		_ready_cast(c)
		c.request_cast("exhume", at + Vector3(i * 0.5, 0, 0))
		_step(c, 0.6)
	await wait_for(func(): return (s["thr"] as DmThrallHost).list().size() >= n and (s["thr"] as DmThrallHost).list().all(func(t): return t.state != DmThrall.S.RISING), 12.0)


func _part_c() -> void:
	Engine.time_scale = 4.0
	var s := await _solo("SR", GRAVECALLER)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var thr: DmThrallHost = s["thr"]
	var rej := _rejects(c)
	await _raise_legion(s, 3)
	ok(thr.list().size() == 3 and thr.list().all(func(t): return t.state != DmThrall.S.RISING), "C: three thralls standing")
	var R: Dictionary = DmSimData.SIGNATURE["rend"]
	var foe := _robber(w, h, Vector3(0, 0, 9))
	var far := _robber(w, h, Vector3(0, 0, 20))
	var hp0s: Array = thr.list().map(func(t): return t.hp)
	var maxs: Array = thr.list().map(func(t): return t.max_hp)
	var dmgs: Array = thr.list().map(func(t): return t.damage)
	_ready_cast(c)
	var ess0 := c.essence()
	var beams0: int = (s["fx"] as RecFx).c.get("beam", 0)
	(s["au"] as RecAudio).sfx.clear()
	c.request_cast("command_rend", Vector3(0, 0, 9))
	ok(rej.is_empty() and is_equal_approx(ess0, c.essence()), "C: rend is free (essence %.1f)" % c.essence())
	ok(is_equal_approx(c.cooldown_left("command_rend"), 9000.0), "C: 9 s cooldown")
	var ev: Dictionary = _events(w, "command_rend", "rend")[0]
	ok((ev["leaps"] as Array).size() == 3 and int(ev["hits"]) == 1, "C: three leaps, one enemy cleaved (%d, %d)" % [(ev["leaps"] as Array).size(), ev["hits"]])
	var ring_ok := true
	for l: Array in ev["leaps"]:
		ring_ok = ring_ok and absf(Vector2(float(l[2]), float(l[3]) - 9.0).length() - 1.2) < 0.01
	ok(ring_ok, "C: every thrall lands on the 1.2 m ring around the cursor")
	var want := 0.0
	for d in dmgs:
		want += float(d) * float(R["damageMult"])
	ok(is_equal_approx(1.0e7 - foe.hp, want) and far.hp == 1.0e7, "C: the cleave is each thrall's damage x 2.5 (%.2f vs %.2f); the far enemy is untouched" % [1.0e7 - foe.hp, want])
	var cost_ok := true
	for i in 3:
		var t: DmThrall = thr.list()[i]
		cost_ok = cost_ok and is_equal_approx(t.hp, maxf(1.0, hp0s[i] - maxs[i] * float(R["hpCost"])))
	ok(cost_ok, "C: each thrall paid 15 % of its health")
	var rf: RecFx = s["fx"]
	var au: RecAudio = s["au"]
	ok(au.sfx.count("sigRend") == 1 and int(rf.c.get("beam", 0)) - beams0 == 3, "C: fx once: sigRend sfx 1, a beam per thrall (%d)" % (int(rf.c.get("beam", 0)) - beams0))
	# aim past the range (13 m) is pulled back
	_ready_cast(c)
	w.events.clear()
	c.request_cast("command_rend", Vector3(0, 0, 40))
	var ev2: Dictionary = _events(w, "command_rend", "rend")[0]
	ok(is_equal_approx(float(ev2["z"]), 13.0), "C: the point is pulled back to 13 m (z %.2f)" % ev2["z"])
	# a thrall at 1 hp is not killed by the price
	for t in thr.list():
		t.hp = 2.0
	_ready_cast(c)
	c.request_cast("command_rend", Vector3(0, 0, 5))
	ok(thr.list().all(func(t): return t.hp >= 1.0), "C: the health price never kills a thrall (floor 1)")
	Engine.time_scale = 1.0
	await _teardown(s)


# ---- Part D: Dirge -----------------------------------------------------------------------------------------------------------------------

func _part_d() -> void:
	Engine.time_scale = 4.0
	var s := await _solo("SM", MOURNER)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var thr: DmThrallHost = s["thr"]
	await _raise_legion(s, 1, Vector3(1, 0, 2))
	var wr: DmThrall = thr.list()[0]
	Engine.time_scale = 1.0
	var inside := _robber(w, h, Vector3(5.5, 0, 0))      # inside 6 + radius
	var outside := _robber(w, h, Vector3(9, 0, 0))
	_ready_cast(c)
	c.p["hp"] = 1.0
	wr.hp = 10.0
	var sp := DmAbilities.sp(c.p, c.now_ms)
	var D: Dictionary = DmSimData.SIGNATURE["dirge"]
	c.request_cast("dirge", Vector3.ZERO)
	_step(c, 0.1)
	var heal := sp * float(DmAbilities.def("dirge")["power"])
	ok(is_equal_approx(float(c.p["hp"]), minf(float(c.p["stats"]["maxHp"]), 1.0 + heal)), "D: the first beat mends you spell power x 0.6 (%.2f -> %.2f, heal %.2f)" % [1.0, c.p["hp"], heal])
	ok(is_equal_approx(wr.hp, minf(wr.max_hp, 10.0 + wr.max_hp * float(D["thrallHealFrac"]))), "D: ... and your thralls 8 %% of their health (%.1f)" % wr.hp)
	ok(DmStatusSet.of(inside) != null and DmStatusSet.of(inside).is_silenced(), "D: an enemy inside is Silenced")
	ok(DmStatusSet.of(outside) == null or not DmStatusSet.of(outside).is_silenced(), "D: one outside is not")
	_step(c, 3.0)
	var pulses := _events(w, "dirge", "pulse").size()
	ok(pulses == 4, "D: four beats in 4 s (%d)" % pulses)
	ok(is_equal_approx(float(c.p["hp"]), minf(float(c.p["stats"]["maxHp"]), 1.0 + heal * 4.0)) or float(c.p["hp"]) >= float(c.p["stats"]["maxHp"]) - 0.01, "D: four beats of healing (%.2f)" % c.p["hp"])
	_step(c, 1.5)
	ok(_events(w, "dirge", "pulse").size() == 4 and (c.mem("dirge")["zones"] as Array).is_empty(), "D: the song ends after 4 s (no fifth beat, the zone is gone)")
	_step(c, 1.5)
	ok(not DmStatusSet.of(inside).is_silenced(), "D: the silence lapses 1.2 s after the song")
	var au: RecAudio = s["au"]
	ok(au.sfx.count("sigDirge") == 1 and au.sfx.count("tollSmall") == 1 and au.sfx.count("loop:dirgeLoop") == 1, "D: fx once: sigDirge, tollSmall, the dirge bed (%s)" % str(au.sfx))
	await _teardown(s)


# ---- Part E: Plague Bloom + the Rotweaver passive ------------------------------------------------------------------------------------------

func _part_e() -> void:
	var s := await _solo("SP", ROTWEAVER)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var f: DmCorpseField = s["f"]
	var foe := _robber(w, h, Vector3(0, 0, 6))
	var B: Dictionary = DmSimData.SIGNATURE["bloom"]
	_ready_cast(c)
	c.p["resource"]["max"] = 1.0e6
	c.p["resource"]["value"] = 1.0e6
	# one corpse inside reach, others chained
	_corpse(f, Vector3(4, 0, 6))
	_corpse(f, Vector3(8, 0, 6))
	_corpse(f, Vector3(12, 0, 6))
	_corpse(f, Vector3(30, 0, 6))
	c.request_cast("plague_bloom", Vector3(0, 0, 6))
	_step(c, 0.15)
	var ss := DmStatusSet.of(foe)
	ok(ss != null and ss.stacks(&"withered") == 1 and ss.has(&"slow") and is_equal_approx(foe.speed_mult, float(DmSimData.MIASMA_SLOW)), "E: the flower slows the enemy in it and gives the first Withered stack")
	_step(c, 1.0)
	ok(ss.stacks(&"withered") == 2, "E: +1 Withered per second (%d)" % ss.stacks(&"withered"))
	_step(c, 1.0)
	var spreads := _events(w, "plague_bloom", "spread")
	ok(spreads.size() == 1, "E: after 2 s the flower seeded a corpse (%d spread)" % spreads.size())
	ok(f.count() == 3 and is_equal_approx(float(spreads[0]["x"]), 4.0), "E: the NEAREST corpse (4 m) was consumed through the field (%d left)" % f.count())
	ok(is_equal_approx(float(spreads[0]["ms"]), float(B["childDurationS"]) * 1000.0), "E: the child lives 6 s")
	_step(c, 7.0)
	var gens: Array = []
	for z: Dictionary in (c.mem("plague_bloom")["zones"] as Array):
		gens.append(int(z["gen"]))
	ok(gens.all(func(g): return g <= int(B["maxGenerations"])), "E: no flower deeper than 3 generations (%s)" % str(gens))
	ok(_events(w, "plague_bloom", "spread").size() <= 3 and f.count() >= 1, "E: the chain stops on its own (spreads %d, corpses left %d; the corpse 30 m away is untouched)" % [_events(w, "plague_bloom", "spread").size(), f.count()])
	# the cap is 8 (Miasma's is 5)
	_ready_cast(c)
	c.p["resource"]["value"] = 1.0e6
	for e in w.enemies:
		if is_instance_valid(e) and DmStatusSet.of(e) != null:
			DmStatusSet.of(e).clear()
	foe.global_position = Vector3(0, 0, -6)
	f.corpses.clear()
	c.request_cast("plague_bloom", Vector3(0, 0, -6))
	_step(c, 7.6)
	ok(DmStatusSet.of(foe).stacks(&"withered") == 8, "E: Withered stacks cap at 8 (SIGNATURE.bloom.witheredCap): %d" % DmStatusSet.of(foe).stacks(&"withered"))
	var au: RecAudio = s["au"]
	ok(au.sfx.count("sigBloom") == 2 and au.sfx.count("loop:bloomPulse") == 2, "E: fx once per cast: sigBloom and the bloom bed (%s)" % str(au.sfx.slice(0, 6)))
	# the Rotweaver passive: corpses in her Miasma burst
	f.corpses.clear()
	var foe2 := _robber(w, h, Vector3(0, 0, 10))
	for e in [foe2]:
		e.hp = 1.0e7
	_ready_cast(c)
	c.p["resource"]["value"] = 1.0e6
	_corpse(f, Vector3(1.0, 0, 10))
	_corpse(f, Vector3(30, 0, 30))
	c.request_cast("miasma", Vector3(0, 0, 10))
	_step(c, 2.2)
	var bursts := _events(w, "plague_bloom", "burst")
	ok(bursts.size() == 1 and f.count() == 1, "E: the Rotweaver's Miasma burst the corpse lying in it (one burst, the far corpse stays)")
	var cloud: Dictionary = (c.mem("miasma")["zones"] as Array)[0]
	ok(is_equal_approx(float(bursts[0]["r"]), 2.6) and foe2.hp < 1.0e7 and DmStatusSet.of(foe2).stacks(&"withered") >= 1, "E: 2.6 m burst damaged and withered the enemy beside it (dmg %.2f, dps x4 = %.2f)" % [1.0e7 - foe2.hp, float(cloud["dps"]) * 4.0])
	ok(is_equal_approx(float(cloud["r"]), 3.8 * 1.4) and is_equal_approx(float(cloud["cap"]), 8.0), "E: Rotweaver miasma radius x1.4 (%.2f), withered cap 8" % cloud["r"])
	await _teardown(s)
	# the same cast by a Gravecaller bursts nothing
	var g := await _solo("SPG", GRAVECALLER)
	var cg: DmRiteCaster = g["c"]
	var fg: DmCorpseField = g["f"]
	_ready_cast(cg)
	_corpse(fg, Vector3(1.0, 0, 10))
	cg.request_cast("miasma", Vector3(0, 0, 10))
	_step(cg, 2.2)
	var cloud_g: Dictionary = (cg.mem("miasma")["zones"] as Array)[0]
	ok(fg.count() == 1 and _events(g["w"], "plague_bloom", "burst").is_empty() and is_equal_approx(float(cloud_g["r"]), 3.8), "E: a Gravecaller's Miasma leaves corpses alone, radius 3.8")
	await _teardown(g)


# ---- Part F: discipline mods on the other rites, one per discipline ---------------------------------------------------------------------

func _part_f() -> void:
	for cls in [OSSUARY, GRAVECALLER, MOURNER, ROTWEAVER]:
		var d: Dictionary = DmCharacterBuild.discipline_for(float(cls))
		var s := await _solo("SF%d" % cls, cls)
		var c: DmRiteCaster = s["c"]
		ok(c.mods["thrallKind"] == d["mods"]["thrallKind"] and c.mods["thrallCap"] == d["mods"]["thrallCap"], "F: %s caster reads the discipline mods (thrall %s x%d)" % [d["id"], c.mods["thrallKind"], int(c.mods["thrallCap"])])
		await _teardown(s)
	# Ossuary: the litany barrier mod (0.04 per body given) and shieldbearer thralls
	var so := await _solo("SFO", OSSUARY)
	var co: DmRiteCaster = so["c"]
	for i in 3:
		_corpse(so["f"], Vector3(i * 0.5, 0, 2))
	_ready_cast(co)
	co.p["barrier"] = 0.0
	co.request_cast("black_litany", Vector3.ZERO)
	var want_b := float(co.p["stats"]["maxHp"]) * 0.04 * 3.0
	ok(is_equal_approx(float(co.p["barrier"]), want_b), "F: Ossuary litany barrier = maxHp x 0.04 x 3 bodies (%.2f vs %.2f)" % [co.p["barrier"], want_b])
	_ready_cast(co)
	_corpse(so["f"], Vector3(0, 0, 3))
	co.request_cast("exhume", Vector3(0, 0, 3))
	ok(String((so["thr"] as DmThrallHost).list()[0].kind) == "shieldbearer", "F: Ossuary raises shieldbearers")
	await _teardown(so)
	# Gravecaller: sacrificed thralls leave a risen corpse (litany)
	var sg := await _solo("SFG", GRAVECALLER)
	var cg: DmRiteCaster = sg["c"]
	await _raise_legion(sg, 2)
	var field: DmCorpseField = sg["f"]
	field.corpses.clear()
	_ready_cast(cg)
	cg.request_cast("black_litany", Vector3.ZERO)
	ok(field.count() == 2, "F: Gravecaller: each sacrificed thrall lays a risen corpse (%d)" % field.count())
	await _teardown(sg)
	# Mourner: essence regen x1.25, corpseHeal on exhume
	var sm := await _solo("SFM", MOURNER)
	var cm: DmRiteCaster = sm["c"]
	var base := DmCharacterBuild.build({"class_index": GRAVECALLER, "level": 20}, [], {})
	ok(is_equal_approx(float(cm.p["stats"]["essenceRegen"]) / float(base["stats"]["essenceRegen"]), 1.25), "F: Mourner regenerates essence x1.25")
	_corpse(sm["f"], Vector3(0, 0, 3))
	_ready_cast(cm)
	cm.p["hp"] = 1.0
	cm.request_cast("exhume", Vector3(0, 0, 3))
	ok(is_equal_approx(float(cm.p["hp"]), minf(float(cm.p["stats"]["maxHp"]), 1.0 + float(cm.p["stats"]["maxHp"]) * 0.1)), "F: Mourner: raising the dead mends you 10 %% of max health (%.1f)" % cm.p["hp"])
	ok(String((sm["thr"] as DmThrallHost).list()[0].kind) == "wraith", "F: Mourner raises wraiths")
	await _teardown(sm)
	# Rotweaver: Miasma radius x1.4 and cap 8 are covered in E; Withered max stacks from the needle's cap
	var sr := await _solo("SFR", ROTWEAVER)
	var cr: DmRiteCaster = sr["c"]
	ok(is_equal_approx(float(cr.mods["miasmaRadiusMult"]), 1.4) and is_equal_approx(float(cr.mods["witheredMaxStacks"]), 8.0) and cr.mods["miasmaBurstsCorpses"] == true, "F: Rotweaver mods: radius x1.4, 8 Withered, bursts corpses")
	await _teardown(sr)


# ---- Part G: ENet, host + 2 clients -------------------------------------------------------------------------------------------------------

class Peer:
	var node: Node
	var sess: DmSession
	var w: World
	var field: DmCorpseField
	var casters: Dictionary = {}
	var rec: Dictionary = {}
	var rej: Array = []


func _mk(nm: String) -> Peer:
	var pr := Peer.new()
	pr.node = Node.new()
	pr.node.name = nm
	root.add_child(pr.node)
	pr.sess = DmSession.new()
	pr.sess.name = "Session"
	pr.node.add_child(pr.sess)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	pr.sess.character_name = nm
	pr.sess.discipline_id = "rotweaver"
	pr.w = World.new()
	pr.w.name = "W"
	pr.w.classes = {1: GRAVECALLER}
	pr.node.add_child(pr.w)
	pr.field = _field(pr.w)
	(pr.sess.get_node("Players") as Node).child_entered_tree.connect(func(b: Node): _attach.call_deferred(pr, b))
	return pr


func _attach(pr: Peer, b: Node) -> void:
	if not is_instance_valid(b) or b.get_node_or_null("Rites") != null:
		return
	DmThrallHost.attach(b as Node3D, pr.w)
	var c := DmRiteCaster.attach(b as Node3D, pr.w)
	c.random = Callable(self, "_half")
	var st := _stub(c)
	var id: int = (b as DmSessionBody).owner_peer
	pr.casters[id] = c
	pr.rec[id] = st
	c.cast_rejected.connect(func(r, why): pr.rej.append([id, r, why]))


func _part_g() -> void:
	var host := _mk("GH")
	var hpeer := ENetMultiplayerPeer.new()
	ok(hpeer.create_server(PORT, 4) == OK, "G: server created")
	host.sess.host(hpeer)
	_attach(host, host.sess.get_body(1))
	var c1 := _mk("GC1")
	var c2 := _mk("GC2")
	for cl in [c1, c2]:
		var pe := ENetMultiplayerPeer.new()
		pe.create_client("127.0.0.1", PORT)
		(cl as Peer).sess.join(pe)
	var peers: Array = [host, c1, c2]
	ok(await wait_for(func(): return peers.all(func(p): return p.casters.size() == 3)), "G: every peer has a caster on every body")
	var id1 := c1.sess.get_my_id()
	host.w.classes[id1] = ROTWEAVER
	for id in [id1]:
		host.casters[id].auto_step = true
		host.casters[id].p["stats"]["level"] = 20.0
		host.casters[id].p["resource"]["value"] = 1.0e6
		host.casters[id].p["resource"]["max"] = 1.0e6
	host.sess.get_body(id1).position = Vector3(0, 0, 0)
	await create_timer(0.3).timeout
	var hc: DmRiteCaster = host.casters[id1]
	var mine: DmRiteCaster = c1.casters[id1]
	# wall
	mine.request_cast("ossuary_wall", Vector3(0, 0, -5))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == 1)), "G: the wall's event reached every peer")
	for p in peers:
		var a: RecAudio = p.rec[id1][1]
		ok(a.sfx.count("sigWall") == 1 and a.sfx.count("boneHit") == 1, "G: %s wall fx once (%s)" % [p.node.name, str(a.sfx)])
		ok(p.casters[id1].get_node_or_null("Ribs1") != null, "G: %s draws the ribs" % p.node.name)
		ok((p.casters[id1].get_node_or_null("Wall1") != null) == (p == host), "G: %s %s the collider" % [p.node.name, "has" if p == host else "has no"])
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].get_node_or_null("Ribs1") == null), 10.0), "G: the ribs end on every peer after 6 s")
	ok(hc.get_node_or_null("Wall1") == null, "G: the collider is gone on the host")
	for p in peers:
		ok(p.casters[id1].events_played == 2, "G: %s saw raise + gone, once each (%d)" % [p.node.name, p.casters[id1].events_played])
	# dirge: the cast + its four beats once per peer
	hc.p["cooldowns"].clear()
	hc.p["castUntil"] = 0.0
	mine.request_cast("dirge", Vector3.ZERO)
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == 2 + 5), 8.0), "G: the dirge's cast + 4 beats reached every peer")
	for p in peers:
		var a: RecAudio = p.rec[id1][1]
		ok(a.sfx.count("sigDirge") == 1 and a.sfx.count("tollSmall") == 1, "G: %s dirge fx once" % p.node.name)
	# bloom + a chain
	_corpse(host.field, Vector3(3, 0, 8))
	ok(await wait_for(func(): return peers.all(func(p): return p.field.count() == 1)), "G: a corpse replicated")
	hc.p["cooldowns"].clear()
	hc.p["castUntil"] = 0.0
	var n0: int = hc.events_played
	mine.request_cast("plague_bloom", Vector3(0, 0, 8))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == n0 + 2), 6.0), "G: the bloom's cast and its spread reached every peer")
	ok(await wait_for(func(): return peers.all(func(p): return p.field.count() == 0)), "G: the seeded corpse is gone on every peer")
	for p in peers:
		var a: RecAudio = p.rec[id1][1]
		ok(a.sfx.count("sigBloom") == 1, "G: %s bloom fx once" % p.node.name)
	# rend: a thrall raised from a corpse, then commanded
	_corpse(host.field, Vector3(0, 0, 4))
	ok(await wait_for(func(): return peers.all(func(p): return p.field.count() == 1)), "G: rend corpse replicated")
	hc.p["cooldowns"].clear()
	hc.p["castUntil"] = 0.0
	mine.request_cast("exhume", Vector3(0, 0, 4))
	var th: DmThrallHost = host.sess.get_body(id1).get_node("Thralls")
	ok(await wait_for(func(): return th.list().size() == 1 and th.list()[0].state != DmThrall.S.RISING, 10.0), "G: a thrall stands")
	hc.p["cooldowns"].clear()
	hc.p["castUntil"] = 0.0
	var n1: int = hc.events_played
	mine.request_cast("command_rend", Vector3(0, 0, 9))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == n1 + 1)), "G: the rend event reached every peer")
	for p in peers:
		var a: RecAudio = p.rec[id1][1]
		ok(a.sfx.count("sigRend") == 1, "G: %s rend fx once" % p.node.name)
	# a forged intent from a client for another's caster does nothing
	var n2: int = hc.events_played
	c2.casters[id1].request_cast("dirge", Vector3.ZERO, -1, 0)
	await create_timer(0.3).timeout
	ok(hc.events_played == n2, "G: a client cannot cast on another player's body")
	for t in th.list().duplicate():
		t.kill("crumbled")
	for p in peers:   # the host's and the puppets' thrall bodies (children of each peer's world) must not tick on a session that left
		for n in (p as Peer).w.get_children():
			if n is DmThrall:
				n.queue_free()
	await process_frame
	for e in host.w.enemies:
		if is_instance_valid(e):
			e.free()
	for p in [c1, c2, host]:
		(p as Peer).sess.leave()
	await create_timer(0.5).timeout
	for p in peers:
		p.node.queue_free()


# ---- Part H: the slice reads the character's discipline and casts its signature from R ------------------------------------------------------

func _part_h() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("sig%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var ch := await api.load_or_create_character(OSSUARY)
	var character: Dictionary = ch.data
	character["level"] = 12
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"dressing": false, "waves": false, "persist": false})
	var b := g.local_body()
	var c := b.get_node("Rites") as DmRiteCaster
	ok(b.discipline_id == "ossuary" and c.mods["thrallKind"] == "shieldbearer" and is_equal_approx(float(c.mods["wardPerThrall"]), 0.1), "H: the slice's caster reads the Ossuary build (shieldbearers, ward 0.1 per thrall)")
	ok(is_equal_approx(float(c.p["stats"]["level"]), 12.0) and is_equal_approx(float(c.p["stats"]["maxHp"]), b.max_hp), "H: ... at the character's level, same max health as the body (%.0f)" % b.max_hp)
	ok(g.ui_host.rite_at(6) == "ossuary_wall" and g.ui_host.signature == "ossuary_wall", "H: slot 6 (R) is the Ossuary's signature")
	var vm: Dictionary = g.ui_host.hud_state()
	var slots: Array = vm["slots"]
	ok(slots.size() == 6 and slots[5]["key"] == "R" and not slots[5]["locked"] and is_equal_approx(float(slots[5]["cost"]), 30.0), "H: the HUD shows R as a sixth slot, unlocked at level 12, 30 essence")
	var ev0 := c.events_played
	g.input.hotbar.emit(6, Vector3(0, 0, -5) + b.position, 0)
	await create_timer(0.3).timeout
	ok(c.events_played == ev0 + 1 and c.cooldown_left("ossuary_wall") > 15000.0, "H: pressing R raises the wall through the slice's hotbar path")
	# the Ossuary's Bone Ward: damage reduced by wardPerThrall per living thrall
	var hp0 := b.hp
	b.take_damage(100.0, null)
	var plain := hp0 - b.hp
	var th := b.get_node("Thralls") as DmThrallHost
	ok(th.count() == 0 and is_equal_approx(plain, 100.0), "H: without thralls the ward is 0 (took %.1f of 100)" % plain)
	g.corpses.add_corpse(b.position.x, b.position.z + 3.0, "normal", "robber", false, 0.0, 1.0, "")
	g.corpses.add_corpse(b.position.x + 1.0, b.position.z + 3.0, "normal", "robber", false, 0.0, 1.0, "")
	for i in 2:
		c.p["cooldowns"].clear()
		c.p["castUntil"] = 0.0
		c.p["resource"]["value"] = c.p["resource"]["max"]
		c.request_cast("exhume", Vector3(b.position.x + i, 0, b.position.z + 3.0))
		await create_timer(0.7).timeout
	ok(th.count() == 2, "H: two thralls raised")
	var hp1 := b.hp
	b.take_damage(100.0, null)
	var warded := hp1 - b.hp
	ok(absf(warded - 80.0) < 0.5, "H: Bone Ward: 2 thralls x 10 %% = 20 %% less damage (took %.1f of 100)" % warded)
	await g.leave()
	g.queue_free()
	await process_frame


# ---- Part I: perf ------------------------------------------------------------------------------------------------------------------------

func _part_i() -> void:
	var s := await _solo("SPF", ROTWEAVER)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var f: DmCorpseField = s["f"]
	for i in 25:
		_robber(w, h, Vector3(-8 + (i % 5) * 4, 0, 6 + (i / 5) * 3))
	c.p["resource"]["max"] = 1.0e9
	# Best of 5 batches of 100: a batch the OS descheduled on the shared VPS reads 2x+, a real slowdown raises every batch.
	var idle_us := 1.0e9
	for b in 5:
		var t0 := Time.get_ticks_usec()
		for i in 100:
			c.step(DT)
		idle_us = minf(idle_us, float(Time.get_ticks_usec() - t0) / 100.0)
	var cast_us := {}
	for r in ["ossuary_wall", "dirge", "plague_bloom"]:
		_ready_cast(c)
		c.p["resource"]["value"] = 1.0e9
		var t1 := Time.get_ticks_usec()
		c.request_cast(r, Vector3(0, 0, 7))
		cast_us[r] = Time.get_ticks_usec() - t1
	_ready_cast(c)
	var cl := (s["thr"] as DmThrallHost)
	for i in 3:
		_corpse(f, Vector3(i * 0.4, 0, 3))
		_ready_cast(c)
		c.p["resource"]["value"] = 1.0e9
		c.request_cast("exhume", Vector3(i * 0.4, 0, 3))
	await wait_for(func(): return cl.list().size() == 3, 5.0)
	_ready_cast(c)
	var t2 := Time.get_ticks_usec()
	c.request_cast("command_rend", Vector3(0, 0, 9))
	cast_us["command_rend"] = Time.get_ticks_usec() - t2
	# steady state: a wall up, a dirge up, a flower up with 25 enemies around
	_ready_cast(c)
	c.p["resource"]["value"] = 1.0e9
	for r in ["ossuary_wall", "dirge", "plague_bloom"]:
		c.p["cooldowns"].clear()
		c.p["castUntil"] = 0.0
		c.request_cast(r, Vector3(0, 0, 7))
	for i in 20:
		c.step(DT)
	var active_us := 1.0e9   # best of 5 batches of 40, as the idle step above
	for b in 5:
		var t3 := Time.get_ticks_usec()
		for i in 40:
			c.now_ms -= DT * 1000.0   # keep everything alive for the whole measurement
			c.step(DT)
		active_us = minf(active_us, float(Time.get_ticks_usec() - t3) / 40.0)
	print("PERF signatures: cast us wall %d, dirge %d, bloom %d, rend %d | caster step idle %.1f us, wall+dirge+bloom with 25 enemies %.1f us per tick" % [
		cast_us["ossuary_wall"], cast_us["dirge"], cast_us["plague_bloom"], cast_us["command_rend"], idle_us, active_us])
	perf_info(active_us < 1500.0, "I: wall + dirge + bloom stepping costs %.0f us per tick (budget 1500)" % active_us)
	perf_info(cast_us["ossuary_wall"] < 20000 and cast_us["dirge"] < 5000 and cast_us["plague_bloom"] < 5000 and cast_us["command_rend"] < 8000, "I: every signature resolves in well under a frame (wall %d us)" % cast_us["ossuary_wall"])
	perf_info(idle_us < 200.0, "I: an idle caster step is %.1f us (budget 200)" % idle_us)
	await _teardown(s)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
