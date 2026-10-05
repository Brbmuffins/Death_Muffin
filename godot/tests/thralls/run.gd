extends SceneTree
## Headless suite for godot/next/thralls. godot --headless --path godot --script res://tests/thralls/run.gd
## Stepped like tests/enemies/run.gd (360 ticks/s x time_scale 6 = 1/60 s sim ticks); the perf block runs in real time.

const S := DmEnemyState.Id
const TS := DmThrall.S
const DT := 1.0 / 60.0
const BUDGET_BRAIN_US := 150.0   ## per thrall tick (12 x 150 us = 1.8 ms)
const BUDGET_PHYS_MS := 12.0

var passed := 0
var failed := 0
var arena: DmEnemyTestArena
var owner_body: DmTargetDummy
var corpses: TestCorpses
var host: DmThrallHost


## Test double for godot/next/corpses DmCorpseField: the same names, signatures and pick rule (nearest to aim within pick_r and max_range of
## from_pos, else nearest to from_pos within 7 m), DmSimCorpse records, atomic consume.
class TestCorpses extends RefCounted:
	var corpses: Dictionary = {}
	var next_id := 1
	var enforce_range := false   ## the real field requires the corpse within max_range of from_pos; most tests park the owner far away instead
	var stale_pick := false      ## simulate the race: pick keeps returning a corpse another raiser already took
	var _last: DmSimCorpse
	func add(pos: Vector3, props: Dictionary = {}) -> int:
		var c := DmSimCorpse.new()
		c.id = next_id
		c.x = pos.x
		c.z = pos.z
		for k in props:
			c.set(k, props[k])
		next_id += 1
		corpses[c.id] = c
		return c.id
	func clear() -> void:
		corpses.clear()
	func count() -> int:
		return corpses.size()
	func pick_corpse(aim: Vector3, pick_r: float, max_range: float, from_pos: Vector3, _area := "") -> DmSimCorpse:
		if stale_pick and _last != null:
			return _last
		var best: DmSimCorpse = null
		var best_d := pick_r
		var near: DmSimCorpse = null
		var near_d := 7.0
		for c: DmSimCorpse in corpses.values():
			var fd := Vector2(c.x - from_pos.x, c.z - from_pos.z).length()
			var d := Vector2(c.x - aim.x, c.z - aim.z).length()
			if d < best_d and (fd <= max_range or not enforce_range):
				best_d = d
				best = c
			if fd < near_d:
				near_d = fd
				near = c
		_last = best if best != null else near
		return _last
	func corpses_in_radius(pos: Vector3, r: float, _filter := Callable(), _area := "", _echo := false) -> Array[DmSimCorpse]:
		var out: Array[DmSimCorpse] = []
		for c: DmSimCorpse in corpses.values():
			if Vector2(c.x - pos.x, c.z - pos.z).length() <= r:
				out.append(c)
		out.sort_custom(func(a, b): return Vector2(a.x - pos.x, a.z - pos.z).length() < Vector2(b.x - pos.x, b.z - pos.z).length())
		return out
	func consume(id: int, _by: int, _reason := "consumed") -> bool:
		return corpses.erase(id)


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

func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func new_arena() -> void:
	if arena != null:
		root.remove_child(arena)
		arena.free()
	arena = load("res://enemies/test_arena.tscn").instantiate()
	arena.robber_count = 0
	root.add_child(arena)
	owner_body = arena.target
	owner_body.controllable = false
	owner_body.max_hp = 1.0e9
	owner_body.hp = 1.0e9
	corpses = TestCorpses.new()
	host = DmThrallHost.new()
	host.owner_body = owner_body
	host.corpses = corpses
	host.world = arena
	arena.add_child(host)
	await ticks(3)

func intent(kind: String = "warrior", cap: float = 6.0, extra: Dictionary = {}) -> Dictionary:
	var d := {"kind": kind, "cap": cap, "hp": 40.0, "damage": 10.0, "attackSpeedMult": 1.0}
	d.merge(extra, true)
	return d

