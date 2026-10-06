extends SceneTree
## Headless suite for the Cinder Pyre / Mourning Fen kinds (cinder_husk, pyre_priest, cinderhound, slag_brute, bog_hag, mire_leech, fen_wisp,
## drowned_sexton). godot --headless --path godot --script res://tests/enemies/pyre_fen_run.gd
## Numbers are asserted against DmSimData (the old sim's data); behaviour against sim_enemy_ai.gd. Time is in physics ticks with time_scale raised.

const S := DmEnemyState.Id
const DT := 1.0 / 60.0   ## sim seconds per physics tick (240 ticks/s x time_scale 4 in the fight tests, 60 x 1 in the perf test)
const BUDGET_BRAIN_US := 150.0
## Whole-frame cost (DmFrameCost: physics + process + redraw): median budget (or within 1.5x the robber crowd), generous cap on the worst frame.
const BUDGET_FRAME_MS := 16.0
const CAP_WORST_FRAME_MS := 150.0

class CH:
	extends RefCounted
	func kill() -> void:
		pass

class CountVfx:
	extends Node
	var n := {}
	var decals: Array = []
	func _c(k: String) -> void:
		n[k] = int(n.get(k, 0)) + 1
	func emit(_o) -> void: _c("emit")
	func emit_smoke(_o) -> void: _c("smoke")
	func decal(o):
		_c("decal")
		decals.append(String(o["tex"]))
		return CH.new()
	func play(id, _pos, _o = {}):
		_c("play:" + String(id))
		return CH.new()
	func beam(_a, _b, _c2, _w, _d): _c("beam"); return CH.new()
	func projectile(_o): _c("projectile")
	func light_flash(_p, _c2, _i, _l = 0.35) -> void: _c("flash")
	func danger(fn: Callable, _when := true):
		return fn.call()
	func count(k: String) -> int: return int(n.get(k, 0))

class CountAudio:
	extends Node
	var sfx := {}
	func play_sfx(name: String, _pos = null, _i: float = 1.0) -> bool:
		sfx[name] = int(sfx.get(name, 0)) + 1
		return true
	func count(k: String) -> int: return int(sfx.get(k, 0))

## A thrall stand-in: the target contract plus the `cursed_t` the Bog Hag writes.
class FakeThrall:
	extends Node3D
	var cursed_t := 0.0
	var hp := 100.0
	func _ready() -> void:
		add_to_group(&"dm_target")
	func dm_alive() -> bool:
		return hp > 0.0
	func dm_take_enemy_hit(d: float, _f: Node) -> void:
		hp -= d

var passed := 0
var failed := 0
var arena: DmEnemyTestArena
var dummy: DmTargetDummy
var vf: CountVfx
var au: CountAudio
var fxn: DmEnemyFx


func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)

func now() -> float:
	return float(Engine.get_physics_frames()) * DT

func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame

func secs(s: float) -> void:
	await ticks(int(round(s / DT)))

func until(cond: Callable, limit_s: float) -> float:
	var t0 := now()
	while now() - t0 < limit_s:
		if cond.call():
			return now() - t0
		await physics_frame
	return -1.0

func new_arena(with_fx := false) -> void:
	if fxn != null:
		fxn.queue_free()
		fxn = null
	if arena != null:
		root.remove_child(arena)
		arena.free()
	arena = load("res://enemies/test_arena.tscn").instantiate()
	arena.robber_count = 0
	root.add_child(arena)
	dummy = arena.target
	dummy.controllable = false
	dummy.max_hp = 1.0e6
	dummy.hp = 1.0e6
	dummy.global_position = Vector3(0, 0, 40)
	if with_fx:
		vf = CountVfx.new()
		au = CountAudio.new()
		fxn = DmEnemyFx.new()
		fxn.vfx = vf
		fxn.audio = au
		fxn.player_pos = func() -> Vector3: return dummy.global_position
		root.add_child(fxn)
	await ticks(3)

