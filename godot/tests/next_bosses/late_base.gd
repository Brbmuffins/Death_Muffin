extends SceneTree
## Shared helpers of the late-boss suites (saint_run / regent_run / mire_run). NOT a suite: a base class (`extends "res://tests/next_bosses/late_base.gd"`).
## Same method as run.gd: the boss is stepped by hand (set_physics_process(false) + _physics_process(1/60)) so telegraph timing is exact; the hero is made
## unkillable (huge hp) so the boss never resets; counting stubs stand in for Vfx / AudioDirector.

const DT := 1.0 / 60.0
var PORT := DmTestPorts.free_port()

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			var where := ""
			for b in bt:
				where += " | " + String(b.format()).replace("\n", " ; ")
			errors.append("%s:%d %s %s%s" % [file.get_file(), line, code, rationale, where.substr(0, 300)])

## Counting back-ends for the fx (every Vfx / AudioDirector call the router makes).
class Stub extends Node:
	var calls: Dictionary = {}
	var sfx: Array = []
	var particle_scale := 1.0
	var hitstop_scale := 1.0
	func _count(n: String) -> void:
		calls[n] = int(calls.get(n, 0)) + 1
	func danger(cb: Callable, _keep: bool = false) -> void:
		_count("danger")
		cb.call()
	func play_sfx(name_: String, _pos: Variant = null, _i: float = 1.0) -> bool:
		sfx.append(name_)
		return true
	class Handle extends RefCounted:
		var alive := true
		func kill() -> void:
			alive = false
	func decal(_o: Dictionary) -> Variant:
		_count("decal")
		return Handle.new()
	func emit(_o: Dictionary) -> void:
		_count("emit")
	func emit_smoke(_o: Dictionary) -> void:
		_count("emit")
	func light_flash(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void:
		_count("flash")
	func flash(_o: Dictionary) -> void:
		_count("flash")
	func spike_line(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null, _f: Variant = null) -> void:
		_count("spike")
	func beam(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null) -> void:
		_count("beam")
	func projectile(_o: Dictionary) -> void:
		_count("proj")
	func play(_id: String, _at: Variant = null, _o: Variant = null) -> Variant:
		_count("bb")
		return Handle.new()
	func _get(prop: StringName) -> Variant:
		return null

var passed := 0
var failed := 0
var log_ := ErrLog.new()
var api: DmApi
var mock: DmMockBackend     ## must outlive the suite: the api's transport is its callable
var character: Dictionary
var g: DmNextGame
var hb: DmHeroBody
var evs: Array = []          ## [{t: room clock, ev}]
var hurts: Array = []
var boss: DmBoss
var stub := Stub.new()
var astub := Stub.new()
var BOSS_ID := ""            ## set by the suite
var AREA := ""
var ARENA := Vector3.ZERO
var SITE := Vector3.ZERO


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	pass


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		if hb != null and is_instance_valid(hb) and not hb.p.is_empty() and hb.alive and hb.p["stats"]["maxHp"] < 9.0e8:
			god(hb)
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func boot() -> void:
	OS.add_logger(log_)
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("late%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	var bd: Dictionary = DmContent.boss(BOSS_ID)
	AREA = String(bd["area"])
	ARENA = Vector3(float(bd["arena"]["x"]), 0.0, float(bd["arena"]["z"]))
	SITE = Vector3.INF
	for it in DmContent.area(AREA).get("interactables", []):
		if String(it["id"]) == String(bd["summonId"]):
			SITE = Vector3(float(it["x"]), 0.0, float(it["z"]))


func finish() -> void:
	check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), " || ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func new_game(opts: Dictionary, host_root: Node = null) -> DmNextGame:
	var n: DmNextGame = load("res://next/next_game.tscn").instantiate()
	(host_root if host_root != null else root).add_child(n)
	await n.start(character, api, opts)
	return n


## Solo game: world (no dressing), rewards, the stubs, the event log. `hb` is made unkillable.
func solo() -> void:
	g = await new_game({"dressing": false, "hud": false, "waves": false, "audio": false})
	hb = g.local_body()
	god(hb)
	g.bosses.brain_event.connect(func(ev: Dictionary, b: DmBoss) -> void:
		evs.append({"t": b.world.t, "ev": ev.duplicate(true)})
		if ev["t"] == "hurt":
			hurts.append(ev))
	g.bosses.fx.set_backends(stub, astub)
	g.enemy_fx.set_backends(stub, astub)
	await ticks(2)


## Effectively unkillable: the numbers are read from the events, the hp only has to stay > 0.
func god(b: DmHeroBody) -> void:
	b.p["stats"]["maxHp"] = 1.0e9
	b.p["hp"] = 1.0e9
	b._mirror_from_state()


func member() -> DmRewardsMember:
	return g.rewards.members[int(character.get("id", 0))]


## Wake the boss at its site. "" = woken.
func summon() -> String:
	g.bosses.assume_area = AREA
	var why := g.bosses.try_summon(g.session.get_my_id(), BOSS_ID)
	if why == "":
		boss = g.bosses.active_boss()
		boss.set_physics_process(false)
		boss.world.refresh()
	return why


func step(secs: float) -> void:
	for i in int(round(secs / DT)):
		if float(hb.p["stats"]["maxHp"]) < 9.0e8 or hb.hp < 9.0e8:   # the progression (level-ups, loads) resets the stats: stay unkillable
			god(hb)
		boss._physics_process(DT)


func events(kind: String, ms_gt: float = -1.0) -> Array:
	var out: Array = []
	for e in evs:
		var ev: Dictionary = e["ev"]
		if ev["t"] == "boss" and ev["kind"] == kind and (ms_gt < 0.0 or float(ev.get("ms", 0.0)) > ms_gt):
			out.append(e)
	return out


func impacts(kind: String) -> Array:
	return events(kind).filter(func(e: Dictionary) -> bool: return float(e["ev"].get("ms", 0.0)) == 0.0)


func telegraphs(kind: String) -> Array:
	return events(kind, 0.0)


func dmg_scale() -> float:
	return (1.0 + 0.15 * (float(boss.brain.state["level"]) - 1.0)) * float(DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]["enemyDamageMult"])