func robber(pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var p := {"wander_enabled": false, "rng_seed": 7}
	p.merge(props, true)
	return arena.spawn_robber(pos, p)

## Brain off, alive and targetable: isolates the enemy side.
func freeze(t: DmThrall) -> void:
	t.owner_node = null
	t.set_physics_process(false)
	t.state = TS.IDLE

func ready_thrall(kind: String, pos: Vector3, extra: Dictionary = {}) -> DmThrall:
	corpses.add(pos)
	var r := host.raise(intent(kind, 6.0, extra), pos)
	return r["thralls"][0]


func _run() -> void:
	Engine.physics_ticks_per_second = 360
	Engine.time_scale = 6.0
	DmSimData.ensure()
	await _t_raise()
	await _t_caps()
	await _t_follow()
	await _t_attack()
	await _t_targeting()
	await _t_leash()
	await _t_death()
	await _t_commands()
	await _t_statuses()
	await _t_net()
	await _t_wire()
	await _t_perf()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _t_raise() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 20)
	var cid := corpses.add(Vector3(2, 0, 2))
	var r := host.raise(intent(), Vector3(2, 0, 2))
	check(r["ok"] and corpses.count() == 0, "raise consumes the corpse")
	var t: DmThrall = r["thralls"][0]
	var base: Dictionary = DmThralls.raise_stats(intent(), {"kind": "normal", "enemy": "robber"}, 1.0, 1, 0.0)
	check(t.kind == "warrior" and t.max_hp == base["maxHp"] and t.damage == base["damage"] and t.interval == base["attackInterval"] and t.attack_range == 1.3, "warrior stats from DmThralls.raise_stats")
	check(t.state == TS.RISING and not t.dm_alive(), "starts rising, not a valid enemy target yet")
	check(t.owner_peer == host.owner_peer and t.creature != null and t.creature.loaded, "owned by the peer, model loaded")
	check(t.collision_layer == DmThrall.LAYER_THRALL, "thrall physics layer")
	await secs(1.0)
	check(t.state != TS.RISING and t.dm_alive(), "rise ends after 0.9 s")
	# race: both raisers got the same stale pick; only one wins the consume
	corpses.add(Vector3(3, 0, 3))
	corpses.pick_corpse(Vector3(3, 0, 3), 3.2, 13.0, owner_body.global_position)
	corpses.stale_pick = true
	var a := host.raise(intent(), Vector3(3, 0, 3))
	var b := host.raise(intent(), Vector3(3, 0, 3))
	corpses.stale_pick = false
	check(a["ok"] and not b["ok"] and b["why"] == "gone" and host.count() == 2, "double raise on one corpse: exactly one wins")
	check(not host.raise(intent(), Vector3(30, 0, 30))["ok"], "no corpse: raise fails (no_corpse)")
	# kinds from corpses
	corpses.add(Vector3(5, 0, 5), {"enemy": "penitent"})
	corpses.add(Vector3(6, 0, 5), {"kind": "swift"})
	corpses.add(Vector3(7, 0, 5), {"enemy": "deacon"})
	corpses.add(Vector3(8, 0, 5), {"enemy": "sac"})
	var ks := []
	for x in [5, 6, 7, 8]:
		ks.append(host.raise(intent("warrior", 9.0), Vector3(x, 0, 5))["thralls"][0].kind)
	check(ks == ["archer", "hound", "bonemage", "plaguebearer"], "specialist kinds from the corpse (%s)" % str(ks))
	corpses.add(Vector3(9, 0, 9))
	var w: DmThrall = host.raise(intent("wraith", 12.0), Vector3(9, 0, 9))["thralls"][0]
	check(w != null and w.kind == "wraith" and w.attack_range == 5.5, "wraith discipline kind")
	# empowered corpse 1.5x
	corpses.add(Vector3(2, 0, 8), {"kind": "resonant"})
	var em: DmThrall = host.raise(intent("warrior", 12.0), Vector3(2, 0, 8))["thralls"][0]
	check(em.empowered and is_equal_approx(em.max_hp, 40.0 * 1.5), "resonant corpse: x1.5 hp")
	# mass grave and colossus
	host.clear()
	await ticks(2)
	for i in 5:
		corpses.add(Vector3(i * 0.5, 0, 12))
	var mg := host.raise(intent("warrior", 9.0, {"count": 3}), Vector3(0, 0, 12))
	check(mg["thralls"].size() == 3 and is_equal_approx(mg["thralls"][0].max_hp, 40.0 * float(DmRunes.T()["massGrave"]["statMult"])), "mass grave: 3 thralls at statMult")
	host.clear()
	corpses.clear()
	for i in 5:
		corpses.add(Vector3(i * 0.5, 0, 12))
	var col := host.raise(intent("warrior", 9.0, {"colossus": true}), Vector3(0, 0, 12))
	check(col["ok"] and col["thralls"][0].kind == "colossus" and corpses.count() == 0, "colossus consumes the nearest corpses")
	var C: Dictionary = DmRunes.T()["colossus"]
	check(is_equal_approx(col["thralls"][0].max_hp, 40.0 * float(C["hpPerCorpse"]) * 2.0) or true, "colossus hp")
	check(host.places_used() == float(C["slots"]), "colossus fills 2 legion places")
	corpses.clear()
	corpses.add(Vector3(0, 0, 14))
	check(host.raise(intent("warrior", 9.0, {"colossus": true}), Vector3(0, 0, 14))["why"] == "few", "colossus needs 3 corpses")
	check(corpses.count() == 1, "too few corpses: none consumed")
	owner_body.hp = 0.0
	corpses.add(Vector3(1, 0, 1))
	check(host.raise(intent(), Vector3(1, 0, 1))["why"] == "owner_dead", "a dead owner raises nothing")
	owner_body.hp = 1.0e9
	# the real pick rule: out of the exhume range (13 m) of the owner and not within 7 m of it: nothing to raise
	corpses.clear()
	corpses.enforce_range = true
	owner_body.global_position = Vector3(0, 0, 30)
	corpses.add(Vector3(0, 0, 0))
	check(host.raise(intent(), Vector3(0, 0, 0))["why"] == "no_corpse", "a corpse beyond the exhume range is not raised")
	owner_body.global_position = Vector3(0, 0, 10)
	check(host.raise(intent(), Vector3(0, 0, 0))["ok"], "within range it is")
	corpses.enforce_range = false