func kind(def_id: String, pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var p := {"wander_enabled": false, "rng_seed": 7}
	p.merge(props, true)
	return arena.spawn_kind(def_id, pos, p)

func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func zones(k: StringName = &"") -> Array:
	return arena.get_children().filter(func(n): return n is DmHostileZone and (k == &"" or n.kind == k))

func thrall(pos: Vector3) -> FakeThrall:
	var t := FakeThrall.new()
	t.position = pos
	arena.add_child(t)
	return t

## Record telegraphs and strikes of `e` into the returned dictionary.
func tap(e: DmEnemy) -> Dictionary:
	var r := {"tel": [], "hits": []}
	e.telegraph.connect(func(k, f, a, rad, sec): r["tel"].append({"k": k, "from": f, "aim": a, "r": rad, "s": sec}))
	e.struck.connect(func(_t, d): r["hits"].append(d))
	return r

func stats_ok(e: DmEnemy, id: String, hp: float, dmg: float, rng_m: float, wind: float, cd: float, corpse: String, what: String) -> void:
	var d: Dictionary = DmSimData.ENEMIES[id]
	check(e.max_hp == hp and e.damage == dmg and e.attack_range == rng_m, "%s: hp %d / damage %d / range %.1f from def" % [what, hp, dmg, rng_m])
	check(is_equal_approx(e.windup_s, wind) and is_equal_approx(e.cooldown_s, cd), "%s: windup %.2f / cooldown %.2f" % [what, wind, cd])
	check(e.corpse_kind == corpse and e.creature != null and e.creature.loaded, "%s: corpse '%s', model loaded" % [what, corpse])
	check(e.speed >= float(d["speed"]) * 0.92 - 0.001 and e.speed <= float(d["speed"]) * 1.08 + 0.001, "%s: speed ~%.1f" % [what, float(d["speed"])])

## Host -> puppet snapshot round trip for any kind.
func net_roundtrip(def_id: String) -> void:
	await new_arena()
	var host := kind(def_id, Vector3(-5, 0, -20))
	host.take_damage(3.0)
	var s := host.get_net_state()
	host.set_physics_process(false)
	var pup := kind(def_id, Vector3(20, 0, 20))
	pup.set_multiplayer_authority(2)
	pup.apply_net_state(s)
	var s2 := pup.get_net_state()
	check(pup.global_position.is_equal_approx(host.global_position) and s2["state"] == s["state"] and s2["hp"] == s["hp"], "%s: net state round trip" % def_id)
	check(not pup.take_damage(5.0, dummy) and pup.hp == host.hp, "%s: puppet ignores damage" % def_id)


func _run() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.time_scale = 4.0
	DmSimData.ensure()
	await _t_husk()
	await _t_priest()
	await _t_hound()
	await _t_slag()
	await _t_hag()
	await _t_leech()
	await _t_wisp()
	await _t_sexton()
	await _t_fx()
	await _t_perf()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ======================================================================================================================== cinder husk

func _t_husk() -> void:
	await new_arena()
	var e := kind("cinder_husk", Vector3(0, 0, 10))
	stats_ok(e, "cinder_husk", 110.0, 14.0, 1.3, 0.4, 1.2, "normal", "husk")
	dummy.global_position = Vector3(0, 0, 20)
	var r := tap(e)
	check(await until(func(): return r["hits"].size() >= 1, 8.0) > 0.0, "husk walks up and swings")
	check(r["hits"][0] == 14.0 and r["tel"].is_empty(), "husk: plain melee blow of 14, no ground telegraph")
	# dies in a burning pool: EMBER_DEATH radius 1.6, 3 s, 0.3 x damage per second, host-spawned and damaging
	var at := e.global_position
	e.take_damage(1000.0, dummy)
	var zs := zones(&"ember")
	check(e.sm.id() == S.DEAD and zs.size() == 1, "husk: death leaves one ember pool")
	var z: DmHostileZone = zs[0]
	check(is_equal_approx(z.radius, 1.6) and is_equal_approx(z.lifetime, 3.0) and is_equal_approx(z.dps, 14.0 * 0.3) and z.damaging, "husk: pool r 1.6 / 3 s / dps 4.2 / damaging")
	check(flat(z.global_position, at) < 0.01 and z.source == e, "husk: pool at the body, owned by it")
	dummy.global_position = at + Vector3(0.5, 0, 0)
	var hp0 := dummy.hp
	await secs(1.3)
	check(absf((hp0 - dummy.hp) - 4.2) < 0.01, "husk: standing in the embers costs 4.2 per second (%.2f)" % (hp0 - dummy.hp))
	await secs(2.5)
	check(zones(&"ember").is_empty(), "husk: the pool burns out after 3 s")
	# level scaling hook (the spawner's damage_mult) reaches the pool; elite x1.5
	await new_arena()
	var s := kind("cinder_husk", Vector3(0, 0, 10), {"damage_mult": 2.0, "elite": true})
	s.take_damage(1e9, null)
	var sz: DmHostileZone = zones(&"ember")[0]
	check(absf(sz.dps - 14.0 * 2.0 * 1.5 * 0.3) < 0.001, "husk: pool dps follows level + elite damage (%.2f)" % sz.dps)
	# a puppet draws a visual-only pool
	await new_arena()
	var host := kind("cinder_husk", Vector3(-5, 0, -20))
	var pup := kind("cinder_husk", Vector3(20, 0, 20))
	pup.set_multiplayer_authority(2)
	host.set_physics_process(false)
	host.take_damage(1e9, null)
	var pz := zones(&"ember").size()
	pup.apply_net_state(host.get_net_state())
	var zs2 := zones(&"ember")
	check(pz == 1 and zs2.size() == 2 and zs2.filter(func(x): return not x.damaging).size() == 1, "husk: puppet death = visual-only pool")
	await net_roundtrip("cinder_husk")


# ======================================================================================================================== pyre priest

func _t_priest() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var e := kind("pyre_priest", Vector3(0, 0, 14))
	stats_ok(e, "pyre_priest", 90.0, 15.0, 8.5, 0.95, 3.4, "normal", "priest")
	check(is_equal_approx(e.scale.x, 1.05) and e.attack_anim == "cast", "priest: scale 1.05, cast clip")
	var r := tap(e)
	check(await until(func(): return r["hits"].size() >= 1, 10.0) > 0.0, "priest: casts at the target")
	var t0: Dictionary = r["tel"][0]
	check(t0["k"] == &"ember" and is_equal_approx(t0["r"], 1.7) and is_equal_approx(t0["s"], 0.95), "priest: ember telegraph r 1.7 for the 0.95 s wind-up")
	check(flat(t0["aim"], Vector3(0, 0, 26)) < 0.01, "priest: aimed where the target stood")
	check(r["hits"][0] == 15.0, "priest: coal hits for 15")
	var zs := zones(&"ember")
	check(zs.size() == 1 and is_equal_approx(zs[0].radius, 1.7) and is_equal_approx(zs[0].lifetime, 4.0) and is_equal_approx(zs[0].dps, 15.0 * 0.4), "priest: pool r 1.7 / 4 s / dps 6.0")
	check(flat(zs[0].global_position, t0["aim"]) < 0.01, "priest: the ground burns at the aim")
	var d := flat(e.global_position, dummy.global_position)
	check(d > 4.0 and d < 8.6, "priest: holds casting range (%.1f m)" % d)
	# walking out of the telegraph dodges the coal (the pool still lands)
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var p := kind("pyre_priest", Vector3(0, 0, 14))
	p.telegraph.connect(func(_k, _f, _a, _r, _s): dummy.global_position = Vector3(8, 0, 26))
	check(await until(func(): return not zones(&"ember").is_empty(), 10.0) > 0.0, "priest dodge: the pool lands anyway")
	check(dummy.hits_taken == 0, "priest dodge: stepping out of the ring takes nothing")
	await net_roundtrip("pyre_priest")
	# puppet: ATTACK with the replicated aim re-announces the telegraph at the same radius
	await new_arena()
	var host := kind("pyre_priest", Vector3(0, 0, 14))
	var pup := kind("pyre_priest", Vector3(20, 0, 20))
	pup.set_multiplayer_authority(2)
	var pr := tap(pup)
	host.set_physics_process(false)
	host.aim = Vector3(1, 0, 22)
	host.sm.change(S.ATTACK)
	host.aim = Vector3(1, 0, 22)
	pup.apply_net_state(host.get_net_state())
	check(pr["tel"].size() == 1 and pr["tel"][0]["k"] == &"ember" and pr["tel"][0]["aim"].is_equal_approx(Vector3(1, 0, 22)), "priest: puppet derives the ember telegraph from the replicated ATTACK")


# ======================================================================================================================== cinderhound

func _t_hound() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var e := kind("cinderhound", Vector3(0, 0, 12), {"flank_side": 1.0})
	stats_ok(e, "cinderhound", 62.0, 11.0, 1.2, 0.24, 0.78, "swift", "cinderhound")
	e.home = e.global_position
	var r := tap(e)
	var max_x := 0.0
	var t0 := now()
	while now() - t0 < 6.0 and r["hits"].is_empty():
		await physics_frame
		max_x = maxf(max_x, absf(e.global_position.x))
	check(max_x > 1.0, "cinderhound flanks wide (%.2f m)" % max_x)
	check(not r["hits"].is_empty() and r["hits"][0] == 11.0, "cinderhound bites for 11")
	check(int(DmSimData.ENEMIES["cinderhound"]["pack"][0]) == 2 and int(DmSimData.ENEMIES["cinderhound"]["pack"][1]) == 3 and DmSimData.ENEMIES["cinderhound"]["behavior"] == "flank", "cinderhound: hunts in packs of 2-3")
	e.take_damage(1000.0, dummy)
	check(e.sm.id() == S.DEAD and e.corpse_kind == "swift" and zones().is_empty(), "cinderhound: dies leaving a swift corpse (no pool)")
	await net_roundtrip("cinderhound")


# ======================================================================================================================== slag brute

func _t_slag() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 20)
	var e := kind("slag_brute", Vector3(0, 0, 12))
	stats_ok(e, "slag_brute", 520.0, 28.0, 2.2, 1.0, 2.9, "resonant", "slag")
	check(is_equal_approx(e.radius, 1.0) and e.slam_radius() == 2.7, "slag: radius 1.0, slam 2.7")
	var r := tap(e)
	check(await until(func(): return r["hits"].size() >= 1, 12.0) > 0.0, "slag: lumbers in and slams")
	var t0: Dictionary = r["tel"][0]
	check(t0["k"] == &"slam" and is_equal_approx(t0["r"], 2.7) and is_equal_approx(t0["s"], 1.0), "slag: slam telegraph r 2.7 for 1.0 s")
	check(r["hits"][0] == 28.0, "slag: slam hits for 28")
	var zs := zones(&"ember")
	check(zs.size() == 1 and is_equal_approx(zs[0].radius, 2.7) and is_equal_approx(zs[0].lifetime, 4.0) and is_equal_approx(zs[0].dps, 28.0 * 0.3), "slag: the slam leaves a pool r 2.7 / 4 s / dps 8.4")
	check(flat(zs[0].global_position, t0["aim"]) < 0.01, "slag: the pool is on the slam aim")
	# a bystander inside the ring is hit too, one outside is not
	await new_arena()
	dummy.global_position = Vector3(0, 0, 20)
	var inn := arena.get_child_count()
	var d2 := DmTargetDummy.new()
	d2.controllable = false
	d2.position = Vector3(2.0, 0, 20)
	arena.add_child(d2)
	var d3 := DmTargetDummy.new()
	d3.controllable = false
	d3.position = Vector3(3.2, 0, 20)
	arena.add_child(d3)
	var s := kind("slag_brute", Vector3(0, 0, 17.5))
	s.attack_cd = 0.0
	check(await until(func(): return dummy.hits_taken > 0, 6.0) > 0.0, "slag: slam lands")
	check(d2.hits_taken == 1 and d3.hits_taken == 0, "slag: area slam hits inside 2.7 m (%d) not outside (%d)" % [d2.hits_taken, d3.hits_taken])
	# death: a fire death, no pool of its own
	s.take_damage(1e9, dummy)
	check(s.sm.id() == S.DEAD and zones(&"ember").size() == 1, "slag: death is a fire flare, only the slam pool remains")
	# puppet draws the visual-only pool at impact time
	await new_arena()
	var host := kind("slag_brute", Vector3(0, 0, 12))
	var pup := kind("slag_brute", Vector3(20, 0, 20))
	pup.set_multiplayer_authority(2)
	host.set_physics_process(false)
	pup.aim = Vector3(5, 0, 5)
	pup.on_impact_visual()
	var zs2 := zones(&"ember")
	check(zs2.size() == 1 and not zs2[0].damaging and is_equal_approx(zs2[0].radius, 2.7), "slag: puppet impact = visual-only pool")
	await net_roundtrip("slag_brute")


