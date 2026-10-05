extends SceneTree
## DmRiteCaster tests (godot/next/rites). godot --headless --path godot --script res://tests/rites/run.gd
## Part A: solo (DmSession on OfflineMultiplayerPeer), host stepped by hand (deterministic). Part B: in-process ENet, 1 host + 2 clients
## (separate SceneMultiplayer branches). Ports 5194-5195 on 127.0.0.1 only.

var PORT := DmTestPorts.free_port()   # random free port per run (parallel suites)
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
	await _part_a()
	await _part_b()
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


func _zero() -> float:
	return 0.0


# ---- test doubles ------------------------------------------------------------------------------------------------------------------------

## DmRiteWorld test double (the contract in next/rites/README.md).
class World:
	extends RefCounted
	var enemies: Array = []
	var events: Array = []
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

	func on_rite_event(ev: Dictionary) -> void:
		events.append(ev)


class RecMotifs:
	extends RefCounted
	var n := 0
	func bone_splinters(_x, _y, _z, _o) -> void: n += 1
	func rot_spores(_x, _z, _c, _o) -> void: n += 1


## Recording Vfx stand-in: counts calls per kind.
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


class RecAudio:
	extends RefCounted
	var sfx: Array = []
	var loops: Array = []
	func play_sfx(id, _p, _i) -> void: sfx.append(id)
	func loop_sfx(id, _ms, _p, _f) -> void: loops.append(id)


func _stub(c: DmRiteCaster) -> Array:
	var f := RecFx.new()
	var a := RecAudio.new()
	c.fx.fx = f
	c.fx.audio = a
	return [f, a]


func _robber(world: World, parent: Node, pos: Vector3) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	e.position = pos
	parent.add_child(e)
	world.add(e)
	return e


func _expected_needle(caster: DmRiteCaster, jitter: float, crit_roll: float) -> float:
	var nc := DmAbilities.needle_cast(DmAbilities.sp(caster.p, 0.0), caster.p["loadout"], "", 0, jitter)
	return float(DmAbilities.needle_hit(nc["dmg"], crit_roll)["amount"])


func _run_host(c: DmRiteCaster, secs: float, dt := 0.02) -> void:
	for i in int(round(secs / dt)):
		c.step(dt)
		if c.world != null:
			for e in c.world.enemies:   # the frame-less host also ticks the enemies' DmStatusSets
				var ss := DmStatusSet.of(e) if is_instance_valid(e) else null
				if ss != null:
					ss.advance(dt)


# ---- Part A: solo ------------------------------------------------------------------------------------------------------------------------