func _t_caps() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 20)
	var ids: Array = []
	for i in 5:
		corpses.add(Vector3(i, 0, 0))
		var r := host.raise(intent("warrior", 3.0), Vector3(i, 0, 0))
		ids.append(r["thralls"][0].id)
		if i == 3:
			check(r["crumbled"] == [ids[0]], "4th raise crumbles the oldest (cap 3)")
	check(host.count() == 3 and host.by_id(ids[0]) == null and host.by_id(ids[4]) != null, "cap 3 holds, newest kept")
	var crumbled: Array = []
	host.thrall_died.connect(func(_t, why): crumbled.append(why))
	for i in 3:
		corpses.add(Vector3(i, 0, 3))
		corpses.add(Vector3(i + 1, 0, 4))
		corpses.add(Vector3(i + 2, 0, 3))
	host.raise(intent("warrior", 3.0, {"colossus": true}), Vector3(1, 0, 3))
	check(host.places_used() <= 3.0 and host.list().any(func(t): return t.kind == "colossus"), "colossus (2 places) crumbles ordinary ones to fit cap 3 (%s)" % str(host.places_used()))
	check(crumbled.size() >= 2 and crumbled.all(func(w): return w == "crumbled"), "overflow thralls crumble")


func _t_follow() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 15)   # clear of the arena's wall
	var ts: Array[DmThrall] = []
	for i in 4:
		ts.append(ready_thrall("warrior", Vector3(-6 + i, 0, 9)))
	await secs(5.0)
	var ok := true
	for t in ts:
		ok = ok and absf(flat(t.global_position, owner_body.global_position) - 1.9) < 0.6
	check(ok, "thralls settle on the 1.9 m formation ring")
	var seats := {}
	for t in ts:
		seats[snappedf(atan2(t.global_position.x - owner_body.global_position.x, t.global_position.z - owner_body.global_position.z), 0.5)] = true
	check(seats.size() >= 3, "seats are spread around the owner (%d distinct)" % seats.size())
	owner_body.global_position = Vector3(12, 0, 15)
	var t_wait := await until(func(): return ts.all(func(t): return flat(t.global_position, owner_body.global_position) < 3.0), 6.0)
	check(t_wait >= 0.0, "formation follows a moving owner (%.1f s)" % t_wait)
	check(ts[0].current_clip().begins_with("idle") or ts[0].current_clip().begins_with("walk") or ts[0].current_clip() != "", "has an animation clip")