# ======================================================================================================================== bog hag

func _t_hag() -> void:
	await new_arena()
	var t1 := thrall(Vector3(0, 0, 22))
	var t2 := thrall(Vector3(1.0, 0, 22))
	var t3 := thrall(Vector3(3.4, 0, 22.5))
	var far := thrall(Vector3(-8, 0, 20))
	dummy.global_position = Vector3(1.5, 0, 23)
	var st := DmStatusSet.ensure(dummy)
	var e := kind("bog_hag", Vector3(0, 0, 14))
	stats_ok(e, "bog_hag", 100.0, 12.0, 9.5, 1.3, 4.4, "normal", "hag")
	e.attack_cd = 0.0
	var r := tap(e)
	check(await until(func(): return r["hits"].size() >= 4, 10.0) > 0.0, "hag: hexes the group")
	var t0: Dictionary = r["tel"][0]
	check(t0["k"] == &"hex" and is_equal_approx(t0["r"], 3.1) and is_equal_approx(t0["s"], 1.3), "hag: hex telegraph r 3.1 for 1.3 s")
	check(flat(t0["aim"], t2.global_position) < 0.01, "hag: aimed at the thickest thrall knot (centre thrall), got %s" % str(t0["aim"]))
	var dmg := 12.0 * 0.55
	check(absf(r["hits"][0] - dmg) < 0.001 and absf((100.0 - t2.hp) - dmg) < 0.001, "hag: blow x0.55 = %.1f" % dmg)
	check(t1.cursed_t == 6.0 and t2.cursed_t == 6.0 and t3.cursed_t == 6.0, "hag: thralls in the ring are cursed for 6 s")
	check(far.cursed_t == 0.0 and far.hp == 100.0, "hag: a thrall outside the ring is untouched")
	check(st.has(&"chill") and st.remaining(&"chill") <= 1.8 and st.remaining(&"chill") > 1.0, "hag: a player in the ring is chilled 1.8 s")
	check(is_equal_approx(float(DmSimData.HAG_HEX["thrallDamageMult"]), 0.7), "hag: cursed thralls hit x0.7 (DmThrall reads HAG_HEX)")
	# no thralls: aimed at the target
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var h2 := kind("bog_hag", Vector3(0, 0, 14))
	h2.attack_cd = 0.0
	var r2 := tap(h2)
	await until(func(): return not r2["tel"].is_empty(), 6.0)
	check(not r2["tel"].is_empty() and flat(r2["tel"][0]["aim"], Vector3(0, 0, 25)) < 0.5, "hag: no thralls -> hex on the target")
	# a dodge: leaving the ring avoids the blow
	h2.telegraph.connect(func(_k, _f, _a, _r, _s): dummy.global_position = Vector3(9, 0, 25))
	await net_roundtrip("bog_hag")