func zones(kind: StringName = &"") -> Array:
	return get_nodes_in_group(&"dm_hostile_zone").filter(func(z: Node) -> bool: return kind == &"" or (z as DmHostileZone).kind == kind)


func clear_zones() -> void:
	for z in get_nodes_in_group(&"dm_hostile_zone"):
		z.free()


func clear_adds() -> void:
	for e in g.director.enemies.values():
		(e as Node).queue_free()
	g.director.enemies.clear()


## Hero next to the boss's grave with the shards for `n` summons.
func at_site(shards: int) -> void:
	hb.teleport(SITE + Vector3(0.0, 0.0, 2.0))
	g.bosses.assume_area = AREA
	member().prog.add_shards(shards)
	await ticks(2)


## The shared fight-summary checks: thralls engage (edge rule) and credit the owner, a rite hits, a stun staggers once.
func thralls_and_rites() -> void:
	hb.teleport(ARENA + Vector3(-9.0, 0.0, 2.0))
	boss.world.refresh()
	clear_adds()
	boss.set_physics_process(true)
	var th: DmThrallHost = hb.get_node("Thralls")
	var rr: Dictionary = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 40.0, "attackSpeedMult": 1.0})
	check(bool(rr["ok"]), "%s: a thrall is raised" % BOSS_ID)
	var t1: DmThrall = rr["thralls"][0]
	t1.set_deferred("global_position", boss.global_position + Vector3(-2.6, 0.0, 0.0))   # next to her: no navmesh needed in an area the areas track has not opened
	var hp_t: float = boss.brain.state["hp"]
	var engaged := await until(func() -> bool: return t1.target == boss, 8.0)
	check(engaged, "%s: the thrall engages the boss (edge rule)" % BOSS_ID)
	await until(func() -> bool: return boss.hp < hp_t - 1.0, 8.0)
	check(boss.hp < hp_t and boss.brain.last_hit_by == str(g.session.get_my_id()), "%s: thrall blows hurt the boss and credit the owner" % BOSS_ID)
	th.clear()
	boss.set_physics_process(false)
	var caster: DmRiteCaster = hb.get_node("Rites")
	hb.teleport(ARENA + Vector3(-5.0, 0.0, 2.0))
	boss.world.refresh()
	check(g.enemies_in_radius(boss.global_position, 0.5).has(boss) and g.enemy_by_id(int(boss.get_meta(&"dm_id"))) == boss, "%s: the rite world sees the boss (enemies_in_radius / enemy_by_id)" % BOSS_ID)
	var hp_r := boss.hp
	caster.request_cast("bone_needle", boss.global_position, int(boss.get_meta(&"dm_id")))
	await until(func() -> bool: return boss.hp < hp_r, 3.0)
	check(boss.hp < hp_r, "%s: Bone Needle damages the boss (%.1f)" % [BOSS_ID, hp_r - boss.hp])


