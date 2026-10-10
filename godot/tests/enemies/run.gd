extends SceneTree
## Headless suite for godot/enemies (the robber scene pilot). godot --headless --path godot --script res://tests/enemies/run.gd
## Time is stepped in physics ticks (1/60 s) with Engine.time_scale raised so the suite stays quick; assertions are in sim seconds.

const S := DmEnemyState.Id
const DT := 1.0 / 60.0
## Perf budget (headless, 30 robbers chasing, visuals + animation on): mean DmEnemy brain cost per enemy tick. Measured ~40 us on
## this VPS (load avg ~4, mostly move_and_slide); the budget is 150 us (30 x 150 us = 4.5 ms of a 16.7 ms frame, ~27%, the most the enemy brain may take) and total
## physics-process time per frame must stay under 8 ms (headless, includes the physics + navigation servers).
const BUDGET_BRAIN_US := 150.0
## Whole-frame cost (physics tick + process + redraw, DmFrameCost): median budget + a generous cap on the worst frame. A quiet VPS measures ~8 ms /
## 60 ms worst; one stall from another process must not fail the run, a real regression (every frame slower, or a 100+ ms stall in our code) must.
const BUDGET_FRAME_MS := 14.0
const CAP_WORST_FRAME_MS := 150.0

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

func robber(pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var p := {"wander_enabled": false, "rng_seed": 7}
	p.merge(props, true)
	return arena.spawn_robber(pos, p)

func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _run() -> void:
	# Physics deltas are scaled by time_scale, so 360 ticks/s x 6 gives the enemies a normal 1/60 s step at 6x wall speed.
	Engine.physics_ticks_per_second = 360
	Engine.time_scale = 6.0
	DmSimData.ensure()
	await _t_stats()
	await _t_idle_aggro()
	await _t_chase_obstacle()
	await _t_attack()
	await _t_damage_death()
	await _t_leash()
	await _t_net()
	await _t_sim_lod()
	_t_anim_lod()
	await _t_perf()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _t_stats() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var e := robber(Vector3(-20, 0, -20))
	var d: Dictionary = DmSimData.ENEMIES["robber"]
	check(e.max_hp == float(d["hp"]) and e.hp == e.max_hp, "hp from def")
	check(e.damage == float(d["damage"]) and e.attack_range == float(d["attackRange"]), "damage + range from def")
	check(is_equal_approx(e.windup_s, 0.42) and is_equal_approx(e.cooldown_s, 1.3), "windup/cooldown from def")
	check(e.speed >= 2.6 * 0.92 - 0.001 and e.speed <= 2.6 * 1.08 + 0.001, "speed within +-8% of def")
	check(e.creature != null and e.creature.loaded, "creature model loaded")
	check(e.sm.id() == S.IDLE, "starts idle")
	var r := robber(Vector3(-18, 0, -20), {"rising": true})
	check(r.sm.id() == S.RISING, "rising spawn starts in RISING")
	await secs(1.3)
	check(r.sm.id() == S.IDLE, "rise ends in idle after 1.1 s")


func _t_idle_aggro() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)   # 25 m away: beyond aggro 15
	var e := robber(Vector3(0, 0, 8))
	e.home = e.global_position
	await secs(1.5)
	check(e.sm.id() == S.IDLE and e.target == null, "idle while the target is out of aggro range")
	check(e.current_clip().begins_with("idle"), "idle clip plays (%s)" % e.current_clip())
	dummy.global_position = Vector3(0, 0, 8 + 14.0)   # 14 m: inside aggro
	var t := await until(func(): return e.sm.id() == S.CHASE, 1.0)
	check(t >= 0.0, "aggro within 0.3 s sim scan period once the target is inside 15 m (t=%.2f)" % t)
	await secs(0.3)
	check(e.current_clip() in ["walk", "run"], "chase plays a locomotion clip (%s)" % e.current_clip())