# ======================================================================================================================== mire leech

func _t_leech() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var e := kind("mire_leech", Vector3(0, 0, 14))
	stats_ok(e, "mire_leech", 22.0, 4.0, 0.9, 0.21, 0.72, "none", "leech")
	check(is_equal_approx(e.radius, 0.32) and int(DmSimData.ENEMIES["mire_leech"]["pack"][0]) == 4 and int(DmSimData.ENEMIES["mire_leech"]["pack"][1]) == 6 and e.corpse_s == 2.4, "leech: tiny, swarms of 4-6, crumbles after 2.4 s")
	var r := tap(e)
	var worst := 0.0
	var t0 := now()
	while now() - t0 < 6.0 and r["hits"].is_empty():
		await physics_frame
		if e.creature != null:
			worst = maxf(worst, absf(e.creature.root.scale.x - 1.0))
	check(not r["hits"].is_empty() and r["hits"][0] == 4.0, "leech: bites for 4")
	check(worst > 0.02 and worst < 0.14, "leech: squash-and-sway wiggle while it slithers (%.3f)" % worst)
	e.take_damage(1000.0, dummy)
	check(e.sm.id() == S.DEAD and e.corpse_kind == "none", "leech: dies, no corpse")
	await secs(2.6)
	check(not is_instance_valid(e), "leech: the body is freed 2.4 s later")
	await net_roundtrip("mire_leech")