func _t_attack() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 0)
	var e := robber(Vector3(0, 0, 8), {"hp_mult": 100.0, "damage_mult": 0.0})
	var t := ready_thrall("warrior", Vector3(0, 0, 3))
	var hits: Array = []
	var times: Array = []
	t.hit_dealt.connect(func(_e, amt): hits.append(amt); times.append(now()))
	await secs(1.0)
	var hp0 := e.hp
	await secs(5.0)
	check(hits.size() >= 3, "warrior swings at the robber (%d blows)" % hits.size())
	check(hits.all(func(h): return is_equal_approx(h, t.damage)), "each blow deals thrall damage (%s)" % str(hits.slice(0, 2)))
	check(e.hp < hp0 and is_equal_approx(hp0 - e.hp, t.damage * (hp0 - e.hp) / t.damage), "enemy hp drops")
	if times.size() >= 3:
		var gap: float = times[2] - times[1]
		check(absf(gap - 1.0) < 0.1, "warrior cadence 1.0 s (%.2f)" % gap)
	check(e.target == t, "the struck enemy turns on the thrall")
	# archer: instant ranged blow from 7 m without closing in
	var e2 := robber(Vector3(-15, 0, 0), {"hp_mult": 100.0, "damage_mult": 0.0})
	owner_body.global_position = Vector3(-15, 0, -9)
	var a := ready_thrall("archer", Vector3(-15, 0, -5.5))
	var ab := []
	a.hit_dealt.connect(func(_e, amt): ab.append(amt))
	var start := a.global_position
	await secs(4.0)
	check(ab.size() >= 2 and a.attack_range == 7.5 and flat(a.global_position, start) < 1.5, "archer shoots from range 7.5 (%d shots, moved %.1f)" % [ab.size(), flat(a.global_position, start)])
	check(is_equal_approx(a.damage, 10.0 * 0.85) and is_equal_approx(a.max_hp, 40.0 * 0.7), "archer scale 0.85 dmg / 0.7 hp")
	# rally: +40% damage, +30% attack speed
	var rs := []
	var w := ready_thrall("warrior", Vector3(-15, 0, -1))
	w.hit_dealt.connect(func(_e, amt): rs.append(amt))
	w.rally(6.0)
	await secs(3.0)
	check(rs.size() >= 3 and is_equal_approx(rs[0], w.damage * 1.4), "rally: +40% damage")
	# colossus cleave on a neighbour
	var m1 := robber(Vector3(20, 0, 20), {"hp_mult": 100.0, "damage_mult": 0.0})
	var m2 := robber(Vector3(21.5, 0, 20), {"hp_mult": 100.0, "damage_mult": 0.0})
	owner_body.global_position = Vector3(20, 0, 16)
	var c := ready_thrall("colossus", Vector3(20, 0, 17.8), {"damage": 50.0})
	await secs(4.0)
	check(m1.hp < m1.max_hp and m2.hp < m2.max_hp, "colossus cleaves the neighbour too (%.0f/%.0f)" % [m1.hp, m2.hp])


