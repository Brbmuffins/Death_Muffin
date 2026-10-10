extends "res://tests/common/dm_suite_part.gd"
## The control / movement rites (godot/next/rites: grave_step, veil_step, grave_frost, bone_prison, grave_hands, rally_dead).
## godot --headless --path godot --script res://tests/rites/control_run.gd
## Part A: solo (DmSession on OfflineMultiplayerPeer), host stepped by hand. Part B: in-process ENet, 1 host + 2 clients on DmTestPorts.free_port()
## (positions replicate, once-per-peer fx). Part D: a real DmHeroBody on a real NavigationServer3D map (walls, areas). Part C: perf.

var PORT := DmTestPorts.free_port()
var passed := 0
var failed := 0
const DT := 0.02


func ok(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _initialize() -> void:
	await _main()


func _main() -> void:
	DmSimData.ensure()
	await _part_a()
	await _part_b()
	await _part_d()
	await _part_c()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func wait_for(cond: Callable, timeout := 8.0) -> bool:
	for i in int(timeout * 60.0):   # sim ticks, not a wall-clock timer
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func _half() -> float:
	return 0.5


# ---- doubles -----------------------------------------------------------------------------------------------------------------------------

## DmRiteWorld + the corpse field's owner: enemies, `corpses`, `area_of`.
class World:
	extends Node3D
	var enemies: Array = []
	var corpses: DmCorpseField
	var events: Array = []
	var area := ""
	var nav: Object = null   ## optional: area_of asks it (part D)
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
		return area

	func on_rite_event(ev: Dictionary) -> void:
		events.append(ev)


class RecMotifs:
	extends RefCounted
	var n := 0
	func bone_splinters(_x, _y, _z, _o) -> void: n += 1
	func grave_dirt(_x, _z, _o) -> void: n += 1
	func soul_motes(_x, _z, _c, _o) -> void: n += 1
	func cracked_ground(_x, _z, _r, _c, _o) -> void: n += 1
	func mist_whisper(_x, _z, _c, _o) -> void: n += 1
	func spectral_hands(_x, _z, _o) -> void: n += 1
	func spirit_wisps(_x, _z, _c, _o) -> void: n += 1


class RecFx:
	extends RefCounted
	var c := {}
	var beams: Array = []   ## the follow callables the beams were given
	var motifs := RecMotifs.new()
	func _b(k: String) -> void: c[k] = int(c.get(k, 0)) + 1
	func decal(_o) -> Variant: _b("decal"); return null
	func emit(_o) -> void: _b("emit")
	func emit_smoke(_o) -> void: _b("smoke")
	func flash(_o) -> void: _b("flash")
	func play(id, _p, _o) -> Variant: _b("bb"); _b("bb:" + String(id)); return null
	func projectile(_o) -> Variant: _b("projectile"); return null
	func beam(_a, b, _c, _w, _d) -> Variant: _b("beam"); beams.append(b); return null
	func light_flash(_p, _c, _i, _l) -> void: _b("light")
	func spike_ring(_x, _z, _r, _n, _d) -> void: _b("spikes")
	func grave_hands(_x, _z, _r, n, _d) -> Variant: _b("hands"); c["hands_n"] = n; return null
	func total() -> int:
		var t := 0
		for k in c:
			if not String(k).begins_with("bb:") and k != "hands_n":
				t += int(c[k])
		return t


class RecAudio:
	extends RefCounted
	var sfx: Array = []
	var loops: Array = []
	func play_sfx(id, _p, _i) -> void: sfx.append(id)
	func loop_sfx(id, _ms, _p, _f) -> void: loops.append(id)


class FieldVfx:
	extends Node
	func decal(_o: Dictionary) -> Variant: return null
	func emit(_o: Dictionary) -> void: pass


## A body whose avatar is skipped (no models in tests): the real DmHeroBody mover, vitals and navmesh hooks.
class TestHero:
	extends DmHeroBody
	func _make_avatar() -> void:
		pass


class FakeNav:
	extends RefCounted
	var map: RID
	func nav_ready() -> bool: return true
	func nav_closest(p: Vector3) -> Vector3:
		var c := NavigationServer3D.map_get_closest_point(map, p)
		return Vector3(c.x, 0.0, c.z)
	func nav_clamp(p: Vector3) -> Vector3:
		var c := nav_closest(p)
		return p if Vector2(c.x - p.x, c.z - p.z).length_squared() < 0.0004 else c
	func area_at(_x: float, z: float) -> String:
		return "hall" if z < 10.0 else "crypt"


class FakeGame:
	extends Node
	var world: FakeNav


func _robber(w: World, parent: Node, pos: Vector3, hp := 1.0e6) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	e.position = pos
	parent.add_child(e)
	e.hp = hp
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


func _tick(c: DmRiteCaster) -> void:
	c.world.corpses.step(DT)
	c.step(DT)
	var b := c.body as DmSessionBody
	if b != null and b.simulated:
		b.step_host(DT, DmSession.MOVE_SPEED, DmSession.ARENA_HALF)
	for e in c.world.enemies:
		var ss := DmStatusSet.of(e) if is_instance_valid(e) else null
		if ss != null:
			ss.advance(DT)


func _step(c: DmRiteCaster, secs: float) -> void:
	for i in int(round(secs / DT)):
		_tick(c)


func _corpse(f: DmCorpseField, pos: Vector3, area := "") -> DmSimCorpse:
	return f.add_corpse(pos.x, pos.z, "normal", "robber", false, 0.0, 1.0, area)


func _ready_cast(c: DmRiteCaster) -> void:
	c.p["cooldowns"].clear()
	c.p["castUntil"] = 0.0
	c.p["resource"]["value"] = float(c.p["resource"]["max"])


## One solo session with a world, a corpse field, a thrall host and a caster (level 20 so every rite is unlocked).
func _solo(nm: String, factory := Callable()) -> Dictionary:
	var h := Node.new()
	h.name = nm
	root.add_child(h)
	var sess := DmSession.new()
	sess.name = "Session"
	if factory.is_valid():
		sess.body_factory = factory
	h.add_child(sess)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	sess.character_name = "Solo"
	sess.discipline_id = "gravecaller"
	var w := World.new()
	w.name = "W"
	h.add_child(w)
	var f := _field(w)
	sess.host(OfflineMultiplayerPeer.new())
	var body := sess.get_body(1)
	body.position = Vector3(0, 0, 0)
	DmThrallHost.attach(body, w)
	var c := DmRiteCaster.attach(body, w)
	c.auto_step = false
	c.random = Callable(self, "_half")
	c.p["stats"]["level"] = 20.0
	var st := _stub(c)
	await process_frame
	return {"h": h, "sess": sess, "w": w, "f": f, "body": body, "c": c, "fx": st[0], "au": st[1], "thr": body.get_node("Thralls")}


func _teardown(s: Dictionary) -> void:
	for t in (s["thr"] as DmThrallHost).list():
		t.target = null   # the enemies are freed next
	for e in (s["w"] as World).enemies:
		if is_instance_valid(e):
			e.free()
	await (s["sess"] as DmSession).leave()
	(s["h"] as Node).queue_free()


func _rejects(c: DmRiteCaster) -> Array:
	var rej: Array = []
	c.cast_rejected.connect(func(r, why): rej.append([r, why]))
	return rej


func _evs(w: World, t: String, rite: String) -> Array:
	return w.events.filter(func(ev): return ev.get("t") == t and ev.get("rite") == rite)


func _sp(c: DmRiteCaster) -> float:
	return DmAbilities.sp(c.p, c.now_ms)


# ---- Part A: solo ------------------------------------------------------------------------------------------------------------------------

func _part_a() -> void:
	for r in ["grave_step", "veil_step", "grave_frost", "bone_prison", "grave_hands", "rally_dead"]:
		ok(DmRiteRegistry.has(r) and DmRiteRegistry.module(r).id == r, "A: %s registered with its own module" % r)
	ok(DmRiteRegistry.module("grave_hands").steps and not DmRiteRegistry.module("bone_prison").steps, "A: only grave_hands ticks on the host")

	var s := await _solo("S1")
	var c: DmRiteCaster = s["c"]
	var f: DmCorpseField = s["f"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var fx: RecFx = s["fx"]
	var au: RecAudio = s["au"]
	var body: DmSessionBody = s["body"]
	var rej := _rejects(c)
	var nums: Array = []
	c.hit_number.connect(func(_p, a, _c): nums.append(a))
	var shakes := [0]
	c.shake_requested.connect(func(_a): shakes[0] += 1)

	# --- level gates (the kit's unlock levels)
	for pair in [["veil_step", 4], ["grave_step", 5], ["rally_dead", 6], ["grave_frost", 7], ["bone_prison", 9], ["grave_hands", 11]]:
		c.p["stats"]["level"] = float(pair[1]) - 1.0
		rej.clear()
		c.request_cast(pair[0], Vector3(0, 0, 5))
		ok(rej.size() == 1 and rej[0][1] == "locked", "A: %s is locked below level %d" % [pair[0], pair[1]])
	c.p["stats"]["level"] = 20.0
	rej.clear()

	# =========================== Veil Step ===========================
	var VS: Dictionary = DmCombatData.const_table("VEIL_STEP")
	var VD: Dictionary = DmAbilities.def("veil_step")
	ok(is_equal_approx(float(VD["range"]), 5.5) and float(VD["essenceCost"]) == 0.0 and float(VD["cooldownMs"]) == 7000.0, "A: veil_step rules: 5.5 m, free, 7 s")
	c.request_cast("veil_step", Vector3(0.1, 0, 0.1))
	ok(rej.size() == 1 and rej[0][1] == "no_target" and w.events.is_empty() and c.cooldown_left("veil_step") == 0.0, "A: veil with the cursor on the caster is refused (no_target), nothing spent")
	var e0: float = c.essence()
	c.request_cast("veil_step", Vector3(10, 0, 0))
	ok(is_equal_approx(c.essence(), e0) and is_equal_approx(c.cooldown_left("veil_step"), 7000.0), "A: veil costs no essence, cooldown 7000 ms")
	ok(body.dashing and body.position.x == 0.0, "A: the body does not jump: the glide starts on the host")
	var xs: Array = []
	for i in 12:
		_tick(c)
		xs.append(body.position.x)
	ok(not body.dashing and is_equal_approx(body.position.x, 5.5) and absf(body.position.z) < 0.001, "A: veil lands exactly 5.5 m toward the cursor (x %.3f)" % body.position.x)
	ok(xs[0] > xs[1] - xs[0] and xs[0] > 1.0 and xs[7] > 5.4, "A: ease-out glide (first step %.2f m, done by 0.16 s)" % xs[0])
	var mono := true
	for i in range(1, xs.size()):
		mono = mono and xs[i] >= xs[i - 1] - 0.0001
	ok(mono and absf(body.yaw - PI * 0.5) < 0.01, "A: the glide never goes backward and the body faces its way")
	ok(au.sfx == ["veilStep"] and fx.c.get("decal", 0) == 2 and fx.c.get("smoke", 0) == 1 and fx.c.get("light", 0) == 1 and fx.c.get("bb:veil_step_trail", 0) == 1,
		"A: veil fx exactly once (sfx %s, decals %d)" % [str(au.sfx), fx.c.get("decal", 0)])
	rej.clear()
	c.request_cast("veil_step", Vector3(0, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "cooldown", "A: veil on cooldown refused")
	_ready_cast(c)
	body.position = Vector3(0, 0, 0)
	c.request_cast("veil_step", Vector3(2.0, 0, 0))
	_step(c, 0.3)
	ok(is_equal_approx(body.position.x, 2.0), "A: veil toward a nearer cursor stops at the cursor (%.3f)" % body.position.x)
	# arena edge = the plain body's "wall"
	_ready_cast(c)
	body.position = Vector3(38, 0, 0)
	_tick(c)
	c.request_cast("veil_step", Vector3(60, 0, 0))
	_step(c, 0.3)
	ok(is_equal_approx(body.position.x, DmSession.ARENA_HALF), "A: veil never leaves the arena (x %.3f)" % body.position.x)
	_ready_cast(c)
	c.request_cast("veil_step", Vector3(60, 0, 0))   # already at the edge: no room
	ok(rej.back()[1] == "no_target", "A: no room to slip -> refused (no_target)")
	# movement intents wait for the glide
	body.position = Vector3(0, 0, 0)
	_ready_cast(c)
	_tick(c)
	c.request_cast("veil_step", Vector3(0, 0, 5))
	body.set_move_target(Vector3(-20, 0, 0))
	_tick(c)
	ok(body.position.x == 0.0 and body.position.z > 0.5, "A: a move order during the glide does not bend it")
	body.stop()
	_step(c, 0.3)
	ok(is_equal_approx(body.position.z, 5.0), "A: the glide still lands where validated (z %.3f)" % body.position.z)
	# dead / dash stops
	body.position = Vector3(0, 0, 0)
	_ready_cast(c)
	c.set_alive(false)
	rej.clear()
	c.request_cast("veil_step", Vector3(5, 0, 0))
	ok(rej.size() == 1 and rej[0][1] == "dead", "A: dead caster cannot veil")
	c.set_alive(true)

	# =========================== Grave Step ===========================
	var GD: Dictionary = DmAbilities.def("grave_step")
	ok(float(GD["range"]) == 12.0 and float(GD["essenceCost"]) == 10.0 and float(GD["cooldownMs"]) == 5000.0 and is_equal_approx(float(GD["power"]), 1.3), "A: grave_step rules: 12 m, 10 essence, 5 s, power 1.3")
	body.position = Vector3(0, 0, 0)
	_ready_cast(c)
	_tick(c)
	rej.clear()
	var ev_n := w.events.size()
	c.request_cast("grave_step", Vector3(0, 0, 8))
	ok(rej.size() == 1 and rej[0][1] == "no_corpse" and w.events.size() == ev_n and c.cooldown_left("grave_step") == 0.0, "A: no corpse -> refused (no_corpse), nothing spent")
	var cp_far := _corpse(f, Vector3(0, 0, 14))
	c.request_cast("grave_step", Vector3(0, 0, 14))
	ok(rej.size() == 2 and rej[1][1] == "no_corpse", "A: a corpse 14 m away is out of range (no_corpse)")
	f.consume(cp_far.id, 1, "consumed")
	var cp_other := _corpse(f, Vector3(0, 0, 6), "crypt")
	w.area = "hall"
	c.request_cast("grave_step", Vector3(0, 0, 6))
	ok(rej.size() == 3 and rej[2][1] == "no_corpse", "A: a corpse in another area is refused (no_corpse)")
	f.consume(cp_other.id, 1, "consumed")
	w.area = ""
	var e_near := _robber(w, h, Vector3(0.8, 0, 10.5))     # inside 2.6 m of the corpse at z 10
	var e_edge := _robber(w, h, Vector3(0, 0, 12.9))       # 2.9 m: its edge reaches (radius counted)
	var e_out := _robber(w, h, Vector3(0, 0, 14.6))
	var cp := _corpse(f, Vector3(0, 0, 10))
	var hp_n := e_near.hp
	var hp_o := e_out.hp
	var ess := c.essence()
	var dmg := _sp(c) * 1.3
	c.request_cast("grave_step", Vector3(0.5, 0, 10.5))
	ok(rej.size() == 3 and body.position.is_equal_approx(Vector3(0, 0, 10)), "A: the body lands on the corpse at once (host teleport): %s" % str(body.position))
	ok(is_equal_approx(ess - c.essence(), 10.0) and is_equal_approx(c.cooldown_left("grave_step"), 5000.0), "A: 10 essence, cooldown 5000 ms")
	ok(f.count() == 1 and f.get_corpse(cp.id) != null, "A: the corpse stays for the next rite")
	ok(is_equal_approx(hp_n - e_near.hp, dmg) and e_out.hp == hp_o, "A: burst damage = spell power x 1.3 (%.3f vs %.3f); outside untouched" % [hp_n - e_near.hp, dmg])
	var ssn := DmStatusSet.of(e_near)
	ok(ssn != null and ssn.has(&"bleed") and is_equal_approx(ssn.remaining(&"bleed"), float(DmSimData.HEMORRHAGE["durationS"])), "A: the enemies bleed (Hemorrhage 4 s)")
	ok(DmStatusSet.of(e_edge) != null and DmStatusSet.of(e_edge).has(&"bleed"), "A: the burst measures to the enemy's edge")
	var hp_b := e_near.hp
	_step(c, 1.0)
	ok(absf((hp_b - e_near.hp) - dmg * 0.12) < dmg * 0.02, "A: bleed ticks dps = 12%% of the hit (%.3f per s)" % (hp_b - e_near.hp))
	ok(au.sfx.count("bloodStep") == 1 and fx.c.get("beam", 0) == 1 and fx.c.get("bb:grave_step_smoke", 0) == 2, "A: grave_step fx once (sfx bloodStep, beam, 2 smoke bursts)")
	ok(nums.size() == 2 and shakes[0] >= 1, "A: owner gets hit numbers + shake")
	ok(absf(body.yaw) < 0.01 and w.events.back()["rite"] == "grave_step" and _evs(w, "step", "grave_step").size() == 1, "A: one step event, the body faces its way (yaw %.2f)" % body.yaw)
	rej.clear()
	c.request_cast("grave_step", Vector3(0, 0, 10))
	ok(rej.size() == 1 and rej[0][1] == "cooldown", "A: grave_step on cooldown refused")
	# step back: a corpse near the caster is picked by the 7 m fallback when the cursor is off
	_ready_cast(c)
	f.consume(cp.id, 1, "consumed")
	var cp2 := _corpse(f, Vector3(0, 0, 4))
	c.request_cast("grave_step", Vector3(30, 0, 30))
	ok(body.position.is_equal_approx(Vector3(0, 0, 4)), "A: a cursor far from any corpse falls back to the nearest corpse within 7 m")
	f.consume(cp2.id, 1, "consumed")
	c.p["resource"]["value"] = 5.0
	_ready_cast(c)
	c.p["resource"]["value"] = 5.0
	rej.clear()
	_corpse(f, Vector3(0, 0, 6))
	c.request_cast("grave_step", Vector3(0, 0, 6))
	ok(rej.size() == 1 and rej[0][1] == "essence", "A: grave_step without essence refused")
	for e in [e_near, e_edge, e_out]:
		e.free()
	w.enemies.clear()
	f.corpses.clear()

	# =========================== Grave Frost ===========================
	var FD: Dictionary = DmAbilities.def("grave_frost")
	var G: Dictionary = DmSimData.GRAVE_FROST
	ok(float(FD["range"]) == 7.0 and float(FD["essenceCost"]) == 20.0 and float(FD["cooldownMs"]) == 4500.0 and is_equal_approx(float(FD["power"]), 1.4), "A: grave_frost rules: 7 m, 20 essence, 4.5 s, power 1.4")
	ok(float(G["halfAngleDeg"]) == 35.0 and float(G["chillS"]) == 3.0 and float(G["shatterMult"]) == 1.5, "A: cone 35 deg half angle, chill 3 s, shatter x1.5")
	body.position = Vector3(0, 0, 0)
	_ready_cast(c)
	_tick(c)
	var f1 := _robber(w, h, Vector3(0, 0, 3))
	var f2 := _robber(w, h, Vector3(1.0, 0, 6.0))
	var f_side := _robber(w, h, Vector3(5, 0, 3))      # outside the 35 deg cone
	var f_far := _robber(w, h, Vector3(0, 0, 9.0))     # beyond 7 m + radius
	var f_back := _robber(w, h, Vector3(0, 0, -3))
	var hp1 := f1.hp
	ess = c.essence()
	fx.c.clear()
	fx.motifs.n = 0
	au.sfx.clear()
	c.request_cast("grave_frost", Vector3(0, 0, 10))
	ok(is_equal_approx(ess - c.essence(), 20.0) and is_equal_approx(c.cooldown_left("grave_frost"), 4500.0), "A: 20 essence, cooldown 4500 ms")
	ok(f1.hp == hp1 and (DmStatusSet.of(f1) == null or not DmStatusSet.of(f1).has(&"chill")), "A: nothing happens before the bolt lands")
	ok(fx.c.get("projectile", 0) == 1 and au.sfx == ["frost"] and fx.c.get("bb:grave_frost_mist", 0) == 1 and fx.motifs.n == 4, "A: cast fx once: bolt, frost sound, mist, 4 motifs (%d)" % fx.motifs.n)
	_step(c, 0.4)
	dmg = _sp(c) * 1.4
	ok(is_equal_approx(hp1 - f1.hp, dmg) and is_equal_approx(f2.hp, 1.0e6 - dmg), "A: cone damage = spell power x 1.4 (%.3f vs %.3f)" % [hp1 - f1.hp, dmg])
	ok(f_side.hp == 1.0e6 and f_far.hp == 1.0e6 and f_back.hp == 1.0e6, "A: enemies outside the cone / range / behind are untouched")
	var sc := DmStatusSet.of(f1)
	ok(sc.has(&"chill") and is_equal_approx(f1.speed_mult, float(DmSimData.CHILL["moveMult"])) and is_equal_approx(f1.attack_rate_mult, float(DmSimData.CHILL["attackRateMult"])), "A: chilled: -30%% move, -25%% attack speed (%.2f / %.2f)" % [f1.speed_mult, f1.attack_rate_mult])
	ok(is_equal_approx(sc.remaining(&"chill"), 3.0 - 0.2) or sc.remaining(&"chill") > 2.6, "A: chill lasts 3 s from the landing (%.2f left)" % sc.remaining(&"chill"))
	ok(DmStatusSet.of(f_side) == null or not DmStatusSet.of(f_side).has(&"chill"), "A: the enemy outside the cone is not chilled")
	var lands := _evs(w, "land", "grave_frost")
	ok(lands.size() == 1 and lands[0]["seen"].size() == 2 and lands[0]["n"] == 2, "A: one land event listing the 2 touched enemies")
	ok(au.sfx == ["frost"] and fx.c.get("decal", 0) >= 3, "A: frost fx once, no shatter sound on the first cast (sfx %s)" % str(au.sfx))
	# shatter: already chilled -> x1.5
	_step(c, 4.3)
	ok(not DmStatusSet.of(f1).has(&"chill") and is_equal_approx(f1.speed_mult, 1.0), "A: chill expires (speed back to 1)")
	_ready_cast(c)
	c.request_cast("grave_frost", Vector3(0, 0, 10))
	_step(c, 0.4)
	var hp_c := f1.hp
	_ready_cast(c)
	c.request_cast("grave_frost", Vector3(0, 0, 10))
	_step(c, 0.4)
	ok(is_equal_approx(hp_c - f1.hp, dmg * 1.5), "A: an already Chilled enemy shatters for x1.5 (%.3f vs %.3f)" % [hp_c - f1.hp, dmg * 1.5])
	ok(au.sfx.has("needleHit") and fx.c.get("bb:frost_shard_hit", 0) >= 1, "A: shatter plays its shard fx and sound")
	ok(is_equal_approx(DmStatusSet.of(f1).remaining(&"chill"), 3.0 - 0.2) or DmStatusSet.of(f1).remaining(&"chill") > 2.6, "A: a shatter re-chills for 3 s")
	# cursor on the caster -> along the facing; refusals
	body.yaw = 0.0
	var hp_f := f1.hp
	_ready_cast(c)
	c.request_cast("grave_frost", Vector3(0, 0, 0))
	_step(c, 0.4)
	ok(f1.hp < hp_f, "A: a cursor on the caster casts along the body's facing (deviation from the sim's empty cone)")
	rej.clear()
	c.request_cast("grave_frost", Vector3(0, 0, 10))
	ok(rej.size() == 1 and (rej[0][1] == "cooldown" or rej[0][1] == "busy"), "A: frost on cooldown refused")
	_ready_cast(c)
	c.p["resource"]["value"] = 5.0
	rej.clear()
	c.request_cast("grave_frost", Vector3(0, 0, 10))
	ok(rej.size() == 1 and rej[0][1] == "essence", "A: frost without essence refused")
	# a caster that dies while the bolt flies lands nothing
	_ready_cast(c)
	var hp_d := f2.hp
	c.request_cast("grave_frost", Vector3(0, 0, 10))
	c.set_alive(false)
	_step(c, 0.4)
	ok(f2.hp == hp_d, "A: a dead caster's bolt does nothing")
	c.set_alive(true)
	for e in w.enemies:
		e.free()
	w.enemies.clear()

	# =========================== Bone Prison ===========================
	var PD: Dictionary = DmAbilities.def("bone_prison")
	var P: Dictionary = DmSimData.BONE_PRISON
	ok(float(PD["range"]) == 11.0 and float(PD["radius"]) == 2.4 and float(PD["essenceCost"]) == 24.0 and float(PD["cooldownMs"]) == 9000.0 and is_equal_approx(float(PD["power"]), 1.1), "A: bone_prison rules: 11 m, r 2.4, 24 essence, 9 s, power 1.1")
	ok(float(P["rootS"]) == 1.8 and int(P["fracture"]) == 1, "A: root 1.8 s, 1 Fracture stack")
	body.position = Vector3(0, 0, 0)
	_ready_cast(c)
	_tick(c)
	var p1 := _robber(w, h, Vector3(0, 0, 6))
	var p2 := _robber(w, h, Vector3(1.5, 0, 6.5))
	var p_out := _robber(w, h, Vector3(4.0, 0, 6))
	var p_edge := _robber(w, h, Vector3(0, 0, 8.6))    # 2.6 from the centre: edge reaches 2.4 + radius
	var hpp := p1.hp
	ess = c.essence()
	fx.c.clear()
	au.sfx.clear()
	nums.clear()
	c.request_cast("bone_prison", Vector3(0, 0, 6))
	dmg = _sp(c) * 1.1
	ok(is_equal_approx(ess - c.essence(), 24.0) and is_equal_approx(c.cooldown_left("bone_prison"), 9000.0), "A: 24 essence, cooldown 9000 ms")
	ok(is_equal_approx(hpp - p1.hp, dmg) and is_equal_approx(1.0e6 - p2.hp, dmg), "A: prison damage = spell power x 1.1 (%.3f vs %.3f)" % [hpp - p1.hp, dmg])
	ok(p_out.hp == 1.0e6 and DmStatusSet.of(p_out) == null, "A: an enemy outside the ring is untouched")
	ok(DmStatusSet.of(p_edge).has(&"root"), "A: the ring measures to the enemy's edge")
	ok(p1.speed_mult == 0.0 and DmStatusSet.of(p1).has(&"root") and is_equal_approx(DmStatusSet.of(p1).remaining(&"root"), 1.8), "A: rooted 1.8 s (move 0)")
	ok(DmStatusSet.of(p1).stacks(&"fracture") == 1, "A: one Fracture stack")
	ok(au.sfx == ["prison"] and fx.c.get("spikes", 0) == 1 and fx.c.get("bb:bone_prison_burst", 0) == 1 and fx.c.get("decal", 0) == 2, "A: prison fx exactly once (sfx %s)" % str(au.sfx))
	ok(nums.size() == 3 and shakes[0] >= 2, "A: owner gets 3 hit numbers + shake")
	_step(c, 1.7)
	ok(p1.speed_mult == 0.0, "A: still rooted at 1.7 s")
	_step(c, 0.2)
	ok(is_equal_approx(p1.speed_mult, 1.0) and not DmStatusSet.of(p1).has(&"root"), "A: the root ends after 1.8 s")
	ok(DmStatusSet.of(p1).stacks(&"fracture") == 1, "A: Fracture outlasts the root")
	_ready_cast(c)
	hpp = p1.hp
	c.request_cast("bone_prison", Vector3(0, 0, 6))
	ok(is_equal_approx(hpp - p1.hp, dmg * (1.0 + float(DmSimData.FRACTURE["perStack"]))), "A: the second prison hits the Fractured enemy harder (x%.2f)" % ((hpp - p1.hp) / dmg))
	ok(DmStatusSet.of(p1).stacks(&"fracture") == 2, "A: Fracture stacks")
	# range clamp
	_ready_cast(c)
	var p_far := _robber(w, h, Vector3(0, 0, 11.5))
	var p_beyond := _robber(w, h, Vector3(0, 0, 20))
	c.request_cast("bone_prison", Vector3(0, 0, 30))
	ok(p_far.hp < 1.0e6 and p_beyond.hp == 1.0e6, "A: the aim is clamped to 11 m (the ring lands at z 11)")
	# kill: no statuses on the dead; kill credit
	var kills := [0]
	c.hit_resolved.connect(func(_r, _id, _a, _c, killed): kills[0] += int(killed))
	_ready_cast(c)
	var weak := _robber(w, h, Vector3(0, 0, 5), 1.0)
	c.request_cast("bone_prison", Vector3(0, 0, 5))
	ok(weak.hp <= 0.0 and kills[0] == 1 and (DmStatusSet.of(weak) == null or not DmStatusSet.of(weak).has(&"root")), "A: a prisoner that dies is reported once and gets no statuses")
	rej.clear()
	c.request_cast("bone_prison", Vector3(0, 0, 6))
	ok(rej.size() == 1 and (rej[0][1] == "cooldown" or rej[0][1] == "busy"), "A: prison on cooldown refused")
	_ready_cast(c)
	_ready_cast(c)
	c.p["resource"]["value"] = 5.0
	rej.clear()
	c.request_cast("bone_prison", Vector3(0, 0, 6))
	ok(rej.size() == 1 and rej[0][1] == "essence", "A: prison without essence refused")
	for e in w.enemies:
		if is_instance_valid(e):
			e.free()
	w.enemies.clear()

	# =========================== Grave Hands ===========================
	var HD: Dictionary = DmAbilities.def("grave_hands")
	var GH: Dictionary = DmSimData.GRAVE_HANDS
	ok(float(HD["range"]) == 10.0 and float(HD["radius"]) == 3.5 and float(HD["essenceCost"]) == 26.0 and float(HD["cooldownMs"]) == 11000.0 and is_equal_approx(float(HD["power"]), 0.4), "A: grave_hands rules: 10 m, r 3.5, 26 essence, 11 s, power 0.4")
	ok(float(GH["durationS"]) == 3.0 and float(GH["tickS"]) == 0.5 and float(GH["perCorpse"]) == 0.15 and int(GH["maxCorpses"]) == 4, "A: 3 s, a rake every 0.5 s, +15%% per corpse up to 4")
	for kcorpses in [0, 2, 6]:
		body.position = Vector3(0, 0, 0)
		f.corpses.clear()
		w.events.clear()
		_ready_cast(c)
		_tick(c)
		for i in kcorpses:
			_corpse(f, Vector3(float(i) * 0.4 - 1.0, 0, 6.5))
		var hh := _robber(w, h, Vector3(0, 0, 6))
		var hh_out := _robber(w, h, Vector3(0, 0, 11))
		var want := DmAbilities.grave_hands(_sp(c), float(kcorpses))
		ok(int(want["corpses"]) == mini(kcorpses, 4), "A: corpses counted up to 4 (%d)" % kcorpses)
		fx.c.clear()
		au.sfx.clear()
		au.loops.clear()
		ess = c.essence()
		c.request_cast("grave_hands", Vector3(0, 0, 6))
		ok(is_equal_approx(ess - c.essence(), 26.0) and is_equal_approx(c.cooldown_left("grave_hands"), 11000.0), "A: 26 essence, cooldown 11000 ms (%d corpses)" % kcorpses)
		ok(f.count() == kcorpses, "A: the corpses stay (%d)" % kcorpses)
		ok(au.sfx == ["hands"] and au.loops == ["handsLoop"] and fx.c.get("hands", 0) == 1 and int(fx.c.get("hands_n", 0)) == int(want["hands"]), "A: field fx once, %d hands (%d corpses)" % [int(want["hands"]), kcorpses])
		var hp_h := hh.hp
		_step(c, 0.1)
		ok(is_equal_approx(hp_h - hh.hp, float(want["dmg"])), "A: first rake at 60 ms = %.3f (%d corpses) vs %.3f" % [hp_h - hh.hp, kcorpses, float(want["dmg"])])
		ok(is_equal_approx(hh.speed_mult, DmSimData.MIASMA_SLOW), "A: slowed by the field (MIASMA_SLOW)")
		_step(c, 3.3)
		ok(is_equal_approx(hp_h - hh.hp, 6.0 * float(want["dmg"])), "A: 6 rakes in 3 s (%.3f vs %.3f)" % [hp_h - hh.hp, 6.0 * float(want["dmg"])])
		ok(_evs(w, "rake", "grave_hands").size() == 6 and _evs(w, "end", "grave_hands").size() == 1 and _evs(w, "field", "grave_hands").size() == 1, "A: events: field 1, rake 6, end 1")
		ok(hh_out.hp == 1.0e6 and is_equal_approx(hh.speed_mult, 1.0), "A: outside untouched, the slow ends with the field")
		hh.free()
		hh_out.free()
		w.enemies.clear()
	# a caster that dies ends the field; the fx is dropped once
	body.position = Vector3(0, 0, 0)
	w.events.clear()
	_ready_cast(c)
	var hd := _robber(w, h, Vector3(0, 0, 6))
	c.request_cast("grave_hands", Vector3(0, 0, 6))
	_step(c, 1.0)
	c.set_alive(false)
	var hp_e := hd.hp
	_step(c, 1.0)
	ok(hd.hp == hp_e and _evs(w, "end", "grave_hands").size() == 1, "A: a dead caster's field stops raking and ends")
	c.set_alive(true)
	rej.clear()
	_ready_cast(c)
	c.request_cast("grave_hands", Vector3(0, 0, 6))
	c.request_cast("grave_hands", Vector3(0, 0, 6))
	ok(rej.size() == 1 and (rej[0][1] == "cooldown" or rej[0][1] == "busy"), "A: hands on cooldown refused")
	_ready_cast(c)
	c.p["resource"]["value"] = 5.0
	c.request_cast("grave_hands", Vector3(0, 0, 6))
	ok(rej.back()[1] == "essence", "A: hands without essence refused")
	for e in w.enemies:
		if is_instance_valid(e):
			e.free()
	w.enemies.clear()

	# =========================== Rally the Dead ===========================
	var RL: Dictionary = DmSimData.RALLY
	var RD: Dictionary = DmAbilities.def("rally_dead")
	ok(float(RD["essenceCost"]) == 20.0 and float(RD["cooldownMs"]) == 12000.0 and float(RL["durationS"]) == 6.0 and float(RL["gravecallerBonusS"]) == 2.0, "A: rally rules: 20 essence, 12 s, 6 s (+2 s Gravecaller)")
	ok(float(RL["damageMult"]) == 1.4 and float(RL["attackSpeedMult"]) == 1.3 and float(RL["healFrac"]) == 0.2, "A: +40%% damage, +30%% attack speed, 20%% heal")
	body.position = Vector3(0, 0, 0)
	w.events.clear()
	_ready_cast(c)
	rej.clear()
	ess = c.essence()
	c.request_cast("rally_dead", Vector3(0, 0, 5))
	ok(rej.size() == 1 and rej[0][1] == "no_thralls" and c.essence() == ess and c.cooldown_left("rally_dead") == 0.0 and w.events.is_empty(), "A: no thralls -> refused (no_thralls), free")
	var thr: DmThrallHost = s["thr"]
	for i in 3:
		_corpse(f, Vector3(1.0 + i * 0.7, 0, 3))
	c.p["resource"]["value"] = 1000.0
	c.p["resource"]["max"] = 1000.0
	for i in 3:
		c.p["cooldowns"].clear()
		c.p["castUntil"] = 0.0
		c.request_cast("exhume", Vector3(1.0 + i * 0.7, 0, 3))
	ok(thr.count() == 3, "A: three thralls raised for the rally (%d)" % thr.count())
	var risen := await wait_for(func(): return thr.list().all(func(t): return t.state != DmThrall.S.RISING), 6.0)
	ok(risen, "A: the legion finished rising")
	var rallied_before := thr.list().filter(func(t): return t.rally_t > 0.0).size()
	var t0: DmThrall = thr.list()[0]
	t0.hp = t0.max_hp * 0.5
	var hp_t := t0.hp
	var foe := _robber(w, h, Vector3(2, 0, 7))
	var foe2 := _robber(w, h, Vector3(-2, 0, 14))
	w.events.clear()
	fx.c.clear()
	au.sfx.clear()
	fx.beams.clear()
	_ready_cast(c)
	ess = c.essence()
	c.request_cast("rally_dead", Vector3(2, 0, 7))
	ok(rallied_before == 0 and thr.list().all(func(t): return is_equal_approx(t.rally_t, 8.0)), "A: every thrall rallied for 8 s (6 s + Gravecaller 2 s)")
	ok(is_equal_approx(t0.hp, minf(t0.max_hp, hp_t + t0.max_hp * 0.2)), "A: 20%% of max health restored (%.2f -> %.2f of %.2f)" % [hp_t, t0.hp, t0.max_hp])
	ok(is_equal_approx(ess - c.essence(), 20.0) and is_equal_approx(c.cooldown_left("rally_dead"), 12000.0), "A: 20 essence, cooldown 12000 ms")
	ok(thr.list().all(func(t): return t.target == foe), "A: every thrall within the leash turns on the enemy nearest the cursor")
	var evr := _evs(w, "rally", "rally_dead")
	ok(evr.size() == 1 and evr[0]["ids"].size() == 3, "A: ONE rally event naming the 3 thralls")
	ok(au.sfx == ["rallyDead"] and fx.c.get("beam", 0) == 3 and fx.c.get("decal", 0) == 4 and fx.c.get("bb:rally_area", 0) == 1 and fx.c.get("bb:rally_thrall_rim", 0) == 3 and fx.c.get("light", 0) == 1,
		"A: rally fx exactly once (sfx %s, beams %d, decals %d)" % [str(au.sfx), fx.c.get("beam", 0), fx.c.get("decal", 0)])
	var at_ok := true
	for b: Callable in fx.beams:
		var v: Variant = b.call()
		at_ok = at_ok and v is Vector3 and (v as Vector3).y == 1.0
	ok(at_ok and fx.beams.size() == 3, "A: the beams follow the thralls")
	# non-Gravecaller: 6 s
	body.discipline_id = "veilwalker"
	_ready_cast(c)
	c.request_cast("rally_dead", Vector3(2, 0, 7))
	ok(thr.list().all(func(t): return is_equal_approx(t.rally_t, 6.0)), "A: other disciplines rally for 6 s")
	body.discipline_id = "gravecaller"
	# the rally ends: after the duration the beams / sigils stop following (null) and the buff is over
	for t in thr.list():
		t.rally_t = 0.0
	# a focus beyond the leash is not forced on the legion
	for t in thr.list():
		t.target = null
	w.enemies.erase(foe)
	foe.free()
	foe2.global_position = Vector3(-2, 0, 30)
	_ready_cast(c)
	c.request_cast("rally_dead", Vector3(-2, 0, 14))
	ok(thr.list().all(func(t): return t.target == null and t.rally_t > 0.0), "A: a focus beyond the leash is not forced on the legion (still rallied)")
	# dead caster
	_ready_cast(c)
	c.set_alive(false)
	rej.clear()
	c.request_cast("rally_dead", Vector3(2, 0, 7))
	ok(rej.size() == 1 and rej[0][1] == "dead", "A: dead caster cannot rally")
	c.set_alive(true)
	_ready_cast(c)
	c.p["resource"]["value"] = 5.0
	rej.clear()
	c.request_cast("rally_dead", Vector3(2, 0, 7))
	ok(rej.size() == 1 and rej[0][1] == "essence", "A: rally without essence refused")
	# forged intents
	var rj := c.rejected_intents
	c.request_cast("grave_step", Vector3(NAN, 0, 0), -1, 1)
	c.request_cast("veil_step", Vector3(1, 0, 1), -1, 99)
	ok(c.rejected_intents == rj + 2, "A: forged / non-finite intents rejected")
	await _teardown(s)


# ---- Part B: ENet, host + 2 clients ------------------------------------------------------------------------------------------------------

class Peer:
	var node: Node
	var sess: DmSession
	var w: World
	var field: DmCorpseField
	var casters: Dictionary = {}
	var rec: Dictionary = {}   ## owner id -> [RecFx, RecAudio]
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
	pr.sess.discipline_id = "gravecaller"
	pr.w = World.new()
	pr.w.name = "W"
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


func _bpos(p: Peer, id: int) -> Vector3:
	return p.sess.get_body(id).position


func _part_b() -> void:
	var host := _mk("H")
	var hpeer := ENetMultiplayerPeer.new()
	ok(hpeer.create_server(PORT, 4) == OK, "B: server created")
	host.sess.host(hpeer)
	_attach(host, host.sess.get_body(1))
	var c1 := _mk("C1")
	var c2 := _mk("C2")
	for cl in [c1, c2]:
		var pe := ENetMultiplayerPeer.new()
		pe.create_client("127.0.0.1", PORT)
		(cl as Peer).sess.join(pe)
	var peers: Array = [host, c1, c2]
	ok(await wait_for(func(): return peers.all(func(p): return p.casters.size() == 3)), "B: every peer has a caster + thrall host on every body")
	var id1 := c1.sess.get_my_id()
	var id2 := c2.sess.get_my_id()
	for id in [id1, id2]:
		host.casters[id].auto_step = true
		host.casters[id].p["stats"]["level"] = 20.0
		host.casters[id].p["resource"]["value"] = 1000.0
		host.casters[id].p["resource"]["max"] = 1000.0
	var hb: DmSessionBody = host.sess.get_body(id1)
	hb.position = Vector3(-6, 0, 0)
	await step_secs(0.4)
	ok(await wait_for(func(): return (_bpos(c2, id1) - Vector3(-6, 0, 0)).length() < 0.3), "B: the observer sees the body at its spawn spot")

	# --- veil step: the body glides on the host, the position replicates, the observer sees it moving (interpolated, not jumping)
	var seen_mid := [0]
	var jump := [0.0]
	var last := [_bpos(c2, id1)]
	var sampler := func() -> void:
		var q := _bpos(c2, id1)
		if (q - last[0]).length() > jump[0]:
			jump[0] = (q - last[0]).length()
		if q.x > -5.5 and q.x < -0.6:
			seen_mid[0] += 1
		last[0] = q
	c1.casters[id1].request_cast("veil_step", Vector3(0, 0, 0))
	for i in 40:
		await process_frame
		sampler.call()
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == 1)), "B: veil event on host + both clients")
	ok((hb.position - Vector3(-0.5, 0, 0)).length() < 0.01, "B: the host body slipped 5.5 m toward the cursor (%s)" % str(hb.position))
	ok(await wait_for(func(): return (_bpos(c2, id1) - hb.position).length() < 0.1 and (_bpos(c1, id1) - hb.position).length() < 0.1), "B: the glide's end position replicated to both clients")
	ok(seen_mid[0] >= 1 and jump[0] < 5.4, "B: the observer interpolates the glide (%d mid frames, biggest jump %.2f m)" % [seen_mid[0], jump[0]])
	for p in peers:
		var a: RecAudio = p.rec[id1][1]
		var fxr: RecFx = p.rec[id1][0]
		ok(a.sfx == ["veilStep"] and fxr.c.get("decal", 0) == 2, "B: %s veil fx exactly once (sfx %s)" % [p.node.name, str(a.sfx)])
	# refusal over the wire: cooldown
	c1.casters[id1].request_cast("veil_step", Vector3(0, 0, 0))
	ok(await wait_for(func(): return c1.rej.size() >= 1) and c1.rej[0][2] == "cooldown", "B: veil on cooldown refused to the owner")

	# --- grave step: a long blink replicates as a snap (no glide across the gap), once-per-peer fx
	host.casters[id1].p["cooldowns"].clear()
	var cpb := _corpse(host.field, Vector3(5, 0, 6))
	ok(await wait_for(func(): return peers.all(func(p): return p.field.count() == 1)), "B: corpse replicated")
	var ebw := _robber(host.w, host.node, Vector3(5.5, 0, 6.5))
	var hp0 := ebw.hp
	var start := hb.position
	var mids := [0]
	c1.casters[id1].request_cast("grave_step", Vector3(5, 0, 6))
	for i in 40:
		await process_frame
		var q := _bpos(c2, id1)
		if (q - start).length() > 1.0 and (q - Vector3(5, 0, 6)).length() > 1.0:
			mids[0] += 1
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == 2)), "B: step event on host + both clients")
	ok((hb.position - Vector3(5, 0, 6)).length() < 0.01, "B: the host body re-formed on the corpse")
	ok(await wait_for(func(): return (_bpos(c2, id1) - Vector3(5, 0, 6)).length() < 0.1 and (_bpos(c1, id1) - Vector3(5, 0, 6)).length() < 0.1), "B: the new position replicated to both clients")
	ok(mids[0] == 0, "B: clients snap, they never glide across the blink (%d mid frames)" % mids[0])
	var burst := DmAbilities.sp(host.casters[id1].p, host.casters[id1].now_ms) * 1.3
	ok(hp0 - ebw.hp >= burst - 0.001 and hp0 - ebw.hp <= burst * 1.49 and DmStatusSet.of(ebw).has(&"bleed"), "B: the burst (plus its bleed so far) hit the enemy on the host (%.2f vs %.2f)" % [hp0 - ebw.hp, burst])
	for p in peers:
		var a: RecAudio = p.rec[id1][1]
		ok(a.sfx == ["veilStep", "bloodStep"] and p.casters[id1].events_played == 2, "B: %s grave_step fx exactly once (sfx %s)" % [p.node.name, str(a.sfx)])
	ok(host.field.count() == 1 and c1.field.count() == 1, "B: the corpse stayed everywhere")
	host.field.consume(cpb.id, 1, "consumed")
	ebw.free()
	host.w.enemies.clear()

	# --- frost / prison / hands by the second client on enemies that exist on the host only
	hb = host.sess.get_body(id2)
	hb.position = Vector3(0, 0, 0)
	await step_secs(0.3)
	var e_c := _robber(host.w, host.node, Vector3(0, 0, 4))
	var e_c2 := _robber(host.w, host.node, Vector3(0.5, 0, 6))
	var hpf := e_c.hp
	c2.casters[id2].request_cast("grave_frost", Vector3(0, 0, 10))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id2].events_played == 2), 5.0), "B: frost cast + land on every peer")
	ok(await wait_for(func(): return DmStatusSet.of(e_c).has(&"chill") and DmStatusSet.of(e_c2).has(&"chill")), "B: the frost landed on both enemies on the host")
	ok(is_equal_approx(hpf - e_c.hp, DmAbilities.sp(host.casters[id2].p, host.casters[id2].now_ms) * 1.4), "B: network frost damage == DmAbilities")
	ok(DmStatusSet.of(e_c).has(&"chill") and DmStatusSet.of(e_c2).has(&"chill"), "B: both enemies chilled on the host")
	for p in peers:
		var a: RecAudio = p.rec[id2][1]
		var fxr: RecFx = p.rec[id2][0]
		ok(a.sfx == ["frost"] and fxr.c.get("projectile", 0) == 1 and p.casters[id2].events_played == 2 and fxr.c.get("bb:grave_frost_mist", 0) == 1,
			"B: %s frost fx exactly once (sfx %s, shots %d)" % [p.node.name, str(a.sfx), fxr.c.get("projectile", 0)])
	var ev2: int = host.casters[id2].events_played
	c2.casters[id2].request_cast("bone_prison", Vector3(0, 0, 5))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id2].events_played == ev2 + 1)), "B: prison event on every peer")
	await wait_for(func(): return DmStatusSet.of(e_c).has(&"root") and DmStatusSet.of(e_c).stacks(&"fracture") == 1)
	ok(DmStatusSet.of(e_c).has(&"root") and e_c.speed_mult == 0.0 and DmStatusSet.of(e_c).stacks(&"fracture") == 1, "B: prison root + fracture on the host")
	for p in peers:
		var a: RecAudio = p.rec[id2][1]
		var fxr: RecFx = p.rec[id2][0]
		ok(a.sfx == ["frost", "prison"] and fxr.c.get("spikes", 0) == 1, "B: %s prison fx exactly once (sfx %s)" % [p.node.name, str(a.sfx)])
	await step_secs(0.3)
	host.casters[id2].p["cooldowns"].clear()
	var ev3: int = host.casters[id2].events_played
	var hph := e_c.hp
	c2.casters[id2].request_cast("grave_hands", Vector3(0, 0, 5))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id2].events_played >= ev3 + 8), 6.0), "B: hands field + 6 rakes + end on every peer")
	await wait_for(func(): return hph - e_c.hp > 0.0)
	for p in peers:
		var a: RecAudio = p.rec[id2][1]
		var fxr: RecFx = p.rec[id2][0]
		ok(p.casters[id2].events_played == ev3 + 8 and a.sfx.count("hands") == 1 and fxr.c.get("hands", 0) == 1 and a.loops == ["handsLoop"],
			"B: %s hands fx exactly once (events %d, hands %d)" % [p.node.name, p.casters[id2].events_played - ev3, fxr.c.get("hands", 0)])
	ok(hph - e_c.hp > 0.0, "B: the field raked the enemy on the host")

	# --- rally: thralls from exhume, one event, fx once per peer, puppets resolvable on clients
	await step_secs(0.6)
	hb = host.sess.get_body(id1)
	hb.position = Vector3(-4, 0, 0)
	host.casters[id1].p["cooldowns"].clear()
	for i in 2:
		_corpse(host.field, Vector3(-4 + i, 0, 2.5))
	ok(await wait_for(func(): return peers.all(func(p): return p.field.count() == 2)), "B: rally corpses replicated")
	for i in 2:
		host.casters[id1].p["cooldowns"].clear()
		host.casters[id1].p["castUntil"] = 0.0
		c1.casters[id1].request_cast("exhume", Vector3(-4 + i, 0, 2.5))
		await wait_for(func(): return (hb.get_node("Thralls") as DmThrallHost).count() == i + 1)
	var thr: DmThrallHost = hb.get_node("Thralls")
	ok(await wait_for(func(): return thr.count() == 2 and thr.list().all(func(t): return t.state != DmThrall.S.RISING), 8.0), "B: two thralls risen on the host")
	ok(await wait_for(func(): return (c2.sess.get_body(id1).get_node("Thralls") as DmThrallHost).count() == 2, 6.0), "B: the thralls replicated to the observer")
	var ev4: int = host.casters[id1].events_played
	for p in peers:
		(p.rec[id1][1] as RecAudio).sfx.clear()
		(p.rec[id1][0] as RecFx).c.clear()
		(p.rec[id1][0] as RecFx).beams.clear()
	host.casters[id1].p["cooldowns"].clear()
	host.casters[id1].p["castUntil"] = 0.0
	c1.casters[id1].request_cast("rally_dead", Vector3(0, 0, 6))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == ev4 + 1)), "B: rally event on every peer")
	ok(await wait_for(func(): return thr.list().all(func(t): return t.rally_t > 0.0)), "B: the host rallied both thralls")
	for p in peers:
		var a: RecAudio = p.rec[id1][1]
		var fxr: RecFx = p.rec[id1][0]
		ok(p.casters[id1].events_played == ev4 + 1 and a.sfx == ["rallyDead"] and fxr.c.get("beam", 0) == 2 and fxr.c.get("decal", 0) == 3 and fxr.c.get("bb:rally_area", 0) == 1,
			"B: %s rally visuals ran exactly once (sfx %s, beams %d, decals %d)" % [p.node.name, str(a.sfx), fxr.c.get("beam", 0), fxr.c.get("decal", 0)])
	var fol_ok := true
	for b: Callable in (c2.rec[id1][0] as RecFx).beams:
		fol_ok = fol_ok and b.call() is Vector3
	ok(fol_ok and (c2.rec[id1][0] as RecFx).beams.size() == 2, "B: the observer's beams find the thrall puppets")
	ok(await wait_for(func(): return (c2.sess.get_body(id1).get_node("Thralls") as DmThrallHost).list().all(func(t): return t.rally_t > 0.0), 4.0), "B: the observer's thrall puppets show the rally")

	# --- forged: a client casts for another body
	var rj: int = host.casters[id1].rejected_intents
	c2.casters[id1]._rpc_cast.rpc_id(1, "veil_step", Vector3(0, 0, 0), -1)
	ok(await wait_for(func(): return host.casters[id1].rejected_intents == rj + 1), "B: a forged control-rite RPC is rejected by the host")

	for t in thr.list().duplicate():
		t.target = null
		t.kill("crumbled")
	await step_secs(0.2)
	for e in host.w.enemies:
		if is_instance_valid(e):
			e.free()
	for p in [c1, c2, host]:
		(p as Peer).sess.leave()
	await step_secs(0.5)
	for p in peers:
		p.node.queue_free()


