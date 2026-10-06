extends SceneTree
## Headless suite for the Ossuary / Nave / Sanctum / Coliseum kinds: deacon, golem, wraith, gargoyle (godot/enemies/<kind>.tscn).
## godot --headless --path godot --script res://tests/enemies/cathedral_run.gd
## Same stepping conventions as kinds_run.gd: physics ticks, Engine.time_scale raised, assertions in sim seconds.

const S := DmEnemyState.Id
const DT := 1.0 / 60.0
## Perf (headless, 30 mixed cathedral bodies engaged with a circling target, visuals on): mean DmEnemy brain cost per enemy tick, the MEDIAN of
## SAMPLES runs (the VPS is shared). Same 150 us budget as the Graves crowd; the Deacon's 0.25 s corpse / Sanctify scan is timed separately.
const BUDGET_BRAIN_US := 150.0
## Whole-frame cost (DmFrameCost: physics + process + redraw): budget on the median of the samples, generous cap on the worst frame.
const BUDGET_FRAME_MS := 16.0
const CAP_WORST_FRAME_MS := 150.0
const BUDGET_SCAN_US := 150.0
const SAMPLES := 3
const PILOT_ROBBER_US := 73.0   ## the pilot suite's robber brain cost on this VPS (kinds_run.gd PERF line); the box's slowdown = this run's robber cost / it, never below 1x
const REL_KIND := 3.0            ## each cathedral kind may cost at most this x the robber in the same run

var passed := 0
var failed := 0
var arena: DmEnemyTestArena
var dummy: DmTargetDummy
var field: DmCorpseField


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

func new_arena(with_field: bool = false) -> void:
	if arena != null:
		root.remove_child(arena)
		arena.free()
	arena = load("res://enemies/test_arena.tscn").instantiate()
	arena.robber_count = 0
	root.add_child(arena)
	dummy = arena.target
	dummy.controllable = false
	dummy.max_hp = 1.0e9
	dummy.hp = dummy.max_hp
	arena.get_node("NavRegion/Wall").free()   # the arena's centre wall (the navmesh keeps its cut-out, which only shapes long paths)
	field = null
	if with_field:
		field = DmCorpseField.new()
		field.name = "Corpses"
		field.visuals = false
		field.auto_step = false
		arena.add_child(field)
	await ticks(3)