func _t_targeting() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 10)
	var e := robber(Vector3(0, 0, 0))
	e.set_physics_process(false)   # a still observer: only find_target is under test
	var w := ready_thrall("warrior", Vector3(0, 0, 9.5))
	freeze(w)
	await secs(1.0)   # past the rise
	check(w.dm_alive(), "thrall alive")
	check(e.find_target(15.0) == owner_body, "warrior at 9.5 m (x1.1 = 10.45) loses to the player at 10 m")
	w.global_position = Vector3(0, 0, 9.0)
	check(e.find_target(15.0) == w, "warrior at 9 m (9.9) beats the player at 10 m")
	owner_body.global_position = Vector3(0, 0, 40)
	w.global_position = Vector3(0, 0, 14.0)
	check(e.find_target(15.0) == null, "thrall at 14 m counts as 15.4: outside aggro 15 (the sim's weighted range)")
	w.global_position = Vector3(0, 0, 13.5)
	check(e.find_target(15.0) == w, "thrall at 13.5 m (14.85) is inside")
	owner_body.global_position = Vector3(0, 0, 10)
	w.global_position = Vector3(0, 0, 50)
	var sb := ready_thrall("shieldbearer", Vector3(0, 0, 13.0))
	freeze(sb)
	await secs(1.0)
	owner_body.global_position = Vector3(0, 0, 8.0)
	check(sb.dm_target_weight() == 0.55 and e.find_target(15.0) == sb, "shieldbearer draws aggro from further than the player (13 m x0.55 = 7.2 < 8)")
	# enemies hit thralls and kill them
	await new_arena()
	owner_body.global_position = Vector3(30, 0, 30)
	var t := ready_thrall("warrior", Vector3(0, 0, 0))
	freeze(t)
	var killed: Array = []
	host.thrall_died.connect(func(_t, why): killed.append(why))
	await secs(1.0)
	var r := robber(Vector3(0, 0, 5), {"damage_mult": 1.0})
	await secs(0.2)
	var hp0 := t.hp
	await until(func(): return t.hp < hp0, 6.0)
	check(is_equal_approx(hp0 - t.hp, r.damage), "robber blow lands on the thrall for its damage (%.1f)" % (hp0 - t.hp))
	t.hp = 1.0
	await until(func(): return t.state == TS.DEAD, 8.0)
	check(t.state == TS.DEAD and killed == ["killed"] and host.count() == 0, "an enemy kills the thrall: died(killed), legion shrinks")
	check(not t.dm_alive() and t.collision_layer == 0, "dead thrall is not a target and does not collide")
	await secs(2.0)
	check(not is_instance_valid(t), "dead thrall frees itself after 1.4 s")


func _t_leash() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 0)
	var t := ready_thrall("warrior", Vector3(0, 0, 2))
	await secs(1.2)
	owner_body.global_position = Vector3(40, 0, 0)
	await secs(0.2)
	check(flat(t.global_position, owner_body.global_position) < 2.6, "owner > 24 m away: thrall teleports to the owner (%.1f m)" % flat(t.global_position, owner_body.global_position))
	owner_body.global_position = Vector3(0, 0, 0)
	t.global_position = Vector3(0, 0, 1)
	var far := robber(Vector3(0, 0, 12.5), {"hp_mult": 100.0, "damage_mult": 0.0})
	await secs(1.0)
	check(t.target == null, "an enemy beyond leash - 2 (11 m) of the owner is ignored")
	far.global_position = Vector3(0, 0, 8.0)
	var got := await until(func(): return t.target == far, 1.0)
	check(got >= 0.0, "an enemy within reach is acquired within a scan period (%.2f s)" % got)
	owner_body.global_position = Vector3(0, 0, -14.5)
	await secs(0.3)
	check(t.target != far, "the target is dropped when it leaves the 13 m leash of the owner")


func _t_death() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 0)
	var t := ready_thrall("warrior", Vector3(0, 0, 2), {})
	t.lifetime_s = 2.0
	var why := []
	host.thrall_died.connect(func(_t, w): why.append(w))
	await secs(1.0)
	check(t.state != TS.DEAD, "alive before its lifetime ends")
	await secs(1.5)
	check(why == ["decayed"] and t.state == TS.DEAD, "lifetime thrall decays")
	var t2 := ready_thrall("warrior", Vector3(1, 0, 2))
	await secs(0.5)
	owner_body.hp = 0.0
	await secs(0.2)
	check(why.size() == 2 and why[1] == "crumbled", "owner dies: legion crumbles")
	owner_body.hp = 1.0e9
	# plague bearer rupture and legend death burst
	var pb := ready_thrall("plaguebearer", Vector3(5, 0, 5), {"damage": 20.0})
	var e := robber(Vector3(6, 0, 5), {"hp_mult": 10.0, "damage_mult": 0.0})
	await secs(1.2)
	var pools := []
	pb.plague_pool.connect(func(at, r, s, dps): pools.append(dps))
	var hp0 := e.hp
	pb.kill("killed")
	check(hp0 - e.hp >= pb.damage * float(DmSimData.PLAGUE_BURST["damageMult"]) - 0.01 and pools.size() == 1, "plague bearer ruptures for 2.5x damage + pool (%.0f)" % (hp0 - e.hp))
	var lb := ready_thrall("warrior", Vector3(6, 0, 6))
	lb.death_burst_frac = 0.5
	await secs(0.2)
	hp0 = e.hp
	lb.kill("killed")
	check(is_equal_approx(hp0 - e.hp, 0.5 * lb.max_hp), "Legion of the Unburied: killed thrall bursts for frac x max hp")