func _t_chase_obstacle() -> void:
	await new_arena()
	# Wall: x in [-4, 4], z in [-0.5, 0.5]. Robber and target on opposite sides, 12 m apart (inside aggro).
	var e := robber(Vector3(0, 0, -6))
	dummy.global_position = Vector3(0, 0, 6)
	var max_dx := 0.0
	var inside := false
	var reached := false
	var t0 := 0.0
	var start := now()
	while now() - start < 12.0:
		await physics_frame
		var p := e.global_position
		max_dx = maxf(max_dx, absf(p.x))
		if absf(p.x) < 4.0 and absf(p.z) < 0.5:
			inside = true
		if e.sm.id() == S.ATTACK or flat(p, dummy.global_position) < 1.6:
			reached = true
			t0 = now() - start
			break
	check(reached, "robber reaches the target around the wall (%.1f s)" % t0)
	check(max_dx > 4.0, "it detoured around the wall end (max |x| %.2f)" % max_dx)
	check(not inside, "it never entered the wall")
	# straight run time would be ~12/2.6 = 4.6 s; the detour is allowed to be at most ~2x that
	check(t0 < 10.0, "detour is not absurdly long")


func _t_attack() -> void:
	await new_arena()
	var e := robber(Vector3(0, 0, 14))
	dummy.global_position = Vector3(0, 0, 18)
	var hits: Array[float] = []
	var clock := [0.0]
	e.struck.connect(func(_t, dmg): hits.append(clock[0]); check(dmg == 11.0, "blow damage = def damage (11)"))
	var swings: Array[float] = []
	e.state_changed.connect(func(_p, n): if n == S.ATTACK: swings.append(clock[0]))
	var start := now()
	while now() - start < 9.0:
		clock[0] = now()
		await physics_frame
	check(hits.size() >= 5, "several blows landed in 9 s (%d)" % hits.size())
	check(dummy.hp == dummy.max_hp - 11.0 * dummy.hits_taken and dummy.hits_taken == hits.size(), "dummy lost 11 hp per blow")
	if hits.size() >= 4 and swings.size() >= 4:
		var gaps := 0.0
		for i in range(2, hits.size()):
			gaps += hits[i] - hits[i - 1]
		gaps /= float(hits.size() - 2)
		# The sim starts the cooldown at impact and the next wind-up only when it expires: period = cooldown + wind-up = 1.72 s.
		check(absf(gaps - 1.72) < 0.1, "cadence = cooldown + wind-up = 1.72 s (mean gap %.3f)" % gaps)
		var wind := hits[0] - swings[0]
		check(absf(wind - 0.42) < 0.05, "impact lands one wind-up (0.42 s) after the swing starts (%.3f)" % wind)
	var dist := flat(e.global_position, dummy.global_position)
	check(dist <= 1.3 * 1.35 + 0.4 and dist > 0.5, "stands inside strike reach (%.2f m)" % dist)
	# Out of reach at the impact: step the target away during the wind-up, no damage is dealt.
	var n0 := dummy.hits_taken
	await until(func(): return e.sm.id() == S.ATTACK, 3.0)
	dummy.global_position += Vector3(0, 0, 4)
	await secs(0.5)
	check(dummy.hits_taken == n0, "a swing whose target stepped out of reach deals nothing")


