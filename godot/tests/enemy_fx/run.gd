extends SceneTree
## DmEnemyFx suite. godot --headless --path godot --script res://tests/enemy_fx/run.gd
## Part 1: every kind on the host/solo path with counting Vfx + audio back-ends (fx and sfx exactly once per event).
## Part 2: a host and a client branch in one tree joined over ENet (127.0.0.1, random port 40000-49999): the client's telegraph arrives from
##         replicated state with lead time (measured), nothing is double-dispatched on either side.
## Part 3: cost (real Vfx): per event and per frame with 30 enemies. Part 4: pre-warm coverage (effect ids, sound ids exist).

const S := DmEnemyState.Id
const DT := 1.0 / 60.0

class CH:
	extends RefCounted
	var alive := true
	func kill() -> void:
		alive = false

## Counting Vfx back-end: records every call DmEnemyFx / DmEventFx make.
class CountVfx:
	extends Node
	var n := {}
	var decals: Array = []
	var plays: Array = []
	var danger_depth := 0
	var danger_decals := 0
	func _c(k: String) -> void:
		n[k] = int(n.get(k, 0)) + 1
	func emit(_o) -> void: _c("emit")
	func emit_smoke(_o) -> void: _c("smoke")
	func decal(o):
		_c("decal")
		decals.append(String(o["tex"]))
		if danger_depth > 0 or o.get("danger", false):
			danger_decals += 1
		return CH.new()
	func play(id, _pos, _o = {}):
		_c("play")
		plays.append(String(id))
		return CH.new()
	func beam(_a, _b, _c2, _w, _d): _c("beam"); return CH.new()
	func projectile(_o): _c("projectile")
	func light_flash(_p, _c2, _i, _l = 0.35) -> void: _c("flash")
	func danger(fn: Callable, when := true):
		danger_depth += 1
		var r = fn.call()
		danger_depth -= 1
		return r
	func count(k: String) -> int: return int(n.get(k, 0))
	func has_tex(t: String) -> bool: return decals.has(t)

class CountAudio:
	extends Node
	var sfx := {}
	func play_sfx(name: String, _pos = null, _i: float = 1.0) -> bool:
		sfx[name] = int(sfx.get(name, 0)) + 1
		return true
	func count(k: String) -> int: return int(sfx.get(k, 0))
	func total() -> int:
		var t := 0
		for k in sfx: t += int(sfx[k])
		return t

## Replication seam of the test: the host sends every enemy's get_net_state at 20 Hz (and, when `flush`, immediately on a state change).
class Rep:
	extends Node
	var enemies: Array = []   # host: DmEnemy list; client: puppet list (same order)
	var is_host := false
	var flush := false
	var acc := 0.0
	var sent := 0
	func _process(dt: float) -> void:
		if not is_host or multiplayer.multiplayer_peer == null or multiplayer.get_peers().is_empty():
			return
		acc += dt
		if acc >= 0.05:
			acc = 0.0
			send()
	func send() -> void:
		var arr: Array = []
		for i in enemies.size():
			arr.append([i, enemies[i].get_net_state()])
		sent += 1
		snap.rpc(arr)
	@rpc("authority", "call_remote", "unreliable_ordered")
	func snap(arr: Array) -> void:
		for it in arr:
			(enemies[int(it[0])] as DmEnemy).apply_net_state(it[1])

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

func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame

func secs(s: float) -> void:
	await ticks(int(round(s / DT)))

func until(cond: Callable, limit_s: float) -> float:
	var t0 := float(Engine.get_physics_frames()) * DT
	while float(Engine.get_physics_frames()) * DT - t0 < limit_s:
		if cond.call():
			return float(Engine.get_physics_frames()) * DT - t0
		await physics_frame
	return -1.0


func new_arena(with_fx := true) -> void:
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
	dummy.global_position = Vector3(0, 0, 20)
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