## Defeat -> DmSessionRewards.on_boss_defeated + the session report. Returns the shards dropped.
func defeat_and_report() -> void:
	var drops: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _p: Vector3) -> void: drops.append(d))
	var earned: Array = []
	g.rewards.boss_earned.connect(func(_c: int, id: String, first: bool, _p: Vector3) -> void: earned.append([id, first]))
	var reported: Array = []
	g.rewards.batch_reported.connect(func(b: int, r: Variant) -> void: reported.append([b, r]))
	var died: Array = []
	boss.died.connect(func(_e: DmEnemy) -> void: died.append(1))
	var defeated: Array = []
	g.bosses.defeated.connect(func(id: String, killer: int, _p: Vector3) -> void: defeated.append([id, killer]))
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	g.rewards.rng = func() -> float: return 0.5
	var m := member()
	var xp0: float = float(m.prog.character["experience"])
	if String(boss.brain.state["state"]) == "sunk":
		boss.brain.state["state"] = "idle"
	var adds_before := g.director.enemies.size()
	boss.take_damage(boss.hp + 1.0, hb)
	check(boss.hp == 0.0 and boss.sm.id() == DmEnemyState.Id.DEAD and not boss.is_hittable() and died.size() == 1, "%s: lethal hit -> DEAD at once, died emitted" % BOSS_ID)
	check(events("defeated").size() == 1 and str(events("defeated")[0]["ev"]["killer"]) == str(g.session.get_my_id()) and defeated == [[BOSS_ID, g.session.get_my_id()]], "%s: defeated event names the killer" % BOSS_ID)
	check("bossDefeat" in astub.sfx, "%s: bossDefeat sound" % BOSS_ID)
	check(earned == [[BOSS_ID, true]], "%s: the member is paid; first kill" % BOSS_ID)
	var shards := 0
	for d in drops:
		if d.get("kind") == "shard":
			shards += int(d["amount"])
	check(drops.size() >= 2 and shards >= 2, "%s: gold + shards (+2 first kill) + items dropped (%d drops, %d shards)" % [BOSS_ID, drops.size(), shards])
	check(float(m.prog.character["experience"]) > xp0 or int(m.stats["levels"]) > 0, "%s: boss XP applied" % BOSS_ID)
	check(int(m.stats["bosses"]) == 1 and m.reporter._bosses.size() == 1, "%s: boss kill queued for the report {boss, tier, diff, first}" % BOSS_ID)
	var key: String = m.reporter._bosses.keys()[0]
	check(key.begins_with(BOSS_ID + "|") and key.contains("|1|"), "%s: reported as a first kill (%s)" % [BOSS_ID, key])
	await g.rewards.flush()
	check(reported.size() >= 1 and not m.reporter.has_pending() and reported[0][1] is Dictionary and not (reported[0][1] as Dictionary).has("error"), "%s: batch sent, nothing pending, backend answered (%s)" % [BOSS_ID, str(reported)])
	check(g.director.enemies.size() <= adds_before, "%s: its adds leave with it" % BOSS_ID)


## A wipe / leaving the area resets the boss (no reward, can be woken again).
func wipe_resets() -> void:
	boss.queue_free()
	await ticks(3)
	hb.teleport(SITE + Vector3(0.0, 0.0, 2.0))
	member().prog.add_shards(int(DmContent.boss(BOSS_ID)["shards"]))
	await ticks(2)
	check(summon() == "", "%s: woken again after the kill" % BOSS_ID)
	var resets: Array = []
	g.bosses.reset.connect(func(id: String) -> void: resets.append(id))
	hb.teleport(Vector3(0, 0, 20))   # out of the area: the boss goes back to sleep
	g.bosses.assume_area = ""
	boss.world.refresh()
	step(0.1)
	check(resets == [BOSS_ID] and not boss.is_hittable() and boss.sm.id() != DmEnemyState.Id.DEAD, "%s: everyone gone -> the boss resets (no reward)" % BOSS_ID)
	boss.queue_free()
	await ticks(3)


