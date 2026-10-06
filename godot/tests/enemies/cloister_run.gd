extends SceneTree
## Suite for the Cloister kinds (acolyte, templar, seraph, plague_doctor, flagellant): godot --headless --path godot --script res://tests/enemies/cloister_run.gd
## Same stepping helpers as kinds_run.gd. Time is in physics ticks (360 Hz, time_scale 6) so assertions are in sim seconds.

const S := DmEnemyState.Id
const DT := 1.0 / 60.0
const BUDGET_BRAIN_US := 150.0   ## same budget as the Graves crowd (kinds_run.gd)
const BUDGET_PHYS_MS := 30.0   ## quiet VPS ~4-5 ms; dev runs at load average 40 measured 12-22 ms. Catches runaway cost, brain us is the strict number

## Stand-in for a thrall (DmThrall contract the acolyte uses): group dm_thrall, `died`, `dead_reason`.
class FakeThrall:
	extends Node3D
	signal died(t)
	var dead_reason := ""
	func kill(reason: String) -> void:
		dead_reason = reason
		died.emit(self)

## Minimal recording Vfx / audio back-ends for the DmEnemyFx check.
class CH:
	extends RefCounted
	func kill() -> void: pass
class CountVfx:
	extends Node
	var decals: Array = []
	var projectiles := 0
	var in_danger := 0
	var danger_decals := 0
	func emit(_o) -> void: pass
	func emit_smoke(_o) -> void: pass
	func decal(o):
		decals.append(String(o["tex"]))
		if in_danger > 0 or o.get("danger", false):
			danger_decals += 1
		return CH.new()
	func play(_id, _pos, _o = {}): return CH.new()
	func beam(_a, _b, _c, _w, _d): return CH.new()
	func projectile(_o) -> void: projectiles += 1
	func light_flash(_p, _c, _i, _l = 0.35) -> void: pass
	func danger(fn: Callable, _when := true):
		in_danger += 1
		var r = fn.call()
		in_danger -= 1
		return r
class CountAudio:
	extends Node
	var sfx := {}
	func play_sfx(name: String, _pos = null, _i: float = 1.0) -> bool:
		sfx[name] = int(sfx.get(name, 0)) + 1
		return true

var passed := 0
var failed := 0
var arena: DmEnemyTestArena
var dummy: DmTargetDummy


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

func new_arena() -> void:
	if arena != null:
		root.remove_child(arena)
		arena.free()
	arena = load("res://enemies/test_arena.tscn").instantiate()
	arena.robber_count = 0
	root.add_child(arena)
	dummy = arena.target
	dummy.controllable = false
	dummy.max_hp = 1.0e9
	dummy.hp = 1.0e9
	await ticks(3)

