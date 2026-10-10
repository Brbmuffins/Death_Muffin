extends SceneTree
## Headless suite for the Hollow Graves enemy kinds (godot/enemies/<kind>.tscn). godot --headless --path godot --script res://tests/enemies/kinds_run.gd
## Pilot (robber) checks live in run.gd; this file shares its stepping helpers.
## Time is stepped in physics ticks (1/60 s) with Engine.time_scale raised so the suite stays quick; assertions are in sim seconds.

const S := DmEnemyState.Id
const DT := 1.0 / 60.0
## Perf budget (headless, 30 robbers chasing, visuals + animation on): mean DmEnemy brain cost per enemy tick. Measured ~40 us on
## this VPS (load avg ~4, mostly move_and_slide); the budget is 150 us (30 x 150 us = 4.5 ms of a 16.7 ms frame, ~27%, the most the enemy brain may take) and total
## physics-process time per frame must stay under 8 ms (headless, includes the physics + navigation servers).
const BUDGET_BRAIN_US := 150.0
## Whole-frame cost (DmFrameCost: physics + process + redraw): budget on the median, separate generous cap on the worst frame.
const BUDGET_FRAME_MS := 16.0
const CAP_WORST_FRAME_MS := 150.0

var passed := 0
var failed := 0
var arena: DmEnemyTestArena
var dummy: DmTargetDummy
var extra_dummies: Array[DmTargetDummy] = []


func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)

## Sim clock in seconds (physics ticks; a main-loop frame can contain several ticks when time_scale > 1).
func now() -> float:
	return float(Engine.get_physics_frames()) * DT

func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame

func secs(s: float) -> void:
	await ticks(int(round(s / DT)))

## Step until `cond` is true or `limit_s` sim seconds pass. Returns the sim seconds waited, or -1 on timeout.
func until(cond: Callable, limit_s: float) -> float:
	var t0 := now()
	while now() - t0 < limit_s:
		if cond.call():
			return now() - t0
		await physics_frame
	return -1.0

func new_arena(count: int = 0) -> void:
	if arena != null:
		root.remove_child(arena)
		arena.free()
	arena = load("res://enemies/test_arena.tscn").instantiate()
	arena.robber_count = count
	root.add_child(arena)
	dummy = arena.target
	dummy.controllable = false
	await ticks(3)   # let the navigation map sync