## Whole-frame cost (DmFrameCost) with the boss fighting on the real clock: median budget + a cap on the worst frame.
func perf(extra: Callable = Callable()) -> void:
	g.bosses.assume_area = AREA
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	g.director.enabled = false
	for i in 16:
		g.director.spawn("ghoul" if i % 2 == 0 else "robber", ARENA + Vector3(sin(float(i)) * 7.0, 0.0, cos(float(i)) * 7.0), [hb])
	var th: DmThrallHost = hb.get_node("Thralls")
	th.clear()
	th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 9000.0, "damage": 5.0, "attackSpeedMult": 1.0})
	for i in 4:
		th.raise({"kind": "warrior", "cap": 99.0, "hp": 9000.0, "damage": 5.0, "attackSpeedMult": 1.0}, ARENA + Vector3(-6.0 + float(i), 0.0, 2.0))
	if extra.is_valid():
		extra.call()
	boss.set_physics_process(true)
	await ticks(60)
	var fc := DmFrameCost.attach(root)
	await ticks(360)
	var med := fc.median_ms()
	var worst := fc.worst_busy_ms()
	print("perf %s: whole frame median %.2f ms, p95 %.2f ms, worst %.2f ms (%d frames, boss + 16 adds + 5 thralls, %d pools)" % [BOSS_ID, med, fc.p95_ms(), worst, fc.samples(), zones().size()])
	perf_info(med < 18.0, "%s: frame median %.2f ms < 18 ms (budget)" % [BOSS_ID, med])
	perf_info(worst < 150.0, "%s: worst frame %.2f ms < 150 ms (cap)" % [BOSS_ID, worst])
	fc.queue_free()
	boss.set_physics_process(false)
	th.clear()
	var samples: Array = []
	boss.world.refresh()
	for i in 400:
		var u0 := Time.get_ticks_usec()
		boss._physics_process(DT)
		samples.append(Time.get_ticks_usec() - u0)
	samples.sort()
	print("perf %s: brain tick median %.0f us, p95 %.0f us" % [BOSS_ID, samples[samples.size() / 2], samples[int(samples.size() * 0.95)]])
	perf_info(float(samples[samples.size() / 2]) < 500.0, "%s: brain tick median %.0f us < 500 us" % [BOSS_ID, samples[samples.size() / 2]])