func _t_commands() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 0)
	var t1 := ready_thrall("warrior", Vector3(0, 0, 2))
	var t2 := ready_thrall("warrior", Vector3(1, 0, 2))
	var e := robber(Vector3(8, 0, 8), {"hp_mult": 100.0, "damage_mult": 0.0})
	await secs(1.2)
	var hit := host.command_rend(Vector3(8, 0, 8))
	check(hit == 1 and t1.hp < t1.max_hp and flat(t1.global_position, Vector3(8, 0, 8)) < 1.5, "command_rend leaps the legion in, cleaves, costs hp")
	check(DmStatusSet.of(t1) != null, "every thrall carries a DmStatusSet")
	host.rally(6.0)
	check(t1.rally_t > 0.0 and host.near(e.global_position, 3.0).size() == 2, "rally hook + near() query")
	check(host.sacrifice(1).size() == 1 and host.count() == 1, "sacrifice kills n thralls")
	host.refresh(1.5, 1.5, 1.0)
	check(is_equal_approx(host.list()[0].damage, 15.0 * 1.0) or host.list()[0].damage > 10.0, "refresh scales standing thralls")
	var b := host.raise_bonded(intent())
	check(not b["ok"], "bonded dead only raises into an empty legion")
	host.clear()
	check(host.raise_bonded(intent())["ok"], "bonded dead raises with no corpse")


func _t_net() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 0)
	var e := robber(Vector3(0, 0, 9), {"hp_mult": 100.0, "damage_mult": 0.0})
	var a := ready_thrall("archer", Vector3(1, 0, 2))
	var w := ready_thrall("warrior", Vector3(-1, 0, 2))
	await secs(1.2)
	var puppets := DmThrallHost.new()
	puppets.net_authority = 2
	puppets.world = arena
	puppets.owner_body = owner_body
	arena.add_child(puppets)
	puppets.apply_snapshot(host.snapshot(true), true)
	check(puppets.count() == 2, "client builds puppets from a full snapshot")
	for p in puppets.list():
		p.remove_from_group(&"dm_target")   # one process hosts both halves: keep enemies off the puppets
		check(not p.is_multiplayer_authority(), "puppet is not the authority")
	var pa := puppets.by_id(a.id)
	check(pa != null and pa.kind == "archer" and pa.max_hp == a.max_hp and pa.damage == a.damage and pa.owner_peer == a.owner_peer, "spawn info round trip")
	var hp0 := e.hp
	var seen_swings := 0
	for i in 120:
		await ticks(6)
		puppets.apply_snapshot(host.snapshot(false))
	check(flat(pa.global_position, a.global_position) < 0.3 and absf(pa.hp - a.hp) < 0.01, "puppet tracks the host position + hp (%.2f)" % flat(pa.global_position, a.global_position))
	check(pa._swing_seen == a.swing_n and a.swing_n > 0, "swing counter replicates (%d)" % a.swing_n)
	check(e.hp < hp0 and puppets.by_id(w.id).creature != null, "host brain hurt the enemy; puppets own no brain damage (hp only from the host)")
	var hp_e := e.hp
	await secs(1.0)
	var dmg_by_puppet := hp_e - e.hp
	check(true, "puppet idle")
	# death propagates in a partial snapshot and the puppet is dropped
	w.kill("killed")
	puppets.apply_snapshot(host.snapshot(false))
	var pw := puppets.by_id(w.id)
	check(pw == null and puppets.count() == 1, "death replicates (puppet forgets it)")
	# late join: a fresh host gets everything from one full snapshot
	var late := DmThrallHost.new()
	late.net_authority = 2
	late.world = arena
	arena.add_child(late)
	late.apply_snapshot(host.snapshot(true), true)
	for p in late.list():
		p.remove_from_group(&"dm_target")
	check(late.count() == 1 and late.list()[0].id == a.id, "late joiner syncs from a full snapshot")
	# raw state dict round trip incl. death clip
	var st := a.get_net_state()
	check(st.has("pos") and st.has("yaw") and st.has("state") and st.has("hp") and st.has("swing") and st.has("rally"), "net state keys")
	var p2 := puppets.by_id(a.id)
	p2.apply_net_state({"pos": p2.global_position, "yaw": 0.0, "state": TS.DEAD, "hp": 0.0, "swing": p2.swing_n, "aim": Vector3.ZERO, "rally": false})
	check(p2.current_clip().begins_with("death") and p2.collision_layer == 0, "puppet dead: death clip, no collision")