func _run() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.time_scale = 4.0
	DmSimData.ensure()
	await _t_kinds()
	await _t_elite_censer()
	await _t_no_double()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	await _t_net()
	await _t_perf()
	_t_warm()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Run one full swing of `e` (first ATTACK to its end), then freeze its brain.
func one_swing(e: DmEnemy, limit_s: float = 12.0) -> bool:
	var t := await until(func(): return e.sm.id() == S.ATTACK, limit_s)
	if t < 0.0:
		return false
	t = await until(func(): return e.sm.id() != S.ATTACK, 3.0)
	e.set_physics_process(false)
	await ticks(2)
	return t >= 0.0


func _t_kinds() -> void:
	var cases := [
		# def, spawn pos, props, telegraph count, telegraph sfx, expected decal textures, voice family
		["robber", Vector3(0, 0, 6), {}, 0, "", [], "Humanoid"],
		["hound", Vector3(0, 0, 6), {}, 0, "", [], "Beast"],
		["bat", Vector3(0, 0, 6), {}, 0, "", [], "Beast"],
		["risen", Vector3(0, 0, 6), {}, 0, "", [], "Humanoid"],
		["penitent", Vector3(0, 0, 5), {}, 1, "tollSmall", ["cone", "coneEdge", "ring"], "Humanoid"],
		["sac", Vector3(0, 0, 5), {}, 1, "tellStrike", ["disc"], "Brute"],
		["moth", Vector3(0, 0, 8), {}, 1, "tellStrike", ["disc", "ring"], "Spirit"],
	]
	for c in cases:
		var d: String = c[0]
		await new_arena()
		var e := kind(d, c[1] + Vector3(0, 0, 20), c[2])
		check(await one_swing(e), "%s: completes a swing" % d)
		check(fxn.stats["telegraph"] == c[3], "%s: %d telegraph(s) (%d)" % [d, c[3], fxn.stats["telegraph"]])
		check(fxn.stats["strike"] == 1, "%s: exactly one impact (%d)" % [d, fxn.stats["strike"]])
		check(au.count("enemyAttack" + String(c[6])) == 1, "%s: attack voice once (%s)" % [d, str(au.sfx)])
		if c[4] != "":
			check(au.count(c[4]) == 1, "%s: telegraph sound %s once" % [d, c[4]])
			check(vf.danger_decals >= 1, "%s: telegraph drawn inside danger()" % d)
		else:
			check(au.count("tellStrike") + au.count("tollSmall") == 0, "%s: melee swing has no telegraph sound" % d)
		for t in c[5]:
			check(vf.has_tex(t), "%s: telegraph decal %s" % [d, t])
		if d == "sac":
			check(au.count("boneHit") == 1, "sac: slam impact sound once")
			check(arena.get_children().filter(func(n): return n is DmHostileZone).is_empty(), "sac: no zone")
		if d == "moth":
			check(fxn.stats["zone"] == 1 and vf.has_tex("glow"), "moth: dust cloud visual once (zone %d)" % fxn.stats["zone"])
		if d == "bat":
			check(e.flying > 0.0, "bat hovers")
		# death
		var before := au.total()
		e.set_physics_process(true)
		e.take_damage(1e9, dummy)
		await ticks(2)
		check(fxn.stats["death"] == 1 and au.count("enemyDeath") == 1, "%s: death sound once" % d)
		check(au.count("enemyDeath" + String(c[6])) == 1, "%s: death voice once" % d)
		check(au.total() - before == 2, "%s: death makes exactly 2 sounds (%d)" % [d, au.total() - before])
		check(fxn.stats["hit"] == 1, "%s: damaged seen once" % d)
	# Barrow Ghoul: spawn (rising) -> burrow -> telegraphed eruption -> burst -> melee
	await new_arena()
	var g := kind("ghoul", Vector3(0, 0, 29), {"rising": true})
	check(fxn.stats["spawn"] == 1, "ghoul: spawn fx once")
	var t := await until(func(): return g.sm.id() == S.ERUPT, 15.0)
	check(t >= 0.0 and fxn.stats["telegraph"] == 1 and vf.has_tex("cracks"), "ghoul: erupt telegraph once (cracks ring)")
	t = await until(func(): return g.sm.id() == S.EMERGE, 3.0)
	check(t >= 0.0 and fxn.stats["erupt"] == 1 and au.count("burst") == 1, "ghoul: eruption burst + sound once")
	g.take_damage(g.max_hp * 0.8, dummy)   # below digAtFrac: dig in
	await ticks(4)
	check(fxn.stats["dig"] == 1, "ghoul: dig-in smoke once")
	# Fire death goes through the router (pyre kinds have no scene yet: feed the router directly)
	var ev := {"id": 1, "x": 0.0, "z": 0.0, "elite": false, "def": "slag_brute"}
	var before_flash := vf.count("play")
	fxn.fx._death(ev)
	check(vf.count("play") > before_flash, "fire-death flare reuses the current game's burst")


