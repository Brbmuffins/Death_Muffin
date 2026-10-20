extends SceneTree
## DmEnemyFx on the combat core's events (client/next/enemy_fx). godot --headless --path client --script res://tests/enemy_fx/run.gd
## Part 1: every kind on the host/solo path with counting Vfx + audio back-ends (fx and sfx exactly once per event); the enemies are bodies of the core with their own brains,
##         swinging at a hero who cannot fall.
## Part 2: a host game and a client game in one tree joined over ENet (127.0.0.1, a free port): the client's fx plays what its puppet core's events say, once, the same telegraphs
##         and the same deaths as the host's.
## Part 3: pre-warm coverage (effect ids, sound ids exist).
## Not here: the cost of the old per-enemy watchers and the pooled decal transients' cap (tests/benchmark.gd and draw_budget.gd count what the fight costs now).

const DT := 1.0 / 60.0
const S_ERUPT := DmCoreEvents.State.ERUPT
const S_EMERGE := DmCoreEvents.State.EMERGE

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
	func reset() -> void:
		n.clear()
		decals.clear()
		plays.clear()
		danger_depth = 0
		danger_decals = 0

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
	func reset() -> void:
		sfx.clear()

class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var passed := 0
var failed := 0
var errlog := ErrorLog.new()
var api: DmApi
var character: Dictionary
var g: DmNextGame
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var vf: CountVfx
var au: CountAudio
var fxn: DmEnemyFx
var origin := Vector3.ZERO
var dirv := Vector3(1, 0, 0)    ## the way the arena runs (clear ground of at least 16 m)
var side := Vector3(0, 0, 1)


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


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	DmSimData.ensure()
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("efx%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	character = (await api.load_or_create_character(2)).data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"areas": ["graves"], "dressing": false, "persist": false, "waves": false, "wander": false, "hud": false, "audio": false})
	host = g.core_host
	core = host.core
	hero = g.local_body()
	hero.p["god"] = true   # the hero stands and cannot fall
	origin = hero.position
	find_arena()
	vf = CountVfx.new()
	au = CountAudio.new()
	fxn = g.enemy_fx
	fxn.set_backends(vf, au)
	await ticks(3)
	await _t_kinds()
	await _t_elite_censer()
	g.queue_free()
	await ticks(3)
	await _t_net()
	_t_warm()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%d passed, %d failed" % [passed, failed])
	print("%s enemy_fx %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


## The first direction from the hero along which the ground (the navigation mesh, flat distance) is clear for 16 m, and 3 m to either side (tests/rites.gd's).
func find_arena() -> void:
	var map: RID = g.world.nav_map()
	var best := -1.0
	for a in range(0, 360, 15):
		var d := Vector3(cos(deg_to_rad(a)), 0.0, sin(deg_to_rad(a)))
		var s := Vector3(-d.z, 0.0, d.x)
		var run := 0.0
		for k in range(1, 19):
			var ok := true
			for off in [-3.0, 0.0, 3.0]:
				var q: Vector3 = origin + d * float(k) + s * off
				var cp := NavigationServer3D.map_get_closest_point(map, q)
				if Vector2(cp.x - q.x, cp.z - q.z).length() > 0.3:
					ok = false
			if not ok:
				break
			run = float(k)
		if run > best:
			best = run
			dirv = d
			side = s
		if run >= 18.0:
			break
	check(best >= 16.0, "the arena: ground clear for %.0f m along (%.2f, %.2f)" % [best, dirv.x, dirv.z])


## A point `along` metres from the hero's place along the arena and `across` to the side.
func at(along: float, across := 0.0) -> Vector3:
	return origin + dirv * along + side * across


## A fresh scene: the enemies and corpses gone, the hero at his place, the counting back-ends and the fx's counters zero.
func new_arena() -> void:
	for id in core.enemy_ids():
		host.remove_enemy(int(id))
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	await ticks(3)
	hero.teleport(origin)
	hero.heal(1e6)
	vf.reset()
	au.reset()
	for k in fxn.stats:
		fxn.stats[k] = 0
	await ticks(3)


func kind(def_id: String, along: float, rising := false, elite := false, across := 0.0) -> int:
	return host.spawn_enemy(def_id, at(along, across), 1, 1.0, 1.0, elite, "graves", rising)


## How long a body of `def` standing `along` metres from the hero can take to land its first blow: it walks up, winds up and may wait out its cooldown (twelve seconds at the least).
func swing_limit(def: String, along: float) -> float:
	var e: Dictionary = DmSimData.ENEMIES[def]
	return maxf(12.0, DmSimConsts.RISE_TIME + along / maxf(0.1, float(e["speed"])) + float(e["windupMs"]) / 1000.0 + float(e["cooldownMs"]) / 1000.0 + 4.0)


## Run one full swing of `id` (its first impact), then freeze it.
func one_swing(id: int, limit_s: float = 12.0) -> bool:
	var s0: int = fxn.stats["strike"]
	var t := await until(func() -> bool: return int(fxn.stats["strike"]) > s0, limit_s)
	await ticks(8)   # the blow itself (a cloud, a slam's pool) follows the impact's picture by a tick or two; nothing swings twice in that time
	core.stun(id, 3600.0)
	await ticks(2)
	return t >= 0.0


func _t_kinds() -> void:
	var cases := [
		# def, spawn distance from the hero (along the arena), telegraph count, telegraph sfx, expected decal textures (the voices are the audio map's own: DmAudioMap.enemy_voice)
		["robber", 6.0, 0, "", []],
		["hound", 6.0, 0, "", []],
		["bat", 6.0, 0, "", []],
		["risen", 6.0, 0, "", []],
		["penitent", 5.0, 1, "tollSmall", ["cone", "coneEdge", "ring"]],
		["sac", 5.0, 1, "tellStrike", ["disc"]],
		["moth", 8.0, 1, "tellStrike", ["disc", "ring"]],
	]
	for c in cases:
		var d: String = c[0]
		await new_arena()
		var id := kind(d, float(c[1]))
		var voice := DmAudioMap.enemy_voice(d)
		check(voice != "", "%s: has a voice family in the audio map" % d)
		check(await one_swing(id, swing_limit(d, float(c[1]))), "%s: completes a swing" % d)
		check(fxn.stats["telegraph"] == c[2], "%s: %d telegraph(s) (%d)" % [d, c[2], fxn.stats["telegraph"]])
		check(fxn.stats["strike"] == 1, "%s: exactly one impact (%d)" % [d, fxn.stats["strike"]])
		check(au.count(DmAudioMap.voice_attack(voice)) == 1, "%s: attack voice once (%s)" % [d, str(au.sfx)])
		if c[3] != "":
			check(au.count(c[3]) == 1, "%s: telegraph sound %s once" % [d, c[3]])
			check(vf.danger_decals >= 1, "%s: telegraph drawn inside danger()" % d)
		else:
			check(au.count("tellStrike") + au.count("tollSmall") == 0, "%s: melee swing has no telegraph sound" % d)
		for t in c[4]:
			check(vf.has_tex(t), "%s: telegraph decal %s" % [d, t])
		if d == "sac":
			check(au.count("boneHit") == 1, "sac: slam impact sound once")
			check(fxn.stats["zone"] == 0, "sac: no zone")
		if d == "moth":
			check(fxn.stats["zone"] == 1 and vf.has_tex("glow"), "moth: dust cloud visual once (zone %d)" % fxn.stats["zone"])
		if d == "bat":
			check(float(core.enemy_info(id)["flying"]) > 0.0 if core.enemy_info(id).has("flying") else bool(DmContent.enemy("bat").get("flying", false)), "bat hovers")
		# death
		var before := au.total()
		core.damage(id, 1e9, hero.core_id)
		await ticks(2)
		check(fxn.stats["death"] == 1 and au.count("enemyDeath") == 1, "%s: death sound once" % d)
		check(au.count(DmAudioMap.voice_death(voice)) == 1, "%s: death voice once" % d)
		check(au.total() - before == 2, "%s: death makes exactly 2 sounds (%d)" % [d, au.total() - before])
		check(fxn.stats["hit"] == 1, "%s: damaged seen once" % d)
	# Barrow Ghoul: spawn (rising) -> burrow -> telegraphed eruption -> burst -> melee
	await new_arena()
	var gh := kind("ghoul", 11.0, true)
	await ticks(2)   # the core's events reach the fx at the end of the tick
	check(fxn.stats["spawn"] == 1, "ghoul: spawn fx once")
	var burrow: Dictionary = DmSimData.BURROW
	var t := await until(func() -> bool: return int(core.enemy_info(gh)["state"]) == S_ERUPT, maxf(15.0, DmSimConsts.RISE_TIME + 11.0 / float(burrow["speed"]) + float(burrow["digS"]) + 8.0))
	check(t >= 0.0 and fxn.stats["telegraph"] == 1 and vf.has_tex("cracks"), "ghoul: erupt telegraph once (cracks ring)")
	t = await until(func() -> bool: return int(core.enemy_info(gh)["state"]) == S_EMERGE, 3.0)
	check(t >= 0.0 and fxn.stats["erupt"] == 1 and au.count("burst") == 1, "ghoul: eruption burst + sound once")
	var mx := float(core.enemy_info(gh)["max_hp"])
	core.damage(gh, mx * (1.0 - float(burrow["digAtFrac"]) * 0.4), hero.core_id)   # below digAtFrac: dig in
	await ticks(4)
	check(fxn.stats["dig"] == 1, "ghoul: dig-in smoke once")
	# Fire death goes through the router (the pyre kinds): the flare reuses the current game's burst
	var ev := {"id": 1, "x": 0.0, "z": 0.0, "elite": false, "def": "slag_brute"}
	var before_flash := vf.count("play")
	fxn.fx._death(ev)
	check(vf.count("play") > before_flash, "fire-death flare reuses the current game's burst")


func _t_elite_censer() -> void:
	await new_arena()
	var el := kind("robber", 11.0, true, true)
	await ticks(2)
	check(fxn.stats["spawn"] == 1 and au.count("eliteAggro") == 1, "elite: spawn fx + aggro sound once")
	check(vf.has_tex("ring") and vf.decals.count("ring") == 1, "elite: purple aura ring once")
	await secs(DmEnemyFx.RISE_S + 0.2)
	core.stun(el, 3600.0)
	core.damage(el, 1e9, hero.core_id)
	await ticks(2)
	check(au.count("eliteDeath") == 1 and au.count("enemyDeath") == 0, "elite: elite death sound only")
	check(vf.count("flash") == 1, "elite: death light flash once")
	# censer: aura ring + incense effect; hastes a neighbour
	await new_arena()
	var c := kind("censer", 14.0)
	await ticks(2)
	check(vf.plays == ["censer_incense"], "censer: incense effect once")
	check(vf.decals.count("ring") == 0, "censer: ground ring is the status track's (none from enemy fx)")
	var r := kind("robber", 14.0, false, false, 2.0)
	core.stun(r, 3600.0)
	await secs(0.2)
	check(fxn.watched() >= 1, "the censer is held while it lives: its incense (%d held)" % fxn.watched())
	core.damage(c, 1e9, hero.core_id)
	await ticks(2)
	check(au.count("enemyDeath") == 1, "censer: death sound once")
	check(fxn.watched() == 0, "a dead censer's incense is let go, and a plain robber is never held (%d held)" % fxn.watched())
	host.remove_enemy(r)
	await ticks(3)
	check(fxn.watched() == 0, "a removed enemy is let go (%d held)" % fxn.watched())
	# a rising spawn plays rise motes only near the hero
	await new_arena()
	var far := host.spawn_enemy("robber", origin + dirv * (maxf(DmEnemyFx.ELITE_AGGRO_RANGE, maxf(DmEnemyFx.NEAR_X, DmEnemyFx.NEAR_Z)) + 15.0), 1, 1.0, 1.0, false, "graves", true)
	var near := kind("robber", 10.0, true)
	await secs(DmEnemyFx.RISE_S * 0.8)
	check(vf.count("smoke") >= 2, "rising bodies shed dust")
	core.stun(far, 3600.0)
	core.stun(near, 3600.0)


# ============================================================================================ net

## One host and one client DmNextGame over ENet loopback (each in its own SceneMultiplayer branch, like tests/coop.gd).
func _t_net() -> void:
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	var hg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	var cg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	var port := DmTestPorts.free_port()
	check(port >= 1024, "net: free port %d" % port)
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(port, 2) == OK, "net: server")
	await hg.start(character, api, {"peer": sp, "areas": ["graves"], "dressing": false, "waves": false, "wander": false, "hud": false, "persist": false, "audio": false})
	var cp := ENetMultiplayerPeer.new()
	check(cp.create_client("127.0.0.1", port) == OK, "net: client")
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "waves": false, "hud": false, "persist": false, "audio": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0) >= 0.0, "net: peers connected")
	check(cg.is_guest and cg.core_host.puppet and not hg.core_host.puppet, "net: the client's core is a puppet, the host's is not")
	var hh := hg.local_body()
	var cb := hg.body_of(cg.session.get_my_id())   # the client's body, simulated on the host
	hh.p["god"] = true
	cb.p["god"] = true
	var hv := CountVfx.new()
	var ha := CountAudio.new()
	var cv := CountVfx.new()
	var ca := CountAudio.new()
	hg.enemy_fx.set_backends(hv, ha)
	cg.enemy_fx.set_backends(cv, ca)
	var tlog_h: Array = []   # [kind, usec, seconds]
	var tlog_c: Array = []
	hg.core_host.telegraph.connect(func(id: int, tell: int, _fx: float, _fz: float, _ax: float, _az: float, _r: float, s: float) -> void: tlog_h.append([tell, Time.get_ticks_usec(), s, id]))
	cg.core_host.telegraph.connect(func(id: int, tell: int, _fx: float, _fz: float, _ax: float, _az: float, _r: float, s: float) -> void: tlog_c.append([tell, Time.get_ticks_usec(), s, id]))
	await ticks(3)
	for b in [hh, cb]:
		b.teleport(origin)
	var defs := ["robber", "penitent", "sac", "moth", "ghoul"]
	var spots := [at(7.0, -3.0), at(8.0, -1.5), at(7.0, 1.5), at(9.0, 3.0), at(11.0, 0.0)]
	var ids: Array[int] = []
	for i in defs.size():
		ids.append(hg.core_host.spawn_enemy(defs[i], spots[i], 1, 1.0, 1.0, false, "graves", defs[i] == "ghoul"))
	await ticks(3)
	var n := 0
	var swing_s := 25.0   # up to 25 s of physics ticks, or longer when the slowest of them needs it: let the room swing
	for d: String in defs:
		swing_s = maxf(swing_s, swing_limit(d, 11.0) * 2.0)
	for _i in int(swing_s * 60.0):
		if tlog_h.size() >= 4 and hg.enemy_fx.stats["strike"] >= 3:
			break
		await physics_frame
	for _i in 30:   # 0.5 s: let in-flight batches land
		await physics_frame
	check(tlog_h.size() >= 3, "net: host telegraphed %d times" % tlog_h.size())
	check(cg.enemy_fx.stats["telegraph"] == tlog_c.size() and hg.enemy_fx.stats["telegraph"] == tlog_h.size(), "net: each peer's fx saw its own telegraphs exactly once (h %d/%d c %d/%d)" % [hg.enemy_fx.stats["telegraph"], tlog_h.size(), cg.enemy_fx.stats["telegraph"], tlog_c.size()])
	check(tlog_c.size() >= tlog_h.size() - 1 and tlog_c.size() <= tlog_h.size(), "net: client got every telegraph the host sent (%d of %d)" % [tlog_c.size(), tlog_h.size()])
	# match each client telegraph to the host's
	var used := {}
	for th in tlog_h:
		for tc in tlog_c:
			if tc[0] == th[0] and tc[3] == th[3] and tc[1] >= th[1] and not used.has(tc):
				used[tc] = true
				n += 1
				break
	check(n >= 3, "net: the client got the telegraphs (%d matched)" % n)
	# client-side sounds/decals came from the puppet core's events: telegraph sfx once per telegraph
	var tele_sounds_c := ca.count("tellStrike") + ca.count("tollSmall")
	var tele_sounds_h := ha.count("tellStrike") + ha.count("tollSmall")
	check(tele_sounds_c == tele_sounds_h or absi(tele_sounds_c - tele_sounds_h) <= 1, "net: telegraph sounds equal on both peers (h %d c %d)" % [tele_sounds_h, tele_sounds_c])
	check(absi(cg.enemy_fx.stats["zone"] - hg.enemy_fx.stats["zone"]) <= 1 and cg.enemy_fx.stats["zone"] >= 1, "net: dust cloud seen on both peers (h %d c %d)" % [hg.enemy_fx.stats["zone"], cg.enemy_fx.stats["zone"]])
	# death replicates: one death fx per peer
	var d0h: int = hg.enemy_fx.stats["death"]
	var d0c: int = cg.enemy_fx.stats["death"]
	var e0 := int(ids[0])
	var s0h: int = ha.count("enemyDeath")
	var s0c: int = ca.count("enemyDeath")
	var hit0h: int = hg.enemy_fx.stats["hit"]
	var hit0c: int = cg.enemy_fx.stats["hit"]
	hg.core_host.core.damage(e0, 1e9, hh.core_id)
	for _i in 30:   # 0.5 s
		await physics_frame
	check(hg.enemy_fx.stats["death"] == d0h + 1 and cg.enemy_fx.stats["death"] == d0c + 1, "net: death fx once per peer (h %d c %d)" % [hg.enemy_fx.stats["death"] - d0h, cg.enemy_fx.stats["death"] - d0c])
	check(ha.count("enemyDeath") == s0h + 1 and ca.count("enemyDeath") == s0c + 1, "net: death sound once per peer")
	check(hg.enemy_fx.stats["hit"] - hit0h == cg.enemy_fx.stats["hit"] - hit0c, "net: hit flash events equal (h %d c %d)" % [hg.enemy_fx.stats["hit"] - hit0h, cg.enemy_fx.stats["hit"] - hit0c])
	for id in hg.core_host.core.enemy_ids():
		hg.core_host.core.stun(int(id), 3600.0)
	hg.queue_free()
	cg.queue_free()
	await ticks(5)


func _t_warm() -> void:
	var effects: Dictionary = DmFxData.data().get("effects", {})
	for id in DmEnemyFx.EFFECT_IDS:
		check(effects.has(id), "warm: Binbun effect %s is in the DmWarmup set" % id)
	for id in DmEnemyFx.SFX_IDS:
		check(not DmAudioMap.defn(id).is_empty(), "sfx: %s exists in the audio map" % id)
