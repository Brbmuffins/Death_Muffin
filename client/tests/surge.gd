extends SceneTree
## Grave Surges on the combat core (client/README.md "Grave Surges"), headless, against the local mock backend only (never a real server): the game scene as a player gets it (every area but
## the Depths) with a Gravecaller in god mode. Where a rule is checked the surge is driven by hand (`update(dt, heroes)`, what the director does every physics tick); where the wiring is, the
## director's own ticks drive it. Every kill goes through the core (`DmCoreHost.damage` with the hero's id), so it takes the real path: EV_ENEMY_DIED -> `enemy_died` -> the director's hook ->
## the surge. The old game's checks of Grave Surges and of Restless Crypts replayed on the core, and what the core changes:
##   A the director makes the surge and hears the core's deaths; the clock is unset and the numbers are DmSimData.SURGE's;
##   B no surge in a safe area or an instance, with no hero, or while a boss stands (the clock does not run: it holds its value); with a hero in a combat area it runs;
##   C the first surge opens after firstDelayS of hero time, not before, and once; its event, banner and the counsel's tip; a crypt of the area 9 to 30 m from EVERY hero (never one nearer
##     or farther from any of them), else a wave's spawn point;
##   D three waves at waveAtS (1.5, 7.5, 13.5 s) of 1.2 x the area's wave size: queued through the director (the surge's update makes no body) and made SPAWNS_PER_TICK a tick, bodies of the core
##     of the area's roster rising at the crypt; the Wave Speed tier's size; the global cap, with what is queued counted in;
##   E a death that is not the surge's does not count; 80 % of what came dead: `surgeCleared`, "Surge Quelled", the offering (gold and an item on the ground at the crypt), the next surge
##     90 to 150 s away;
##   F the timeout: `surgeFailed` after durationS, "The Surge Recedes", nothing paid; the hero leaving the area, and the director following him to another combat area, fail it on the
##     director's own tick; a director that is off (a guest's) moves no clock;
##   G Restless Crypts: the next surge 0.6 x as far from Wave Speed tier 6;
##   H through the director alone: its ticks run the clock from the unset state, the surge opens by itself, the waves come on its clock and climb out three bodies a tick, the deaths the core
##     reports clear it, the offering is paid;
##   I the queue: a wave that is queued is the surge's however it is made (the tick drain or `flush_spawns`); a surge that ends with a wave still queued, and the surge after it, are not credited
##     with those bodies, nor is an ordinary wave queued beside an open surge; the Graves cleared under an open surge drop its queue and the surge fails on its time instead of hanging.
## ZERO script errors or engine errors in the log. Run: godot --headless --fixed-fps 60 --path client --script res://tests/surge.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://surge_test"
const BAKE := ["grave_robber", "bone_hound"]
## Where the hero stands in the Graves, at its door: four of its five crypts are 9 to 30 m from him (the fifth, (-16.45, -28.23), is 33 m away).
const DOOR := Vector3(0.0, 0.0, 1.0)
## The sim's fair breach rule, written out here on purpose (the surge reads it from DmSimConsts): a crypt opens 9 to 30 m from every hero.
const CRYPT_MIN := 9.0
const CRYPT_MAX := 30.0

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var d: DmWaveDirector
var host: DmCoreHost
var hero: DmHeroBody
var m: DmRewardsMember
var events: Array = []      ## [id, ctx] of the HUD's game events
var sev: Array = []         ## the director's surge events
var dropped: Array = []     ## [drop, place] the rewards put on the ground
var waves: Array = []       ## the director's wave_spawned counts
var want := 0               ## the Graves' surge wave: the wave size x waveSizeMult


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL surge: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_ticks: int) -> bool:
	var end := Engine.get_physics_frames() + limit_ticks
	while not bool(cond.call()) and Engine.get_physics_frames() < end:
		await physics_frame
	return bool(cond.call())


func _initialize() -> void:
	OS.set_environment("DM_SYNC_NAV", "1")   # (DmNextWorld reads it when the game starts: the navmesh merges in step with game time)
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
	DmSimData.ensure()
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("surge%d" % (Time.get_ticks_usec() % 100000), "s@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"name": "tester", "hud": true, "audio": false, "seed": 20261018, "waves": false, "wander": false, "persist": false, "baked_dir": OUT})
	d = g.director
	host = g.core_host
	hero = g.local_body()
	m = g.my_member()
	g.world.set_unlocked(DmNextWorld.every_area())
	hero.p["god"] = true
	d.rng.seed = 20261018
	want = DmMath.js_round(float(DmContent.area("graves")["waveSize"]) * float(DmSimData.SURGE["waveSizeMult"]))
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append([id, ctx]))
	d.surge_event.connect(func(e: Dictionary) -> void: sev.append(e))
	d.wave_spawned.connect(func(n: int) -> void: waves.append(n))
	g.rewards.loot_dropped.connect(func(_c: int, drop: Dictionary, at: Vector3) -> void: dropped.append([drop, at]))
	var n := 0
	while (m.tape == null or not m.tape.ready_for("surge")) and n < 240:
		await process_frame
		n += 1
	check(m.tape != null and m.tape.ready_for("surge"), "the member's drop tape holds the surge's offering (server-decided drops, B20)")
	_a_the_port()
	await _b_no_surge_to_be_had()
	await _c_the_first_surge()
	await _d_three_waves()
	await _e_the_offering()
	await _d_the_tier_and_the_cap()
	await _c_every_hero_and_no_fair_crypt()
	await _f_failing()
	await _g_restless()
	await _h_through_the_director()
	await _i_the_queue()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s surge %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	g.queue_free()
	await process_frame
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ helpers