# ---- Part D: a real DmHeroBody on a real navigation map ---------------------------------------------------------------------------------

## Two walkable slabs (x -12..2 and 3..12, z -12..20) with a 1 m wall between them; the area changes at z = 10.
func _make_nav() -> Array:
	var map := NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(map, true)
	var nm := NavigationMesh.new()
	nm.vertices = PackedVector3Array([Vector3(-12, 0, -12), Vector3(2, 0, -12), Vector3(2, 0, 20), Vector3(-12, 0, 20),
		Vector3(3, 0, -12), Vector3(12, 0, -12), Vector3(12, 0, 20), Vector3(3, 0, 20)])
	nm.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nm.add_polygon(PackedInt32Array([4, 5, 6, 7]))
	NavigationServer3D.map_set_use_async_iterations(map, false)   # merges in step with the frames (under --fixed-fps the worker thread lagged: "map is synced" flaked)
	var reg := NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(reg, map)
	NavigationServer3D.region_set_navigation_mesh(reg, nm)
	NavigationServer3D.region_set_enabled(reg, true)
	return [map, reg]


func _part_d() -> void:
	var nav_rids := _make_nav()
	var nav := FakeNav.new()
	nav.map = nav_rids[0]
	for i in 6:
		await physics_frame
	ok(NavigationServer3D.map_get_iteration_id(nav.map) > 0, "D: the test navigation map is synced")
	var q := nav.nav_closest(Vector3(2.5, 0, 0))
	ok(absf(q.x - 2.0) < 0.6 and nav.nav_clamp(Vector3(-5, 0, 0)).is_equal_approx(Vector3(-5, 0, 0)), "D: the map answers (wall point snaps to the slab edge, floor stays)")
	var game := FakeGame.new()
	game.name = "G"
	game.world = nav
	var factory := func() -> DmSessionBody:
		var b := TestHero.new()
		b.game = game
		return b
	var s := await _solo("S5", factory)
	(s["h"] as Node).add_child(game)
	var c: DmRiteCaster = s["c"]
	var w: World = s["w"]
	var f: DmCorpseField = s["f"]
	var fx: RecFx = s["fx"]
	var au: RecAudio = s["au"]
	var body: TestHero = s["body"]
	w.nav = nav
	var rej := _rejects(c)
	ok(body.game == game and not body.p.is_empty(), "D: a real DmHeroBody (vitals + navmesh hooks) carries the caster")
	body.position = Vector3(0, 0, 0)
	ok(body.walkable(Vector3(0, 0, 0)) and not body.walkable(Vector3(2.5, 0, 0)) and body.walkable(Vector3(3.5, 0, 0)), "D: walkable() asks the navmesh")
	ok(body.area_of_point(Vector3(0, 0, 5)) == "hall" and body.area_of_point(Vector3(0, 0, 15)) == "crypt", "D: area_of_point asks the world")
	ok(body.dash_point(Vector3(5.5, 0, 0)).is_equal_approx(Vector3(2.0, 0, 0)), "D: dash_point stops at the last walkable 0.25 m step before the wall (%s)" % str(body.dash_point(Vector3(5.5, 0, 0))))

	# --- veil step into a wall: stops at the wall; every glide position is on the navmesh
	var wp := body.position
	_ready_cast(c)
	_tick(c)
	var rlog: Array = []
	c.cast_rejected.connect(func(r, why): rlog.append(why))
	c.request_cast("veil_step", Vector3(10, 0, 0))
	ok(rlog.is_empty() and body.dashing, "D: veil toward a wall is accepted (it shortens)")
	var on_mesh := true
	var max_x := -99.0
	for i in 12:
		_tick(c)
		on_mesh = on_mesh and body.walkable(body.position)
		max_x = maxf(max_x, body.position.x)
	ok(on_mesh and max_x <= 2.02 and absf(body.position.x - 2.0) < 0.02, "D: every glide position stayed on the navmesh and the body stopped at the wall (x %.3f)" % body.position.x)
	# straight at the wall from beside it: nothing to gain -> refused
	_ready_cast(c)
	body.position = Vector3(1.9, 0, 0)
	_tick(c)
	c.request_cast("veil_step", Vector3(10, 0, 0))
	ok(rlog.size() == 1 and rlog[0] == "no_target", "D: pressed against the wall there is no step to take (no_target)")
	# area boundary
	_ready_cast(c)
	body.position = Vector3(-8, 0, 6)
	_tick(c)
	c.request_cast("veil_step", Vector3(-8, 0, 12))
	_step(c, 0.4)
	ok(body.position.z < 10.0 and body.position.z > 9.4 and body.area_of_point(body.position) == "hall", "D: veil never leaves the hall (z %.3f)" % body.position.z)
	# a path through the open side
	_ready_cast(c)
	body.position = Vector3(-8, 0, -2)
	_tick(c)
	c.request_cast("veil_step", Vector3(-3, 0, -2))
	_step(c, 0.4)
	ok(is_equal_approx(body.position.x, -3.0), "D: a free path goes the whole way (x %.3f)" % body.position.x)

	# --- grave step onto a corpse inside the wall: resolved onto the navmesh, never inside the wall
	_ready_cast(c)
	body.position = Vector3(-6, 0, 0)
	_tick(c)
	var cw := _corpse(f, Vector3(2.5, 0, 0))
	w.area = ""
	c.request_cast("grave_step", Vector3(2.5, 0, 0))
	ok(body.walkable(body.position) and absf(body.position.x - 2.5) <= 0.6 and not (body.position.x > 2.02 and body.position.x < 2.98), "D: a corpse inside the wall puts you on the nearest walkable point (%s)" % str(body.position))
	ok(w.events.back()["rite"] == "grave_step" and (w.events.back()["x"] == body.position.x), "D: the event carries the resolved point")
	# a corpse across the wall: allowed (it is a blink), lands on the corpse
	_ready_cast(c)
	f.corpses.clear()
	body.position = Vector3(-6, 0, 0)
	_tick(c)
	_corpse(f, Vector3(5, 0, 0))
	c.request_cast("grave_step", Vector3(5, 0, 0))
	ok(body.position.is_equal_approx(Vector3(5, 0, 0)), "D: a blink may cross the wall (the sim's grave step has no path rule)")
	f.corpses.clear()
	w.enemies.clear()

	# --- perf on the navmesh: veil validation (22 closest-point queries)
	var tot := 0.0
	var n := 200
	for i in n:
		body.position = Vector3(-10, 0, 0)
		var t0 := Time.get_ticks_usec()
		body.dash_point(Vector3(-4.5, 0, 0))
		tot += float(Time.get_ticks_usec() - t0)
	var dp_us := tot / float(n)
	print("PERF veil dash_point on the navmesh (5.5 m, 22 queries): %.1f us" % dp_us)
	perf_info(dp_us < 2000.0, "D: dash_point < 2 ms (%.0f us)" % dp_us)
	await _teardown(s)
	NavigationServer3D.free_rid(nav_rids[1])
	NavigationServer3D.free_rid(nav_rids[0])
	game.queue_free()