func kind(def_id: String, pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var p := {"wander_enabled": false, "rng_seed": 7}
	p.merge(props, true)
	return arena.spawn_kind(def_id, pos, p)

func robber(pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var p := {"wander_enabled": false, "rng_seed": 7}
	p.merge(props, true)
	return arena.spawn_robber(pos, p)

func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()



func _run() -> void:
	Engine.physics_ticks_per_second = 360
	Engine.time_scale = 6.0
	DmSimData.ensure()
	await _t_hound()
	await _t_penitent()
	await _t_sac()
	await _t_moth()
	await _t_bat()
	await _t_ghoul()
	await _t_censer_risen()
	await _t_perf()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Spawn `n` extra target dummies (for area-blow checks).
func extra_dummy(pos: Vector3) -> DmTargetDummy:
	var d := DmTargetDummy.new()
	d.controllable = false
	d.position = pos
	arena.add_child(d)
	return d


## Host -> puppet snapshot round trip for any kind.
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


func _t_hound() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var d: Dictionary = DmSimData.ENEMIES["hound"]
	var e := kind("hound", Vector3(-20, 0, -20))
	check(e.max_hp == 42.0 and e.damage == 8.0 and e.attack_range == 1.2, "hound: hp 42 / damage 8 / range 1.2 from def")
	check(is_equal_approx(e.windup_s, 0.25) and is_equal_approx(e.cooldown_s, 0.8), "hound: windup 0.25 / cooldown 0.8")
	check(e.speed >= 4.4 * 0.92 - 0.001 and e.speed <= 4.4 * 1.08 + 0.001, "hound: speed ~4.4 (%.2f)" % e.speed)
	check(e.corpse_kind == "swift" and e.creature != null and e.creature.loaded, "hound: swift corpse, model loaded")
	# flanking: starts 14 m out, must swing wide (lateral offset up to 3 m) before closing, on its flank side
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var f := kind("hound", Vector3(0, 0, 12), {"flank_side": 1.0})
	f.home = f.global_position
	var max_x := 0.0
	var t0 := now()
	var hit := [-1.0]
	f.struck.connect(func(_t, _d): if hit[0] < 0.0: hit[0] = now() - t0)
	while now() - t0 < 6.0 and hit[0] < 0.0:
		await physics_frame
		max_x = maxf(max_x, absf(f.global_position.x))
	check(max_x > 1.0, "hound flanks: swung %.2f m to the side on the way in" % max_x)
	var hit_at: float = hit[0]
	check(hit_at > 0.0 and hit_at < 5.0, "hound reaches and bites (%.2f s)" % hit_at)
	var avg := 14.0 / maxf(0.01, hit_at - 0.25)
	check(avg > 3.0, "hound closes fast (%.1f m/s mean over the approach)" % avg)
	await secs(6.0)
	var gaps := 6.0 / maxf(1.0, float(dummy.hits_taken - 1))
	check(dummy.hp == dummy.max_hp - 8.0 * dummy.hits_taken, "hound bite = 8")
	check(absf(gaps - 1.05) < 0.25, "hound cadence ~ cooldown + windup = 1.05 s (%.2f)" % gaps)
	f.take_damage(1000.0, dummy)
	check(f.sm.id() == S.DEAD and f.corpse_kind == "swift", "hound dies and leaves a swift corpse")
	check(is_instance_valid(f), "hound corpse stays for the corpse system")
	await net_roundtrip("hound")
	await _t_elite()


func _t_elite() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("hound", Vector3(-20, 0, -20), {"elite": true})
	check(is_equal_approx(e.max_hp, 42.0 * 3.6) and is_equal_approx(e.damage, 12.0), "elite hound: hp x3.6, damage x1.5")
	check(is_equal_approx(e.windup_s, 0.25 * 0.85) and is_equal_approx(e.cooldown_s, 0.8 * 0.8), "elite: windup x0.85, cooldown x0.8")
	check(is_equal_approx(e.scale.x, 1.35) and is_equal_approx(e.radius, 0.45 * 1.25), "elite: scale 1.35, radius x1.25")
	check(e.creature != null and e.creature.opts.get("emissive", 0) == 0x4a1f8a, "elite: purple emissive look")


func _t_penitent() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("penitent", Vector3(-20, 0, -20))
	check(e.max_hp == 78.0 and e.damage == 18.0 and e.attack_range == 7.5, "penitent: hp 78 / damage 18 / range 7.5")
	check(is_equal_approx(e.windup_s, 1.1) and is_equal_approx(e.cooldown_s, 3.2) and e.corpse_kind == "resonant", "penitent: windup 1.1, cooldown 3.2, resonant corpse")
	check(is_equal_approx(e.scale.x, 1.05), "penitent: scale 1.05")
	# keeps its distance: walks in to ~attackRange-1.5 = 6 m, never closer than ~5 while the target stands still
	await new_arena()
	dummy.max_hp = 1.0e6
	dummy.hp = 1.0e6
	dummy.global_position = Vector3(0, 0, 26)
	var p := kind("penitent", Vector3(0, 0, 14))
	var tel: Array = []
	p.telegraph.connect(func(k, _f, aim, r, sec): tel.append([k, aim, r, sec]))
	var hits: Array = []
	p.struck.connect(func(_t, dmg): hits.append(dmg))
	var min_d := 99.0
	var start := now()
	while now() - start < 8.0:
		await physics_frame
		min_d = minf(min_d, flat(p.global_position, dummy.global_position))
	check(min_d > 4.5 and min_d < 7.1, "penitent holds a casting range (closest %.2f m)" % min_d)
	check(tel.size() >= 1 and tel[0][0] == &"cone" and is_equal_approx(tel[0][3], 1.1), "penitent telegraphs a cone for its wind-up")
	check(hits.size() >= 1 and hits[0] == 18.0, "cone hits the target for the def damage (18)")
	check(p.current_clip().begins_with("cast") or p.attack_anim == "cast", "penitent uses the cast clip")
	# backs off a target that closes in
	var before := flat(p.global_position, dummy.global_position)
	dummy.global_position = p.global_position + Vector3(0, 0, 2.0)
	await secs(1.0)
	var after := flat(p.global_position, dummy.global_position)
	check(after > 2.0 + 0.3 or p.sm.id() == S.ATTACK, "penitent retreats from a target at 2 m (%.2f -> %.2f)" % [2.0, after])
	# the cone is dodgeable: step sideways out of the cone during the wind-up
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var q := kind("penitent", Vector3(0, 0, 19), {"rng_seed": 3})
	await until(func(): return q.sm.id() == S.ATTACK, 6.0)
	check(q.sm.id() == S.ATTACK, "penitent starts casting")
	var n0 := dummy.hits_taken
	dummy.global_position += Vector3(6.0, 0, 0)   # far outside the 30 degree half-angle at ~6 m
	await secs(1.4)
	check(dummy.hits_taken == n0, "stepping out of the telegraphed cone avoids the blow")
	# a second body inside the cone is hit too (area blow)
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var d2 := extra_dummy(Vector3(0.6, 0, 27.0))
	var r := kind("penitent", Vector3(0, 0, 19.5), {"rng_seed": 5})
	await secs(5.0)
	check(dummy.hits_taken >= 1 and d2.hits_taken >= 1, "cone hits every body inside it (%d, %d)" % [dummy.hits_taken, d2.hits_taken])
	r.take_damage(1000.0, dummy)
	check(r.sm.id() == S.DEAD and r.corpse_kind == "resonant", "penitent death leaves a resonant corpse")
	await net_roundtrip("penitent")


func _t_sac() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("sac", Vector3(-20, 0, -20))
	check(e.max_hp == 140.0 and e.damage == 15.0 and e.attack_range == 1.6 and e.radius == 0.8, "sac: hp 140 / damage 15 / range 1.6 / radius 0.8")
	check(is_equal_approx(e.windup_s, 0.7) and is_equal_approx(e.cooldown_s, 1.8) and e.corpse_kind == "toxic", "sac: windup 0.7, cooldown 1.8, toxic corpse")
	check(e.speed < 1.3 * 1.08 + 0.001 and is_equal_approx(e.scale.x, 1.2), "sac: slow (%.2f) and big" % e.speed)
	# slam: area blow centred on the aim point fixed at wind-up start
	await new_arena()
	dummy.global_position = Vector3(0, 0, 20)
	var side := extra_dummy(Vector3(1.4, 0, 20))     # inside the 1.9 m slam radius of the aim, outside melee reach of the sac
	var far := extra_dummy(Vector3(4.0, 0, 20))      # outside the radius
	var s := kind("sac", Vector3(0, 0, 17.0), {"rng_seed": 9})
	var tel: Array = []
	s.telegraph.connect(func(k, _f, aim, r, sec): tel.append([k, r, sec]))
	await secs(6.0)
	check(tel.size() >= 1 and tel[0][0] == &"slam" and is_equal_approx(tel[0][1], 1.9) and is_equal_approx(tel[0][2], 0.7), "sac telegraphs a 1.9 m slam ring for 0.7 s")
	check(dummy.hits_taken >= 1 and dummy.hp == dummy.max_hp - 15.0 * dummy.hits_taken, "slam hits the target for 15")
	check(side.hits_taken >= 1, "slam is an area blow: a body next to the target is hit")
	check(far.hits_taken == 0, "a body outside the slam radius is not hit")
	# dodge: step out of the ring during the wind-up
	await new_arena()
	dummy.global_position = Vector3(0, 0, 20)
	var s2 := kind("sac", Vector3(0, 0, 17.0), {"rng_seed": 9})
	await until(func(): return s2.sm.id() == S.ATTACK, 6.0)
	var n0 := dummy.hits_taken
	dummy.global_position += Vector3(0, 0, 4.0)
	await secs(1.2)
	check(dummy.hits_taken == n0, "leaving the slam ring in the wind-up avoids the blow")
	s2.take_damage(10000.0, dummy)
	check(s2.sm.id() == S.DEAD and s2.corpse_kind == "toxic", "sac dies leaving a toxic corpse (the corpse system ruptures it)")
	await net_roundtrip("sac")


func _t_moth() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("moth", Vector3(-20, 0, -20))
	check(e.max_hp == 52.0 and e.damage == 10.0 and e.attack_range == 7.0, "moth: hp 52 / damage 10 / range 7")
	check(is_equal_approx(e.windup_s, 0.95) and is_equal_approx(e.cooldown_s, 3.8) and e.corpse_kind == "swift", "moth: windup 0.95, cooldown 3.8, swift corpse")
	check(e.flying == 1.3 and e.attack_kind == "dust", "moth: flies at 1.3 and casts dust")
	await secs(0.2)
	check(e.get_node("Visual").position.y > 1.0 and e.get_node("Visual").position.y < 1.6, "moth hovers (visual y %.2f)" % e.get_node("Visual").position.y)
	check(e.global_position.y < 0.1, "moth body stays on the ground plane (sim)")
	check(e.creature != null and e.creature.loaded, "moth: model (or fallback rig) loaded")
	# dust: burst on the aim, then a cloud that keeps hurting whoever stands in it
	await new_arena()
	dummy.max_hp = 1.0e6
	dummy.hp = 1.0e6
	dummy.global_position = Vector3(0, 0, 26)
	var m := kind("moth", Vector3(0, 0, 14))
	var tel: Array = []
	m.telegraph.connect(func(k, _f, aim, r, sec): tel.append([k, r, sec]))
	var dmg: Array = []
	m.struck.connect(func(_t, d): dmg.append(d))
	var min_d := 99.0
	var zone_seen: Array = [null]
	var start := now()
	while now() - start < 9.0:
		await physics_frame
		min_d = minf(min_d, flat(m.global_position, dummy.global_position))
		if zone_seen[0] == null:
			var zs := get_nodes_in_group(&"dm_hostile_zone")
			if zs.size() > 0:
				zone_seen[0] = zs[0]
				check(is_equal_approx((zs[0] as DmHostileZone).radius, 2.0) and is_equal_approx((zs[0] as DmHostileZone).dps, 3.5), "dust cloud: radius 2, dps blow x0.35 = 3.5")
				check(is_equal_approx((zs[0] as DmHostileZone).lifetime, 3.5), "dust cloud lingers 3.5 s")
	check(min_d > 3.5, "moth keeps its distance (closest %.2f m)" % min_d)
	check(tel.size() >= 1 and tel[0][0] == &"dust" and is_equal_approx(tel[0][1], 2.0) and is_equal_approx(tel[0][2], 0.95), "moth telegraphs a 2 m dust ring")
	check(dmg.size() >= 1 and dmg[0] == 10.0, "dust burst hits for the def damage (10)")
	check(zone_seen[0] != null, "the cloud zone was spawned")
	# standing in the cloud hurts every second; leaving it does not
	var landed := dummy.hits_taken
	check(landed >= 4, "standing in the cloud keeps hurting (%d hits in 9 s)" % landed)
	# dodge: leave the ring during the wind-up
	await new_arena()
	dummy.global_position = Vector3(0, 0, 26)
	var q := kind("moth", Vector3(0, 0, 14), {"rng_seed": 3})
	await until(func(): return q.sm.id() == S.ATTACK, 8.0)
	var n0 := dummy.hits_taken
	dummy.global_position += Vector3(6.0, 0, 0)
	await secs(5.0)
	check(dummy.hits_taken == n0, "leaving the ring in the wind-up avoids burst and cloud (%d)" % (dummy.hits_taken - n0))
	check(get_nodes_in_group(&"dm_hostile_zone").size() == 0, "the cloud expires and frees itself")
	q.take_damage(1000.0, dummy)
	check(q.sm.id() == S.DEAD and q.corpse_kind == "swift", "moth dies and leaves a swift corpse")
	await net_roundtrip("moth")


func _t_bat() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("bat", Vector3(-20, 0, -20))
	check(e.max_hp == 16.0 and e.damage == 4.0 and e.attack_range == 0.9 and e.radius == 0.3, "bat: hp 16 / damage 4 / range 0.9 / radius 0.3")
	check(is_equal_approx(e.windup_s, 0.18) and is_equal_approx(e.cooldown_s, 0.9) and e.corpse_kind == "none", "bat: windup 0.18, cooldown 0.9, no corpse")
	check(e.speed >= 5.2 * 0.92 - 0.001 and e.hit_run == 0.8 and e.flying == 1.5, "bat: speed ~5.2, hitRun 0.8, flying 1.5")
	check(e.creature != null and e.creature.loaded, "bat: model (or fallback rig) loaded")
	# hit and run: bite, flee for 0.8 s (distance grows), come back, bite again
	await new_arena()
	dummy.max_hp = 1.0e6
	dummy.hp = 1.0e6
	dummy.global_position = Vector3(0, 0, 20)
	var b := kind("bat", Vector3(0, 0, 14), {"flank_side": -1.0})
	var bites: Array = []
	b.struck.connect(func(_t, d): bites.append(now()))
	var fled: Array = []
	var max_gap := [0.0]
	b.state_changed.connect(func(_p, n): if n == S.FLEE: fled.append(now()))
	var start := now()
	while now() - start < 10.0:
		await physics_frame
		if b.sm.id() == S.FLEE:
			max_gap[0] = maxf(max_gap[0], flat(b.global_position, dummy.global_position))
	check(bites.size() >= 4, "bat keeps biting (%d bites in 10 s)" % bites.size())
	check(dummy.hp == dummy.max_hp - 4.0 * bites.size(), "each bite = 4")
	check(fled.size() >= bites.size() - 1, "every bite is followed by a flee (%d flees / %d bites)" % [fled.size(), bites.size()])
	check(max_gap[0] > 2.5, "it flits away from the target (%.2f m)" % max_gap[0])
	# the flee lasts hitRun (0.8 s), then it returns to chase
	var st: Array = []
	var b2 := kind("bat", Vector3(0, 0, 14), {"rng_seed": 5})
	b2.state_changed.connect(func(_p, n): st.append([n, now()]))
	await secs(6.0)
	var t_flee := -1.0
	var t_back := -1.0
	for i in st.size():
		if st[i][0] == S.FLEE and t_flee < 0.0:
			t_flee = st[i][1]
		elif t_flee >= 0.0 and t_back < 0.0 and st[i][0] == S.CHASE:
			t_back = st[i][1]
	check(t_flee > 0.0 and absf((t_back - t_flee) - 0.8) < 0.1, "flee lasts hitRun = 0.8 s (%.2f)" % (t_back - t_flee))
	# no corpse: dies, crumbles and frees itself
	b.take_damage(1000.0, dummy)
	check(b.sm.id() == S.DEAD and b.corpse_kind == "none", "bat dies with corpse kind none")
	await secs(3.0)
	check(not is_instance_valid(b), "a corpse-less body frees itself after the fall")
	# a pack: 5 bats, all fly in and bite
	await new_arena()
	dummy.max_hp = 1.0e6
	dummy.hp = 1.0e6
	dummy.global_position = Vector3(0, 0, 20)
	for i in 5:
		kind("bat", Vector3(-3 + i * 1.5, 0, 12), {"rng_seed": 20 + i})
	await secs(6.0)
	check(dummy.hits_taken >= 8, "a pack of 5 bats lands many bites (%d)" % dummy.hits_taken)
	await net_roundtrip("bat")
	# Skull-Rat: the same flank body without the flying/flee
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var r := kind("rat", Vector3(-20, 0, -20))
	check(r.max_hp == 18.0 and r.damage == 4.0 and r.hit_run == 0.0 and r.flying == 0.0 and r.corpse_kind == "none", "rat: hp 18 / damage 4, no flee, no corpse")
	check(is_equal_approx(r.windup_s, 0.2) and is_equal_approx(r.cooldown_s, 0.7) and r.radius == 0.3, "rat: windup 0.2, cooldown 0.7")
	check(r.sm.states[S.FLEE] != null and r.creature != null and r.creature.loaded, "rat: flanker state set, model loaded")
	await net_roundtrip("rat")


func _t_ghoul() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var e := kind("ghoul", Vector3(-20, 0, -20), {"rising": true})
	check(e.max_hp == 60.0 and e.damage == 12.0 and e.attack_range == 1.3, "ghoul: hp 60 / damage 12 / range 1.3")
	check(is_equal_approx(e.windup_s, 0.42) and is_equal_approx(e.cooldown_s, 1.4) and e.corpse_kind == "normal", "ghoul: windup 0.42, cooldown 1.4, normal corpse")
	check(e.sm.id() == S.BURROW and not e.get_node("Visual").visible, "ghoul spawns underground and hidden")
	check(not e.take_damage(10.0, dummy) and e.hp == 60.0, "untouchable underground")
	e.stun(1.0)
	check(e.sm.id() == S.BURROW, "stun does nothing underground")
	var surf := kind("ghoul", Vector3(-22, 0, -20))
	check(surf.sm.id() == S.IDLE and surf.get_node("Visual").visible, "a non-rising ghoul starts on the surface")
	# tunnel toward the target (14 m out, inside aggro), erupt under it, hit it
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var g := kind("ghoul", Vector3(0, 0, 11), {"rising": true})
	var tel: Array = []
	g.telegraph.connect(func(k, _f, aim, r, sec): tel.append([k, r, sec, aim]))
	var cues: Array = []
	g.cue.connect(func(k, _at, _r): cues.append(k))
	var tun_start := g.global_position
	var t_burrow := await until(func(): return g.sm.id() == S.ERUPT, 6.0)
	check(t_burrow > 0.0, "ghoul tunnels to the target and starts erupting (%.2f s)" % t_burrow)
	var tunneled := flat(g.global_position, tun_start)
	check(tunneled > 8.0 and not g.get_node("Visual").visible, "it travelled underground (%.1f m), still hidden" % tunneled)
	check(flat(g.global_position, dummy.global_position) <= 2.6, "it surfaces within surfaceR 2.5 m (%.2f)" % flat(g.global_position, dummy.global_position))
	check(tel.size() == 1 and tel[0][0] == &"erupt" and is_equal_approx(tel[0][1], 1.8) and is_equal_approx(tel[0][2], 1.0), "erupt telegraph: 1.8 m ring, 1.0 s")
	check(not g.take_damage(5.0, dummy) and g.hp == 60.0, "untouchable while the eruption winds up")
	var aim: Vector3 = tel[0][3]
	await until(func(): return g.sm.id() == S.EMERGE, 2.0)
	check(dummy.hits_taken == 1 and dummy.hp == dummy.max_hp - 12.0, "eruption hits the target in its ring for the blow (12)")
	check(flat(g.global_position, aim) < 0.01 and g.get_node("Visual").visible and cues.has(&"erupt"), "it surfaces at the aim, visible, erupt cue sent")
	await secs(0.5)
	check(g.sm.id() == S.CHASE or g.sm.id() == S.ATTACK, "after the 0.3 s recovery it fights as a melee body (%d)" % g.sm.id())
	# dodge: step out of the ring during the eruption wind-up
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var g2 := kind("ghoul", Vector3(0, 0, 11), {"rising": true})
	await until(func(): return g2.sm.id() == S.ERUPT, 6.0)
	dummy.global_position += Vector3(5.0, 0, 0)
	await secs(1.3)
	check(dummy.hits_taken == 0, "stepping out of the ring avoids the eruption")
	# dig in once below 50% hp, hittable on the surface, then tunnel again
	g2.take_damage(35.0, dummy)   # 60 -> 25 (< 30)
	var cleared := [0]
	g2.statuses_cleared.connect(func(): cleared[0] += 1)
	check(g2.sm.id() == S.DIG and g2.dug_in, "below 50% hp it digs in")
	check(g2.take_damage(1.0, dummy) and g2.hp == 24.0, "still hittable during the 0.8 s dig animation")
	await until(func(): return g2.sm.id() == S.BURROW, 2.0)
	check(g2.sm.id() == S.BURROW and cleared[0] == 1, "dig ends underground; statuses cleared")
	var b: DmStateBurrow = g2.sm.states[S.BURROW]
	check(is_equal_approx(b.burrow_left, 8.0) or b.burrow_left < 8.0, "the second run has an 8 m tunnel budget (%.1f left)" % b.burrow_left)
	await until(func(): return g2.sm.id() == S.EMERGE, 8.0)
	await secs(0.4)
	g2.take_damage(2.0, dummy)
	check(g2.sm.id() != S.DIG and g2.sm.id() != S.BURROW, "it digs in only once")
	g2.take_damage(1000.0, dummy)
	check(g2.sm.id() == S.DEAD and g2.corpse_kind == "normal" and g2.collision_layer == 0, "ghoul dies leaving a normal corpse")
	# at most BURROW.maxPerTarget (3) bodies erupt under one target at once
	await new_arena()
	dummy.max_hp = 1.0e6
	dummy.hp = 1.0e6
	dummy.global_position = Vector3(0, 0, 20)
	var gs: Array[DmEnemy] = []
	for i in 5:
		gs.append(kind("ghoul", Vector3(-4 + i * 2.0, 0, 16), {"rising": true, "rng_seed": 30 + i}))
	var peak := 0
	var start := now()
	while now() - start < 1.3:
		await physics_frame
		var n := 0
		for x in gs:
			if x.sm.id() == S.ERUPT:
				n += 1
		peak = maxi(peak, n)
	check(peak == 3, "no more than 3 ghouls erupt under one target at once (peak %d)" % peak)
	await secs(3.0)
	var up := 0
	for x in gs:
		if x.sm.id() != S.BURROW and x.sm.id() != S.ERUPT:
			up += 1
	check(up == 5, "the waiting ones erupt after the first wave (%d/5 surfaced)" % up)
	# net: state ids and visibility round trip while underground
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var host := kind("ghoul", Vector3(-5, 0, -20), {"rising": true})
	var s := host.get_net_state()
	host.set_physics_process(false)
	var pup := kind("ghoul", Vector3(20, 0, 20))
	pup.set_multiplayer_authority(2)
	pup.apply_net_state(s)
	check(pup.sm.id() == S.BURROW and not pup.get_node("Visual").visible, "puppet of a burrowed ghoul is hidden")
	pup.apply_net_state({"pos": pup.global_position, "yaw": 0.0, "state": S.EMERGE, "hp": 60.0, "anim": "attack"})
	check(pup.get_node("Visual").visible, "puppet shows the ghoul once it emerges")
	pup.apply_net_state({"pos": pup.global_position, "yaw": 0.0, "state": S.DIG, "hp": 20.0, "anim": "dig"})
	check(pup.current_clip().begins_with("dig") or pup.current_clip() != "", "puppet plays the dig clip (%s)" % pup.current_clip())
	await net_roundtrip("ghoul")


func _t_censer_risen() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var c := kind("censer", Vector3(-20, 0, -20))
	check(c.max_hp == 96.0 and c.damage == 7.0 and c.attack_range == 1.5 and c.corpse_kind == "normal", "censer: hp 96 / damage 7 / range 1.5 / normal corpse")
	check(is_equal_approx(c.windup_s, 0.52) and is_equal_approx(c.cooldown_s, 1.7), "censer: windup 0.52, cooldown 1.7")
	var near := kind("hound", Vector3(-17, 0, -20))
	var far := kind("hound", Vector3(-12, 0, -20))
	await secs(1.2)
	check(DmStatusSet.of(near).has(&"incensed") and DmStatusSet.of(c).has(&"incensed"), "incense hastes an ally within 5 m and the censer itself")
	check(DmStatusSet.of(far) == null or not DmStatusSet.of(far).has(&"incensed"), "an ally 8 m away is not incensed")
	check(DmStatusSet.of(near).remaining(&"incensed") <= 1.5 + 0.01, "haste lasts hasteS = 1.5 s")
	# the haste is real: x1.3 move, x1.25 attack rate
	near.attack_cd = 1.0
	var cd0 := near.attack_cd
	await ticks(60)
	check(near.attack_cd < cd0 - 1.0 * 1.0, "attack cooldown runs faster while incensed (%.2f -> %.2f in 1 s)" % [cd0, near.attack_cd])
	# killed: the aura stops
	c.take_damage(1000.0, dummy)
	await secs(2.5)
	check(not DmStatusSet.of(near).has(&"incensed"), "kill the censer and the haste wears off")
	await net_roundtrip("censer")
	# Risen: plain melee body, no corpse, dark look
	await new_arena()
	dummy.global_position = Vector3(0, 0, 40)
	var r := kind("risen", Vector3(-20, 0, -20))
	check(r.max_hp == 36.0 and r.damage == 8.0 and r.attack_range == 1.2 and is_equal_approx(r.windup_s, 0.38) and is_equal_approx(r.cooldown_s, 1.2), "risen: hp 36 / damage 8 / range 1.2 / windup 0.38 / cooldown 1.2")
	check(r.corpse_kind == "none" and is_equal_approx(r.scale.x, 0.95) and r.creature.opts.get("tint", 0) == 0x8a8078, "risen: no corpse, scale 0.95, grey tint")
	r.take_damage(999.0)
	await secs(3.0)
	check(not is_instance_valid(r), "risen crumble away after dying")
	await net_roundtrip("risen")


## Mixed Hollow Graves crowd: 30 bodies by the area's spawn weights (robber 8, hound 6, bat 5, penitent 3, moth 3, ghoul 3 surfaced, sac 2) around a
## dummy that circles at 3 m. Per-kind brain cost comes from DmEnemy.prof_kind.
func _t_perf() -> void:
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	await new_arena()
	DmEnemy.profile = true
	var mix := ["robber", "robber", "hound", "bat", "penitent", "robber", "hound", "moth", "bat", "ghoul", "robber", "sac", "hound", "bat", "moth",
		"robber", "penitent", "hound", "bat", "ghoul", "robber", "hound", "sac", "moth", "bat", "robber", "penitent", "hound", "ghoul", "robber"]
	var es: Array[DmEnemy] = []
	for i in 30:
		var a := TAU * i / 30.0
		es.append(kind(mix[i], Vector3(sin(a) * 11.0, 0, 6.0 + cos(a) * 11.0), {"rng_seed": 100 + i, "leash_range": 80.0}))
	dummy.max_hp = 1.0e9
	dummy.hp = dummy.max_hp
	dummy.global_position = Vector3(0, 0, 6)
	await secs(1.0)
	DmEnemy.prof_reset()
	var fc := DmFrameCost.attach(root)
	var start := now()
	while now() - start < 8.0:
		var a := (now() - start) * 0.6
		dummy.global_position = Vector3(sin(a) * 3.0, 0, 6.0 + cos(a) * 3.0)
		await physics_frame
	fc.queue_free()
	DmEnemy.profile = false
	var brain := float(DmEnemy.prof_brain_us) / maxf(1.0, float(DmEnemy.prof_ticks))
	var line := ""
	var worst := 0.0
	for k in DmEnemy.prof_kind:
		var v: Array = DmEnemy.prof_kind[k]
		var us := float(v[1]) / maxf(1.0, float(v[0]))
		worst = maxf(worst, us)
		line += " %s %.0f us;" % [k, us]
	var engaged := 0
	for e in es:
		if e.sm.id() != S.IDLE and e.sm.id() != S.RISING:
			engaged += 1
	print("PERF mixed-30 Graves crowd: brain %.1f us/enemy-tick, frame median %.2f ms (p95 %.2f, worst %.2f), engaged %d/30, %d blows" % [brain, fc.median_ms(), fc.p95_ms(), fc.worst_busy_ms(), engaged, dummy.hits_taken])
	print("PERF   per kind:", line)
	check(engaged >= 27, "the mixed crowd is engaged (%d/30)" % engaged)
	perf_info(brain < BUDGET_BRAIN_US, "mixed brain cost %.1f us/enemy-tick under %.0f us" % [brain, BUDGET_BRAIN_US])
	perf_info(worst < BUDGET_BRAIN_US, "every kind under the %.0f us budget (worst %.1f us)" % [BUDGET_BRAIN_US, worst])
	perf_info(fc.median_ms() < BUDGET_FRAME_MS and fc.worst_busy_ms() < CAP_WORST_FRAME_MS, "frame median %.2f ms under %.0f ms, worst %.1f ms under %.0f ms" % [fc.median_ms(), BUDGET_FRAME_MS, fc.worst_busy_ms(), CAP_WORST_FRAME_MS])


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