## The hero stands at `p` (put on the navmesh) and the game scene has seen him arrive.
func _stand(p: Vector3) -> void:
	hero.teleport(g.world.nav_closest(p))
	await ticks(3)


## Every body of the core leaves: the queued ones are dropped, the living go at once (no death, corpse or credit), the dead 4 s after they fell.
func _clear() -> void:
	d.clear()
	for id in host.core.enemy_ids():
		host.remove_enemy(id)
	await until(func() -> bool: return host.enemy_total() == 0, 60 * 5)
	await ticks(1)


func _area_mid(id: String) -> Vector3:
	var r: Dictionary = DmContent.area(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


func _banners() -> Array:
	return events.filter(func(e: Array) -> bool: return e[0] == "banner").map(func(e: Array) -> String: return String((e[1] as Dictionary).get("title", "")))


func _tip_fired(tip: String) -> bool:
	var c: DmCounsel = g.ui.counsel
	return c.seen.has(tip) or c._queued(tip) or c.pending.has(tip) or String(c.shown.get("id", "")) == tip


## The crypts of `area` 9 to 30 m from every one of `heroes`, worked out from the data and not through the surge.
func _crypts_in_range(area: String, heroes: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for c: Dictionary in DmDb.sim_world()["crypts"]:
		if String(c["area"]) != area:
			continue
		var p := Vector2(float(c["x"]), float(c["z"]))
		var fair := true
		for h: Node3D in heroes:
			var far := p.distance_to(Vector2(h.position.x, h.position.z))
			fair = fair and far >= CRYPT_MIN and far <= CRYPT_MAX
		if fair:
			out.append(Vector3(p.x, 0.0, p.y))
	return out


func _is_one_of(at: Vector3, crypts: Array[Vector3]) -> bool:
	return crypts.any(func(c: Vector3) -> bool: return c.distance_to(at) < 0.01)


## Up to `n` of `ids` (the core's bodies) die by the hero's blow now; a body that is rising or burrowed shrugs it, so it is tried again a little later. Returns how many died.
func _kill(ids: Array, n: int) -> int:
	var died := 0
	for _round in 20:
		for id: int in ids:
			if died >= n:
				break
			if host.enemy_alive(id) and bool(host.damage(id, 1.0e9, hero.core_id)["killed"]):
				died += 1
		if died >= n:
			break
		await ticks(10)
	await ticks(2)   # the deaths reach the director with the next tick's events
	return died


## The wall time of an ordinary physics tick here, in ms (the median of 12): what a tick that makes a wave's bodies is compared with (INFO only).
func _idle_tick_ms() -> float:
	var ms: Array = []
	for _i in 12:
		var t0 := Time.get_ticks_usec()
		await ticks(1)
		ms.append((Time.get_ticks_usec() - t0) / 1000.0)
	ms.sort()
	return float(ms[ms.size() / 2])


## The surge's `update(dt)` that brings a wave (timed, INFO only), then the ticks that make it: until the director's queue is empty and one tick more (the last bodies' spawn events).
## {by_update: bodies the update itself made, queued, update_ms, made: [bodies made in each tick], tick_ms: [each tick's wall time], dispatch_ms: [each tick's core event dispatch]}.
func _wave_over_ticks(dt: float) -> Dictionary:
	var total0 := host.enemy_total()
	var t0 := Time.get_ticks_usec()
	d.surge.update(dt, [hero])
	var out := {"update_ms": (Time.get_ticks_usec() - t0) / 1000.0, "by_update": host.enemy_total() - total0, "queued": d.pending_count(), "made": [], "tick_ms": [], "dispatch_ms": []}
	host.measure = true
	var spare := false
	for _i in 16:
		var before := host.enemy_total()
		host.dispatch_us = 0
		var t1 := Time.get_ticks_usec()
		await ticks(1)
		(out["tick_ms"] as Array).append((Time.get_ticks_usec() - t1) / 1000.0)
		(out["made"] as Array).append(host.enemy_total() - before)
		(out["dispatch_ms"] as Array).append(host.dispatch_us / 1000.0)
		if d.pending_count() == 0:
			if spare:
				break
			spare = true
	host.measure = false
	return out


func _sum(a: Array) -> int:
	var t := 0
	for x in a:
		t += int(x)
	return t


func _ms(a: Array) -> String:
	return " / ".join(a.map(func(x: float) -> String: return "%.1f" % x))


# ------------------------------------------------------------------------------------------------------------------ A

func _a_the_port() -> void:
	var s := d.surge
	check(s != null and s.director == d and not s.active, "the director makes the surge")
	check(host.enemy_died.is_connected(d._on_enemy_died), "the director hears every death of the core")
	check(s.surge_in < 0.0, "the clock is not set until it first runs")
	var S: Dictionary = DmSimData.SURGE
	check(float(S["firstDelayS"]) == 100.0 and float(S["minIntervalS"]) == 90.0 and float(S["maxIntervalS"]) == 150.0 and float(S["durationS"]) == 20.0 and float(S["waveSizeMult"]) == 1.2
		and float(S["clearFrac"]) == 0.8 and S["waveAtS"] == [1.5, 7.5, 13.5] and DmSimData.RESTLESS_SURGE_MULT == 0.6,
		"the numbers are the old game's: 100 s, then 90 to 150 s, 20 s to hold, waves at 1.5 / 7.5 / 13.5 s of 1.2 x the wave size, 80 %%, Restless Crypts x0.6")
	check(want == 11, "the Graves' wave of 9 climbs out as 11 (%d)" % want)


# ------------------------------------------------------------------------------------------------------------------ B

func _b_no_surge_to_be_had() -> void:
	var s := d.surge
	for id: String in ["chapterhouse", "depths"]:   # a safe area, an instance
		d.configure_area(id)
		s.update(1000.0, [hero])
		check(not s.active and s.surge_in < 0.0 and sev.is_empty(), "%s: no surge, and the clock does not run" % id)
	d.configure_area("graves")
	s.update(1000.0, [])
	check(not s.active and s.surge_in < 0.0 and sev.is_empty(), "no hero in the area: no surge, the clock does not run")
	# a boss stands: the real Gravedigger King, woken at his grave
	var me := g.session.get_my_id()
	m.prog.local["shards"] = 99
	await _stand(g.bosses.site_pos("gravedigger") + Vector3(0.0, 0.0, 2.0))
	var why := g.bosses.try_summon(me, "gravedigger")
	var boss := g.bosses.active_boss()
	check(why == "" and boss != null and g.bosses.living().size() == 1, "the Gravedigger King is awake (%s)" % why)
	if boss != null:
		boss.set_physics_process(false)   # his brain rests: only that he stands matters here
	s.update(1000.0, [hero])
	check(not s.active and s.surge_in < 0.0 and sev.is_empty(), "a boss stands: no surge, the clock does not run")
	if boss != null:
		boss.queue_free()
	await ticks(3)
	await _clear()   # whatever the King's waking made
	check(g.bosses.living().is_empty(), "the King is gone")
	s.update(1.0, [hero])
	check(not s.active and is_equal_approx(s.surge_in, float(DmSimData.SURGE["firstDelayS"]) - 1.0), "a hero in a combat area, no boss: the clock starts at firstDelayS and runs (%.2f)" % s.surge_in)


# ------------------------------------------------------------------------------------------------------------------ C

func _c_the_first_surge() -> void:
	var s := d.surge
	await _stand(DOOR)
	check(g.area_id == "graves", "the hero stands in the Graves (%s)" % g.area_id)
	s.update(s.surge_in - 0.5, [hero])
	check(not s.active and is_equal_approx(s.surge_in, 0.5), "99.5 s of hero time: the clock stands at 0.5 s, no surge")
	s.update(0.4, [hero])
	check(not s.active and sev.is_empty(), "99.9 s: not yet")
	events.clear()
	s.update(0.2, [hero])
	check(s.active and sev.size() == 1 and String(sev[0]["t"]) == "surge", "100.1 s: the first surge opens (%s)" % str(sev))
	check(not s.start([hero]) and sev.size() == 1, "a second one does not open over it")
	var ev: Dictionary = sev[0]
	var at := Vector3(float(ev["x"]), 0.0, float(ev["z"]))
	var rect: Dictionary = DmContent.area("graves")["rect"]
	var fair := _crypts_in_range("graves", [hero])
	check(String(ev["area"]) == "graves" and bool(ev["crypt"]) and float(ev["durationMs"]) == 20000.0 and at.x >= float(rect["x0"]) and at.x <= float(rect["x1"]) and at.z >= float(rect["z0"]) and at.z <= float(rect["z1"]),
		"it opens at a crypt in the Graves, for 20 s (%s)" % str(ev))
	check(fair.size() == 4 and _is_one_of(at, fair), "the crypt is one of the four 9 to 30 m from the hero (%.1f, %.1f)" % [at.x, at.z])
	check(_banners().has("Grave Surge") and events.any(func(e: Array) -> bool: return e[0] == "surge_opened"), "the 'Grave Surge' banner and the surge_opened event reach the HUD")
	await ticks(2)
	check(_tip_fired("surge"), "the counsel raises the Grave Surge tip")


# ------------------------------------------------------------------------------------------------------------------ D

func _d_three_waves() -> void:
	var s := d.surge
	await _clear()
	var crypt := Vector3(float(sev[0]["x"]), 0.0, float(sev[0]["z"]))
	var idle := await _idle_tick_ms()
	waves.clear()
	s.update(1.4, [hero])
	check(s.waves_spawned == 0 and s.spawned == 0 and d.pending_count() == 0 and host.enemy_total() == 0, "1.4 s: nothing has climbed out yet, nothing is queued")
	var cost: Array = [await _wave_over_ticks(0.2)]
	check(s.waves_spawned == 1 and s.spawned == want and waves == [want], "1.6 s: the first wave: %d bodies, counted when it is decided" % want)
	s.update(5.8, [hero])
	check(s.waves_spawned == 1, "7.4 s: still the first")
	cost.append(await _wave_over_ticks(0.2))
	check(s.waves_spawned == 2 and s.spawned == 2 * want, "7.6 s: the second")
	s.update(5.8, [hero])
	cost.append(await _wave_over_ticks(0.2))
	check(s.waves_spawned == 3 and s.spawned == 3 * want and waves == [want, want, want] and host.enemy_total() == 3 * want, "13.6 s: the third: 3 waves of %d (%d came, %d in the core)" % [want, s.spawned, host.enemy_total()])
	var per_tick := DmWaveDirector.SPAWNS_PER_TICK
	for w in 3:
		var c: Dictionary = cost[w]
		var made: Array = c["made"]
		check(int(c["by_update"]) == 0 and int(c["queued"]) == want and _sum(made) == want and (made.max() as int) == per_tick and made.filter(func(n: int) -> bool: return n > 0).size() == ceili(float(want) / per_tick),
			"wave %d: the update makes no body, queues %d, and the ticks make them %d at most a tick (%s)" % [w + 1, want, per_tick, str(made)])
		var busy: Array = made.filter(func(n: int) -> bool: return n > 0)
		print("INFO surge: wave %d of %d: queued by the surge's update in %.2f ms, made over %d ticks (%s a tick); the ticks, one more for the last events, took %s ms (an idle tick here %.1f ms) and dispatched the core's spawn events in %s ms"
			% [w + 1, want, c["update_ms"], busy.size(), ", ".join(busy.map(str)), _ms(c["tick_ms"]), idle, _ms(c["dispatch_ms"])])
	var roster: Array = d.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))
	var near := 0
	var rising := 0
	var fit := 0
	for id in host.core.enemy_ids():
		var info := host.enemy_info(id)
		near += 1 if host.enemy_position(id).distance_to(crypt) < 6.0 else 0
		var state := int(info["state"])
		rising += 1 if state == DmCoreEvents.State.RISING or state == DmCoreEvents.State.BURROW else 0   # a ghoul comes up burrowed
		fit += 1 if String(info["area"]) == "graves" and roster.has(String(info["def"])) else 0
	check(near >= s.spawned - 3 and rising == s.spawned and fit == s.spawned, "they climb out of the crypt: %d of %d within 6 m, %d rising or burrowed, %d the Graves' own kinds" % [near, s.spawned, rising, fit])