func _t_damage_death() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var e := robber(Vector3(-20, 0, -20))
	var died := [0]
	e.died.connect(func(_x): died[0] += 1)
	check(e.take_damage(10.0, dummy), "take_damage applies")
	check(e.hp == 58.0, "hp 68 -> 58")
	check(e.sm.id() == S.HURT, "a hit staggers an idle robber")
	check(e.current_clip().begins_with("hurt"), "flinch clip plays (%s)" % e.current_clip())
	await secs(0.5)
	check(e.sm.id() != S.HURT, "flinch ends")
	e.take_damage(5.0, dummy)
	check(e.sm.id() != S.HURT, "second hit inside the stagger cooldown does not re-flinch")
	# attack is not cancelled by plain damage
	var a := robber(Vector3(-20, 0, 20))
	dummy.global_position = Vector3(-20, 0, 21)
	await until(func(): return a.sm.id() == S.ATTACK, 4.0)
	a.take_damage(3.0, dummy)
	check(a.sm.id() == S.ATTACK, "plain damage does not cancel a swing")
	a.stun(0.5)
	check(a.sm.id() == S.HURT, "stun interrupts a swing")
	# death
	e.take_damage(1000.0, dummy)
	check(e.sm.id() == S.DEAD and died[0] == 1, "lethal damage -> DEAD, died emitted once")
	check(e.current_clip().begins_with("death"), "death clip plays (%s)" % e.current_clip())
	check(e.collision_layer == 0, "corpse stops colliding")
	check(not e.take_damage(5.0, dummy) and died[0] == 1, "dead enemies ignore damage")
	var pos := e.global_position
	await secs(0.5)
	check(e.global_position.is_equal_approx(pos), "corpse does not move")
	var c := robber(Vector3(-22, 0, -20), {"corpse_s": 0.3})
	c.take_damage(999.0)
	await secs(0.6)
	check(not is_instance_valid(c), "corpse_s frees the body")


func _t_leash() -> void:
	await new_arena()
	var e := robber(Vector3(-20, 0, 20), {"rng_seed": 11})
	e.home = e.global_position
	dummy.global_position = Vector3(-20, 0, 20 - 12)
	await until(func(): return e.sm.id() == S.CHASE, 2.0)
	check(e.sm.id() == S.CHASE, "chasing before the leash test")
	await secs(1.0)
	dummy.global_position = Vector3(25, 0, -25)   # runs far away
	var t := await until(func(): return e.sm.id() == S.RETURN, 2.0)
	check(t >= 0.0, "target beyond 1.5 x aggro -> RETURN (%.2f s)" % t)
	check(e.target == null, "target dropped")
	t = await until(func(): return e.sm.id() == S.IDLE, 25.0)
	check(t >= 0.0, "back home and idle (%.1f s)" % t)
	check(e.flat_dist_home() <= 1.2, "ended within 1.2 m of home (%.2f)" % e.flat_dist_home())
	# ignores a target while returning (no kiting)
	dummy.global_position = Vector3(-20, 0, 12)
	await secs(1.0)
	check(e.sm.id() == S.CHASE, "re-aggros once idle at home with a target in range")


func _t_net() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var host := robber(Vector3(-5, 0, -20))
	host.take_damage(8.0)
	var s := host.get_net_state()
	host.set_physics_process(false)   # the pup lands on the host's spot; keep the host from swinging at the dummy
	check(s.has_all(["pos", "yaw", "state", "hp", "anim"]), "net state has pos/yaw/state/hp/anim")
	var pup := robber(Vector3(20, 0, 20), {"with_visual": true})
	pup.set_multiplayer_authority(2)
	check(not pup.is_multiplayer_authority(), "puppet is not authority")
	pup.apply_net_state(s)
	check(pup.global_position.is_equal_approx(host.global_position), "first snapshot snaps the position")
	var s2 := pup.get_net_state()
	check(s2["state"] == s["state"] and s2["hp"] == s["hp"] and is_equal_approx(float(s2["yaw"]), float(s["yaw"])), "state/hp/yaw round-trip")
	check(pup.current_clip().begins_with("hurt"), "puppet plays the replicated hurt clip (%s)" % pup.current_clip())
	# puppet brain is off: a target next to it does not trigger a swing or a blow
	dummy.global_position = pup.global_position + Vector3(0, 0, 1)
	var hits_before := dummy.hits_taken
	await secs(2.5)
	check(pup.sm.id() == S.HURT and dummy.hits_taken == hits_before, "non-authority never runs the brain (state %d, hits %d->%d)" % [pup.sm.id(), hits_before, dummy.hits_taken])
	check(not pup.take_damage(5.0, dummy) and pup.hp == 60.0, "non-authority ignores take_damage")
	# interpolation toward a moved snapshot
	var moved := {"pos": pup.global_position + Vector3(3, 0, 0), "yaw": 1.0, "state": S.CHASE, "hp": 60.0, "anim": "walk"}
	pup.apply_net_state(moved)
	await secs(0.8)
	check(flat(pup.global_position, moved["pos"]) < 0.05, "puppet eases to the new position")
	check(pup.sm.id() == S.CHASE, "puppet adopts the replicated state")
	pup.apply_net_state({"pos": pup.global_position, "yaw": 0.0, "state": S.DEAD, "hp": 0.0, "anim": "death"})
	check(pup.current_clip().begins_with("death") and pup.collision_layer == 0, "puppet dead: death clip + no collision")