# ---- Part C: perf ------------------------------------------------------------------------------------------------------------------------

func _part_c() -> void:
	var s := await _solo("S3")
	var c: DmRiteCaster = s["c"]
	var f: DmCorpseField = s["f"]
	var w: World = s["w"]
	var h: Node = s["h"]
	var body: DmSessionBody = s["body"]
	var thr: DmThrallHost = s["thr"]
	var foes: Array = []
	for i in 25:
		foes.append(_robber(w, h, Vector3(-4 + (i % 5) * 1.6, 0, 5 + (i / 5) * 1.6)))   # a packed pack: everything is inside every ring
	c.p["resource"]["value"] = 1.0e6
	c.p["resource"]["max"] = 1.0e6
	for i in 3:
		_corpse(f, Vector3(i * 0.7, 0, 2.0))
		c.request_cast("exhume", Vector3(i * 0.7, 0, 2.0))
		_ready_cast(c)
		c.p["resource"]["value"] = 1.0e6
	await wait_for(func(): return thr.list().all(func(t): return t.state != DmThrall.S.RISING), 6.0)
	var cost := {}
	for r in ["grave_step", "veil_step", "grave_frost", "bone_prison", "grave_hands", "rally_dead"]:
		var tot := 0.0
		var n := 30
		for i in n:
			_ready_cast(c)
			c.p["resource"]["value"] = 1.0e6
			f.corpses.clear()
			for j in 4:
				_corpse(f, Vector3(1.0 + j * 0.3, 0, 6.0))
			body.position = Vector3(0, 0, 0)
			var aim := Vector3(0, 0, 6) if r != "veil_step" else Vector3(5, 0, 0)
			var t0 := Time.get_ticks_usec()
			c.request_cast(r, aim)
			tot += float(Time.get_ticks_usec() - t0)
			c.mem("grave_hands").clear()
			c._pending.clear()
			body.dashing = false
		cost[r] = tot / float(n)
	print("PERF cast us (25 enemies in range): grave_step %.0f, veil_step %.0f, grave_frost %.0f (+cone on landing, see below), bone_prison %.0f, grave_hands %.0f, rally_dead %.0f" % [
		cost["grave_step"], cost["veil_step"], cost["grave_frost"], cost["bone_prison"], cost["grave_hands"], cost["rally_dead"]])
	for r in cost:
		perf_info(float(cost[r]) < 6000.0, "C: %s cast costs < 6 ms (%.0f us)" % [r, cost[r]])
	# frost landing (the cone) with 25 enemies inside
	for e in foes:
		e.global_position = Vector3(randf_range(-1.5, 1.5), 0, randf_range(1.0, 6.5))
	var tfr := 0.0
	var fm: DmRiteModule = DmRiteRegistry.module("grave_frost")
	for i in 20:
		var t0 := Time.get_ticks_usec()
		fm.call("_arrive", c, Vector3.ZERO, 0.0, 1.0, 7.0, 10.0, Vector3(0, 0.9, 7))
		tfr += float(Time.get_ticks_usec() - t0)
	var frost_us := tfr / 20.0
	print("PERF grave_frost cone landing with 25 enemies inside: %.0f us" % frost_us)
	perf_info(frost_us < 6000.0, "C: the frost cone resolves < 6 ms for 25 enemies (%.0f us)" % frost_us)
	# frame cost: no zones vs 3 hands fields rake-ticking over 25 enemies
	for e in foes:
		e.global_position = Vector3(randf_range(-1.5, 1.5), 0, randf_range(4.5, 7.5))
	_ready_cast(c)
	c.mem("grave_hands").clear()
	c._pending.clear()
	var n := 1000
	var t_base := Time.get_ticks_usec()
	for i in n:
		c.step(DT)
	var base_us := float(Time.get_ticks_usec() - t_base) / float(n)
	var zones: Array = c.mem("grave_hands").get_or_add("zones", [])
	for k in 3:
		zones.append({"id": 100 + k, "x": 0.0, "z": 6.0 + k * 0.2, "r": 3.5, "dmg": 1.0, "until": c.now_ms + 1.0e9, "next": c.now_ms + 60.0})
	var worst := 0.0
	var t_z := Time.get_ticks_usec()
	for i in n:
		var t0 := Time.get_ticks_usec()
		c.step(DT)
		worst = maxf(worst, float(Time.get_ticks_usec() - t0))
	var zone_us := float(Time.get_ticks_usec() - t_z) / float(n)
	print("PERF host step: idle %.1f us/tick; 3 grave_hands fields over 25 enemies %.1f us/tick avg, worst tick (a rake) %.0f us" % [base_us, zone_us, worst])
	perf_info(zone_us < 3000.0 and worst < 12000.0, "C: 3 fields over 25 enemies < 3 ms/tick avg, rake tick < 12 ms (%.0f / %.0f us)" % [zone_us, worst])
	perf_info(base_us < 300.0, "C: an idle caster step is cheap (%.1f us)" % base_us)
	zones.clear()
	await _teardown(s)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