# ------------------------------------------------------------------------------------------------------------------ E

func _e_the_offering() -> void:
	var s := d.surge
	var ids: Array = Array(host.core.enemy_ids())
	var need := int(ceil(float(s.spawned) * float(DmSimData.SURGE["clearFrac"])))   # 27 of 33
	await ticks(90)   # they rise first (about 1.1 s)
	# a body of the ordinary waves is not the surge's: its death does not count
	var other := host.spawn_enemy("robber", hero.position + Vector3(4.0, 0.0, 0.0), 1, 1.0, 0.0, false, "graves", false)
	await ticks(1)
	host.damage(other, 1.0e9, hero.core_id)
	await ticks(2)
	check(s.killed == 0, "a body that is not the surge's dies: it is not counted (%d)" % s.killed)
	var died := await _kill(ids, need - 1)
	check(died == need - 1 and s.killed == need - 1, "%d of the surge's own die: counted by id (%d, %d)" % [need - 1, died, s.killed])
	sev.clear()
	s.update(0.1, [hero])
	check(s.active and sev.is_empty(), "%d of %d: the crypt stands open" % [need - 1, s.spawned])
	died = await _kill(ids, 1)
	check(died == 1 and s.killed == need, "the %dth" % need)
	dropped.clear()
	events.clear()
	var crypt := s.pos
	var gold_due := DmMath.js_round((24.0 + 10.0 * float(DmContent.area("graves")["level"])) * float(DmWaveUpgrades.wave_modifiers(d.wave_tier)["rewardMult"]) * float(DmContent.difficulty(d.difficulty)["rewardMult"]))
	s.update(0.1, [hero])
	check(not s.active and sev.size() == 1 and String(sev[0]["t"]) == "surgeCleared" and _banners().has("Surge Quelled"), "80 %% of what came (%d of %d): 'Surge Quelled' (%s)" % [need, s.spawned, str(sev)])
	check(float(sev[0]["x"]) == crypt.x and float(sev[0]["z"]) == crypt.z and String(sev[0]["area"]) == "graves", "the event names the crypt")
	var gold := dropped.filter(func(x: Array) -> bool: return String((x[0] as Dictionary).get("kind", "")) == "gold")
	var items := dropped.filter(func(x: Array) -> bool: return (x[0] as Dictionary).has("claim") and String(x[0]["claim"]["kind"]) == "surge")
	check(gold.size() == 1 and int(gold[0][0]["amount"]) == gold_due, "the crypt pays %d gold (%s)" % [gold_due, str(gold.map(func(x: Array) -> int: return int(x[0]["amount"])))])
	check(items.size() >= 1 and (gold + items).all(func(x: Array) -> bool: return (x[1] as Vector3).distance_to(crypt) < 0.01), "and an item from the server's surge tape, both on the ground at the crypt (%d)" % items.size())
	check(s.surge_in >= float(DmSimData.SURGE["minIntervalS"]) and s.surge_in <= float(DmSimData.SURGE["maxIntervalS"]), "the next surge is %.0f s away (90 to 150)" % s.surge_in)
	var wait := s.surge_in
	sev.clear()
	s.update(wait - 0.5, [hero])
	check(not s.active and sev.is_empty(), "it does not open before its time")
	s.update(1.0, [hero])
	check(s.active and sev.size() == 1 and String(sev[0]["t"]) == "surge", "and opens when it is up")
	s.fail()
	sev.clear()