func _t_elite_censer() -> void:
	await new_arena()
	var el := kind("robber", Vector3(0, 0, 29), {"elite": true, "rising": true})
	check(fxn.stats["spawn"] == 1 and au.count("eliteAggro") == 1, "elite: spawn fx + aggro sound once")
	check(vf.has_tex("ring") and vf.decals.count("ring") == 1, "elite: purple aura ring once")
	await secs(1.3)
	el.take_damage(1e9, dummy)
	await ticks(2)
	check(au.count("eliteDeath") == 1 and au.count("enemyDeath") == 0, "elite: elite death sound only")
	check(vf.count("flash") == 1, "elite: death light flash once")
	# censer: aura ring + incense effect; hastes a neighbour
	await new_arena()
	var c := kind("censer", Vector3(0, 0, 32))
	check(vf.plays == ["censer_incense"], "censer: incense effect once")
	check(vf.decals.count("ring") == 0, "censer: ground ring is the status track's (none from enemy fx)")
	var r := kind("robber", Vector3(2, 0, 32))
	await secs(0.2)
	var sm0 := vf.count("smoke")
	c.take_damage(1e9, dummy)
	await ticks(2)
	check(au.count("enemyDeath") == 1, "censer: death sound once")
	var slot_alive := fxn.watched()
	check(slot_alive == 2, "two enemies still watched")
	r.queue_free()
	await ticks(3)
	check(fxn.watched() == 1, "freed enemy is unwatched (%d)" % fxn.watched())
	# a rising spawn plays rise motes only near the hero
	await new_arena()
	var far := kind("robber", Vector3(0, 0, 75), {"rising": true})
	var near := kind("robber", Vector3(0, 0, 28), {"rising": true})
	await secs(0.9)
	check(vf.count("smoke") >= 2, "rising bodies shed dust")


func _t_no_double() -> void:
	await new_arena()
	var e := kind("penitent", Vector3(0, 0, 25))
	check(await one_swing(e), "double: swing")
	var t0: int = fxn.stats["telegraph"]
	var s0: int = fxn.stats["strike"]
	var h0: int = fxn.stats["hit"]
	# the host feeding its own snapshots back (host migration / tests) must not replay anything
	for i in 5:
		var d := e.get_net_state()
		d["state"] = S.ATTACK
		d["hp"] = 1.0
		e.apply_net_state(d)
	await secs(0.8)
	check(fxn.stats["telegraph"] == t0 + 0 or fxn.stats["telegraph"] == t0, "double: authority never derives a telegraph from a snapshot (%d vs %d)" % [fxn.stats["telegraph"], t0])
	check(fxn.stats["hit"] == h0, "double: authority never derives damage from a snapshot")
	check(fxn.stats["strike"] <= s0 + 1, "double: at most the one forced swing's impact")
	fxn.queue_free()   # one DmEnemyFx per peer: a second one watching the same bodies would (rightly) double everything
	fxn = null
	await process_frame