func kind(def_id: String, pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var p := {"wander_enabled": false, "rng_seed": 7}
	p.merge(props, true)
	return arena.spawn_kind(def_id, pos, p)

func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## Record every telegraph of `e` as [kind, from, aim, radius, seconds, time].
func rec_telegraphs(e: DmEnemy) -> Array:
	var out := []
	e.telegraph.connect(func(k: StringName, f: Vector3, a: Vector3, r: float, s: float) -> void: out.append([String(k), f, a, r, s, now()]))
	return out

func rec_hits(e: DmEnemy) -> Array:
	var out := []
	e.struck.connect(func(_t: Node3D, d: float) -> void: out.append([d, now()]))
	return out

func net_roundtrip(def_id: String) -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
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
	pup.apply_net_state({"pos": pup.global_position, "yaw": 0.0, "state": S.DEAD, "hp": 0.0, "anim": "death"})
	check(pup.collision_layer == 0, "%s: puppet dead stops colliding" % def_id)


func _run() -> void:
	Engine.physics_ticks_per_second = 360
	Engine.time_scale = 6.0
	DmSimData.ensure()
	await _t_golem()
	await _t_wraith()
	await _t_gargoyle()
	await _t_deacon()
	await _t_perf()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ======================================================================================================================= golem

func _t_golem() -> void:
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("golem", Vector3(0, 0, 0))
	check(e is DmEnemyHazard and e.max_hp == 430.0 and e.damage == 26.0 and e.attack_range == 2.1, "golem: hazard kind, hp 430 / damage 26 / range 2.1")
	check(is_equal_approx(e.windup_s, 0.95) and is_equal_approx(e.cooldown_s, 2.7), "golem: windup 0.95 / cooldown 2.7")
	check(e.speed >= 1.5 * 0.92 - 0.001 and e.speed <= 1.5 * 1.08 + 0.001 and is_equal_approx(e.scale.x, 1.0), "golem: speed ~1.5 (%.2f), scale 1" % e.speed)
	check((e as DmEnemyHazard).slam_radius() == 2.8 and e.corpse_kind == "normal" and e.creature != null and e.creature.loaded, "golem: slam radius 2.8, model loaded")
	# slam: telegraph at the aim fixed at wind-up start, radius 2.8, lands after 0.95 s on everything inside the ring
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 3.0)
	var d2 := DmTargetDummy.new()
	d2.controllable = false
	d2.position = Vector3(0, 0, 3.0 + 2.5)   # inside the ring when the aim is at the first dummy
	arena.add_child(d2)
	var d3 := DmTargetDummy.new()
	d3.controllable = false
	d3.position = Vector3(0, 0, 3.0 + 3.4)
	arena.add_child(d3)
	var g := kind("golem", Vector3(0, 0, 0))
	g.attack_cd = 0.0
	var tl := rec_telegraphs(g)
	var hits := rec_hits(g)
	await until(func(): return not tl.is_empty(), 6.0)
	check(not tl.is_empty() and tl[0][0] == "slam" and is_equal_approx(tl[0][3], 2.8) and is_equal_approx(tl[0][4], 0.95), "golem: telegraph slam r 2.8 over 0.95 s")
	var aim0: Vector3 = tl[0][2] if not tl.is_empty() else Vector3.ZERO
	check(flat(aim0, dummy.global_position) < 0.1, "golem: aim = where the target stood at wind-up start")
	await until(func(): return hits.size() >= 2, 3.0)
	check(hits.size() == 2 and hits[0][0] == 26.0, "golem: the slam hits both bodies inside the ring for 26 (%d hits)" % hits.size())
	check(d3.hits_taken == 0, "golem: a body 3.4 m past the aim (outside 2.8) is untouched")
	if not hits.is_empty() and not tl.is_empty():
		check(absf((hits[0][1] - tl[0][5]) - 0.95) < 0.12, "golem: blow lands %.2f s after the telegraph" % (hits[0][1] - tl[0][5]))
	# death: three corpses (its own + 2 risen on the ring), tracked by the corpse field
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var v := kind("golem", Vector3(0, 0, 0))
	field.track(v)
	v.take_damage(9999.0)
	await secs(0.2)
	var kinds := {}
	for c: DmSimCorpse in field.corpses.values():
		kinds[c.enemy] = int(kinds.get(c.enemy, 0)) + 1
	check(field.count() == 3 and kinds.get("golem", 0) == 1 and kinds.get("risen", 0) == 2, "golem: death leaves 3 corpses (golem + 2 risen): %s" % [kinds])
	await net_roundtrip("golem")


# ======================================================================================================================= wraith