# ------------------------------------------------------------------------------------------------------------------ D (the tier, the cap)

func _d_the_tier_and_the_cap() -> void:
	var s := d.surge
	# the Wave Speed tier makes a surge's waves bigger, as it does an ordinary wave
	await _clear()
	d.set_wave_tier(3.0)
	d._since_arrival = 1.0e9   # the tier is fully in
	var big := DmMath.js_round(float(DmContent.area("graves")["waveSize"]) * float(DmSimData.SURGE["waveSizeMult"]) * float(DmWaveUpgrades.wave_modifiers(3.0)["sizeMult"]))
	check(s.start([hero]), "a surge opens at Wave Speed tier 3")
	s.update(1.6, [hero])
	check(big > want and s.spawned == big and d.pending_count() == big, "the tier's size: a wave of %d, not %d (%d decided, %d queued)" % [big, want, s.spawned, d.pending_count()])
	s.fail()
	d.set_wave_tier(0.0)
	d._since_arrival = 0.0
	# the global cap, with what is queued counted in: 65 of the 72 bodies the world holds are there, so a wave decides the 7 that fit and the next two (queued before the first is made) none
	await _clear()
	var cap := int(DmSimData.GLOBAL_ENEMY_CAP)
	for i in cap - 7:
		host.spawn_enemy("robber", Vector3(-22.0, 0.0, -33.0), 1, 1.0, 0.0, false, "graves", false)
	check(host.enemy_total() == cap - 7, "%d bodies stand" % (cap - 7))
	check(s.start([hero]), "a surge opens with the world nearly full")
	s.update(1.6, [hero])
	check(s.spawned == 7 and d.pending_count() == 7 and host.enemy_total() == cap - 7, "the first wave decides the 7 that fit and queues them (%d decided, %d queued, the world holds %d)" % [s.spawned, d.pending_count(), host.enemy_total()])
	s.update(12.0, [hero])
	check(s.waves_spawned == 3 and s.spawned == 7 and d.pending_count() == 7, "the queued 7 count against the cap: the other waves decide none (%d decided, %d queued)" % [s.spawned, d.pending_count()])
	d.flush_spawns()
	check(d.pending_count() == 0 and host.enemy_total() == cap, "made, the world holds exactly %d (%d)" % [cap, host.enemy_total()])
	s.fail()
	await _clear()
	sev.clear()