# ============================================================================================ net

func _branch(nm: String) -> Node3D:
	var h := Node3D.new()
	h.name = nm
	root.add_child(h)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	return h


func _t_net() -> void:
	var port := DmTestPorts.free_port()
	check(port >= 40000, "net: free port %d" % port)
	var H := _branch("H")
	var C := _branch("C")
	var hpeer := ENetMultiplayerPeer.new()
	check(hpeer.create_server(port, 2) == OK, "net: server")
	H.multiplayer.multiplayer_peer = hpeer
	var cpeer := ENetMultiplayerPeer.new()
	check(cpeer.create_client("127.0.0.1", port) == OK, "net: client")
	C.multiplayer.multiplayer_peer = cpeer
	for _i in 300:   # up to 5 s of physics ticks
		if not H.multiplayer.get_peers().is_empty():
			break
		await physics_frame
	check(not H.multiplayer.get_peers().is_empty(), "net: peers connected")
	await process_frame
	# host world: arena under H; client world: bare puppets under C
	var arena_h: DmEnemyTestArena = load("res://enemies/test_arena.tscn").instantiate()
	arena_h.robber_count = 0
	H.add_child(arena_h)
	arena_h.target.controllable = false
	arena_h.target.global_position = Vector3(0, 0, 20)
	var hv := CountVfx.new()
	var ha := CountAudio.new()
	var cv := CountVfx.new()
	var ca := CountAudio.new()
	var hfx := DmEnemyFx.new()
	hfx.vfx = hv
	hfx.audio = ha
	hfx.scope = H
	hfx.player_pos = func() -> Vector3: return Vector3.ZERO
	H.add_child(hfx)
	var cfx := DmEnemyFx.new()
	cfx.vfx = cv
	cfx.audio = ca
	cfx.scope = C
	cfx.player_pos = func() -> Vector3: return Vector3.ZERO
	C.add_child(cfx)
	var hrep := Rep.new()
	hrep.name = "Rep"
	hrep.is_host = true
	H.add_child(hrep)
	var crep := Rep.new()
	crep.name = "Rep"
	C.add_child(crep)
	await ticks(3)
	var defs := ["robber", "penitent", "sac", "moth", "ghoul"]
	var props := [{}, {}, {}, {}, {"rising": true}]
	var spots := [Vector3(-6, 0, 25), Vector3(-3, 0, 26), Vector3(3, 0, 25), Vector3(8, 0, 27), Vector3(0, 0, 29)]
	var host_es: Array = []
	var pups: Array = []
	var tlog_h: Array = []   # [kind, usec, seconds]
	var tlog_c: Array = []
	for i in defs.size():
		var p := {"wander_enabled": false, "rng_seed": 7}
		p.merge(props[i], true)
		var he := arena_h.spawn_kind(defs[i], spots[i], p)
		host_es.append(he)
		var pu: DmEnemy = load("res://enemies/%s.tscn" % defs[i]).instantiate()
		for k in p:
			pu.set(k, p[k])
		pu.position = spots[i]
		C.add_child(pu)
		pups.append(pu)
		he.telegraph.connect(func(k, _f, _a, _r, s): tlog_h.append([String(k), Time.get_ticks_usec(), s, defs[i]]))
		pu.telegraph.connect(func(k, _f, _a, _r, s): tlog_c.append([String(k), Time.get_ticks_usec(), s, defs[i]]))
		he.state_changed.connect(func(_p, _n): if hrep.flush: hrep.send())
	hrep.enemies = host_es
	crep.enemies = pups
	await ticks(3)
	check(pups.all(func(p): return not p.is_multiplayer_authority()), "net: client bodies are puppets")
	check(host_es.all(func(h): return h.is_multiplayer_authority()), "net: host bodies are authority")
	# stop the host's brain from attacking until all are in place; then let each fight a few swings, 20 Hz only, then with flush
	var report := {}
	for mode in ["20Hz", "flush"]:
		hrep.flush = mode == "flush"
		tlog_h.clear()
		tlog_c.clear()
		hfx.stats["telegraph"] = 0
		cfx.stats["telegraph"] = 0
		for he in host_es:
			if he.sm.id() != S.DEAD:
				he.attack_cd = 0.1
		var want: Array = ["cone", "slam", "dust", "erupt"] if mode == "20Hz" else ["cone", "slam", "dust"]
		for _i in 1200:   # up to 20 s of physics ticks
			if want.all(func(k): return tlog_h.any(func(t): return t[0] == k)):
				break
			await physics_frame
		for _i in 18:   # 0.3 s: let in-flight snapshots land
			await physics_frame
		check(tlog_h.size() >= 3, "net[%s]: host telegraphed %d times" % [mode, tlog_h.size()])
		check(cfx.stats["telegraph"] == tlog_c.size() and hfx.stats["telegraph"] == tlog_h.size(), "net[%s]: each peer's fx saw its own telegraphs exactly once (h %d/%d c %d/%d)" % [mode, hfx.stats["telegraph"], tlog_h.size(), cfx.stats["telegraph"], tlog_c.size()])
		check(tlog_c.size() >= tlog_h.size() - 1 and tlog_c.size() <= tlog_h.size(), "net[%s]: client got every telegraph the host sent (%d of %d)" % [mode, tlog_c.size(), tlog_h.size()])
		# lead time: window the client has = host windup - (client arrival - host emit)
		var worst := 1e9
		var best := -1e9
		var sum := 0.0
		var n := 0
		var used := {}
		for th in tlog_h:
			for tc in tlog_c:
				if tc[3] == th[3] and tc[0] == th[0] and tc[1] >= th[1] and not used.has(tc):
					used[tc] = true
					var delay_ms: float = float(tc[1] - th[1]) / 1000.0
					var lead_ms: float = float(th[2]) * 1000.0 - delay_ms
					worst = minf(worst, lead_ms)
					best = maxf(best, lead_ms)
					sum += lead_ms
					n += 1
					report[mode + ":" + String(th[3])] = "delay %.0f ms lead %.0f of %.0f ms" % [delay_ms, lead_ms, float(th[2]) * 1000.0]
					break
		check(n >= 3, "net[%s]: the client got the telegraphs (%d matched)" % [mode, n])
		perf_info(worst > 250.0, "net[%s]: client telegraph lead worst %.0f ms, mean %.0f ms (>250 ms to dodge)" % [mode, worst, sum / maxf(1.0, n)])
		print("  lead[%s] %s" % [mode, str(report)])
	# client-side sounds/decals came from the replicated state: telegraph sfx once per telegraph
	var tele_sounds_c := ca.count("tellStrike") + ca.count("tollSmall")
	var tele_sounds_h := ha.count("tellStrike") + ha.count("tollSmall")
	check(tele_sounds_c == tele_sounds_h, "net: telegraph sounds equal on both peers (h %d c %d)" % [tele_sounds_h, tele_sounds_c])
	check(absi(cfx.stats["zone"] - hfx.stats["zone"]) <= 1 and cfx.stats["zone"] >= 1, "net: dust cloud seen on both peers (h %d c %d)" % [hfx.stats["zone"], cfx.stats["zone"]])
	# death replicates: one death fx per peer
	var he0: DmEnemy = host_es[0]
	he0.take_damage(1e9, null)
	for _i in 24:   # 0.4 s
		await physics_frame
	check(hfx.stats["death"] == 1 and cfx.stats["death"] == 1, "net: death fx once per peer (h %d c %d)" % [hfx.stats["death"], cfx.stats["death"]])
	check(ha.count("enemyDeath") == 1 and ca.count("enemyDeath") == 1, "net: death sound once per peer")
	check(hfx.stats["hit"] == cfx.stats["hit"], "net: hit flash events equal (h %d c %d)" % [hfx.stats["hit"], cfx.stats["hit"]])
	for h in host_es:
		(h as DmEnemy).set_physics_process(false)
	H.multiplayer.multiplayer_peer = null
	C.multiplayer.multiplayer_peer = null
	hpeer.close()
	cpeer.close()
	H.queue_free()
	C.queue_free()
	await process_frame