func _t_wraith() -> void:
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("wraith", Vector3(0, 0, 0))
	check(e is DmEnemyCaster and e.max_hp == 58.0 and e.damage == 17.0 and e.attack_range == 9.0, "wraith: caster kind, hp 58 / damage 17 / range 9")
	check(is_equal_approx(e.windup_s, 1.25) and is_equal_approx(e.cooldown_s, 3.6) and e.attack_kind == "scream", "wraith: windup 1.25 / cooldown 3.6 / scream")
	check(e.corpse_kind == "none" and e.corpse_s > 0.0 and is_equal_approx(e.scale.x, 1.1) and e.flying == 0.45, "wraith: no corpse, scale 1.1, hovers 0.45")
	check(e.creature != null and e.creature.loaded and e.creature.opts.get("spectral", false) and e.creature.opts.get("emissive", 0) == 0x9fb6d8, "wraith: spectral look, pale emissive")
	# keeps range: starts 14 m away, walks in until within attackRange - 0.5, casts from there
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 14)
	var w := kind("wraith", Vector3(0, 0, 0))
	w.attack_cd = 0.0
	var tl := rec_telegraphs(w)
	var hits := rec_hits(w)
	await until(func(): return not tl.is_empty(), 12.0)
	check(not tl.is_empty() and tl[0][0] == "scream" and is_equal_approx(tl[0][3], 2.2) and is_equal_approx(tl[0][4], 1.25), "wraith: telegraph scream r 2.2 over 1.25 s")
	var cast_d := flat(w.global_position, dummy.global_position)
	check(cast_d <= 8.55 and cast_d > 6.0, "wraith: casts from range (%.1f m)" % cast_d)
	# the ring sits on where the target stood: standing still takes it, stepping out (> 2.2 m) dodges it
	var aim0: Vector3 = tl[0][2] if not tl.is_empty() else Vector3.ZERO
	check(flat(aim0, dummy.global_position) < 0.1, "wraith: aim = target position at wind-up start")
	dummy.global_position += Vector3(4.0, 0, 0)
	await secs(1.6)
	check(hits.is_empty(), "wraith: stepping out of the ring dodges the scream")
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 7)
	var w2 := kind("wraith", Vector3(0, 0, 0))
	w2.attack_cd = 0.0
	var hits2 := rec_hits(w2)
	await until(func(): return not hits2.is_empty(), 6.0)
	check(not hits2.is_empty() and hits2[0][0] == 17.0, "wraith: standing in the ring takes 17")
	# dies: no corpse, the body crumbles away (the dissolve is DmEnemyFx's)
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var v := kind("wraith", Vector3(0, 0, 0))
	field.track(v)
	v.take_damage(999.0)
	await secs(0.3)
	check(field.count() == 0 and v.sm.id() == S.DEAD, "wraith: dies without a corpse")
	await secs(3.0)
	check(not is_instance_valid(v), "wraith: body freed after the fall")
	await net_roundtrip("wraith")


# ======================================================================================================================= gargoyle