# ------------------------------------------------------------------------------------------------------------------ C (every hero, no fair crypt)

func _c_every_hero_and_no_fair_crypt() -> void:
	var s := d.surge
	var fair := _crypts_in_range("graves", [hero])
	var seen := {}
	var all_fair := true
	for i in 24:
		sev.clear()
		s.start([hero])
		var at := Vector3(float(sev[0]["x"]), 0.0, float(sev[0]["z"]))
		all_fair = all_fair and bool(sev[0]["crypt"]) and _is_one_of(at, fair)
		seen[snappedf(at.x, 0.01)] = true
		s.fail()
	check(all_fair and seen.size() >= 2, "24 surges, each at one of the %d fair crypts, %d of them used" % [fair.size(), seen.size()])
	# a second hero 3 m from the Graves' crypt at (15.9, -4.7): that crypt is under 9 m from him, so it never opens, wherever the first hero stands
	var mate := Node3D.new()
	root.add_child(mate)
	mate.position = Vector3(18.9, 0.0, -4.7)
	var fair2 := _crypts_in_range("graves", [hero, mate])
	var used := {}
	var in_range := true
	for i in 24:
		sev.clear()
		s.start([hero, mate])
		var at2 := Vector3(float(sev[0]["x"]), 0.0, float(sev[0]["z"]))
		in_range = in_range and bool(sev[0]["crypt"]) and _is_one_of(at2, fair2)
		used[snappedf(at2.x, 0.01)] = true
		s.fail()
	check(fair2.size() < fair.size() and in_range and not used.has(15.9), "a second hero near a crypt: it is left out (%d fair crypts, not %d)" % [fair2.size(), fair.size()])
	# a second hero 100 m away: no crypt is within 30 m of both, so it opens where a wave would climb in: outside aggro, inside the area, not at a crypt
	mate.position = Vector3(100.0, 0.0, 100.0)
	sev.clear()
	check(s.start([hero, mate]) and not bool(sev[0]["crypt"]), "no crypt is fair to both heroes: it opens at a spawn point")
	var spot := Vector3(float(sev[0]["x"]), 0.0, float(sev[0]["z"]))
	var rect: Dictionary = DmContent.area("graves")["rect"]
	check(Vector2(spot.x - hero.position.x, spot.z - hero.position.z).length() >= 6.0 and spot.x >= float(rect["x0"]) and spot.x <= float(rect["x1"]) and spot.z >= float(rect["z0"]) and spot.z <= float(rect["z1"]),
		"that spot is in the Graves, away from the hero (%.1f, %.1f)" % [spot.x, spot.z])
	s.fail()
	mate.free()
	sev.clear()