## Two in-process ENet peers: body + state + events once per peer. `hook` runs mid-fight on the host boss (to provoke the boss's specific events).
func net_part(first_attack: String, pool_kind: StringName = &"") -> void:
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	var hg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	var cg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(PORT, 4) == OK, "net: ENet server on a free port")
	await hg.start(character, api, {"peer": sp, "dressing": false, "hud": false, "waves": false, "audio": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", PORT)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "hud": false, "audio": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "net: client joined")
	var hstub := Stub.new()
	var cstub := Stub.new()
	var hast := Stub.new()
	var cast_ := Stub.new()
	hg.bosses.fx.set_backends(hstub, hast)
	cg.bosses.fx.set_backends(cstub, cast_)
	hg.enemy_fx.set_backends(hstub, hast)
	cg.enemy_fx.set_backends(cstub, cast_)
	var hh := hg.local_body()
	god(hh)
	hg.bosses.assume_area = AREA
	hh.teleport(SITE + Vector3(0.0, 0.0, 2.0))
	await ticks(3)
	var hm: DmRewardsMember = hg.rewards.members[int(character.get("id", 0))]
	hm.prog.add_shards(int(DmContent.boss(BOSS_ID)["shards"]))
	check(hg.bosses.try_summon(hg.session.get_my_id(), BOSS_ID) == "", "net: host summons")
	var hb_: DmBoss = hg.bosses.active_boss()
	hb_.set_physics_process(false)
	var bid := int(hb_.get_meta(&"dm_id"))
	check(await until(func() -> bool: return cg.bosses.boss_by_id(bid) != null and cg.bosses.boss_by_id(bid).is_inside_tree(), 6.0), "net: the boss body spawns on the client (same dm_id)")
	var cb_: DmBoss = cg.bosses.boss_by_id(bid)
	check(cb_ != null and not cb_.is_multiplayer_authority() and cb_.brain == null and cb_.boss_id == BOSS_ID, "net: client body is a brainless puppet")
	check(await until(func() -> bool: return cb_.bstate.active and absf(cb_.max_hp - hb_.max_hp) < 0.01, 4.0), "net: state replicates (active, max hp)")
	hh.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	hb_.world.refresh()
	for i in 200:
		_nstep(hb_, hh)
		if not hb_.brain.pending.is_empty():
			break
	check(await until(func() -> bool: return cb_.telegraphs.size() >= 1, 3.0), "net: the client sees a telegraph in the replicated state (%s)" % (String(cb_.telegraphs[0][0]) if cb_.telegraphs.size() > 0 else "-"))
	if cb_.telegraphs.size() > 0:
		check(String(cb_.telegraphs[0][0]) == first_attack, "net: telegraph kind replicates (%s)" % first_attack)
	check(await until(func() -> bool: return cstub.calls.get("decal", 0) > 0, 3.0), "net: the client played the telegraph decals")
	check(await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events, 2.0), "net: every event is played exactly once per peer (host %d, client %d)" % [hg.bosses.fx.events, cg.bosses.fx.events])
	check(hast.sfx.count("bossAwaken") == 1 and await until(func() -> bool: return cast_.sfx.count("bossAwaken") == 1, 2.0), "net: the awaken sound plays once on each peer")
	if pool_kind != &"":
		for i in 400:
			_nstep(hb_, hh)
			if get_nodes_in_group(&"dm_hostile_zone").size() > 0 and hg.bosses.get_node_or_null("Pools") != null and hg.bosses.get_node("Pools").get_child_count() > 0:
				break
		var hz := hg.bosses.get_node("Pools").get_children()
		check(hz.size() > 0 and (hz[0] as DmHostileZone).damaging, "net: the host's pools damage")
		check(await until(func() -> bool: return cg.bosses.get_node_or_null("Pools") != null and cg.bosses.get_node("Pools").get_child_count() >= hz.size(), 3.0), "net: the client got the pools (%d)" % hz.size())
		var cz := cg.bosses.get_node("Pools").get_children()
		check(cz.size() > 0 and not (cz[0] as DmHostileZone).damaging and (cz[0] as DmHostileZone).kind == pool_kind and (cz[0] as DmHostileZone).global_position.is_equal_approx((hz[0] as DmHostileZone).global_position), "net: the client's pool is visual only, same kind and place")
	hb_.take_damage(hb_.hp - hb_.max_hp * 0.55, hh)
	for i in 10:
		_nstep(hb_, hh)
	check(await until(func() -> bool: return cb_.phase == 2 and absf(cb_.hp - hb_.hp) < hb_.max_hp * 0.01, 3.0), "net: phase and hp replicate (client phase %d)" % cb_.phase)
	check(cb_.global_position.distance_to(hb_.global_position) < 2.5, "net: the client's boss follows the host's position")
	if BOSS_ID == "mire":
		hb_.brain.state["state"] = "sunk"
		hb_._mirror()
		check(await until(func() -> bool: return cb_.bstate.state == "sunk", 3.0) and not cb_.is_hittable() and cb_.is_awake() and cg.bosses.active_boss() == cb_ and cg.bosses.living().is_empty(), "net: sunk replicates, the client's puppet is awake but not hittable")
		hb_.brain.state["state"] = "idle"
		hb_._mirror()
	hb_.take_damage(hb_.hp + 1.0, hh)
	check(await until(func() -> bool: return cb_.sm.id() == DmEnemyState.Id.DEAD, 3.0), "net: the client sees the boss die")
	check(await until(func() -> bool: return cast_.sfx.has("bossDefeat"), 3.0), "net: the defeat sound plays on the client too")
	hg.queue_free()
	cg.queue_free()
	await ticks(3)


func _nstep(b: DmBoss, hero: DmHeroBody) -> void:
	if float(hero.p["stats"]["maxHp"]) < 9.0e8 or hero.hp < 9.0e8:
		god(hero)
	b._physics_process(DT)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