func kind(def_id: String, pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var p := {"wander_enabled": false, "rng_seed": 7}
	p.merge(props, true)
	return arena.spawn_kind(def_id, pos, p)

func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func median(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return float(b[b.size() / 2])


func _run() -> void:
	Engine.physics_ticks_per_second = 360
	Engine.time_scale = 6.0
	DmSimData.ensure()
	await _t_flagellant()
	await _t_templar()
	await _t_plague_doctor()
	await _t_acolyte()
	await _t_seraph()
	await _t_fx()
	await _t_perf()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Death, corpse kind and host -> puppet snapshot for any kind.
func death_and_net(def_id: String, corpse: String) -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var host := kind(def_id, Vector3(-5, 0, -20))
	check(host.corpse_kind == corpse, "%s: corpse kind %s" % [def_id, corpse])
	host.take_damage(3.0)
	var s := host.get_net_state()
	host.set_physics_process(false)
	var pup := kind(def_id, Vector3(20, 0, 20))
	pup.set_multiplayer_authority(2)
	pup.apply_net_state(s)
	var s2 := pup.get_net_state()
	check(pup.global_position.is_equal_approx(host.global_position) and s2["state"] == s["state"] and s2["hp"] == s["hp"], "%s: net state round trip" % def_id)
	check(not pup.take_damage(5.0, dummy) and pup.hp == host.hp, "%s: puppet ignores damage" % def_id)
	pup.apply_net_state({"pos": pup.global_position, "yaw": 0.0, "state": S.DEAD, "hp": 0.0, "anim": "death"})
	check(pup.collision_layer == 0, "%s: puppet dead stops colliding" % def_id)
	# the host body: dies once, emits `died` once with the def's corpse kind
	host.set_physics_process(true)
	var died: Array = []
	host.died.connect(func(en): died.append(en.corpse_kind))
	host.take_damage(9999.0, dummy)
	await ticks(3)
	check(host.sm.id() == S.DEAD and died.size() == 1 and died[0] == corpse and host.collision_layer == 0, "%s: dies, `died` once (corpse %s)" % [def_id, corpse])


func _t_flagellant() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("flagellant", Vector3(-20, 0, -20))
	check(e.max_hp == 120.0 and e.damage == 12.0 and e.attack_range == 1.3, "flagellant: hp 120 / damage 12 / range 1.3 from def")
	check(is_equal_approx(e.windup_s, 0.38) and is_equal_approx(e.cooldown_s, 1.1) and e.speed >= 2.7 * 0.92 - 0.001 and e.speed <= 2.7 * 1.08 + 0.001, "flagellant: windup 0.38, cooldown 1.1, speed ~2.7")
	check(e.creature != null and e.creature.loaded, "flagellant: model loaded")
	# frenzy below half hp: x1.45 move, x1.6 attack rate (DmStatusSet)
	var ss := DmStatusSet.ensure(e)
	await ticks(30)
	check(not ss.has(&"frenzy") and e.speed_mult == 1.0 and e.attack_rate_mult == 1.0, "flagellant: calm above half hp")
	e.hp = e.max_hp * 0.4
	await ticks(60)
	check(ss.has(&"frenzy") and is_equal_approx(e.speed_mult, 1.45) and is_equal_approx(e.attack_rate_mult, 1.6), "flagellant: frenzy below half hp (x1.45 move, x1.6 rate)")
	# the faster rate is real: blow gap on a standing target
	var gaps: Array = []
	for frenzy in [false, true]:
		await new_arena()
		var f := kind("flagellant", Vector3(0, 0, 0), {"rng_seed": 5})
		DmStatusSet.ensure(f)
		dummy.global_position = Vector3(0, 0, 1.2)
		if frenzy:
			f.hp = f.max_hp * 0.3
		await secs(0.3)
		f.hp = f.max_hp * (0.3 if frenzy else 1.0)
		var t_hits: Array = []
		f.struck.connect(func(_t, _d): t_hits.append(now()))
		await until(func(): return t_hits.size() >= 4, 14.0)
		gaps.append((t_hits[t_hits.size() - 1] - t_hits[1]) / maxf(1.0, float(t_hits.size() - 2)))
	check(gaps[0] > 1.05 and gaps[1] < gaps[0] * 0.75, "flagellant: frenzied blows come faster (%.2f s -> %.2f s apart)" % [gaps[0], gaps[1]])
	await death_and_net("flagellant", "normal")


func _t_templar() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("templar", Vector3(-20, 0, -20))
	check(e.max_hp == 180.0 and e.damage == 17.0 and e.attack_range == 1.6, "templar: hp 180 / damage 17 / range 1.6 from def")
	check(is_equal_approx(e.windup_s, 0.65) and is_equal_approx(e.cooldown_s, 1.6) and is_equal_approx(e.scale.x, 1.1), "templar: windup 0.65, cooldown 1.6, scale 1.1")
	check(e.creature != null and e.creature.loaded, "templar: model loaded")
	# shield: 60-degree half-arc in front passes 30%; sides, back, Fracture and DoT take full damage
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var t := kind("templar", Vector3(0, 0, 0))
	t.set_physics_process(false)
	var blocks: Array = []
	t.cue.connect(func(k, _a, _r): blocks.append(k))
	var tests := [["front", Vector3(0, 0, 4), 30.0], ["front 55 deg", Vector3(sin(deg_to_rad(55.0)) * 4.0, 0, cos(deg_to_rad(55.0)) * 4.0), 30.0],
		["side 70 deg", Vector3(sin(deg_to_rad(70.0)) * 4.0, 0, cos(deg_to_rad(70.0)) * 4.0), 100.0], ["back", Vector3(0, 0, -4), 100.0]]
	for c in tests:
		t.hp = t.max_hp
		t.rotation.y = 0.0
		t._stagger_t = 99.0
		dummy.global_position = c[1]
		t.take_damage(100.0, dummy)
		check(absf((t.max_hp - t.hp) - float(c[2])) < 0.01, "templar shield: %s takes %.0f of 100 (%.1f)" % [c[0], c[2], t.max_hp - t.hp])
	check(blocks.count(&"shield_block") == 1, "templar: one shield_block cue per 0.25 s (%d)" % blocks.count(&"shield_block"))
	t.hp = t.max_hp
	t.rotation.y = 0.0
	dummy.global_position = Vector3(0, 0, 4)
	t.take_damage(100.0, dummy, false)
	check(absf(t.max_hp - t.hp - 100.0) < 0.01, "templar: a DoT tick (undirected) ignores the shield")
	t.hp = t.max_hp
	t.take_damage(100.0, null)
	check(absf(t.max_hp - t.hp - 100.0) < 0.01, "templar: damage with no source ignores the shield")
	t.hp = t.max_hp
	DmStatusSet.ensure(t).apply(&"fracture", dummy)
	t.take_damage(100.0, dummy)
	check(absf(t.max_hp - t.hp - 100.0) < 0.01, "templar: Fracture breaks the shield")
	# it fights: closes in and swings for 17
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var f := kind("templar", Vector3(0, 0, 14))
	var dmg: Array = []
	f.struck.connect(func(_t, d): dmg.append(d))
	await until(func(): return dmg.size() >= 2, 12.0)
	check(dmg.size() >= 2 and dmg[0] == 17.0, "templar closes in and hits for 17 (%s)" % [dmg])
	await death_and_net("templar", "resonant")


func _t_plague_doctor() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("plague_doctor", Vector3(-20, 0, -20))
	check(e.max_hp == 90.0 and e.damage == 13.0 and e.attack_range == 8.5, "plague doctor: hp 90 / damage 13 / range 8.5 from def")
	check(is_equal_approx(e.windup_s, 1.0) and is_equal_approx(e.cooldown_s, 3.6) and (e as DmEnemyCaster).attack_kind == "flask", "plague doctor: windup 1.0, cooldown 3.6, flask")
	check(e.creature != null and e.creature.loaded and e.attack_anim == "cast", "plague doctor: model loaded, cast anim")
	# flask: ring telegraph at the aim, hit + toxic pool on landing; keeps its range
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var m := kind("plague_doctor", Vector3(0, 0, 14))
	var tel: Array = []
	m.telegraph.connect(func(k, _f, a, r, sec): tel.append([k, r, sec, a]))
	var dmg: Array = []
	m.struck.connect(func(_t, d): dmg.append(d))
	var zone: Array = [null]
	var min_d := 99.0
	var start := now()
	while now() - start < 9.0:
		await physics_frame
		min_d = minf(min_d, flat(m.global_position, dummy.global_position))
		if zone[0] == null:
			var zs := get_nodes_in_group(&"dm_hostile_zone")
			if zs.size() > 0:
				zone[0] = zs[0]
				var z := zs[0] as DmHostileZone
				check(z.kind == &"toxic" and is_equal_approx(z.radius, 1.8) and is_equal_approx(z.lifetime, 5.0) and is_equal_approx(z.dps, 13.0 * 0.35), "flask pool: toxic, radius 1.8, 5 s, dps 4.55")
	check(min_d > 3.5, "plague doctor keeps its distance (closest %.2f m)" % min_d)
	check(tel.size() >= 1 and tel[0][0] == &"flask" and is_equal_approx(tel[0][1], 1.8) and is_equal_approx(tel[0][2], 1.0), "plague doctor telegraphs a 1.8 m flask ring over 1.0 s")
	check(dmg.size() >= 1 and dmg[0] == 13.0, "flask hits for the def damage (13)")
	check(zone[0] != null and dummy.hits_taken >= 3, "the toxic pool keeps hurting (%d hits)" % dummy.hits_taken)
	# dodge: leave the ring during the wind-up -> no direct hit
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var q := kind("plague_doctor", Vector3(0, 0, 14), {"rng_seed": 3})
	await until(func(): return q.sm.id() == S.ATTACK, 8.0)
	var n0 := dummy.hits_taken
	dummy.global_position = Vector3(8, 0, 26)
	await secs(1.3)
	check(dummy.hits_taken == n0, "walking out of the flask ring dodges it")
	# silenced: never starts a cast
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var sl := kind("plague_doctor", Vector3(0, 0, 14))
	DmStatusSet.ensure(sl).apply(&"silence", dummy, 1, 6.0)
	var casts := [0]
	sl.telegraph.connect(func(_k, _f, _a, _r, _s): casts[0] += 1)
	await secs(5.0)
	check(casts[0] == 0, "a silenced plague doctor does not cast")
	await secs(2.5)
	check(casts[0] >= 1, "...and casts again when the silence ends")
	# puppet: the replicated ATTACK state gives the telegraph and a visual-only pool at the landing
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var p := kind("plague_doctor", Vector3(0, 0, 0))
	p.set_multiplayer_authority(2)
	var ptel: Array = []
	p.telegraph.connect(func(k, _f, _a, _r, sec): ptel.append([k, sec]))
	p.apply_net_state({"pos": Vector3.ZERO, "yaw": 0.0, "state": S.CHASE, "hp": p.hp, "anim": "idle", "aim": Vector3(2, 0, 4), "t": 0.0})
	p.apply_net_state({"pos": Vector3.ZERO, "yaw": 0.0, "state": S.ATTACK, "hp": p.hp, "anim": "attack", "aim": Vector3(2, 0, 4), "t": 0.2})
	check(ptel.size() == 1 and ptel[0][0] == &"flask" and is_equal_approx(ptel[0][1], 0.8), "puppet: flask telegraph from the replicated ATTACK state (0.8 s left)")
	await secs(1.0)
	var zs := get_nodes_in_group(&"dm_hostile_zone")
	check(zs.size() == 1 and not (zs[0] as DmHostileZone).damaging and (zs[0] as DmHostileZone).global_position.is_equal_approx(Vector3(2, 0, 4)), "puppet: a visual-only toxic pool at the aim when the flask lands")
	await death_and_net("plague_doctor", "toxic")


func _t_acolyte() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("acolyte", Vector3(-20, 0, -20)) as DmEnemyClstAcolyte
	check(e.max_hp == 92.0 and e.damage == 14.0 and e.attack_range == 8.0, "acolyte: hp 92 / damage 14 / range 8 from def")
	check(is_equal_approx(e.windup_s, 0.9) and is_equal_approx(e.cooldown_s, 3.0) and e.attack_kind == "curse" and e.attack_anim == "cast", "acolyte: windup 0.9, cooldown 3.0, curse, cast anim")
	check(e.creature != null and e.creature.loaded, "acolyte: model loaded")
	# curse: telegraph ring, homing hit for 14; holds range
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var a := kind("acolyte", Vector3(0, 0, 14)) as DmEnemyClstAcolyte
	var tel: Array = []
	a.telegraph.connect(func(k, _f, _a, r, sec): tel.append([k, r, sec]))
	var dmg: Array = []
	a.struck.connect(func(_t, d): dmg.append(d))
	var min_d := 99.0
	var start := now()
	while now() - start < 8.0:
		await physics_frame
		min_d = minf(min_d, flat(a.global_position, dummy.global_position))
	check(min_d > 3.0, "acolyte keeps its distance (closest %.2f m)" % min_d)
	check(tel.size() >= 2 and tel[0][0] == &"curse" and tel[0][1] == 0.0 and is_equal_approx(tel[0][2], 0.9), "acolyte telegraphs a curse over 0.9 s")
	check(dmg.size() >= 2 and dmg[0] == 14.0, "the curse hits for 14 (%d hits)" % dmg.size())
	var gap := 0.0
	# the curse homes: stepping aside does not dodge it
	await new_arena()
	dummy.global_position = Vector3(0, 0, 8)
	var h := kind("acolyte", Vector3(0, 0, 0), {"rng_seed": 3})
	await until(func(): return h.sm.id() == S.ATTACK, 8.0)
	var n0 := dummy.hits_taken
	dummy.global_position = Vector3(5, 0, 6)
	await secs(1.2)
	check(dummy.hits_taken == n0 + 1, "the curse follows a target that steps aside (still within reach)")
	# ...but out of reach (> attackRange x 1.35 + 0.4 = 11.2 m) it fizzles
	await new_arena()
	dummy.global_position = Vector3(0, 0, 8)
	var h2 := kind("acolyte", Vector3(0, 0, 0), {"rng_seed": 3})
	await until(func(): return h2.sm.id() == S.ATTACK, 8.0)
	var n1 := dummy.hits_taken
	dummy.global_position = Vector3(0, 0, 14)
	await secs(1.2)
	check(dummy.hits_taken == n1, "a target past 11.2 m when the curse lands is not hit")
	# unbind: a killed thrall within 7 m is claimed; a Risen is requested 1 s later; capped at 4, 4 s apart
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var u := kind("acolyte", Vector3(0, 0, 0)) as DmEnemyClstAcolyte
	u.set_physics_process(true)
	var rises: Array = []
	u.unbind_rise.connect(func(at, by): rises.append([at, by, now()]))
	var cues: Array = []
	u.cue.connect(func(k, _at, _r): cues.append(k))
	var th: Array = []
	for i in 6:
		var ft := FakeThrall.new()
		ft.position = Vector3(2.0 + float(i) * 0.1, 0, 3)
		ft.add_to_group(&"dm_thrall")
		arena.add_child(ft)
		th.append(ft)
	var far := FakeThrall.new()
	far.position = Vector3(10, 0, 0)
	far.add_to_group(&"dm_thrall")
	arena.add_child(far)
	await secs(1.0)   # the acolyte connects to thralls it sees (0.5 s watch)
	(th[0] as FakeThrall).kill("crumbled")
	far.kill("killed")
	check(u.pending.is_empty(), "unbind: ignores a crumbled thrall and one beyond 7 m")
	var t_kill := now()
	(th[1] as FakeThrall).kill("killed")
	check(u.pending.size() == 1 and cues.has(&"unbind"), "unbind: a killed thrall within 7 m is claimed (cue `unbind`)")
	(th[2] as FakeThrall).kill("killed")
	check(u.pending.size() == 1, "unbind: 4 s cooldown between claims")
	await secs(1.2)
	check(rises.size() == 1 and absf(rises[0][2] - t_kill - 1.0) < 0.2 and (rises[0][0] as Vector3).is_equal_approx(Vector3(2.1, 0, 3)), "unbind: Risen requested 1 s later at the fall (%.2f s)" % (rises[0][2] - t_kill if rises.size() > 0 else -1.0))
	var risen := kind("risen", Vector3(2.1, 0, 3))
	u.adopt(risen)
	check(risen.get_meta(&"unbound_by") == u, "unbind: adopted Risen is tagged unbound_by the acolyte")
	for i in 3:
		await secs(4.1)
		(th[3 + i] as FakeThrall).kill("killed")
		await secs(1.1)
		u.adopt(kind("risen", Vector3(2.0, 0, 3)))
	check(rises.size() == 4 and u.pending.size() == 0, "unbind: four claimed over time (%d)" % rises.size())
	var extra := FakeThrall.new()
	extra.position = Vector3(2, 0, 3)
	extra.add_to_group(&"dm_thrall")
	arena.add_child(extra)
	await secs(4.6)
	extra.kill("killed")
	check(u.pending.is_empty() and u._alive_unbound() == 4, "unbind: at most 4 claimed Risen alive per acolyte")
	u.unbound[0].take_damage(9999.0)
	await secs(4.6)
	var extra2 := FakeThrall.new()
	extra2.position = Vector3(2, 0, 3)
	extra2.add_to_group(&"dm_thrall")
	arena.add_child(extra2)
	await secs(0.6)
	extra2.kill("killed")
	check(u.pending.size() == 1, "unbind: a freed slot (a Risen died) can be claimed again")
	await death_and_net("acolyte", "normal")
	# silenced acolyte also never casts
	await new_arena()
	dummy.global_position = Vector3(0, 0, 14)
	var sl := kind("acolyte", Vector3(0, 0, 4))
	DmStatusSet.ensure(sl).apply(&"silence", dummy, 1, 5.0)
	var casts := [0]
	sl.telegraph.connect(func(_k, _f, _a, _r, _s): casts[0] += 1)
	await secs(4.0)
	check(casts[0] == 0, "a silenced acolyte does not cast")


func _t_seraph() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("seraph", Vector3(-20, 0, -20))
	check(e.max_hp == 120.0 and e.damage == 8.0 and e.attack_range == 6.5, "seraph: hp 120 / damage 8 / range 6.5 from def")
	check(is_equal_approx(e.windup_s, 1.3) and is_equal_approx(e.cooldown_s, 8.5) and e.flying == 0.7, "seraph: windup 1.3, cooldown 8.5, hovers at 0.7")
	await secs(0.2)
	check(e.get_node("Visual").position.y > 0.4 and e.get_node("Visual").position.y < 1.0 and e.global_position.y < 0.1, "seraph hovers (visual y %.2f), body on the ground plane" % e.get_node("Visual").position.y)
	check(e.creature != null and e.creature.loaded and e.creature.opts.has("wings"), "seraph: model loaded with wings")
	# ward: Sanctify the 4 most wounded allies within 5.5 m, once per cooldown; far allies and the seraph itself excluded
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var s := kind("seraph", Vector3(0, 0, 0), {"rng_seed": 11})
	s.attack_cd = 0.0
	var allies: Array = []
	for i in 6:
		var al := kind("robber", Vector3(2.0 + float(i) * 0.5, 0, 1.0), {"rng_seed": 20 + i})
		al.hp = al.max_hp * (0.3 + 0.1 * float(i))   # ally 0 most wounded
		allies.append(al)
	var far := kind("robber", Vector3(10, 0, 0))
	var cues: Array = []
	s.cue.connect(func(k, _at, _r): cues.append(k))
	await secs(0.3)
	var blessed := 0
	var picked_ok := true
	for i in 6:
		var has_s := DmStatusSet.of(allies[i]) != null and DmStatusSet.of(allies[i]).has(&"sanctified")
		blessed += 1 if has_s else 0
		if has_s != (i < 4):
			picked_ok = false
	check(blessed == 4 and picked_ok, "seraph ward: blesses the 4 most wounded allies (%d blessed)" % blessed)
	check(DmStatusSet.of(far) == null or not DmStatusSet.of(far).has(&"sanctified"), "seraph ward: an ally 10 m away is not blessed")
	check(DmStatusSet.of(s) == null or not DmStatusSet.of(s).has(&"sanctified"), "seraph ward: not itself")
	check(cues.count(&"sanctify") == 4, "seraph ward: a `sanctify` cue per blessed ally")
	check(s.attack_cd > 8.0 and s.attack_cd <= 8.5, "seraph ward spends the cooldown (%.2f s left)" % s.attack_cd)
	var ss0 := DmStatusSet.of(allies[0])
	check(is_equal_approx(ss0.remaining(&"sanctified"), 5.0) or ss0.remaining(&"sanctified") > 4.5, "sanctified lasts ~5 s")
	var hp0: float = allies[0].hp
	DmStatusSet.hit(allies[0], 10.0, dummy)
	check(absf((hp0 - allies[0].hp) - 7.0) < 0.01, "sanctified ally takes x0.7 damage")
	await secs(4.0)
	check(cues.count(&"sanctify") == 4, "seraph ward: no second ward before the cooldown ends")
	await secs(5.0)
	check(cues.count(&"sanctify") >= 5, "seraph ward: blesses again (the two it skipped, or the expired) after 8.5 s")
	# with nobody to bless it curses its target instead, from range, hovering 4 m off
	await new_arena()
	dummy.global_position = Vector3(0, 0, 14)
	var c := kind("seraph", Vector3(0, 0, 4))
	var tel: Array = []
	c.telegraph.connect(func(k, _f, _a, r, sec): tel.append([k, r, sec]))
	var dmg: Array = []
	c.struck.connect(func(_t, d): dmg.append(d))
	var min_d := 99.0
	var start := now()
	while now() - start < 6.0:
		await physics_frame
		min_d = minf(min_d, flat(c.global_position, dummy.global_position))
	check(tel.size() >= 1 and tel[0][0] == &"curse" and is_equal_approx(tel[0][2], 1.3), "seraph with no ally: curse telegraph over 1.3 s")
	check(dmg.size() >= 1 and dmg[0] == 8.0 and min_d > 3.0, "seraph curse hits for 8, keeps its distance (closest %.2f m)" % min_d)
	# silenced: no ward
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var sl := kind("seraph", Vector3(0, 0, 0))
	sl.attack_cd = 0.0
	var al2 := kind("robber", Vector3(2, 0, 0))
	DmStatusSet.ensure(sl).apply(&"silence", dummy, 1, 3.0)
	await secs(2.0)
	check(not DmStatusSet.ensure(al2).has(&"sanctified"), "a silenced seraph does not ward")
	await secs(2.0)
	check(DmStatusSet.ensure(al2).has(&"sanctified"), "...and wards when the silence ends")
	await death_and_net("seraph", "resonant")


## DmEnemyFx plays the curse / flask telegraphs from these kinds' own signals (counting back-ends).
func _t_fx() -> void:
	await new_arena()
	var vf := CountVfx.new()
	var au := CountAudio.new()
	var fxn := DmEnemyFx.new()
	fxn.player_pos = func() -> Vector3: return Vector3(0, 0, 10)
	fxn.vfx = vf
	fxn.audio = au
	root.add_child(fxn)
	dummy.global_position = Vector3(0, 0, 14)
	var d := kind("plague_doctor", Vector3(0, 0, 4))
	var a := kind("acolyte", Vector3(6, 0, 4))
	fxn.watch(d)
	fxn.watch(a)
	await until(func(): return fxn.stats["telegraph"] >= 2, 10.0)
	check(fxn.stats["telegraph"] >= 2, "fx: both casters' telegraphs reached DmEnemyFx (%d)" % fxn.stats["telegraph"])
	check(vf.danger_decals >= 3 and vf.decals.has("ring") and vf.decals.has("disc") and vf.projectiles >= 1, "fx: curse ring + flask disc/ring/lob drawn in Vfx.danger")
	check(int(au.sfx.get("curse", 0)) >= 1 and int(au.sfx.get("tellStrike", 0)) >= 1, "fx: `curse` and `tellStrike` sounds played")
	await until(func(): return fxn.stats["strike"] >= 2, 6.0)
	check(fxn.stats["strike"] >= 2, "fx: impacts reached DmEnemyFx (%d)" % fxn.stats["strike"])
	d.take_damage(9999.0, dummy)
	await ticks(3)
	check(fxn.stats["death"] >= 1, "fx: a death reached DmEnemyFx")
	fxn.queue_free()


## Mixed Cloister crowd: 30 bodies by the spawn weights of the late areas (acolyte 6, templar 8, seraph 6, plague doctor 8, flagellant 8 + 4 robbers
## as ward fodder) around a circling dummy. Median of several samples (the VPS is shared).
func _t_perf() -> void:
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	await new_arena()
	DmEnemy.profile = true
	var mix := ["templar", "plague_doctor", "flagellant", "acolyte", "seraph", "templar", "flagellant", "plague_doctor", "robber", "templar",
		"acolyte", "flagellant", "seraph", "plague_doctor", "templar", "flagellant", "acolyte", "plague_doctor", "templar", "robber",
		"flagellant", "seraph", "plague_doctor", "templar", "flagellant", "acolyte", "robber", "plague_doctor", "templar", "flagellant"]
	var es: Array[DmEnemy] = []
	for i in 30:
		var a := TAU * i / 30.0
		var e := kind(mix[i], Vector3(sin(a) * 11.0, 0, 6.0 + cos(a) * 11.0), {"rng_seed": 100 + i, "leash_range": 80.0})
		DmStatusSet.ensure(e)
		es.append(e)
	dummy.global_position = Vector3(0, 0, 6)
	await secs(1.0)
	var brains: Array = []
	var phys: Array = []
	var procs: Array = []
	var per_kind := {}
	var blows := 0
	for sample in 5:
		DmEnemy.prof_reset()
		var phys_sum := 0.0
		var proc_sum := 0.0
		var frames := 0
		var start := now()
		while now() - start < 3.0:
			var a := (now() - start) * 0.6
			dummy.global_position = Vector3(sin(a) * 3.0, 0, 6.0 + cos(a) * 3.0)
			await physics_frame
			frames += 1
			phys_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
			proc_sum += Performance.get_monitor(Performance.TIME_PROCESS)
		brains.append(float(DmEnemy.prof_brain_us) / maxf(1.0, float(DmEnemy.prof_ticks)))
		phys.append(phys_sum / frames * 1000.0)
		procs.append(proc_sum / frames * 1000.0)
		for k in DmEnemy.prof_kind:
			var v: Array = DmEnemy.prof_kind[k]
			if not per_kind.has(k):
				per_kind[k] = []
			per_kind[k].append(float(v[1]) / maxf(1.0, float(v[0])))
	DmEnemy.profile = false
	var line := ""
	var worst := 0.0
	for k in per_kind:
		var m := median(per_kind[k])
		worst = maxf(worst, m)
		line += " %s %.0f us;" % [k, m]
	var engaged := 0
	for e in es:
		if e.sm.id() != S.IDLE and e.sm.id() != S.RISING:
			engaged += 1
	print("PERF mixed-30 Cloister crowd (median of 5 x 3 s): brain %.1f us/enemy-tick, physics %.2f ms/tick, process %.2f ms/frame, engaged %d/30, %d blows" % [median(brains), median(phys), median(procs), engaged, int(dummy.hits_taken)])
	print("PERF   per kind:", line)
	check(engaged >= 27, "the mixed crowd is engaged (%d/30)" % engaged)
	check(median(brains) < BUDGET_BRAIN_US, "mixed brain cost %.1f us/enemy-tick under %.0f us" % [median(brains), BUDGET_BRAIN_US])
	check(worst < BUDGET_BRAIN_US, "every kind under the %.0f us budget (worst %.1f us)" % [BUDGET_BRAIN_US, worst])
	check(median(phys) < BUDGET_PHYS_MS, "physics tick %.2f ms under %.0f ms" % [median(phys), BUDGET_PHYS_MS])