# ------------------------------------------------------------------------------------------------------------------ F

func _f_failing() -> void:
	var s := d.surge
	await _clear()
	dropped.clear()
	events.clear()
	sev.clear()
	var dur := float(DmSimData.SURGE["durationS"])
	check(s.start([hero]), "a surge opens")
	s.update(dur - 0.5, [hero])
	check(s.active and s.spawned == 3 * want and d.pending_count() == 3 * want, "19.5 s with nothing killed: still open, the three waves are decided and queued")
	s.update(1.0, [hero])
	check(not s.active and sev.size() == 2 and String(sev[1]["t"]) == "surgeFailed" and _banners().has("The Surge Recedes"), "20 s: 'The Surge Recedes' (%s)" % str(sev.map(func(e: Dictionary) -> String: return String(e["t"]))))
	await ticks(3)
	check(dropped.is_empty(), "nothing is paid for a surge that ran out")
	check(s.surge_in >= float(DmSimData.SURGE["minIntervalS"]) and s.surge_in <= float(DmSimData.SURGE["maxIntervalS"]), "the next one is %.0f s away" % s.surge_in)
	await _clear()
	# the area empties
	sev.clear()
	check(s.start([hero]), "another opens")
	s.reset()
	check(not s.active and sev.size() == 2 and String(sev[1]["t"]) == "surgeFailed", "the area empties: the surge fails")
	s.reset()
	check(sev.size() == 2, "and a surge that is not open does not fail again")
	await _clear()
	# the clock ticks only with a hero in a combat area
	s.surge_in = 5.0
	s.update(1.0, [])
	check(s.surge_in == 5.0, "the idle clock holds without a hero")
	# through the director's own tick: the hero leaves for the Chapterhouse (a hub), then goes to another combat area
	d.cap = 0   # no ordinary waves
	d.enabled = true
	sev.clear()
	check(s.start([hero]), "a surge opens under the director")
	var home: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	await _stand(Vector3(float(home["x"]), 0.0, float(home["z"])))
	check(g.area_id == "chapterhouse" and not s.active and sev.size() == 2 and String(sev[1]["t"]) == "surgeFailed", "the hero leaves for the Chapterhouse: the director's tick fails the surge")
	await _stand(DOOR)
	await ticks(2)
	sev.clear()
	check(d.area_id == "graves" and s.start([hero]), "back in the Graves, another opens")
	await _stand(_area_mid("ossuary"))
	var failed := sev.filter(func(e: Dictionary) -> bool: return String(e["t"]) == "surgeFailed" and String(e["area"]) == "graves")
	check(d.area_id == "ossuary" and not s.active and failed.size() == 1, "the director follows him to the Ossuary and fails the Graves' surge (%s)" % d.area_id)
	# a director that is off (a guest's) moves no clock
	d.enabled = false
	var clock := s.surge_in
	await ticks(60)
	check(s.surge_in == clock and not s.active, "a director that is off moves no clock")
	d.configure_area("graves")
	await _stand(DOOR)
	await _clear()
	sev.clear()


# ------------------------------------------------------------------------------------------------------------------ G