func _part_a() -> void:
	var h := Node.new()
	h.name = "S"
	root.add_child(h)
	var sess := DmSession.new()
	sess.name = "Session"
	h.add_child(sess)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/S"))
	sess.character_name = "Solo"
	sess.discipline_id = "gravecaller"
	ok(sess.host(OfflineMultiplayerPeer.new()) == OK, "A: solo session hosts on OfflineMultiplayerPeer")
	var body := sess.get_body(1)
	var world := World.new()
	var c := DmRiteCaster.attach(body, world)
	c.auto_step = false
	c.random = Callable(self, "_half")
	var st := _stub(c)
	var fx: RecFx = st[0]
	var au: RecAudio = st[1]
	await process_frame

	# initial resource state from the rules
	var max_e: float = c.p["stats"]["maxEssence"]
	ok(is_equal_approx(c.essence(), max_e * 0.6), "A: essence starts at 60% of max (DmResources.initial)")
	ok(c.get_state()["max_essence"] == max_e and c.get_state()["cooldowns"].is_empty(), "A: host body sees its own state")
	var states := [0]
	c.state_changed.connect(func(_s): states[0] += 1)

	# --- needle: numbers, fx once, cooldown, essence refund
	var e1 := _robber(world, h, Vector3(3, 0, 6))
	var id1 := world.enemy_id(e1)
	var hp0 := e1.hp
	var ess0 := c.essence()
	c.request_cast("bone_needle", Vector3(3, 0, 6), id1)
	ok(c.events_played == 1 and world.events.size() == 1 and world.events[0]["t"] == "cast", "A: cast event played once on the host (solo)")
	ok(fx.c.get("flash", 0) == 1 and au.sfx == ["needleCast"] and fx.c.get("projectile", 0) == 1, "A: needle cast fx/sfx exactly once (flash 1, sfx needleCast, projectile 1)")
	ok(e1.hp == hp0, "A: no damage before the needle arrives")
	ok(c.cooldown_left("bone_needle") > 0.0 and is_equal_approx(c.cooldown_left("bone_needle"), 380.0), "A: cooldown = ability def 380 ms")
	_run_host(c, 0.04)
	c.request_cast("bone_needle", Vector3(3, 0, 6), id1)
	ok(c.events_played == 1, "A: second cast inside the cooldown is refused (no event)")
	_run_host(c, 0.5)
	var want := _expected_needle(c, 0.5, 0.5)
	ok(is_equal_approx(hp0 - e1.hp, want), "A: needle damage == DmAbilities (%.4f vs %.4f)" % [hp0 - e1.hp, want])
	ok(c.events_played == 2 and fx.c.get("flash", 0) == 2 and au.sfx == ["needleCast", "needleHit"] and fx.motifs.n == 1 and fx.c.get("emit", 0) == 1, "A: hit fx/sfx once (flash 2, needleHit, 8 dust, splinters)")
	var gain: float = c.essence() - ess0
	var regen := DmResources.passive("necromancer", {"stats": c.p["stats"], "value": 0.0, "max": max_e, "sinceHurtMs": 1e9, "sinceResourceGainMs": 1e9})
	ok(gain >= float(DmCombatData.const_table("NEEDLE_ESSENCE")) and gain <= float(DmCombatData.const_table("NEEDLE_ESSENCE")) + regen * 0.6, "A: needle refunds NEEDLE_ESSENCE (gain %.2f)" % gain)
	ok(e1.sm.id() == DmEnemyState.Id.HURT or e1.hp < hp0, "A: DmEnemy took the hit through its damage API")
	# crit
	c.random = Callable(self, "_zero")
	_run_host(c, 0.5)
	var hp1 := e1.hp
	c.request_cast("bone_needle", Vector3(3, 0, 6), id1)
	_run_host(c, 0.5)
	ok(is_equal_approx(hp1 - e1.hp, _expected_needle(c, 0.0, 0.0)) and is_equal_approx(_expected_needle(c, 0.0, 0.0), want * 1.8 * 0.9), "A: crit roll < 8 percent -> x1.8 (jitter 0 -> x0.9) per DmAbilities")
	c.random = Callable(self, "_half")
	# refusals
	_run_host(c, 0.5)
	var rej: Array = []
	c.cast_rejected.connect(func(r, why): rej.append([r, why]))
	var e_far := _robber(world, h, Vector3(3, 0, 40))
	c.request_cast("bone_needle", Vector3(3, 0, 40), world.enemy_id(e_far))
	ok(rej.size() == 1 and rej[0][1] == "range", "A: needle beyond range refused (range)")
	c.request_cast("bone_needle", Vector3(-30, 0, -30), -1)
	ok(rej.size() == 2 and rej[1][1] == "no_target", "A: needle with nothing under the aim refused (no_target)")
	ok(world.events.size() == 4, "A: refusals broadcast nothing (4 events so far: 2 casts + 2 hits)")
	# pick by aim point when no id is named
	var ev_n := c.events_played
	c.request_cast("bone_needle", Vector3(3.5, 0, 6.5), -1)
	ok(c.events_played == ev_n + 1 and world.events.back()["enemy_id"] == id1, "A: aim point picks the nearest enemy when no id is sent")
	_run_host(c, 0.6)

	# --- forged owner
	var rj := c.rejected_intents
	c.request_cast("bone_needle", Vector3(3, 0, 6), id1, 99)
	ok(c.rejected_intents == rj + 1, "A: intent from a non-owner peer is rejected (forged)")
	c.request_cast("fireball", Vector3(0, 0, 0), -1, 1)
	c.request_cast("miasma", Vector3(NAN, 0, 0), -1, 1)
	ok(c.rejected_intents == rj + 3, "A: unknown rite / non-finite aim rejected")

	# --- miasma
	var e_in := _robber(world, h, Vector3(3, 0, 10))     # inside the circle
	var e_out := _robber(world, h, Vector3(3, 0, 16))    # outside (r ~3.8)
	var ess_before := c.essence()
	var mz: Dictionary = DmAbilities.miasma(DmAbilities.sp(c.p, 0.0), c._mods, "", 1.0, {"x": 3.0, "z": 0.0}, {"x": 3.0, "z": 10.0})
	var n_ev := world.events.size()
	var cool_before := c.cooldown_left("miasma")
	c.request_cast("miasma", Vector3(3, 0, 10))
	ok(world.events.size() == n_ev + 1 and world.events.back()["t"] == "cast" and world.events.back()["rite"] == "miasma", "A: miasma cast event")
	ok(is_equal_approx(ess_before - c.essence(), float(DmAbilities.def("miasma")["essenceCost"])), "A: miasma costs essenceCost (25)")
	ok(is_equal_approx(c.cooldown_left("miasma"), float(DmAbilities.def("miasma")["cooldownMs"])) and cool_before == 0.0, "A: miasma cooldown 7000 ms from the def")
	ok(au.sfx.count("miasma") == 0, "A: cloud sound waits for the landing")
	var hp_in := e_in.hp
	var hp_out := e_out.hp
	_run_host(c, 3.0)
	ok(world.events.back()["t"] == "land" and is_equal_approx(world.events.back()["r"], mz["r"]) and is_equal_approx(mz["r"], 3.8), "A: land event radius == DmAbilities.miasma radius (3.8)")
	ok(au.sfx.count("miasma") == 1 and au.loops == ["miasmaLoop"] and fx.c.get("smoke", 0) == 1 and fx.c.get("bb", 0) == 2, "A: landing fx/sfx exactly once (bb: 1 crit_hit + 1 cloud)")
	var lost := hp_in - e_in.hp
	# pulses at 0, 1, 2 s after landing: stacks 1,2,3 -> ~ dps * 6 stack-seconds, minus the flight/last partial step
	ok(lost > mz["dps"] * 3.0 and lost < mz["dps"] * 7.0, "A: Withered damage from the cloud in the dps range (lost %.2f, dps %.3f)" % [lost, mz["dps"]])
	ok(e_out.hp == hp_out, "A: enemy outside the circle untouched")
	ok(is_equal_approx(e_in.speed_mult, DmSimData.MIASMA_SLOW), "A: enemy in the cloud slowed by MIASMA_SLOW")
	# cooldown + essence refusals
	rej.clear()
	c.request_cast("miasma", Vector3(3, 0, 10))
	ok(rej.size() == 1 and rej[0][1] == "cooldown", "A: miasma on cooldown refused")
	_run_host(c, 8.0)
	ok(is_equal_approx(e_in.speed_mult, 1.0), "A: slow ends after the cloud")
	c.p["resource"]["value"] = 10.0
	rej.clear()
	c.request_cast("miasma", Vector3(3, 0, 10))
	ok(rej.size() == 1 and rej[0][1] == "essence", "A: miasma refused without essence")
	c.p["resource"]["value"] = 100.0
	c.set_alive(false)
	c.request_cast("miasma", Vector3(3, 0, 10))
	ok(rej.size() == 2 and rej[1][1] == "dead", "A: dead caster refused")
	c.set_alive(true)
	ok(states[0] > 0, "A: state_changed fired for the HUD")

	# --- enemies die from needles; hit_resolved reports kills
	var kills := [0]
	c.hit_resolved.connect(func(_r, _id, _a, _c, killed): kills[0] += int(killed))
	var dead := [0]
	var e_k := _robber(world, h, Vector3(-2, 0, 6))   # outside the cloud
	var id_k := world.enemy_id(e_k)
	e_k.died.connect(func(_e): dead[0] += 1)
	for i in 30:
		if e_k.hp <= 0.0:
			break
		c.request_cast("bone_needle", Vector3(-2, 0, 6), id_k)
		_run_host(c, 0.5)
	ok(e_k.hp <= 0.0 and e_k.sm.id() == DmEnemyState.Id.DEAD and dead[0] == 1, "A: enemy killed by needles (DmEnemy died signal once)")
	ok(kills[0] == 1, "A: hit_resolved reported exactly one kill")
	rej.clear()
	c.request_cast("bone_needle", Vector3(-2, 0, 6), id_k)
	ok(rej.size() == 1 and rej[0][1] == "no_target", "A: a dead enemy is not a target")

	# --- real Vfx / AudioDirector back-ends run without error (headless)
	var c2 := DmRiteCaster.new()
	c2.name = "Rites2"
	c2.world = world
	body.add_child(c2)
	c2.auto_step = false
	c2.peer_id = 1
	ok(c2.fx.fx != null and c2.fx.audio != null, "A: default fx back-ends are the Vfx / AudioDirector autoloads")
	var e_real := _robber(world, h, Vector3(3, 0, 5))
	c2.request_cast("bone_needle", Vector3(3, 0, 5), world.enemy_id(e_real))
	_run_host(c2, 0.6)
	ok(c2.fx.stats["sfx"] == 2 and c2.fx.stats["projectile"] == 1, "A: real back-ends counted (sfx 2, projectile 1)")
	c2.queue_free()
	for e in world.enemies:
		if is_instance_valid(e):
			e.free()
	await sess.leave()
	h.queue_free()