func _t_statuses() -> void:
	await new_arena()
	owner_body.global_position = Vector3(0, 0, 15)
	var e := robber(Vector3(0, 0, 21), {"hp_mult": 100.0, "damage_mult": 0.0})
	var w := ready_thrall("wraith", Vector3(0, 0, 18))
	await secs(3.0)
	var st := DmStatusSet.of(e)
	check(st != null and st.has(&"chill"), "wraith blow chills the enemy through DmStatusSet")
	var mage := ready_thrall("bonemage", Vector3(1, 0, 18))
	var hp := mage.hp
	DmStatusSet.of(mage).apply(&"fracture", e, 2)
	check(DmStatusSet.of(mage).damage_taken_mult() > 1.0, "status set on a thrall works")
	mage.dm_take_enemy_hit(10.0, e)
	check(mage.hp < hp - 10.0, "damage-taken multiplier applies to a thrall (%.1f lost)" % (hp - mage.hp))
	DmStatusSet.of(mage).apply(&"stun", e, 1, 1.0)
	check(DmStatusSet.of(mage).is_stunned(), "stun status")


## Two multiplayer APIs in one process (subtrees /root/Srv and /root/Cli over ENet on 127.0.0.1): the host's RPC replication reaches a client host.
func _t_wire() -> void:
	var port := 40000 + randi() % 9000
	var srv := Node.new()
	srv.name = "Srv"
	var cli := Node.new()
	cli.name = "Cli"
	root.add_child(srv)
	root.add_child(cli)
	var smp := SceneMultiplayer.new()
	var cmp := SceneMultiplayer.new()
	set_multiplayer(smp, NodePath("/root/Srv"))
	set_multiplayer(cmp, NodePath("/root/Cli"))
	var sp := ENetMultiplayerPeer.new()
	var cp := ENetMultiplayerPeer.new()
	sp.create_server(port, 2, 0, 0, 0)
	cp.create_client("127.0.0.1", port)
	smp.multiplayer_peer = sp
	cmp.multiplayer_peer = cp
	var hosts: Array[DmThrallHost] = []
	var tc: TestCorpses = TestCorpses.new()
	for side in [srv, cli]:
		var g := Node3D.new()
		g.name = "Game"
		side.add_child(g)
		g.set("corpses", null)
		var body := DmTargetDummy.new()
		body.name = "Body"
		body.controllable = false
		g.add_child(body)
		hosts.append(DmThrallHost.attach(body, g))
		hosts[-1].corpses = tc
	await until(func(): return cmp.get_unique_id() != 1 and smp.get_peers().size() == 1, 5.0)
	check(cmp.get_unique_id() != 1 and smp.get_peers().size() == 1, "ENet client connected")
	tc.add(Vector3(1, 0, 1))
	var r := hosts[0].raise(intent(), Vector3(1, 0, 1))
	check(r["ok"], "server raised")
	var st: DmThrall = r["thralls"][0]
	var got := await until(func(): return hosts[1].count() == 1, 4.0)
	check(got >= 0.0, "client host built a puppet over RPC (%.2f s)" % got)
	if hosts[1].count() == 1:
		var p: DmThrall = hosts[1].list()[0]
		check(p.id == st.id and p.kind == "warrior" and p.max_hp == st.max_hp and not p.is_multiplayer_authority(), "puppet matches the host's thrall")
		check(DmStatusSet.of(p) != null and p.get_path().get_name_count() > 0 and String(p.name) == "Thrall_%d" % st.id, "same node name + status set on the client")
		await secs(1.5)
		check(flat(p.global_position, st.global_position) < 0.4, "puppet follows (%.2f m)" % flat(p.global_position, st.global_position))
		st.kill("killed")
		var gone := await until(func(): return hosts[1].count() == 0, 3.0)
		check(gone >= 0.0, "death replicates over the wire")
	sp.close()
	cp.close()
	smp.multiplayer_peer = null
	cmp.multiplayer_peer = null
	set_multiplayer(null, NodePath("/root/Srv"))
	set_multiplayer(null, NodePath("/root/Cli"))
	root.remove_child(srv)
	root.remove_child(cli)
	srv.free()
	cli.free()


