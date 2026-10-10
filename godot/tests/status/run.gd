extends SceneTree
## DmStatusSet tests (godot/next/status). godot --headless --path godot --script res://tests/status/run.gd
## Rules are asserted against DmSimData (the tables the old sim uses), not retyped numbers. Part R: replication over in-process ENet.

var passed := 0
var failed := 0


func ok(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func near(a: float, b: float, eps := 1e-4) -> bool:
	return absf(a - b) <= eps


func _initialize() -> void:
	_main.call_deferred()


## Owner stand-in with the DmEnemy surface the set uses.
class Dummy:
	extends Node3D
	signal died(e)
	signal statuses_cleared
	var speed_mult := 1.0
	var attack_rate_mult := 1.0
	var hp := 1000.0
	var max_hp := 1000.0
	var def := {}
	var stuns: Array = []
	var hits: Array = []
	func take_damage(a: float, from: Node = null, _stagger := true) -> bool:
		a = DmStatusSet.scale_taken(self, a)   # what every real owner does on entry
		hp -= a
		hits.append([a, from])
		return true
	func stun(s: float) -> void:
		stuns.append(s)


func _dummy(parent: Node, nm := "D") -> Dummy:
	var d := Dummy.new()
	d.name = nm
	parent.add_child(d)
	DmStatusSet.attach(d)
	return d


func _run(s: DmStatusSet, secs: float, dt := 0.02) -> void:
	for i in int(round(secs / dt)):
		s.advance(dt)


func _main() -> void:
	DmSimData.ensure()
	DmStatusSet.warm()
	var h := Node.new()
	root.add_child(h)
	_rules(h)
	_dots_and_credit(h)
	_misc(h)
	_perf(h)
	await _replication()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _rules(h: Node) -> void:
	var S := DmSimData
	var d := _dummy(h)
	var s := DmStatusSet.of(d)
	ok(s.speed_mult() == 1.0 and s.attack_rate_mult() == 1.0 and s.damage_taken_mult() == 1.0, "empty set: all multipliers 1")
	# chill
	s.apply(&"chill")
	ok(near(d.speed_mult, float(S.CHILL["moveMult"])) and near(d.attack_rate_mult, float(S.CHILL["attackRateMult"])), "chill: move/attack-rate from CHILL, written to the owner")
	ok(near(s.remaining(&"chill"), float(S.CHILL["durationS"])), "chill: default duration CHILL.durationS")
	s.apply(&"chill", null, 1, 1.0)
	ok(near(s.remaining(&"chill"), float(S.CHILL["durationS"])), "chill: a shorter re-apply keeps the longer time")
	s.apply(&"chill", null, 1, 9.0)
	ok(near(s.remaining(&"chill"), 9.0), "chill: a longer re-apply extends it")
	s.remove(&"chill")
	ok(d.speed_mult == 1.0 and d.attack_rate_mult == 1.0, "chill removed: multipliers back to 1")
	s.apply(&"chill")
	_run(s, float(S.CHILL["durationS"]) + 0.2)
	ok(not s.has(&"chill") and d.speed_mult == 1.0, "chill expires after durationS (ticks)")
	# two slows do not fight (the miasma slow vs the ward slow: strongest wins, no overwrite, no stacking)
	s.apply(&"slow", null, 1, 5.0)
	s.apply(&"ward_slow", null, 1, 5.0)
	ok(near(d.speed_mult, minf(S.MIASMA_SLOW, S.WATCHMANS_WARD_SLOW)), "slow + ward_slow: min of the two (%.2f)" % d.speed_mult)
	s.remove(&"slow")
	ok(near(d.speed_mult, S.WATCHMANS_WARD_SLOW), "removing one slow leaves the other in force (was overwritten to 1.0 before)")
	s.apply(&"chill", null, 1, 5.0)
	ok(near(d.speed_mult, S.WATCHMANS_WARD_SLOW * float(S.CHILL["moveMult"])), "ward slow x chill multiply")
	s.apply(&"incensed", null, 1, 5.0)
	ok(near(d.speed_mult, S.WATCHMANS_WARD_SLOW * float(S.CHILL["moveMult"]) * float(S.CENSER["moveMult"])), "x incense haste")
	ok(near(d.attack_rate_mult, float(S.CHILL["attackRateMult"]) * float(S.CENSER["attackRateMult"])), "attack rate: chill x incense")
	s.clear()
	ok(d.speed_mult == 1.0 and d.attack_rate_mult == 1.0 and s.ids().is_empty(), "clear() resets everything")
	# incensed numbers + refresh
	s.apply(&"incensed", null, 1, float(S.CENSER["hasteS"]))
	ok(near(d.speed_mult, float(S.CENSER["moveMult"])) and near(d.attack_rate_mult, float(S.CENSER["attackRateMult"])), "incensed: CENSER moveMult / attackRateMult")
	_run(s, 1.0)
	s.apply(&"incensed", null, 1, float(S.CENSER["hasteS"]))
	ok(near(s.remaining(&"incensed"), float(S.CENSER["hasteS"])), "incensed: the pulse refreshes to hasteS")
	s.clear()
	# root / stun / silence / hex
	s.apply(&"root")
	ok(d.speed_mult == 0.0 and near(s.remaining(&"root"), float(S.BONE_PRISON["rootS"])), "root: speed 0 for BONE_PRISON.rootS")
	s.clear()
	s.apply(&"stun", null, 1, 0.5)
	ok(s.is_stunned() and d.stuns == [0.5], "stun: flag + the owner is interrupted via stun()")
	s.apply(&"stun", null, 1, 0.3)
	ok(d.stuns.size() == 1, "stun: a shorter re-apply does not re-interrupt")
	s.apply(&"silence", null, 1, 1.0)
	ok(s.is_silenced(), "silence flag")
	s.clear()
	s.apply(&"hex")
	ok(near(s.damage_dealt_mult(), float(S.BONE_HEX["damageMult"])) and near(s.remaining(&"hex"), float(S.BONE_HEX["durationS"])), "hex: dealt x BONE_HEX.damageMult for durationS")
	s.clear()
	# damage taken
	s.apply(&"sanctified")
	ok(near(s.damage_taken_mult(), float(S.SANCTIFIED["damageTakenMult"])) and near(s.remaining(&"sanctified"), float(S.SANCTIFIED["durationS"])), "sanctified: taken x SANCTIFIED.damageTakenMult for durationS")
	s.apply(&"shrouded")
	ok(near(s.damage_taken_mult(), float(S.SANCTIFIED["damageTakenMult"]) * float(S.AFFIX_TUNING["shrouded"]["damageTakenMult"])), "shrouded x sanctified")
	var fm := int(S.FRACTURE["maxStacks"])
	s.apply(&"fracture", null, 99)
	ok(s.stacks(&"fracture") == fm, "fracture: stacks capped at FRACTURE.maxStacks")
	ok(near(s.damage_taken_mult(), float(S.SANCTIFIED["damageTakenMult"]) * float(S.AFFIX_TUNING["shrouded"]["damageTakenMult"]) * (1.0 + float(S.FRACTURE["perStack"]) * fm)), "fracture: 1 + perStack x stacks")
	var hp0 := d.hp
	DmStatusSet.hit(d, 100.0)
	ok(near(hp0 - d.hp, 100.0 * s.damage_taken_mult()), "DmStatusSet.hit applies the taken multiplier")
	s.clear()
	# barrier
	s.apply(&"barrier", null, 1, -1.0, {"amount": 50.0})
	ok(near(s.remaining(&"barrier"), float(S.BONE_MANTLE["durationS"])) and near(s.absorb(30.0), 0.0) and near(s.absorb(40.0), 20.0) and not s.has(&"barrier"), "barrier: soaks damage, breaks at 0, lasts BONE_MANTLE.durationS")
	# frenzy follows hp (flagellant)
	var fd := Dummy.new()
	fd.name = "F"
	h.add_child(fd)
	fd.def = S.ENEMIES["flagellant"]
	var fs := DmStatusSet.attach(fd)
	_run(fs, 0.3)
	ok(not fs.has(&"frenzy"), "frenzy: off at full hp")
	fd.hp = fd.max_hp * float(S.FRENZY["atFrac"]) * 0.9
	_run(fs, 0.3)
	ok(fs.has(&"frenzy") and near(fd.speed_mult, float(S.FRENZY["moveMult"])) and near(fd.attack_rate_mult, float(S.FRENZY["attackRateMult"])), "frenzy: below atFrac, FRENZY moveMult / attackRateMult")
	fd.hp = fd.max_hp
	_run(fs, 0.3)
	ok(not fs.has(&"frenzy") and fd.speed_mult == 1.0, "frenzy: ends when healed")
	# non-frenzy bodies never get it
	d.hp = 1.0
	_run(s, 0.3)
	ok(not s.has(&"frenzy"), "frenzy: only for defs with the trait")


func _dots_and_credit(h: Node) -> void:
	var S := DmSimData
	var a := Node3D.new()
	a.name = "A"
	h.add_child(a)
	var b := Node3D.new()
	b.name = "B"
	h.add_child(b)
	var d := _dummy(h, "D2")
	var s := DmStatusSet.of(d)
	var lumps: Array = []
	s.dot_damage.connect(func(id, amt, src, killed, _t): lumps.append([id, amt, src, killed]))
	# bleed: stronger dps wins and takes ownership; time resets
	s.apply(&"bleed", a, 1, -1.0, {"dps": 10.0})
	s.apply(&"bleed", b, 1, -1.0, {"dps": 4.0})
	ok(s.source_of(&"bleed") == a, "bleed: a weaker dps does not steal the owner")
	s.apply(&"bleed", b, 1, -1.0, {"dps": 12.0})
	ok(s.source_of(&"bleed") == b, "bleed: a stronger dps takes over")
	s.apply(&"bleed", a, 1, -1.0, {"dps": 10.0})
	s.apply(&"bleed", b, 1, -1.0, {"dps": 12.0})
	var dur := float(S.HEMORRHAGE["durationS"])
	ok(near(s.remaining(&"bleed"), dur), "bleed: duration HEMORRHAGE.durationS")
	_run(s, dur + 0.5)
	var total := 0.0
	for l in lumps:
		total += l[1]
		ok(l[2] == b, "bleed damage credited to its owner")
	ok(near(total, 12.0 * dur, 12.0 * 0.12) and not s.has(&"bleed"), "bleed: total damage == dps x durationS (%.2f vs %.2f)" % [total, 12.0 * dur])
	ok(lumps.size() < dur / 0.25 + 3, "bleed: applied in ~0.25 s lumps (%d lumps)" % lumps.size())
	ok(d.hits.size() == lumps.size() and d.hits[0][1] == b, "DoT goes through the owner's take_damage with the source")
	# withered: stacks, cap, dps x stacks, last stacker owns
	d.hits.clear()
	lumps.clear()
	d.hp = 1e6
	s.apply(&"withered", a, 1, -1.0, {"dps": 5.0, "cap": 3.0})
	s.apply(&"withered", b, 1, -1.0, {"dps": 3.0, "cap": 3.0})
	s.apply(&"withered", a, 5, -1.0, {"dps": 4.0, "cap": 3.0})
	ok(s.stacks(&"withered") == 3 and s.source_of(&"withered") == a, "withered: cap 3, last stacker owns it")
	ok(near(s.remaining(&"withered"), float(S.WITHERED["durationMs"]) / 1000.0), "withered: duration WITHERED.durationMs")
	_run(s, 1.0)
	var w := 0.0
	for l in lumps:
		w += l[1]
	ok(near(w, 3.0 * 5.0 * 1.0, 3.0 * 5.0 * 0.12), "withered: stacks x strongest dps per second (%.2f vs 15)" % w)
	_run(s, 5.0)
	ok(not s.has(&"withered"), "withered: gone WITHERED.durationMs after the last stack")
	# sanctified / fracture scale DoT damage like the sim (dmg x damage_taken_mult)
	lumps.clear()
	s.apply(&"sanctified", null, 1, 2.0)
	s.apply(&"bleed", a, 1, 1.0, {"dps": 10.0})
	_run(s, 1.0)
	var t2 := 0.0
	for l in lumps:
		t2 += l[1]
	ok(near(t2, 10.0 * float(S.SANCTIFIED["damageTakenMult"]), 1.5), "DoT x damage_taken_mult (%.2f)" % t2)
	s.clear()
	# real enemy: kills credit the source, died fires once, statuses cleared on death, two-source slow behaves
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.with_visual = false
	e.use_nav = false
	e.use_avoidance = false
	e.wander_enabled = false
	e.rng_seed = 3
	h.add_child(e)
	var es := DmStatusSet.attach(e)
	var killer := Node3D.new()
	h.add_child(killer)
	var deaths := [0]
	var from: Array = [null]
	e.died.connect(func(_x): deaths[0] += 1)
	e.damaged.connect(func(_a, _hp, f): from[0] = f)
	var kills: Array = []
	es.dot_damage.connect(func(_id, _amt, src, killed, _t): kills.append([src, killed]))
	e.hp = 2.0
	es.apply(&"bleed", killer, 1, -1.0, {"dps": 20.0})
	es.apply(&"slow", a, 1, 5.0)
	es.apply(&"slow", b, 1, 5.0)
	ok(es.ids().size() == 2 and near(e.speed_mult, S.MIASMA_SLOW), "two sources of the same slow: one entry, MIASMA_SLOW")
	_run(es, 0.5)
	ok(e.hp <= 0.0 and deaths[0] == 1 and from[0] == killer, "DoT kill: died once, damaged.from == the status source")
	ok(not kills.is_empty() and kills.back()[0] == killer and kills.back()[1] == true, "dot_damage reports the killing lump with the source")
	ok(es.ids().is_empty() and e.speed_mult == 1.0, "death clears the set and the multipliers")
	e.queue_free()


func _misc(h: Node) -> void:
	var d := _dummy(h, "D3")
	var s := DmStatusSet.of(d)
	s.apply(&"bleed", null, 1, -1.0, {"dps": 1.0})
	s.apply(&"withered", null, 1, -1.0, {"dps": 1.0})
	s.apply(&"root")
	s.apply(&"slow", null, 1, 5.0)
	s.apply(&"chill")
	s.apply(&"hex")
	d.statuses_cleared.emit()
	ok(s.ids() == [&"hex"] and d.speed_mult == 1.0, "statuses_cleared drops bleed/withered/root/slow/chill only")
	ok(DmStatusSet.ensure(d) == s and DmStatusSet.of(h) == null, "ensure() reuses the set; of() is null without one")
	# censer migration: the real kind hastes through the set
	var c: DmEnemy = load("res://enemies/censer.tscn").instantiate()
	c.with_visual = false
	c.use_nav = false
	c.use_avoidance = false
	c.wander_enabled = false
	h.add_child(c)
	var o: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	o.with_visual = false
	o.use_nav = false
	o.use_avoidance = false
	o.wander_enabled = false
	o.position = Vector3(2, 0, 0)
	h.add_child(o)
	c._aura_cd = 0.0
	c._physics_process(0.02)
	var os := DmStatusSet.of(o)
	ok(os != null and os.has(&"incensed") and near(os.remaining(&"incensed"), float(DmSimData.CENSER["hasteS"])) and near(o.speed_mult, float(DmSimData.CENSER["moveMult"])), "censer pulse applies incensed (CENSER.hasteS / moveMult)")
	ok(o.incense_t == 0.0, "DmEnemy.incense_t is no longer written")
	c.free()
	o.free()


func _perf(h: Node) -> void:
	var sets: Array = []
	var ds: Array = []
	for i in 30:
		var d := _dummy(h, "P%d" % i)
		d.hp = 1.0e9
		var s := DmStatusSet.of(d)
		s.apply(&"chill", null, 1, 1.0e6)
		s.apply(&"bleed", null, 1, 1.0e6, {"dps": 3.0})
		s.apply(&"withered", null, 1, 1.0e6, {"dps": 2.0, "cap": 3.0})
		sets.append(s)
		ds.append(d)
	var n := 200
	var t0 := Time.get_ticks_usec()
	for k in n:
		for s in sets:
			(s as DmStatusSet)._step(0.1)
	var per_tick := float(Time.get_ticks_usec() - t0) / n / 30.0
	# re-applying every frame (a cloud refreshing its slow on 30 enemies) must be cheap too
	t0 = Time.get_ticks_usec()
	for k in n:
		for s in sets:
			(s as DmStatusSet).apply(&"chill", null, 1, 1.0e6)
	var per_apply := float(Time.get_ticks_usec() - t0) / n / 30.0
	var bytes: int = (sets[0] as DmStatusSet).encode().size()
	print("PERF: step %.2f us/set (30 sets x 3 statuses; per 0.1 s tick: %.1f us total), refresh-apply %.2f us, wire %d bytes for 3 statuses" % [per_tick, per_tick * 30.0, per_apply, bytes])
	perf_info(per_tick * 30.0 < 2000.0, "perf: 30 enemies x 3 statuses ticks in < 2 ms per 0.1 s step (%.0f us)" % (per_tick * 30.0))
	perf_info(per_apply < 20.0, "perf: a refresh-apply costs < 20 us (%.2f)" % per_apply)
	ok(bytes == 12, "wire: 4 bytes per status")
	for d in ds:
		d.queue_free()


# ---- replication: in-process ENet host + client ------------------------------------------------------------------------------------------

func _replication() -> void:
	var port := DmTestPorts.free_port()
	var nodes: Array = []
	for nm in ["SH", "SC"]:
		var n := Node.new()
		n.name = nm
		root.add_child(n)
		set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
		var d := _dummy(n, "E")
		nodes.append([n, d])
	var hp := ENetMultiplayerPeer.new()
	ok(hp.create_server(port, 2, 0) == OK, "R: server up")
	root.get_node("SH").multiplayer.multiplayer_peer = hp
	var hs: DmStatusSet = DmStatusSet.of(nodes[0][1])
	var cs: DmStatusSet = DmStatusSet.of(nodes[1][1])
	hs.apply(&"chill", null, 1, 30.0)   # before the client joins: late-join sync
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", port)
	root.get_node("SC").multiplayer.multiplayer_peer = cp
	ok(await _wait(func(): return cs.has(&"chill")), "R: a late joiner receives the existing statuses")
	hs.apply(&"withered", null, 2, -1.0, {"dps": 1.0, "cap": 3.0})
	hs.apply(&"slow", null, 1, 20.0)
	ok(await _wait(func(): return cs.has(&"withered") and cs.has(&"slow")), "R: new statuses replicate")
	ok(cs.stacks(&"withered") == 2 and cs.ids().size() == 3, "R: stacks replicate")
	ok(absf(cs.remaining(&"chill") - 30.0) < 1.5, "R: remaining replicates (%.1f)" % cs.remaining(&"chill"))
	hs.apply(&"withered", null, 1, -1.0, {"dps": 1.0, "cap": 3.0})
	ok(await _wait(func(): return cs.stacks(&"withered") == 3), "R: stack change replicates")
	hs.remove(&"slow")
	ok(await _wait(func(): return not cs.has(&"slow")), "R: removal replicates")
	cs.apply(&"hex")
	ok(not cs.has(&"hex"), "R: clients cannot apply (host authoritative)")
	ok(is_equal_approx(nodes[1][1].speed_mult, 1.0), "R: puppets' multipliers are not written (host owns them)")
	# no resend on a plain refresh (replicate on change only)
	var sent := [0]
	cs.changed.connect(func(): sent[0] += 1)
	for i in 5:
		hs.apply(&"chill", null, 1, 30.0)
	hs.advance(0.2)
	await create_timer(0.3).timeout
	ok(sent[0] == 0, "R: refreshes do not generate traffic")
	hs.clear()
	ok(await _wait(func(): return cs.ids().is_empty()), "R: clear replicates")
	for n in nodes:
		(n[0] as Node).queue_free()


func _wait(cond: Callable, timeout := 6.0) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < timeout * 1000.0:
		if cond.call():
			return true
		await create_timer(0.05).timeout
	return cond.call()


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