func _g_restless() -> void:
	var s := d.surge
	var S: Dictionary = DmSimData.SURGE
	var tier := 0.0
	for ms: Dictionary in DmContent.get_export("upgrades", "WAVE_MILESTONES"):
		if String(ms["id"]) == "restless":
			tier = float(ms["tier"])
	check(tier == 6.0, "Restless Crypts comes with Wave Speed tier %d" % int(tier))
	var lo := INF
	var hi := -INF
	for i in 12:
		s.start([hero])
		s.fail()
		lo = minf(lo, s.surge_in)
		hi = maxf(hi, s.surge_in)
	check(lo >= float(S["minIntervalS"]) and hi <= float(S["maxIntervalS"]), "without it the next surge is 90 to 150 s away (%.0f to %.0f over 12)" % [lo, hi])
	d.set_wave_tier(tier - 0.5)
	lo = INF
	hi = -INF
	for i in 12:
		s.start([hero])
		s.fail()
		lo = minf(lo, s.surge_in)
		hi = maxf(hi, s.surge_in)
	check(lo >= float(S["minIntervalS"]) and hi <= float(S["maxIntervalS"]), "tier %.1f is not enough (%.0f to %.0f)" % [tier - 0.5, lo, hi])
	d.set_wave_tier(tier)
	lo = INF
	hi = -INF
	for i in 12:
		s.start([hero])
		s.fail()
		lo = minf(lo, s.surge_in)
		hi = maxf(hi, s.surge_in)
	var mult := float(DmSimData.RESTLESS_SURGE_MULT)
	check(lo >= float(S["minIntervalS"]) * mult and hi <= float(S["maxIntervalS"]) * mult, "with it the next surge is 40 %% sooner: %.0f to %.0f s over 12 (54 to 90)" % [lo, hi])
	d.set_wave_tier(0.0)
	d.configure_area("graves")
	sev.clear()


# ------------------------------------------------------------------------------------------------------------------ H

func _h_through_the_director() -> void:
	var s := d.surge
	await _stand(DOOR)
	await _clear()
	d.configure_area("graves")
	d.cap = 0   # no ordinary waves: every body that appears is the surge's
	s.surge_in = -1.0
	sev.clear()
	events.clear()
	dropped.clear()
	waves.clear()
	var came: Array = []
	var this_tick := [0]   # spawn events in the tick being dispatched, and the most in one
	var most := [0]
	var on_spawn := func(id: int, _def: String, _level: int, _elite: bool, _area: String, _af: int, _x: float, _z: float, _hp: float) -> void:
		came.append(id)
		this_tick[0] += 1
	var on_ticked := func(_dt: float) -> void:
		most[0] = maxi(most[0], this_tick[0])
		this_tick[0] = 0
	host.enemy_spawned.connect(on_spawn)
	host.ticked.connect(on_ticked)
	d.enabled = true
	await ticks(60)
	var first := float(DmSimData.SURGE["firstDelayS"])
	check(not s.active and absf(s.surge_in - (first - 1.0)) < 0.05, "the director's ticks run the clock from the unset state: a second of them, %.2f s left" % s.surge_in)
	s.surge_in = 0.3
	check(await until(func() -> bool: return s.active, 60 * 2) and sev.size() == 1 and String(sev[0]["t"]) == "surge", "the director opens the surge on its own clock")
	check(await until(func() -> bool: return s.waves_spawned == 3, 60 * 16), "the three waves come on the director's ticks")
	await until(func() -> bool: return d.pending_count() == 0, 60)
	await ticks(2)
	check(waves == [want, want, want] and came.size() == 3 * want and s.spawned == 3 * want, "3 waves of %d (%d bodies of the core came)" % [want, came.size()])
	check(most[0] == DmWaveDirector.SPAWNS_PER_TICK, "they climbed out %d a tick at most, as an ordinary wave's do (%d)" % [DmWaveDirector.SPAWNS_PER_TICK, most[0]])
	check(s.age > 13.5 and s.age < 14.5, "the third came at 13.5 s of the surge's own age (%.2f)" % s.age)
	await ticks(90)   # they rise
	var need := int(ceil(float(s.spawned) * float(DmSimData.SURGE["clearFrac"])))
	var died := await _kill(came, need)
	check(died == need and s.killed == need, "%d of %d die by the hero's blow (%d, the surge counted %d)" % [need, s.spawned, died, s.killed])
	check(await until(func() -> bool: return not s.active, 10), "the director's next tick sees 80 %% and quells it")
	var cleared := sev.filter(func(e: Dictionary) -> bool: return String(e["t"]) == "surgeCleared")
	check(cleared.size() == 1 and sev.size() == 2 and _banners().has("Surge Quelled"), "one 'surgeCleared' and the banner (%s)" % str(sev.map(func(e: Dictionary) -> String: return String(e["t"]))))
	var gold_due := DmMath.js_round((24.0 + 10.0 * float(DmContent.area("graves")["level"])) * float(DmWaveUpgrades.wave_modifiers(d.wave_tier)["rewardMult"]) * float(DmContent.difficulty(d.difficulty)["rewardMult"]))
	var paid := dropped.filter(func(x: Array) -> bool: return String((x[0] as Dictionary).get("kind", "")) == "gold" and int((x[0] as Dictionary)["amount"]) == gold_due)
	var items := dropped.filter(func(x: Array) -> bool: return (x[0] as Dictionary).has("claim") and String(x[0]["claim"]["kind"]) == "surge")
	check(paid.size() == 1 and items.size() >= 1, "the offering is paid: %d gold and %d item(s) from the surge tape" % [gold_due, items.size()])
	check(s.surge_in >= float(DmSimData.SURGE["minIntervalS"]) and s.surge_in <= float(DmSimData.SURGE["maxIntervalS"]), "the next surge is %.0f s away" % s.surge_in)
	host.enemy_spawned.disconnect(on_spawn)
	host.ticked.disconnect(on_ticked)
	d.enabled = false
	await _clear()