# ---- Part B: ENet, host + 2 clients ------------------------------------------------------------------------------------------------------

class Peer:
	var node: Node
	var sess: DmSession
	var world := World.new()
	var casters: Dictionary = {}   ## body owner id -> DmRiteCaster
	var rec: Array = []            ## [RecFx, RecAudio] per owner id
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
	var players: Node = pr.sess.get_node("Players")
	players.child_entered_tree.connect(func(b: Node): _attach.call_deferred(pr, b))
	return pr


func _attach(pr: Peer, b: Node) -> void:
	if not is_instance_valid(b) or b.get_node_or_null("Rites") != null:
		return
	var c := DmRiteCaster.attach(b as Node3D, pr.world)
	c.random = Callable(self, "_half")
	var s := _stub(c)
	var id: int = (b as DmSessionBody).owner_peer
	pr.casters[id] = c
	pr.rec.append([id, s[0], s[1]])
	c.cast_rejected.connect(func(r, why): pr.rej.append([id, r, why]))


func _fxs(pr: Peer, id: int) -> Array:
	for r in pr.rec:
		if r[0] == id:
			return [r[1], r[2]]
	return []


func _part_b() -> void:
	var host := _mk("H")
	var hpeer := ENetMultiplayerPeer.new()
	ok(hpeer.create_server(PORT, 4) == OK, "B: server created")
	host.sess.host(hpeer)
	_attach(host, host.sess.get_body(1))   # the host's own body exists before any signal
	var c1 := _mk("C1")
	var c2 := _mk("C2")
	for cl in [c1, c2]:
		var pe := ENetMultiplayerPeer.new()
		pe.create_client("127.0.0.1", PORT)
		(cl as Peer).sess.join(pe)
	var peers: Array = [host, c1, c2]
	ok(await wait_for(func(): return peers.all(func(p): return p.casters.size() == 3)), "B: every peer has a DmRiteCaster on every body")
	var id1 := c1.sess.get_my_id()
	var id2 := c2.sess.get_my_id()
	ok(id1 != id2 and id1 > 1, "B: distinct peer ids")
	# the arena: enemies only exist on the host (clients render events, they never resolve hits)
	var e_a := _robber(host.world, host.node, Vector3(0, 0, 8))
	var aid := host.world.enemy_id(e_a)
	# C1's body is at its spawn point; put both bodies close to the enemy
	host.sess.get_body(id1).position = Vector3(0, 0, 2)
	host.sess.get_body(id2).position = Vector3(0, 0, -3)
	host.casters[id1].auto_step = true
	await create_timer(0.3).timeout

	# owner casts: intent -> host -> event on every peer
	var hp0 := e_a.hp
	var essence_before: float = host.casters[id1].essence()
	c1.casters[id1].request_cast("bone_needle", Vector3(0, 0, 8), aid)
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played >= 1)), "B: cast event reached host + both clients")
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id1].events_played == 2)), "B: hit event reached host + both clients")
	await create_timer(0.3).timeout
	var want := _expected_needle(host.casters[id1], 0.5, 0.5)
	ok(is_equal_approx(hp0 - e_a.hp, want), "B: network needle damage == DmAbilities (%.4f vs %.4f)" % [hp0 - e_a.hp, want])
	for p in peers:
		var f: RecFx = _fxs(p, id1)[0]
		var a: RecAudio = _fxs(p, id1)[1]
		ok(p.casters[id1].events_played == 2 and a.sfx == ["needleCast", "needleHit"] and f.c.get("flash", 0) == 2 and f.c.get("projectile", 0) == 1 and f.motifs.n == 1,
			"B: %s played the needle fx/sfx exactly once each (events %d, sfx %s)" % [p.node.name, p.casters[id1].events_played, str(a.sfx)])
	ok(host.casters[id1].essence() > essence_before - 0.01, "B: needle costs nothing and refunds essence on the host")
	# HUD state replicated to the owner only
	ok(await wait_for(func(): return c1.casters[id1].get_state().has("cooldowns") and c1.casters[id1].get_state()["max_essence"] == host.casters[id1].p["resource"]["max"]), "B: owner receives the HUD state")
	ok(c2.casters[id1].get_state().is_empty(), "B: other clients do not get another player's resource state")

	# validation over the wire
	await create_timer(0.5).timeout
	host.casters[id1]._now_ms = host.casters[id1]._now_ms   # no-op: clock is real-time here
	c1.casters[id1].request_cast("bone_needle", Vector3(0, 0, 8), aid)
	c1.casters[id1].request_cast("bone_needle", Vector3(0, 0, 8), aid)   # immediately again: busy/cooldown
	ok(await wait_for(func(): return c1.rej.size() >= 1), "B: refusal comes back to the owner")
	ok(c1.rej[0][0] == id1 and (c1.rej[0][2] == "cooldown" or c1.rej[0][2] == "busy"), "B: second cast refused for cooldown (%s)" % str(c1.rej[0]))
	await create_timer(0.6).timeout
	# forged: C2 sends a cast RPC at C1's body caster
	var rj: int = host.casters[id1].rejected_intents
	var ev_before: int = host.casters[id1].events_played
	c2.casters[id1]._rpc_cast.rpc_id(1, "bone_needle", Vector3(0, 0, 8), aid)
	ok(await wait_for(func(): return host.casters[id1].rejected_intents == rj + 1), "B: a client cannot cast for another body (host rejects the forged RPC)")
	await create_timer(0.2).timeout
	ok(host.casters[id1].events_played == ev_before and c2.rej.is_empty(), "B: the forged cast produced no event")
	# the honest API refuses locally
	c2.casters[id1].request_cast("bone_needle", Vector3(0, 0, 8), aid)
	ok(c2.rej.size() == 1 and c2.rej[0][2] == "not_owner", "B: request_cast on someone else's body is refused locally")
	# range + cost over the wire
	var e_far := _robber(host.world, host.node, Vector3(0, 0, 38))
	c2.casters[id2].request_cast("bone_needle", Vector3(0, 0, 38), host.world.enemy_id(e_far))
	ok(await wait_for(func(): return c2.rej.size() >= 2), "B: out-of-range refusal returns to the owner")
	ok(c2.rej.back()[2] == "range", "B: reason is range")
	host.casters[id2].p["resource"]["value"] = 5.0
	c2.casters[id2].request_cast("miasma", Vector3(0, 0, 4))
	ok(await wait_for(func(): return c2.rej.size() >= 3) and c2.rej.back()[2] == "essence", "B: miasma without essence refused (essence)")
	host.casters[id2].p["resource"]["value"] = 100.0

	# miasma by C2: event on every peer once; fx once per peer
	var e_m := _robber(host.world, host.node, Vector3(0, 0, 4))
	var hpm := e_m.hp
	c2.casters[id2].request_cast("miasma", Vector3(0, 0, 4))
	ok(await wait_for(func(): return peers.all(func(p): return p.casters[id2].events_played == 2), 6.0), "B: miasma cast + land events on every peer")
	await create_timer(0.3).timeout
	for p in peers:
		var f: RecFx = _fxs(p, id2)[0]
		var a: RecAudio = _fxs(p, id2)[1]
		ok(p.casters[id2].events_played == 2 and a.sfx == ["miasma"] and a.loops == ["miasmaLoop"] and f.c.get("projectile", 0) == 1 and f.c.get("smoke", 0) == 1 and f.c.get("decal", 0) == 1,
			"B: %s miasma fx exactly once (events %d, sfx %s)" % [p.node.name, p.casters[id2].events_played, str(a.sfx)])
	ok(await wait_for(func(): return e_m.hp < hpm, 4.0), "B: enemy inside the network cloud takes Withered damage")
	ok(is_equal_approx(host.casters[id2].essence(), host.casters[id2].essence()), "B: sanity")

	# teardown
	for e in host.world.enemies:
		if is_instance_valid(e):
			e.free()
	for p in [c1, c2, host]:
		(p as Peer).sess.leave()
	await create_timer(0.5).timeout
	for p in peers:
		p.node.queue_free()