# ======================================================================================================================== fen wisp

func _t_wisp() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var st := DmStatusSet.ensure(dummy)
	var e := kind("fen_wisp", Vector3(0, 0, 14))
	stats_ok(e, "fen_wisp", 60.0, 9.0, 8.5, 1.0, 3.3, "none", "wisp")
	check(e.flying == 1.5 and is_equal_approx(e.scale.x, 0.85), "wisp: hovers 1.5 m, scale 0.85")
	var r := tap(e)
	check(await until(func(): return r["hits"].size() >= 1, 10.0) > 0.0, "wisp: pulses")
	var t0: Dictionary = r["tel"][0]
	check(t0["k"] == &"pulse" and is_equal_approx(t0["r"], 2.3) and is_equal_approx(t0["s"], 1.0), "wisp: pulse telegraph r 2.3 for 1.0 s")
	check(r["hits"][0] == 9.0 and st.has(&"chill") and st.remaining(&"chill") <= 1.8, "wisp: 9 damage and a 1.8 s chill")
	check(zones().is_empty(), "wisp: a pulse leaves no ground zone")
	# the lure: a target closing inside 3.5 m is backed away from AND toward the open water
	var res := []
	for lure in [Vector3(30, 0, 14), Vector3(-30, 0, 14)]:
		await new_arena()
		dummy.global_position = Vector3(0, 0, 16)
		var w := kind("fen_wisp", Vector3(0, 0, 14), {"lure_point": lure})
		w.attack_cd = 99.0
		await secs(0.7)
		res.append(w.global_position)
	check(res[0].x > 0.4 and res[1].x < -0.4 and res[0].z < 13.5 and res[1].z < 13.5, "wisp: backs off toward the lure (%.2f / %.2f), away from the target (z %.2f)" % [res[0].x, res[1].x, res[0].z])
	check(is_equal_approx(DmSimData.FEN_LURE["x"], -44.0) and is_equal_approx(DmSimData.FEN_LURE["z"], -79.0), "wisp: default lure is FEN_LURE (-44, -79)")
	await net_roundtrip("fen_wisp")