func _t_gargoyle() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("gargoyle", Vector3(0, 0, 0))
	check(e is DmEnemyGargoyle and e.max_hp == 150.0 and e.damage == 14.0 and e.attack_range == 1.4, "gargoyle: hp 150 / damage 14 / range 1.4")
	check(is_equal_approx(e.windup_s, 0.9) and is_equal_approx(e.cooldown_s, 3.4) and e.flying == 1.1 and e.corpse_kind == "normal", "gargoyle: windup 0.9 / cooldown 3.4 / hover 1.1 / normal corpse")
	check(e.creature != null and e.creature.loaded, "gargoyle: model loaded")
	# dive: target 7 m out in the open -> telegraph "dive" r 2 over 0.9 s at the target, the body drops onto it, blow on landing
	await new_arena()
	dummy.global_position = Vector3(20, 0, 8)
	var g := kind("gargoyle", Vector3(20, 0, 1))
	g.attack_cd = 0.0
	var tl := rec_telegraphs(g)
	var hits := rec_hits(g)
	await until(func(): return not tl.is_empty(), 4.0)
	check(not tl.is_empty() and tl[0][0] == "dive" and is_equal_approx(tl[0][3], 2.0) and is_equal_approx(tl[0][4], 0.9), "gargoyle: telegraph dive r 2 over 0.9 s")
	var aim0: Vector3 = tl[0][2] if not tl.is_empty() else Vector3.ZERO
	var start_p := g.global_position
	check(flat(aim0, dummy.global_position) < 0.1 and g.diving, "gargoyle: aim = target, diving flag set")
	await secs(0.3)
	check(flat(g.global_position, start_p) < 0.1, "gargoyle: hangs still over its start for the first half of the wind-up")
	var peak: float = (g.get_node("Visual") as Node3D).position.y
	check(peak > 1.1 + 0.4, "gargoyle: climbs during the first half (visual y %.2f)" % peak)
	await secs(0.35)
	var mid_d := flat(g.global_position, aim0)
	check(mid_d < flat(start_p, aim0) and mid_d > 0.1, "gargoyle: drops toward the mark in the second half (%.1f m left)" % mid_d)
	await until(func(): return not hits.is_empty(), 2.0)
	check(not hits.is_empty() and hits[0][0] == 14.0 and flat(g.global_position, aim0) < 0.1, "gargoyle: lands on the mark and hits for 14")
	check(not tl.is_empty() and absf((hits[0][1] - tl[0][5]) - 0.9) < 0.12, "gargoyle: blow %.2f s after the telegraph" % ((hits[0][1] - tl[0][5]) if not hits.is_empty() else -1.0))
	# grounded: stays in the swing state for 0.3 + 1.4 s, then goes back to chasing
	await secs(1.3)
	check(g.sm.id() == S.ATTACK, "gargoyle: still grounded 1.3 s after landing")
	await secs(0.6)
	check(g.sm.id() != S.ATTACK and not g.diving, "gargoyle: back on the hunt ~1.9 s after landing (%d)" % g.sm.id())
	# no dive inside minRange: a target at 2 m gets bitten (no telegraph) within the melee reach
	await new_arena()
	dummy.global_position = Vector3(20, 0, 2.0)
	var b := kind("gargoyle", Vector3(20, 0, 0))
	b.attack_cd = 0.0
	var tl2 := rec_telegraphs(b)
	var hits2 := rec_hits(b)
	await until(func(): return not hits2.is_empty(), 4.0)
	check(tl2.is_empty() and not hits2.is_empty() and hits2[0][0] == 14.0, "gargoyle: close target is bitten, no dive telegraph")
	# a wall between: no dive (the sim's wall_between); it walks round / flanks instead
	await new_arena()
	var wall := StaticBody3D.new()
	wall.collision_layer = DmEnemy.LAYER_WORLD
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(10, 4, 0.5)
	cs.shape = bx
	cs.position.y = 2.0
	wall.add_child(cs)
	wall.position = Vector3(20, 0, 4.0)
	arena.add_child(wall)
	await ticks(3)
	dummy.global_position = Vector3(20, 0, 8)
	var c := kind("gargoyle", Vector3(20, 0, 0))
	c.attack_cd = 0.0
	var tl3 := rec_telegraphs(c)
	await secs(0.6)
	check(tl3.is_empty() and not c.diving, "gargoyle: no dive through a wall")
	# puppet: the replicated ATTACK + dv flag draws the same dive telegraph, shortened by the lead time
	await new_arena()
	var p := kind("gargoyle", Vector3(0, 0, 0))
	p.set_multiplayer_authority(2)
	p.set_physics_process(false)
	var tl4 := rec_telegraphs(p)
	p.apply_net_state({"pos": Vector3(0, 0, 0), "yaw": 0.0, "state": S.ATTACK, "hp": p.hp, "anim": "dive", "aim": Vector3(2, 0, 6), "t": 0.2, "dv": true})
	check(tl4.size() == 1 and tl4[0][0] == "dive" and absf(tl4[0][4] - 0.7) < 0.01 and tl4[0][2] == Vector3(2, 0, 6), "gargoyle puppet: dive telegraph with 0.7 s left")
	await net_roundtrip("gargoyle")
	await new_arena()
	var h := kind("gargoyle", Vector3(0, 0, 0))
	h.diving = true
	check(h.get_net_state().get("dv", false) == true, "gargoyle: dv flag in the net state")


# ======================================================================================================================= deacon