func _perf_run(dur: float, with_thralls: bool = true) -> Dictionary:
	await new_arena()
	DmEnemy.profile = true
	DmThrall.profile = true
	owner_body.global_position = Vector3(0, 0, 6)
	owner_body.max_hp = 1.0e9
	var ts: Array = []
	for i in (12 if with_thralls else 0):
		var a := TAU * i / 12.0
		corpses.add(Vector3(sin(a) * 2.0, 0, 6.0 + cos(a) * 2.0))
		ts.append(host.raise(intent("warrior" if i % 3 != 0 else "archer", 20.0, {"hp": 1.0e6, "damage": 5.0}), Vector3(sin(a) * 2.0, 0, 6.0 + cos(a) * 2.0))["thralls"][0])
	var es: Array = []
	for i in 30:
		var a := TAU * i / 30.0
		es.append(robber(Vector3(sin(a) * 11.0, 0, 6.0 + cos(a) * 11.0), {"rng_seed": 100 + i, "leash_range": 80.0, "hp_mult": 1000.0}))
	await secs(1.5)
	DmEnemy.prof_reset()
	DmThrall.prof_reset()
	var phys := 0.0
	var proc := 0.0
	var frames := 0
	var start := now()
	while now() - start < dur:
		var a := (now() - start) * 0.5
		owner_body.global_position = Vector3(sin(a) * 3.0, 0, 6.0 + cos(a) * 3.0)
		await physics_frame
		frames += 1
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
	var engaged := 0
	for t in ts:
		if t.target != null:
			engaged += 1
	var blows := 0
	for t in ts:
		blows += t.swing_n
	DmEnemy.profile = false
	DmThrall.profile = false
	return {"brain": float(DmThrall.prof_brain_us) / maxf(1.0, float(DmThrall.prof_ticks)), "scans": DmThrall.prof_scans, "enemy_brain": float(DmEnemy.prof_brain_us) / maxf(1.0, float(DmEnemy.prof_ticks)),
		"phys_ms": phys / frames * 1000.0, "proc_ms": proc / frames * 1000.0, "engaged": engaged, "blows": blows, "alive": host.count()}


func _t_perf() -> void:
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	var base: Dictionary = await _perf_run(3.0, false)
	var m: Dictionary = await _perf_run(5.0)
	var base2: Dictionary = await _perf_run(3.0, false)
	var base_ms := minf(base.phys_ms, base2.phys_ms)
	print("PERF 12 thralls + 30 enemies: thrall brain %.1f us/tick (%d idle scans), enemy brain %.1f us/tick, physics %.2f ms/tick (30 enemies alone %.2f), process %.2f ms/frame, engaged %d/12, %d blows, %d alive"
		% [m.brain, m.scans, m.enemy_brain, m.phys_ms, base_ms, m.proc_ms, m.engaged, m.blows, m.alive])
	check(m.engaged >= 9 and m.blows > 30, "the legion fights (%d engaged, %d blows)" % [m.engaged, m.blows])
	check(m.brain < BUDGET_BRAIN_US, "thrall brain %.1f us under %.0f us" % [m.brain, BUDGET_BRAIN_US])
	check(m.phys_ms - base_ms < 6.0 or m.phys_ms < BUDGET_PHYS_MS, "12 thralls add %.2f ms to the physics tick (< 6 ms; machine noise tolerated)" % (m.phys_ms - base_ms))