# ======================================================================================================================== drowned sexton

func _t_sexton() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var st := DmStatusSet.ensure(dummy)
	var off := DmTargetDummy.new()   # beside the chain, out of the line
	off.controllable = false
	off.position = Vector3(3.5, 0, 26)
	arena.add_child(off)
	var e := kind("drowned_sexton", Vector3(0, 0, 19), {}) as DmEnemyPfHazard
	stats_ok(e, "drowned_sexton", 560.0, 25.0, 2.2, 1.0, 2.9, "normal", "sexton")
	check(is_equal_approx(e.radius, 0.95) and e.slam_radius() == 2.5 and int(e.def["deathCorpses"]) == 2, "sexton: radius 0.95, slam 2.5, deathCorpses 2")
	e.attack_cd = 0.0
	var r := tap(e)
	check(await until(func(): return r["tel"].size() >= 1, 6.0) > 0.0 and e.hooking, "sexton: a player 7 m out gets the chain")
	var t0: Dictionary = r["tel"][0]
	check(t0["k"] == &"hook" and is_equal_approx(t0["r"], 8.5) and is_equal_approx(t0["s"], 1.0), "sexton: hook telegraph (range 8.5) for the 1.0 s wind-up")
	check(e.hook_cd > 6.0 and e.hook_cd <= 6.5, "sexton: hook cooldown 6.5 s starts at the wind-up (%.2f)" % e.hook_cd)
	var z0 := dummy.global_position.z
	check(await until(func(): return r["hits"].size() >= 1, 3.0) > 0.0, "sexton: the chain lands")
	check(absf(r["hits"][0] - 25.0 * 0.7) < 0.001 and not e.hooking, "sexton: hook blow x0.7 = 17.5")
	check(z0 - dummy.global_position.z > 3.5 and z0 - dummy.global_position.z <= 4.51, "sexton: dragged ~4.5 m toward it (%.2f)" % (z0 - dummy.global_position.z))
	check(st.has(&"root") and st.remaining(&"root") <= 0.5, "sexton: rooted 0.5 s")
	check(off.hits_taken == 0, "sexton: a target 3.5 m off the line is missed")
	await secs(3.0)
	var hooks := 0
	for t in r["tel"]:
		if t["k"] == &"hook":
			hooks += 1
	check(hooks == 1 and e.hook_cd > 0.0, "sexton: no second chain while the cooldown runs")
	# gating: thralls are never hooked; walls block the chain
	await new_arena()
	var g := kind("drowned_sexton", Vector3(0, 0, 19)) as DmEnemyPfHazard
	g.attack_cd = 0.0
	g.hook_cd = 0.0
	var th := thrall(Vector3(0, 0, 26))
	dummy.global_position = Vector3(0, 0, 26)
	check(g.hook_ready(dummy, 7.0), "sexton: hook ready on a player in range")
	check(not g.hook_ready(th, 7.0), "sexton: a thrall is never hooked")
	check(not g.hook_ready(dummy, 3.0) and not g.hook_ready(dummy, 9.0), "sexton: min range 3.4 / max range 8.5")
	g.global_position = Vector3(0, 0, -5)
	dummy.global_position = Vector3(0, 0, 3)
	check(not g.hook_ready(dummy, 8.0), "sexton: the wall between them blocks the chain")
	g.set_physics_process(false)
	# an interrupted chain does not turn the next slam into a hook
	g.hooking = true
	g.sm.change(S.ATTACK)
	g.sm.change(S.HURT)
	check(not g.hooking, "sexton: a stunned chain clears the hook flag")
	# puppet derives the hook telegraph from the replicated flag
	await new_arena()
	var host := kind("drowned_sexton", Vector3(0, 0, 14)) as DmEnemyPfHazard
	var pup := kind("drowned_sexton", Vector3(20, 0, 20)) as DmEnemyPfHazard
	pup.set_multiplayer_authority(2)
	var pr := tap(pup)
	host.set_physics_process(false)
	host.hooking = true
	host.aim = Vector3(0, 0, 20)
	host.sm.change(S.ATTACK)
	host.hooking = true
	pup.apply_net_state(host.get_net_state())
	check(pr["tel"].size() == 1 and pr["tel"][0]["k"] == &"hook" and is_equal_approx(pr["tel"][0]["r"], 8.5), "sexton: puppet shows the hook telegraph")
	# corpses: deathCorpses 2 = the body plus one risen corpse on a 1.6 m ring (the sim loop runs k = 1 .. n-1)
	await new_arena()
	var field := DmCorpseField.new()
	field.name = "Corpses"
	field.visuals = false
	field.auto_step = false
	arena.add_child(field)
	var c := kind("drowned_sexton", Vector3(30, 0, 30))
	field.track(c)
	c.take_damage(1e9, null)
	var cs := field.corpses_in_radius(Vector3(30, 0, 30), 2.0)
	check(field.count() == 2 and cs.filter(func(k): return k.enemy == "risen").size() == 1, "sexton: dies into 1 corpse + 1 risen (%d)" % field.count())
	await net_roundtrip("drowned_sexton")