func _t_deacon() -> void:
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("deacon", Vector3(0, 0, 0))
	check(e is DmEnemyDeacon and is_equal_approx(e.max_hp, 112.0) and e.damage == 9.0 and e.attack_range == 6.0, "deacon: hp 112 / damage 9 / range 6")
	check(is_equal_approx(e.windup_s, 1.5) and is_equal_approx(e.cooldown_s, 5.5) and is_equal_approx(e.scale.x, 1.15) and e.corpse_kind == "normal", "deacon: windup 1.5 / cooldown 5.5 / scale 1.15 / normal corpse")
	check(e.creature != null and e.creature.loaded and e.model_slug == "deacon", "deacon: deacon model loaded")
	# curse: with a target in reach, a 1.5 s wind-up (telegraph "curse"), then one blow; it stands at 4-5.5 m and backs off when closer than 4 m
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 5.0)
	var d := kind("deacon", Vector3(0, 0, 0))
	d.attack_cd = 0.0
	var tl := rec_telegraphs(d)
	var hits := rec_hits(d)
	await until(func(): return not tl.is_empty(), 4.0)
	check(not tl.is_empty() and tl[0][0] == "curse" and is_equal_approx(tl[0][4], 1.5) and flat(tl[0][2], dummy.global_position) < 0.1, "deacon: telegraph curse over 1.5 s on the target")
	await until(func(): return not hits.is_empty(), 3.0)
	check(not hits.is_empty() and hits[0][0] == 9.0 and absf((hits[0][1] - tl[0][5]) - 1.5) < 0.15, "deacon: curse lands after 1.5 s for 9")
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 2.0)
	var bk := kind("deacon", Vector3(0, 0, 0))
	bk.attack_cd = 99.0
	var y0 := bk.global_position.z
	await secs(1.5)
	check(flat(bk.global_position, dummy.global_position) > 3.0 and bk.global_position.z < y0 - 0.5, "deacon: backs away from a target inside 4 m")
	# raise: a corpse within 8 m (no target needed) -> 1.5 s channel with the "raise" telegraph at the corpse, then the corpse is consumed
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var r := kind("deacon", Vector3(0, 0, 0))
	r.attack_cd = 0.0
	var c := field.add_corpse(0.0, 6.0, "normal", "robber", false, 0.0, 1.0, "graves")
	var tr := rec_telegraphs(r)
	var raised := []
	r.raised.connect(func(at: Vector3) -> void: raised.append(at))
	await until(func(): return not tr.is_empty(), 2.0)
	check(not tr.is_empty() and tr[0][0] == "raise" and is_equal_approx(tr[0][4], 1.5) and absf(tr[0][2].z - 6.0) < 0.01 and r.sm.id() == S.ATTACK, "deacon: channel with a raise telegraph on the corpse (1.5 s)")
	check(field.count() == 1, "deacon: the corpse is still there during the channel")
	await until(func(): return not raised.is_empty(), 3.0)
	check(not raised.is_empty() and field.count() == 0 and absf(raised[0].z - 6.0) < 0.01 and absf(r.attack_cd - 5.5) < 1.7, "deacon: the corpse is consumed (raised) and the cooldown restarts")
	# a corpse taken during the channel (a necromancer exhumed it) raises nothing
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var r2 := kind("deacon", Vector3(0, 0, 0))
	r2.attack_cd = 0.0
	var c2 := field.add_corpse(0.0, 5.0, "normal", "robber", false, 0.0, 1.0, "graves")
	var raised2 := []
	r2.raised.connect(func(at: Vector3) -> void: raised2.append(at))
	await until(func(): return r2.sm.id() == S.ATTACK, 2.0)
	field.consume(c2.id, 1, "consumed")
	await secs(2.0)
	check(raised2.is_empty(), "deacon: nothing is raised from a corpse that was taken mid-channel")
	# sanctify: the most wounded other ally within 6 m gets `sanctified` (x0.7 damage taken, 5 s); cooldown x0.6; deacons and the unhurt are skipped
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 40)
	var s := kind("deacon", Vector3(0, 0, 0))
	s.attack_cd = 0.0
	var a1 := kind("robber", Vector3(2, 0, 0), {"leash_range": 80.0})
	var a2 := kind("robber", Vector3(-3, 0, 0))
	var a3 := kind("robber", Vector3(0, 0, 9))      # out of reach
	var other := kind("deacon", Vector3(0, 0, -2))   # never blessed
	other.attack_cd = 99.0
	a1.hp = a1.max_hp * 0.6
	a2.hp = a2.max_hp * 0.3                         # the most wounded in reach
	a3.hp = a3.max_hp * 0.1
	var cues := []
	s.cue.connect(func(k: StringName, at: Vector3, _r: float) -> void: cues.append([k, at]))
	await until(func(): return not cues.is_empty(), 2.0)
	var st2 := DmStatusSet.of(a2)
	check(not cues.is_empty() and cues[0][0] == &"sanctify" and st2 != null and st2.has(&"sanctified"), "deacon: sanctifies the most wounded ally in reach")
	check(absf(st2.remaining(&"sanctified") - 5.0) < 0.5 and is_equal_approx(st2.damage_taken_mult(), 0.7), "deacon: sanctified lasts 5 s, damage taken x0.7")
	check(DmStatusSet.of(a1) == null or not DmStatusSet.of(a1).has(&"sanctified"), "deacon: one ally per cast")
	check(DmStatusSet.of(a3) == null and DmStatusSet.of(other) == null, "deacon: nothing for an ally out of reach or another deacon")
	check(absf(s.attack_cd - 5.5 * 0.6) < 0.5, "deacon: cooldown x0.6 after a sanctify (%.2f)" % s.attack_cd)
	# silenced deacons do nothing
	await new_arena(true)
	dummy.global_position = Vector3(0, 0, 5)
	var q := kind("deacon", Vector3(0, 0, 0))
	q.attack_cd = 0.0
	var qa := kind("robber", Vector3(2, 0, 0))
	qa.hp = 10.0
	DmStatusSet.ensure(q).apply(&"silence", null, 1, 10.0)
	var qt := rec_telegraphs(q)
	await secs(1.0)
	check(qt.is_empty() and (DmStatusSet.of(qa) == null or not DmStatusSet.of(qa).has(&"sanctified")), "deacon: a silenced deacon neither curses, raises nor blesses")
	await net_roundtrip("deacon")
	# puppet: ATTACK + rz draws the raise thread
	await new_arena()
	var p := kind("deacon", Vector3(0, 0, 0))
	p.set_multiplayer_authority(2)
	p.set_physics_process(false)
	var tp := rec_telegraphs(p)
	p.apply_net_state({"pos": Vector3.ZERO, "yaw": 0.0, "state": S.ATTACK, "hp": p.hp, "anim": "cast", "aim": Vector3(1, 0, 5), "t": 0.5, "rz": true})
	check(tp.size() == 1 and tp[0][0] == "raise" and absf(tp[0][4] - 1.0) < 0.01, "deacon puppet: raise telegraph with 1.0 s left")