## 30 robbers (ring of 11 m around (0,6)) chase a dummy that circles at 3 m. Returns the measurements over `dur` sim seconds.
func _perf_run(props: Dictionary, dur: float) -> Dictionary:
	await new_arena()
	DmEnemy.profile = true
	var es: Array[DmEnemy] = []
	for i in 30:
		var a := TAU * i / 30.0
		var p := {"rng_seed": 100 + i, "leash_range": 80.0}
		p.merge(props, true)
		es.append(robber(Vector3(sin(a) * 11.0, 0, 6.0 + cos(a) * 11.0), p))
	dummy.max_hp = 1.0e9
	dummy.hp = dummy.max_hp
	dummy.global_position = Vector3(0, 0, 6)
	await secs(1.0)    # warm-up: aggro + first paths
	DmEnemy.prof_reset()
	var fc := DmFrameCost.attach(root)
	var start := now()
	while now() - start < dur:
		var a := (now() - start) * 0.6
		dummy.global_position = Vector3(sin(a) * 3.0, 0, 6.0 + cos(a) * 3.0)
		await physics_frame
	if not fc.stalls.is_empty():
		print("PERF   stalls [wall ms, cpu ms, load1]: ", fc.stalls)
	fc.queue_free()
	var engaged := 0
	for e in es:
		if e.sm.id() == S.CHASE or e.sm.id() == S.ATTACK:
			engaged += 1
	DmEnemy.profile = false
	return {"brain": float(DmEnemy.prof_brain_us) / maxf(1.0, float(DmEnemy.prof_ticks)), "nav": float(DmEnemy.prof_nav_us) / maxf(1.0, float(DmEnemy.prof_ticks)),
		"repaths": DmEnemy.prof_repaths, "scans": DmEnemy.prof_scans, "frame_ms": fc.median_ms(), "p95_ms": fc.p95_ms(), "worst_ms": fc.worst_busy_ms(),
		"engaged": engaged, "blows": dummy.hits_taken}

func _t_perf() -> void:
	# Real-time stepping (60 ticks/s, scale 1) so the engine's physics-process monitor is a per-tick number.
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	var m: Dictionary = await _perf_run({}, 6.0)
	print("PERF 30 robbers (nav + avoidance + visuals): brain %.1f us/enemy-tick (nav part %.1f us), repaths %d (%.1f/s total), scans %d, frame median %.2f ms (p95 %.2f, worst %.2f), engaged %d/30, %d blows"
		% [m.brain, m.nav, m.repaths, m.repaths / 6.0, m.scans, m.frame_ms, m.p95_ms, m.worst_ms, m.engaged, m.blows])
	check(m.engaged >= 27, "the pack is engaged (%d/30)" % m.engaged)
	check(m.brain < BUDGET_BRAIN_US, "brain cost %.1f us/enemy-tick under %.0f us" % [m.brain, BUDGET_BRAIN_US])
	check(m.frame_ms < BUDGET_FRAME_MS and m.worst_ms < CAP_WORST_FRAME_MS, "frame median %.2f ms under %.0f ms, worst %.1f ms under %.0f ms" % [m.frame_ms, BUDGET_FRAME_MS, m.worst_ms, CAP_WORST_FRAME_MS])
	check(m.repaths <= 30 * 6 * 4, "repaths staggered (<= 4/s per enemy, %d)" % m.repaths)
	for v in [["no avoidance", {"use_avoidance": false}], ["no visuals", {"with_visual": false}], ["no nav (straight)", {"use_nav": false, "use_avoidance": false}]]:
		var r: Dictionary = await _perf_run(v[1], 3.0)
		print("PERF   variant %-18s brain %.1f us, frame median %.2f ms" % [v[0], r.brain, r.frame_ms])