# ======================================================================================================================== effects

func _t_fx() -> void:
	# priest: telegraph + coal landing + burning pool visual
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 26)
	var p := kind("pyre_priest", Vector3(0, 0, 14))
	p.attack_cd = 0.0
	check(await until(func(): return fxn.stats["strike"] >= 1, 8.0) > 0.0, "fx priest: impact reached")
	await secs(0.3)
	check(fxn.stats["telegraph"] == 1 and au.count("emberThrow") == 1 and au.count("tellStrike") == 1, "fx priest: one ember telegraph with its throw sound")
	check(au.count("emberBurst") == 1 and vf.count("play:vengeful_burst") >= 1, "fx priest: the coal bursts on landing")
	check(fxn.stats["zone"] >= 1 and vf.decals.has("cracks") and vf.count("play:bonfire") >= 1, "fx priest: the burning pool is drawn (zone %d)" % fxn.stats["zone"])
	p.take_damage(1e9, dummy)
	check(fxn.stats["death"] == 1, "fx priest: death effect once")
	# husk death: embers burst once
	await new_arena(true)
	var h := kind("cinder_husk", Vector3(0, 0, 8))
	h.take_damage(1e9, dummy)
	await ticks(3)
	check(fxn.stats["death"] == 1 and au.count("emberBurst") == 1 and vf.count("play:vengeful_burst") >= 1, "fx husk: ember burst once on death")
	check(fxn.stats["zone"] == 1, "fx husk: its pool is drawn")
	# slag: molten slam beat; hex / pulse / hook shapes
	var cases := [["slag_brute", "slagSlam"], ["bog_hag", "curse"], ["fen_wisp", ""], ["drowned_sexton", "boneHit"]]
	for c in cases:
		await new_arena(true)
		dummy.global_position = Vector3(0, 0, 21 if c[0] == "slag_brute" else 25)
		var e := kind(c[0], Vector3(0, 0, 19 if c[0] == "slag_brute" else 17))
		e.attack_cd = 0.0
		check(await until(func(): return fxn.stats["strike"] >= 1, 10.0) > 0.0, "fx %s: impact reached" % c[0])
		await secs(0.4)
		check(fxn.stats["telegraph"] >= 1 and vf.count("decal") >= 2, "fx %s: telegraph decals drawn" % c[0])
		if c[1] != "":
			check(au.count(c[1]) >= 1, "fx %s: %s sound" % [c[0], c[1]])
		if c[0] == "bog_hag":
			check(vf.decals.has("sigil"), "fx hag: hex sigil")
		if c[0] == "slag_brute":
			check(vf.decals.has("cracks") and vf.count("play:surge_eruption") >= 1, "fx slag: molten cracks + eruption")
	# idle tells run (fire / fen motes) near the hero
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 10)
	for d in ["cinder_husk", "pyre_priest", "cinderhound", "slag_brute", "bog_hag", "fen_wisp", "drowned_sexton"]:
		kind(d, Vector3(randf_range(-4, 4), 0, 8 + randf_range(0, 3)), {"wander_enabled": false, "leash_range": 0.0}).set_physics_process(false)
	var e0 := vf.count("emit") + vf.count("smoke")
	await secs(2.0)
	check(vf.count("emit") + vf.count("smoke") - e0 > 8, "fx: idle ember / marsh motes are emitted (%d)" % (vf.count("emit") + vf.count("smoke") - e0))