# ======================================================================================================================= perf

## 30 mixed cathedral bodies (golem 3, deacon 6, wraith 6, gargoyle 6, robber 9) around a circling target; per-enemy brain cost from
## DmEnemy.prof_*, median of SAMPLES runs. Plus the Deacon's scan on its own.
func _t_perf() -> void:
	var slows: Array[float] = []
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	var brains: Array[float] = []
	var frames_med: Array[float] = []
	var frames_worst: Array[float] = []
	var worsts: Array[float] = []
	var line := ""
	var engaged := 0
	for sample in SAMPLES:
		await new_arena(true)
		DmEnemy.profile = true
		var mix := ["robber", "deacon", "wraith", "gargoyle", "golem", "robber", "wraith", "gargoyle", "deacon", "robber", "wraith", "gargoyle", "robber", "deacon",
			"wraith", "gargoyle", "golem", "robber", "wraith", "deacon", "gargoyle", "robber", "wraith", "gargoyle", "deacon", "robber", "golem", "deacon", "robber", "wraith"]
		var es: Array[DmEnemy] = []
		for i in 30:
			var a := TAU * i / 30.0
			es.append(kind(mix[i], Vector3(sin(a) * 11.0, 0, 6.0 + cos(a) * 11.0), {"rng_seed": 100 + i, "leash_range": 80.0}))
		dummy.global_position = Vector3(0, 0, 6)
		field.add_corpse(3.0, 4.0, "normal", "robber", false, 0.0, 1.0, "graves")
		await secs(1.0)
		DmEnemy.prof_reset()
		var fc := DmFrameCost.attach(root)
		var start := now()
		while now() - start < 5.0:
			var a := (now() - start) * 0.6
			dummy.global_position = Vector3(sin(a) * 3.0, 0, 6.0 + cos(a) * 3.0)
			await physics_frame
		fc.queue_free()
		DmEnemy.profile = false
		var rob: Array = DmEnemy.prof_kind.get("robber", [1, 0])
		var rob_us := float(rob[1]) / maxf(1.0, float(rob[0]))
		var slow := maxf(1.0, rob_us / PILOT_ROBBER_US)
		slows.append(slow)
		brains.append(float(DmEnemy.prof_brain_us) / maxf(1.0, float(DmEnemy.prof_ticks)) / slow)   # normalised to the pilot's box speed
		frames_med.append(fc.median_ms())
		frames_worst.append(fc.worst_busy_ms())
		var worst := 0.0
		line = ""
		for k in DmEnemy.prof_kind:
			var v: Array = DmEnemy.prof_kind[k]
			var us := float(v[1]) / maxf(1.0, float(v[0]))
			if k != "robber":
				worst = maxf(worst, us / maxf(1.0, rob_us))
			line += " %s %.0f us;" % [k, us]
		worsts.append(worst)
		engaged = 0
		for e in es:
			if e.sm.id() != S.IDLE and e.sm.id() != S.RISING:
				engaged += 1
	brains.sort()
	frames_med.sort()
	frames_worst.sort()
	worsts.sort()
	# the Deacon's corpse / Sanctify scan against 30 bodies, per call
	var dc: DmEnemyDeacon = null
	for n in arena.get_children():
		if n is DmEnemyDeacon:
			dc = n
			break
	var t0 := Time.get_ticks_usec()
	for i in 500:
		dc.sanctify_target()
		dc._nearest_corpse()
	slows.sort()
	var scan_us := float(Time.get_ticks_usec() - t0) / 500.0 / slows[1]
	print("PERF mixed-30 cathedral crowd (median of %d, normalised to the pilot's box speed; slowdown x%.1f): brain %.1f us/enemy-tick, frame median %.2f ms (worst %.1f), engaged %d/30, deacon scan %.1f us/call (every 0.25 s)" % [SAMPLES, slows[1], brains[1], frames_med[1], frames_worst[1], engaged, scan_us])
	print("PERF   per kind (last sample):", line)
	check(engaged >= 27, "the mixed crowd is engaged (%d/30)" % engaged)
	check(brains[1] < BUDGET_BRAIN_US, "mixed brain cost %.1f us/enemy-tick under %.0f us" % [brains[1], BUDGET_BRAIN_US])
	check(worsts[1] < REL_KIND, "every cathedral kind within %.0fx the robber (worst %.1fx)" % [REL_KIND, worsts[1]])
	check(frames_med[1] < BUDGET_FRAME_MS and frames_worst[1] < CAP_WORST_FRAME_MS, "frame median %.2f ms under %.0f ms, worst %.1f ms under %.0f ms" % [frames_med[1], BUDGET_FRAME_MS, frames_worst[1], CAP_WORST_FRAME_MS])
	check(scan_us < BUDGET_SCAN_US, "deacon scan %.1f us under %.0f us" % [scan_us, BUDGET_SCAN_US])