# ------------------------------------------------------------------------------------------------------------------ I

func _i_the_queue() -> void:
	var s := d.surge
	d.configure_area("graves")
	await _stand(DOOR)
	await _clear()
	sev.clear()
	# a queued wave is the surge's whether the ticks or `flush_spawns` make it: `adopt` takes the core id of each, so the deaths count
	check(s.start([hero]), "a surge opens")
	s.update(1.6, [hero])
	check(d.pending_count() == want, "its first wave is queued (%d)" % d.pending_count())
	d.flush_spawns()
	check(d.pending_count() == 0 and host.enemy_total() == want, "flush_spawns makes the wave at once (%d in the core)" % host.enemy_total())
	await ticks(90)   # they rise
	var flushed: Array = Array(host.core.enemy_ids())
	var died := await _kill(flushed, 3)
	check(died == 3 and s.killed == 3, "the bodies flush_spawns made are the surge's own: 3 die, 3 counted (%d, %d)" % [died, s.killed])
	s.fail()
	await _clear()
	# a surge that ends while its wave is still queued, and the surge after it, are not credited with those bodies
	sev.clear()
	check(s.start([hero]), "surge A opens")
	var serial_a: int = s.serial
	s.update(1.6, [hero])
	check(d.pending_count() == want and s.spawned == want, "A queues a wave")
	s.fail()
	check(d.pending_count() == want, "A ends with the wave still queued")
	check(s.start([hero]) and s.serial == serial_a + 1, "surge B opens over A's queue, with a serial of its own")
	check(await until(func() -> bool: return d.pending_count() == 0, 60), "the queue empties on the ticks")
	await ticks(90)   # they rise
	var left: Array = Array(host.core.enemy_ids())
	check(left.size() == want, "A's bodies climb out all the same (%d)" % left.size())
	died = await _kill(left, 8)   # (a burrowed ghoul shrugs a blow: not all of them are asked)
	check(died == 8 and s.killed == 0 and s.spawned == 0, "B is not credited with them: %d died, B counted %d of the %d it decided" % [died, s.killed, s.spawned])
	s.fail()
	await _clear()
	# the Graves are cleared under an open surge (`clear_area` drops what is queued): the surge does not hang, it fails when its 20 s are up
	sev.clear()
	check(s.start([hero]), "a surge opens")
	s.update(1.6, [hero])
	check(d.pending_count() == want, "it queues a wave")
	d.clear_area("graves")
	check(d.pending_count() == 0 and host.enemy_total() == 0 and s.active and s.spawned == want, "clear_area drops the queued wave; the surge is still open and counts it as decided")
	s.update(float(DmSimData.SURGE["durationS"]), [hero])
	check(not s.active and sev.size() == 2 and String(sev[1]["t"]) == "surgeFailed", "it fails when its time is up, however many of its bodies never came (%s)" % str(sev.map(func(e: Dictionary) -> String: return String(e["t"]))))
	await _clear()
	# an ordinary wave queued beside an open surge is not the surge's: only a wave queued between begin_surge_wave and end_surge_wave carries its serial
	sev.clear()
	check(s.start([hero]), "a surge opens")
	s.update(1.6, [hero])
	d.flush_spawns()
	var its: Array = Array(host.core.enemy_ids())
	d.cap = 28   # (the ordinary waves are allowed again)
	check(d.spawn_wave([hero], 5) == 5 and d.pending_count() == 5, "an ordinary wave of 5 is queued beside the open surge")
	d.flush_spawns()
	var plain: Array = Array(host.core.enemy_ids()).filter(func(id: int) -> bool: return not its.has(id))
	check(its.size() == want and plain.size() == 5, "%d of the surge's, 5 of the ordinary wave's stand" % its.size())
	await ticks(90)   # they rise
	died = await _kill(plain, 5)
	check(died == 5 and s.killed == 0, "the ordinary wave's 5 die: the surge counts none (%d died, %d counted)" % [died, s.killed])
	died = await _kill(its, 2)
	check(died == 2 and s.killed == 2, "and its own 2 do count (%d, %d)" % [died, s.killed])
	s.fail()
	d.configure_area("graves")
	await _clear()
	sev.clear()