# ======================================================================================================================== perf

## One 30-body crowd sample (real time, visuals + animation on): [brain us/enemy-tick, frame median ms, frame worst ms, engaged, per-kind line].
func _crowd(mix: Array) -> Array:
	await new_arena()
	DmEnemy.profile = true
	var es: Array[DmEnemy] = []
	for i in 30:
		var a := TAU * i / 30.0
		es.append(kind(mix[i], Vector3(sin(a) * 11.0, 0, 6.0 + cos(a) * 11.0), {"rng_seed": 100 + i, "leash_range": 80.0}))
	dummy.global_position = Vector3(0, 0, 6)
	await secs(1.0)
	DmEnemy.prof_reset()
	var fc := DmFrameCost.attach(root)
	var start := now()
	while now() - start < 4.0:
		var a := (now() - start) * 0.6
		dummy.global_position = Vector3(sin(a) * 3.0, 0, 6.0 + cos(a) * 3.0)
		await physics_frame
	fc.queue_free()
	DmEnemy.profile = false
	var line := ""
	for k in DmEnemy.prof_kind:
		var v: Array = DmEnemy.prof_kind[k]
		line += " %s %.0f us;" % [k, float(v[1]) / maxf(1.0, float(v[0]))]
	var engaged := es.filter(func(e): return e.sm.id() != S.IDLE and e.sm.id() != S.RISING).size()
	return [float(DmEnemy.prof_brain_us) / maxf(1.0, float(DmEnemy.prof_ticks)), fc.median_ms(), fc.worst_busy_ms(), engaged, line]


func _med(a: Array[float]) -> float:
	a.sort()
	return a[a.size() / 2]


## Mixed-30 crowd of the eight kinds vs a 30-robber baseline measured in the same process (the VPS is shared, absolute numbers swing with its load):
## passes when under the absolute budget (quiet machine) or within 1.5x of the baseline (loaded machine). Median of 3 samples each.
func _t_perf() -> void:
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	var mix := ["cinder_husk", "cinder_husk", "pyre_priest", "cinderhound", "cinderhound", "slag_brute", "bog_hag", "mire_leech", "mire_leech", "mire_leech",
		"fen_wisp", "drowned_sexton", "cinder_husk", "cinderhound", "mire_leech", "pyre_priest", "cinder_husk", "cinderhound", "mire_leech", "bog_hag",
		"fen_wisp", "cinder_husk", "slag_brute", "mire_leech", "cinderhound", "pyre_priest", "mire_leech", "cinder_husk", "drowned_sexton", "fen_wisp"]
	var base_mix := []
	for i in 30:
		base_mix.append("robber")
	var mb: Array[float] = []
	var mp: Array[float] = []
	var mr: Array[float] = []   # worst frame of each mixed sample
	var bb: Array[float] = []
	var bp: Array[float] = []
	var engaged := 0
	var line := ""
	for sample in 3:
		var b: Array = await _crowd(base_mix)
		bb.append(b[0])
		bp.append(b[1])
		var m: Array = await _crowd(mix)
		mb.append(m[0])
		mp.append(m[1])
		mr.append(m[2])
		engaged = m[3]
		line = m[4]
	var brain := _med(mb)
	var phys := _med(mp)
	var base_brain := _med(bb)
	var base_phys := _med(bp)
	print("PERF mixed-30 Pyre/Fen crowd (median of 3): brain %.1f us/enemy-tick (30 robbers %.1f), frame median %.2f ms (30 robbers %.2f), worst %.1f ms, engaged %d/30" % [brain, base_brain, phys, base_phys, _med(mr), engaged])
	print("PERF   per kind (last sample):", line)
	check(engaged >= 27, "the mixed crowd is engaged (%d/30)" % engaged)
	check(brain < BUDGET_BRAIN_US or brain <= base_brain * 1.5, "median brain cost %.1f us/enemy-tick under %.0f us or 1.5x the robber crowd (%.1f)" % [brain, BUDGET_BRAIN_US, base_brain])
	check(phys < BUDGET_FRAME_MS or phys <= base_phys * 1.5, "median frame %.2f ms under %.0f ms or 1.5x the robber crowd (%.2f)" % [phys, BUDGET_FRAME_MS, base_phys])
	check(_med(mr) < CAP_WORST_FRAME_MS, "worst frame %.1f ms under %.0f ms" % [_med(mr), CAP_WORST_FRAME_MS])