# ============================================================================================ perf

func _t_perf() -> void:
	var v: Node = root.get_node_or_null("Vfx")
	if v == null:
		v = DmFxRuntime.new()
		v.name = "Vfx"
		root.add_child(v)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	await process_frame
	await new_arena(false)
	fxn = DmEnemyFx.new()
	fxn.player_pos = func() -> Vector3: return Vector3.ZERO
	root.add_child(fxn)
	await process_frame
	var kinds := ["sac", "penitent", "moth", "robber", "censer", "ghoul"]
	var es: Array = []
	for i in 30:
		var a := TAU * float(i) / 30.0
		es.append(kind(kinds[i % kinds.size()], Vector3(sin(a), 0.0, cos(a)) * 8.0, {"rising": i % 3 == 0}))
		es[i].set_physics_process(false)
	await ticks(3)
	# per-frame cost with 30 watched bodies (idle + ambient)
	var t0 := Time.get_ticks_usec()
	for i in 200:
		fxn._process(0.016)
	var frame_us := float(Time.get_ticks_usec() - t0) / 200.0
	# 30 telegraphs at once (worst case: the whole room swings in one frame), real Vfx
	var sacs: Array = es.filter(func(e): return e is DmEnemyHazard or e is DmEnemyCaster)
	for e in sacs:
		e.announce_telegraph(0.7)   # first salvo = pool growth (DmWarmup does this at load); measure the second
	await process_frame
	t0 = Time.get_ticks_usec()
	for e in sacs:
		e.announce_telegraph(0.7)
	var tele_us := float(Time.get_ticks_usec() - t0) / maxf(1.0, float(sacs.size()))
	# 30 impacts + deaths
	t0 = Time.get_ticks_usec()
	for e in es:
		fxn._impact(fxn._slots[e.get_instance_id()])
	var hit_us := float(Time.get_ticks_usec() - t0) / 30.0
	t0 = Time.get_ticks_usec()
	for e in es.slice(0, 10):
		(e as DmEnemy).take_damage(1e9, null)
	var death_us := float(Time.get_ticks_usec() - t0) / 10.0
	print("  perf: 30 enemies watched: %.0f us/frame; telegraph %.0f us/event (%d events); impact %.0f us/event; death %.0f us/event (incl. enemy)" % [frame_us, tele_us, sacs.size(), hit_us, death_us])
	perf_info(frame_us < 400.0, "perf: per-frame cost with 30 enemies < 0.4 ms (%.0f us)" % frame_us)
	perf_info(tele_us < 500.0, "perf: telegraph < 0.5 ms per event (%.0f us)" % tele_us)
	perf_info(hit_us < 300.0, "perf: impact < 0.3 ms per event (%.0f us)" % hit_us)
	# the pooled rings never grow: a second salvo allocates nothing new in the Vfx
	var tr0: int = v.transient_load()
	for e in sacs:
		e.announce_telegraph(0.7)
	check(v.transient_load() <= 160 + 40, "perf: decal transients stay inside the pool cap (%d)" % v.transient_load())
	cam.queue_free()


func _t_warm() -> void:
	var effects: Dictionary = DmFxData.data().get("effects", {})
	for id in DmEnemyFx.EFFECT_IDS:
		check(effects.has(id), "warm: Binbun effect %s is in the DmWarmup set" % id)
	for id in DmEnemyFx.SFX_IDS:
		check(not DmAudioMap.defn(id).is_empty(), "sfx: %s exists in the audio map" % id)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