## Simulation LOD: an idle body far from every target thinks at a fraction of the tick rate; one inside the LOD radius (still outside aggro) does not.
func _t_sim_lod() -> void:
	await new_arena()
	dummy.global_position = Vector3(0, 0, 25)
	var far := robber(Vector3(-5, 0, -25), {"leash_range": 80.0})   # 50 m from the dummy
	var near := robber(Vector3(18, 0, 25), {"leash_range": 80.0})    # 18 m: beyond aggro (15), inside IDLE_LOD_FAR
	await ticks(20)
	var counts := {}
	for e: DmEnemy in [far, near]:
		far.set_physics_process(e == far)   # the profile counters are global: one body at a time
		near.set_physics_process(e == near)
		DmEnemy.profile = true
		DmEnemy.prof_reset()
		await ticks(120)
		counts[e] = DmEnemy.prof_ticks
		DmEnemy.profile = false
	DmEnemy.profile = false
	check(far.sm.id() == DmEnemyState.Id.IDLE and near.sm.id() == DmEnemyState.Id.IDLE, "sim LOD: both bodies stay idle")
	check(int(counts[far]) <= 120 / DmEnemy.IDLE_LOD_TICKS + 2 and int(counts[far]) >= 120 / DmEnemy.IDLE_LOD_TICKS - 2, "sim LOD: a far idle body ticks every %dth tick (%d of 120)" % [DmEnemy.IDLE_LOD_TICKS, counts[far]])
	check(int(counts[near]) == 120, "sim LOD: an idle body inside the radius keeps the full rate (%d of 120)" % counts[near])
	check(not far.agent.avoidance_enabled and near.agent.avoidance_enabled, "sim LOD: avoidance is off only for the far idle body")
	# the hero walks up: the far body returns to full rate and chases
	far.set_physics_process(true)
	dummy.global_position = far.global_position + Vector3(6, 0, 0)
	await secs(1.5)
	check(far.sm.id() == DmEnemyState.Id.CHASE and far.agent.avoidance_enabled, "sim LOD: a hero in range wakes the body (chase, avoidance back on)")


## Animation LOD measures from the point the camera looks at: everything on screen updates every frame, the band outside ~30 Hz, the rest ~10 Hz.
func _t_anim_lod() -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	for zoom: float in [1.0, 1.45]:
		var dist: float = 22.0 * zoom
		cam.global_position = Vector3(3.0, dist * 0.82, 3.0 + dist * 0.6)
		cam.look_at(Vector3(3.0, 0.0, 3.0), Vector3.UP)
		check(DmCreature.lod_interval(cam, Vector3(3.0, 0.0, 3.0)) == 0.0, "anim LOD x%.2f: a body at the hero updates every frame" % zoom)
		check(DmCreature.lod_interval(cam, Vector3(3.0 + 14.0, 0.0, 3.0 - 10.0)) == 0.0, "anim LOD x%.2f: a body at the screen edge updates every frame" % zoom)
		check(DmCreature.lod_interval(cam, Vector3(3.0 + 60.0 * zoom, 0.0, 3.0)) > 0.0, "anim LOD x%.2f: a body far off screen is throttled" % zoom)
	cam.free()
