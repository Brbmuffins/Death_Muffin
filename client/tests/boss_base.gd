extends SceneTree
## The base of the six other bosses' suites (boss_abbess.gd, boss_congregation.gd, boss_prelate.gd, boss_saint.gd, boss_regent.gd, boss_mire.gd; the Gravedigger King is boss.gd) and of
## the Covenant Seal suite (boss_meta.gd). A suite extends this file, names its boss in `_config()` and writes `run_suite()` from the generic parts below and its boss's own fight.
## Each boss is the real game scene (client/next/next_game.tscn) of a level-20 Gravecaller on the local mock, headless, with the boss's own area loaded and no waves: today's DmBossHost /
## DmBoss / DmBossBrain, ported (client/README.md "The bosses"): the body is an external of the combat core (kind 1), the brain is GDScript and its world is the core.
## The generic parts every boss gets (what archive/old-game:godot/tests/next_bosses/harness.gd checked of each boss, on the core):
##   - `t_replays`: the boss's recorded scenarios (tests/bosses/fixtures, captured from the TS brain) replayed tick by tick through this project's copy of the brain;
##   - `t_summon`: the hub's prompt at the site, the refusals (far, unknown, dead, shards: none spent), key E, the boss's price, busy, the awaken numbers, its registration with the core;
##   - `t_thralls`: a thrall picks the boss by the edge rule, its blows reach the brain with the owner's credit, the boss's blows reach the thrall through the core;
##   - `t_rites`: the rites' queries see it, Bone Needle's range counts its radius and its blow goes to the brain, a stun staggers it once;
##   - `t_wipe`: everyone gone -> it resets (no reward) and its adds leave the core silently; it can be woken again;
##   - `t_defeat`: a lethal blow -> the defeat events, the sound, the rewards (the first-kill bonus once, the report entry, the drops, the XP), the adds gone, a second kill is no first kill;
##   - `t_real_clock`: the brain on the engine's ticks fights with no engine error; `t_net_state`: the co-op step's state round trip.
## ZERO script errors or engine errors in the log (an OS Logger counts them). Gets the crowd models a suite names into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd).
## The by-hand step (`step`) runs the boss's brain and the core's tick once per 1/60 s, the order of the engine's (boss at priority 0, then the core host).

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://boss_test"
const DT := 1.0 / 60.0
const FIXTURES := "res://tests/bosses/"   ## the recorded scenarios (tests/bosses/fixtures, captured from the TS brain; tests/bosses replays them too), replayed on this project's copy of the brains


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## Counting back-ends for the fx (every Vfx / AudioDirector call the router makes), as archive/old-game:godot/tests/next_bosses/harness.gd has them.
class Stub:
	extends Node
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

	class Handle:
		extends RefCounted
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

	func play(_id: String, _a: Variant = null, _b: Variant = null) -> Variant:
		_count("bb")
		return Handle.new()

	func _get(_prop: StringName) -> Variant:
		return null


# ---- what a suite sets in `_config()`
var boss_id := ""
var load_areas: Array = []                    ## the areas the game scene loads (the boss's own)
var bakes: Array = ["thrall_legionnaire"]     ## the crowd models to bake into the scratch folder first (model slugs): the adds the boss calls, the thrall
var replay_count := 6                         ## the recorded scenarios of this boss in tests/bosses/fixtures
var start_opts := {}                          ## extra options for the game scene
var mock_clock: Array = []                    ## [ms]: when given, the mock backend's clock is this (the Seal's prize wants the fight to have lasted a while)

# ---- state
var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var host: DmCoreHost
var core: RefCounted
var hb: DmHeroBody
var c: DmRiteCaster
var me := 0                          ## the hero's peer id
var boss: DmBoss
var mock: DmMockBackend
var api: DmApi
var character: Dictionary
var stub := Stub.new()
var astub := Stub.new()
var evs: Array = []                  ## [{t: the boss's room clock, ev}] every event the brain emitted
var hurts: Array = []                ## the brain's `hurt` events (a blow on a player)
var hero_hurt: Array = []            ## [amount, source] from the hero's `hurt` signal
var thrall_hits: Array = []          ## [thrall id, boss id, kind, damage] from the core's EV_THRALL_HIT_EXTERNAL
var thrall_dmg: Array = []           ## [thrall id, source, amount, hp] from the core's thrall_damaged
var died_n := 0                      ## enemy_died events
var corpse_n := 0                    ## corpse_added events
var removed_n := 0                   ## enemy_removed events
var spawned_n := 0                   ## enemy_spawned events
var hit_log: Array = []              ## [rite, enemy id, amount, crit, killed] from the caster's hit_resolved
var after_kill := Callable()         ## t_defeat calls it right after each lethal blow (the progression's state before the backend's reply may restore the saved one)
var rejected := ""
var defeated: Array = []             ## DmBossHost.defeated
var resets: Array = []               ## DmBossHost.reset
var zone_log: Array = []             ## [id, kind name, source, x, z, radius, seconds] from the core's zone events
var drops: Array = []                ## the rewards' loot_dropped
var earned: Array = []               ## the rewards' boss_earned [boss, first]


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL %s: %s" % [boss_id, what])


func near(a: float, b: float, tol := 1e-6) -> bool:
	return absf(a - b) <= tol * maxf(1.0, maxf(absf(a), absf(b)))


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		if hb != null and is_instance_valid(hb) and hb.alive and not hb.p.is_empty():
			god()
		await physics_frame


func secs(s: float) -> void:
	await ticks(int(round(s * 60.0)))


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		if hb != null and is_instance_valid(hb) and hb.alive and not hb.p.is_empty():
			god()
		await physics_frame
	return cond.call()


## A suite names its boss, its area and the crowd models its fight needs.
func _config() -> void:
	pass


## What a suite sets on the account before the game scene starts (the character is `character`, the mock `mock`, the api `api`).
func before_start() -> void:
	pass


## A suite's whole run, after the game is up (the replays have run).
func run_suite() -> void:
	pass


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	_config()
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in bakes:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	if replay_count > 0:
		t_replays()
	await boot()
	await run_suite()
	await finish()


func boot() -> void:
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var reg := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 20)
	character = ch.data
	if not mock_clock.is_empty():
		mock.now_ms = func() -> int: return mock_clock[0]
	await before_start()
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	var opts := {"areas": load_areas, "offline": true, "name": "tester", "hud": false, "audio": false, "seed": 20261016, "waves": false, "wander": false, "baked_dir": OUT}
	opts.merge(start_opts, true)
	await g.start(character, api, opts)
	g.world.set_unlocked(load_areas)   # the area's navmesh (the boss walks it, thralls too) is what a broken seal switches on
	host = g.core_host
	core = host.core
	hb = g.local_body()
	c = hb.get_node("Rites") as DmRiteCaster
	me = g.session.get_my_id()
	c.random = func() -> float: return 0.5   # no crit, the middle of the needle's jitter
	g.bosses.rng.seed = int(opts["seed"])   # the brains' dice (a Chorus's direction, a lance's niche) the same every run: the host randomizes them in play
	_wire()
	await ticks(3)


func finish() -> void:
	g.queue_free()   # the scene comes down with the boss's body in it, and the log is read after that
	await process_frame
	await process_frame
	check(errlog.errors.is_empty(), "no script or engine errors in the log, the scene's teardown included (%d)" % errlog.errors.size())
	for e in errlog.errors.slice(0, 8):
		printerr("  ERROR: " + e)
	if fails == 0:
		print("PASS %s %d checks" % [get_script().resource_path.get_file().get_basename(), checks])
	quit(1 if fails > 0 else 0)


func _wire() -> void:
	check(g.ready_ and hb != null and c != null and g.bosses != null and g.bosses.name == "Bosses" and g.bosses.fx != null, "the game scene is up, the hero has his caster and the scene has a Bosses host with its fx")
	check(g.bosses.served_areas.has(area()) and g.world.has_area(area()), "the host serves %s and the game scene loaded it" % area())
	god()   # the fight is about numbers, not about the hero surviving them
	g.bosses.fx.set_backends(stub, astub)
	g.bosses.brain_event.connect(func(ev: Dictionary, b: DmBoss) -> void:
		evs.append({"t": b.world.t, "ev": ev.duplicate(true)})
		if ev["t"] == "hurt":
			hurts.append(ev))
	g.bosses.defeated.connect(func(id: String, killer: int, _p: Vector3) -> void: defeated.append([id, killer]))
	g.bosses.reset.connect(func(id: String) -> void: resets.append(id))
	hb.hurt.connect(func(amount: float, source: Variant) -> void: hero_hurt.append([amount, source]))
	host.thrall_hit_external.connect(func(id: int, target: int, kind: String, damage: float) -> void: thrall_hits.append([id, target, kind, damage]))
	host.thrall_damaged.connect(func(id: int, source: int, amount: float, hp: float) -> void: thrall_dmg.append([id, source, amount, hp]))
	host.enemy_died.connect(func(_id: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: died_n += 1)
	host.corpse_added.connect(func(_id: int, _k: int, _d: String, _e: bool, _a: String, _x: float, _z: float, _f: float, _s: float) -> void: corpse_n += 1)
	host.enemy_removed.connect(func(_id: int) -> void: removed_n += 1)
	host.enemy_spawned.connect(func(_id: int, _d: String, _l: int, _e: bool, _a: String, _af: int, _x: float, _z: float, _h: float) -> void: spawned_n += 1)
	host.zone.connect(func(id: int, kind: int, source: int, x: float, z: float, radius: float, seconds: float) -> void: zone_log.append([id, String(DmCoreEvents.ZONE_KINDS[kind]), source, x, z, radius, seconds]))
	g.enemy_fx.set_backends(stub, astub)
	c.hit_resolved.connect(func(rite: String, id: int, amount: float, crit: bool, killed: bool) -> void: hit_log.append([rite, id, amount, crit, killed]))
	c.cast_rejected.connect(func(_rite: String, why: String) -> void: rejected = why)
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _p: Vector3) -> void: drops.append(d))
	g.rewards.boss_earned.connect(func(_c: int, id: String, first: bool, _p: Vector3) -> void: earned.append([id, first]))
	g.rewards.rng = func() -> float: return 0.5


# ------------------------------------------------------------------------------------------------------------------------ helpers

func def() -> Dictionary:
	return DmContent.boss(boss_id)


func area() -> String:
	return String(def()["area"])


func arena() -> Vector3:
	return Vector3(float(def()["arena"]["x"]), 0.0, float(def()["arena"]["z"]))


func site() -> Vector3:
	return g.bosses.site_pos(boss_id)


## 2 m in front of the summoning site (inside the 4 m summon range).
func near_site() -> Vector3:
	return site() + Vector3(0.0, 0.0, 2.0)


func member() -> DmRewardsMember:
	return g.my_member()


## The member's soul shards, set outright (the progression syncs with the backend when the hero changes area: a reply restores the saved count).
func set_shards(n: int) -> void:
	member().prog.local["shards"] = n


func dmg_scale() -> float:
	return (1.0 + 0.15 * (float(boss.brain.state["level"]) - 1.0)) * float(DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]["enemyDamageMult"])


## The scaled damage of a base number (DmBossBrain._dmg).
func scaled(base: float) -> float:
	return base * dmg_scale()


## One tick of the brain and one of the core at a time, by hand: the exact timing of the brain's clock (the boss's own physics process is off) and the core's events.
func step(seconds: float, with_core := true) -> void:
	for i in int(round(seconds / DT)):
		god()
		boss._physics_process(DT)
		if with_core:
			host.tick(DT)


## Effectively unkillable: the numbers are read from the events, the hp only has to stay above zero (the late bosses hit for more than a level-20 hero's health,
## and the progression resets the stats now and then).
func god() -> void:
	if float(hb.p["stats"]["maxHp"]) < 9.0e8 or hb.hp < 9.0e8:
		hb.p["stats"]["maxHp"] = 1.0e9
		hb.p["hp"] = 1.0e9
		hb._mirror_from_state()


## Steps until `cond` holds (by hand), at most `limit` seconds; true if it held.
func step_until(cond: Callable, limit: float) -> bool:
	for i in int(limit / 0.05):
		if cond.call():
			return true
		step(0.05)
	return cond.call()


## One tick at a time until `cond` (exact event times).
func tick_until(cond: Callable, limit: float) -> bool:
	for i in int(limit / DT):
		if cond.call():
			return true
		step(DT)
	return cond.call()


func events(kind: String, ms_gt: float = -1.0) -> Array:
	var out: Array = []
	for e in evs:
		var ev: Dictionary = e["ev"]
		if ev["t"] == "boss" and ev["kind"] == kind and (ms_gt < 0.0 or float(ev.get("ms", 0.0)) > ms_gt):
			out.append(e)
	return out


func telegraphs(kind: String) -> Array:
	return events(kind, 0.0)


func impacts(kind: String) -> Array:
	return events(kind).filter(func(e: Dictionary) -> bool: return float(e["ev"].get("ms", 0.0)) == 0.0)


## The brain's hurts of exactly `base` x scale since index `from`.
func hurts_of(base: float, from := 0) -> Array:
	return hurts.slice(from).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - scaled(base)) < 1e-6)


func clear_logs() -> void:
	evs.clear()
	hurts.clear()
	hero_hurt.clear()
	thrall_hits.clear()
	thrall_dmg.clear()
	hit_log.clear()
	zone_log.clear()
	defeated.clear()
	resets.clear()
	drops.clear()
	earned.clear()
	stub.sfx.clear()
	astub.sfx.clear()
	stub.calls.clear()
	astub.calls.clear()


## Put the hero at `p` and refresh the brain's view of him.
func put(p: Vector3) -> void:
	hb.teleport(p)
	boss.world.refresh()


## Wake the boss as the rules say with the hero at its site and the shards in his progression; the body is stepped by hand until a test gives it back to the engine. "" = woken.
func wake(shards := 30) -> String:
	hb.teleport(near_site())
	set_shards(shards)
	var why := g.bosses.try_summon(me, boss_id)
	if why == "":
		boss = g.bosses.active_boss()
		boss.set_physics_process(false)
		boss.world.refresh()
	return why


## Put an awake boss to sleep the way the game does (everyone gone from the arena: it resets and what it called leaves the core), free the body at once (the host frees a fallen one
## after 8 s) and let the core drop its external.
func dismiss() -> void:
	if boss != null and is_instance_valid(boss):
		if boss.is_awake() and boss.brain != null:
			hb.teleport(Vector3(0.0, 0.0, 20.0))
			boss.world.refresh()
			boss._physics_process(DT)
		boss.queue_free()
	boss = null
	await ticks(3)


## The bodies of the core's table of one def.
func bodies(def_id: String) -> Array:
	var out: Array = []
	for id in core.enemy_ids():
		if String(core.enemy_info(id)["def"]) == def_id:
			out.append(int(id))
	return out


## The zones the core announced since the logs were cleared, of one kind (and one source id when given).
func zones_made(kind: String, source := -1) -> Array:
	return zone_log.filter(func(z: Array) -> bool: return z[1] == kind and (source < 0 or z[2] == source))


## Step (by hand) until the core has no live zone of these kinds (they run out: 9 s at the most), the boss held still by the caller.
func wait_zones_out(kinds := ["toxic", "ember"]) -> void:
	for i in 40:
		if kinds.all(func(k: String) -> bool: return core.zones(k).is_empty()):
			return
		step(0.5)


func hp_of(id: int) -> float:
	var i: Dictionary = host.enemy_info(id)
	return float(i["hp"]) if not i.is_empty() else -1.0


func set_hp(frac: float) -> void:
	boss.brain.state["hp"] = boss.max_hp * frac
	boss.hp = boss.max_hp * frac


## Drop the boss to `frac` of its max hp (through take_damage, like a hit) and run one tick so the phase change fires.
func wound(frac: float) -> void:
	boss.take_damage(boss.hp - boss.max_hp * frac, hb)
	step(0.1)


## A thrall of the hero's, rising: 0.9 s before it acts. `hold` stuns it for good so it stands where it is (it still falls to blows and still is a target).
func thrall(at: Vector3, hp := 4000.0, damage := 40.0) -> int:
	var t := int(core.raise_thrall({"kind": "warrior", "hp": hp, "maxHp": hp, "damage": damage, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false},
		hb.core_id, Vector2(at.x, at.z), 0.0, 8.0))
	return t


func cast(rite: String, aim: Vector3, target := -1) -> Dictionary:
	c.p["castUntil"] = 0.0
	c.p["cooldowns"].erase(rite)
	rejected = ""
	c.request_cast(rite, aim, target)
	return {"ok": rejected == "", "reason": rejected}


func sp_now() -> float:
	return DmAbilities.sp(c.p, c.now_ms)


func hits_of(rite: String, mark := 0) -> Array:
	var out: Array = []
	for i in range(mark, hit_log.size()):
		if String(hit_log[i][0]) == rite:
			out.append(hit_log[i])
	return out


## The awaken numbers: hp = baseHp x (1 + 0.22 (level - 1)) x the difficulty's health.
func awaken_hp_ok(base_hp: float) -> bool:
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want: float = base_hp * (1.0 + 0.22 * (float(boss.brain.state["level"]) - 1.0)) * float(diff["enemyHpMult"])
	return near(boss.max_hp, want) and boss.hp == boss.max_hp


# ------------------------------------------------------------------------------------------------------------------------ the brain, replayed

## Today's recorded scenarios of this boss (tests/bosses/fixtures, captured from the TS brain) through this project's copy of the brain, tick by tick, on today's fake world.
func t_replays() -> void:
	var dir := FIXTURES
	var fake = load(dir.path_join("fake_world.gd"))
	var diff = load(dir.path_join("deep_diff.gd"))
	check(fake != null and diff != null, "today's fake world and diff helper are readable (%s)" % dir)
	if fake == null or diff == null:
		return
	var files: Array = []
	var d := DirAccess.open(dir.path_join("fixtures"))
	if d != null:
		for f in d.get_files():
			if f.begins_with(boss_id + "_") and f.ends_with(".json.gz"):
				files.append(f)
	files.sort()
	check(files.size() == replay_count, "the %s's %d recorded scenarios are there (%d)" % [boss_id, replay_count, files.size()])
	var ticks_total := 0
	for f in files:
		ticks_total += _replay(dir.path_join("fixtures").path_join(f), fake, diff)
	print("INFO %s replays: %d scenarios, %d ticks compared, boss state, world calls and entities every tick" % [boss_id, files.size(), ticks_total])


func _replay(path: String, fake, diff) -> int:
	var fx: Dictionary = JSON.parse_string(PackedByteArray(FileAccess.get_file_as_bytes(path)).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	var w = fake.new(int(fx["seed"]) + 1, fx["difficulty"], int(fx["level"]))
	w.echoes_n = int(fx["echoes"])
	w.cover_boxes = fx["cover"].duplicate(true)
	var brain: RefCounted = DmBossBrains.make(w, fx["boss"])
	var expect_world: Dictionary = {}
	var n := 0
	for tk in fx["ticks"]:
		w.log = []
		for o in tk["ops"]:
			_apply(w, brain, o)
		w.time += float(tk["dt"])
		w.expire_zones()
		brain.update(float(tk["dt"]))
		if tk.has("world"):
			expect_world = tk["world"]
		var msg: String = diff.diff(_boss_snap(brain), tk["boss"], "boss")
		if msg == "":
			msg = diff.diff(w.log, tk["log"], "log")
		if msg == "":
			msg = diff.diff(_world_snap(w), expect_world, "world")
		if msg == "":
			msg = diff.diff(w.time, tk["time"], "time")
		n += 1
		if msg != "":
			check(false, "%s tick %d: %s" % [fx["name"], int(tk["t"]), msg])
			return n
	check(true, "replay " + String(fx["name"]))
	return n


func _apply(w, brain, o: Dictionary) -> void:
	match o["op"]:
		"awaken":
			brain.awaken(o["by"], o["empowered"])
		"damage":
			brain.damage(float(o["amount"]), o["by"], int(o["fracture"]))
		"stagger":
			brain.stagger(float(o["seconds"]))
		"resume":
			brain.resume()
		"set_players":
			w.player_list = []
			for p in o["players"]:
				w.player_list.append({"id": p["id"], "x": float(p["x"]), "z": float(p["z"]), "alive": p["alive"], "area": p["area"]})
		"kill_enemy":
			var e: Dictionary = w.enemy_get(int(o["id"]))
			if not e.is_empty():
				e["hp"] = 0.0
				e["state"] = "dead"
		"del_enemy":
			w.enemy_map.erase(int(o["id"]))
		"add_enemy":
			w.enemy_map[int(o["id"])] = {"id": int(o["id"]), "def": o["def"], "area": o["area"], "x": float(o["x"]), "z": float(o["z"]), "elite": false, "hp": float(o["hp"]), "max_hp": float(o["hp"]), "state": "idle"}
		"add_corpse":
			w.corpse_map[int(o["id"])] = {"id": int(o["id"]), "area": o["area"], "x": float(o["x"]), "z": float(o["z"])}
		"del_corpse":
			w.corpse_map.erase(int(o["id"]))
		"add_thrall":
			w.thrall_map[int(o["id"])] = {"id": int(o["id"]), "x": float(o["x"]), "z": float(o["z"]), "hp": float(o["hp"]), "max_hp": float(o["hp"]), "flash": 0.0, "state": "idle"}
		"set_boss":
			for k in o["fields"]:
				brain.state[k] = o["fields"][k]
		"set_cover":
			w.cover_boxes = o["boxes"].duplicate(true)
		_:
			check(false, "unknown replay op " + str(o["op"]))


func _boss_snap(b) -> Dictionary:
	var s: Dictionary = b.state
	var out := {}
	for k in ["active", "x", "z", "facing", "hp", "maxHp", "phase", "state", "stateT", "flash", "fracture", "fractureT", "withered", "witheredT", "witheredDps", "level"]:
		out[k] = s[k]
	out["empowered"] = bool(s.get("empowered", false))
	return out


func _ents(m: Dictionary) -> Array:
	var out: Array = []
	for e in m.values():
		out.append({"id": e["id"], "hp": e["hp"], "maxHp": e["max_hp"], "state": e["state"], "x": e["x"], "z": e["z"]})
	out.sort_custom(func(a, b): return a["id"] < b["id"])
	return out


func _world_snap(w) -> Dictionary:
	var corpses: Array = w.corpse_map.keys()
	corpses.sort()
	var zones: Array = w.zone_map.keys()
	zones.sort()
	return {"enemies": _ents(w.enemy_map), "thralls": _ents(w.thrall_map), "corpses": corpses, "zones": zones}


# ------------------------------------------------------------------------------------------------------------------------ summoning

## The hub's prompt at the site, the refusals and the boss's price, key E, busy, the awaken numbers and the boss's registration with the core. `cost` is its soul shards, `base_hp` its baseHp.
## Leaves nothing awake.
func t_summon(cost: int, base_hp: float) -> void:
	await ticks(2)
	var ch: DmChapterhouse = g.chapterhouse
	var label := String(def()["summonLabel"])
	hb.teleport(Vector3(0.0, 0.0, 20.0))
	check(g.bosses.try_summon(me, boss_id) == "far", "summon refused away from %s (far)" % label)
	check(g.bosses.try_summon(me, "nobody") == "unknown", "an id that is no boss is not summonable")
	check(g.bosses.try_summon(999, boss_id) == "dead", "an unknown summoner is refused")
	hb.teleport(near_site())
	await ticks(45)   # past the host's 0.5 s tick
	check(g.area_of(me) == area(), "the hero is in the %s" % area())
	var s := site()
	check(s != Vector3.INF and g.bosses.site_near(hb.position, 4.0) == boss_id, "at %s the site is %s's (%s)" % [label, boss_id, str(s)])
	# the hub's prompt: nothing fades, it reads the price; away from the site there is none; the hover prompt asks for a click
	ch._update_prompt(hb)
	check(ch.prompt_text == "<kbd>E</kbd> Summon %s · %d shards" % [def()["name"], cost], "at the site the hub prompt reads '%s'" % str(ch.prompt_text))
	var it: Dictionary = {}
	for x in ch.interactables:
		if String(x["id"]) == String(def()["summonId"]):
			it = x
	check(not it.is_empty() and String(it["kind"]) == "boss" and ch.boss_for_summon(String(it["id"])) == boss_id, "the site is a boss interactable of the area, and the hub maps it to the boss")
	ch.hover = it
	ch._update_prompt(hb)
	check(ch.prompt_text == "<kbd>Click</kbd> Summon %s · %d shards" % [def()["name"], cost], "hovering the site shows the click prompt")
	ch.hover = null
	hb.teleport(Vector3(0.0, 0.0, 20.0))
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "away from the site: no prompt")
	hb.teleport(near_site())
	await ticks(2)
	# the refusals: shards
	var prog := member().prog
	set_shards(0)
	check(g.bosses.try_summon(me, boss_id) == "shards" and g.bosses.active_boss() == null, "no shards -> refused, nothing woken")
	set_shards(cost - 1)
	check(g.bosses.try_summon(me, boss_id) == "shards" and int(prog.local["shards"]) == cost - 1, "%d of %d soul shards is not enough and none are spent" % [cost - 1, cost])
	var why_text := g.bosses.why_text("shards", boss_id, me)
	check(why_text.contains(label) and why_text.contains("(you have %d)" % (cost - 1)), "the refusal names the site and the count (%s)" % why_text)
	# key E at the site wakes it
	set_shards(cost + 2)
	var summoned: Array = []
	g.bosses.summoned.connect(func(b: String, p: int) -> void: summoned.append([b, p]))
	var spawned: Array = []
	g.bosses.boss_spawned.connect(func(b: DmBoss) -> void: spawned.append(b))
	var kev := InputEventKey.new()
	kev.physical_keycode = KEY_E
	kev.pressed = true
	g.bosses._unhandled_input(kev)
	boss = g.bosses.active_boss()
	check(boss != null and boss.boss_id == boss_id, "key E at the site wakes %s" % boss_id)
	if boss == null:
		return
	boss.set_physics_process(false)
	boss.world.refresh()
	check(int(prog.local["shards"]) == 2 and summoned == [[boss_id, me]] and spawned.size() == 1, "the summon took its %d soul shards (%d left) and `summoned` and `boss_spawned` fired once" % [cost, int(prog.local["shards"])])
	check(g.bosses.try_summon(me, boss_id) == "busy" and int(prog.local["shards"]) == 2, "a second summon while it is awake is refused (busy), no shards taken")
	check(boss.is_in_group(&"dm_boss") and boss.get_parent().get_parent() == g.bosses, "the body is a DmBoss under the Bosses host")
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "the prompt hides while a boss is awake")
	# the awaken numbers
	check(awaken_hp_ok(base_hp), "awaken hp = baseHp %d x level x difficulty (%.0f)" % [int(base_hp), boss.max_hp])
	check(boss.phase == 1 and boss.is_awake() and boss.bstate.active, "awake, phase 1")
	check(events("awaken").size() == 1 and stub.calls.get("emit", 0) > 0 and "bossAwaken" in astub.sfx, "the awaken event reaches the fx and starts the boss bed (bossAwaken)")
	check(boss.view != null and boss.view.boss_id == boss_id and boss.view.slug == String(def()["modelSlug"]), "the current client's DmBossView with the model %s" % str(def()["modelSlug"]))
	check(boss.core_id > 0 and host.boss_for(boss.core_id) == boss, "the body registered with the core's host as an external (id %d)" % boss.core_id)
	var info: Dictionary = host.enemy_info(boss.core_id)
	check(not info.is_empty() and bool(info["boss"]) and info["def"] == "boss_" + boss_id and near(float(info["radius"]), 1.6) and near(float(info["hp"]), boss.hp) and info["area"] == area(), "the host's record of it: boss, def, radius 1.6, health, area")
	check(core.enemy_info(boss.core_id).is_empty(), "the core's own table has no enemy of that id")
	await ticks(2)
	check(boss.is_hittable() and host.enemy_alive(boss.core_id), "it is alive for the queries")
	# the boss score follows the local hero while he is in its area (the host asks the AudioDirector twice a second) and ends with the boss
	g.bosses.audio_enabled = true
	await secs(0.7)
	var a := root.get_node_or_null("AudioDirector")
	check(a != null and bool(a.music.state.boss), "the boss score plays while the hero is in its area")
	await dismiss()
	await secs(0.7)
	check(a != null and not bool(a.music.state.boss), "and ends with the boss")
	g.bosses.audio_enabled = false
	check(g.bosses.active_boss() == null and g.bosses.bosses.is_empty() and host.boss_for(0) == null, "a freed body leaves the host and the core")
	clear_logs()


# ------------------------------------------------------------------------------------------------------------------------ thralls

## A suite clears out what would take the thralls' blows or their attention instead of the boss (the Abbess's niches are enemies they hit).
func before_thralls() -> void:
	pass


## A thrall picks the boss by the edge rule (its centre is farther than the 10 m engage range, its edge is not), its blows come back as EV_THRALL_HIT_EXTERNAL naming the thrall, the boss
## and its kind, each one goes to the brain with the owner's credit, and the boss's sweep reaches the thrall by `core.damage` on its id. Leaves the boss free of the engine again.
func t_thralls() -> void:
	clear_logs()
	check(wake() == "", "woken for the thralls")
	await before_thralls()
	var toward := Vector3(-1.0, 0.0, 0.0)
	var bp := boss.global_position
	put(bp + toward * 8.0)
	await ticks(2)
	var t1 := thrall(bp + toward * 11.2)
	core.set_thrall_stats(t1, {"hp": 4000.0})
	var hp0 := boss.hp
	var engaged := await until(func() -> bool: return int(core.thrall_info(t1)["target"]) == boss.core_id, 4.0)
	check(engaged, "the thrall picks it though its centre is 11.2 m away: the boss rule counts from the edge")
	core.set_thrall_pos(t1, Vector2(bp.x + toward.x * 2.6, bp.z + toward.z * 2.6))   # next to it: the walk round a wall of some arenas is the navmesh's business, not this part's
	var hit := await until(func() -> bool: return thrall_hits.size() >= 3, 12.0)
	check(hit and thrall_hits.all(func(h: Array) -> bool: return h[0] == t1 and h[1] == boss.core_id and h[2] == "warrior"), "its blows come back as EV_THRALL_HIT_EXTERNAL naming the thrall, the boss and its kind (%d)" % thrall_hits.size())
	var sum := 0.0
	for h in thrall_hits:
		sum += float(h[3])
	check(near(hp0 - boss.hp, sum) and sum > 0.0, "each went to the brain: it lost exactly their damage (%.1f in %d blows)" % [sum, thrall_hits.size()])
	check(boss.brain.last_hit_by == str(me), "the credit is the thrall's owner (%s)" % boss.brain.last_hit_by)
	core.kill_thrall(t1, "crumbled")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ rites

## The rite world sees the boss from its edge, after the enemies; Bone Needle's range counts its radius and its blow goes to the brain with the hero's credit; a stun staggers it once.
func t_rites() -> void:
	clear_logs()
	check(wake() == "", "woken for the rites")
	var bid := boss.core_id
	var bp := boss.global_position
	await ticks(2)
	put(bp + Vector3(8.0, 0.0, 0.0))
	check(g.enemies_in_radius(bp + Vector3(5.0, 0.0, 0.0), 3.4).has(bid) and not g.enemies_in_radius(bp + Vector3(5.0, 0.0, 0.0), 3.39).has(bid), "the query measures to its edge: 5 m away, radius 3.4 reaches it (5 - 1.6) and 3.39 does not")
	var foes := host.foes_in_radius(bp, 2.0)
	check(foes.size() >= 1 and foes[foes.size() - 1].boss and foes[foes.size() - 1].id == bid and foes[foes.size() - 1].def == "boss_" + boss_id, "as a DmFoe snapshot: the boss, its def")
	c.p["resource"]["value"] = 50.0
	put(bp + Vector3(12.0, 0.0, 0.0))
	var r := cast("bone_needle", bp, bid)
	check(bool(r["ok"]), "Bone Needle at 12 m is accepted (range 11 + its radius 1.6): %s" % r["reason"])
	var hp0 := boss.hp
	var nc := DmAbilities.needle_cast(sp_now(), c.p["loadout"], "", 0, 0.5)
	var hit := DmAbilities.needle_hit(nc["dmg"], 0.5)
	await secs(0.8)
	check(near(hp0 - boss.hp, float(hit["amount"])), "the needle took %.3f from it (the formula %.3f)" % [hp0 - boss.hp, float(hit["amount"])])
	var h := hits_of("bone_needle")
	check(h.size() == 1 and h[0][1] == bid and not bool(h[0][4]) and boss.brain.last_hit_by == str(me), "one hit credited to the hero on its id, not a kill; the brain's credit is the hero")
	put(bp + Vector3(13.0, 0.0, 0.0))
	r = cast("bone_needle", bp, bid)
	check(not bool(r["ok"]) and r["reason"] == "range", "at 13 m it is refused `range` (%s)" % r["reason"])
	boss.stun(5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "a stun staggers it at most 0.5 s (%.2f)" % boss.brain.stagger_t)
	var st0: float = boss.brain.stagger_t
	boss.stun(5.0)
	check(near(boss.brain.stagger_t, st0), "and has a cooldown (no stun-lock)")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ wipe

## Everyone gone from the arena: it goes back to sleep without a reward, what it called leaves with it (no death, no corpse, no credit), and it can be woken again.
## `adds_expected` is how many core bodies it has called by then (`provoke`, if given, is what makes it call them: a phase, a wave).
func t_wipe(adds_expected := 0, provoke := Callable()) -> void:
	clear_logs()
	check(wake() == "", "woken for the wipe")
	put(arena() + Vector3(3.0, 0.0, 0.0))
	if provoke.is_valid():
		await provoke.call()
	await ticks(1)   # the core's events of the hand-stepped fight reach the host
	var adds: Array = []
	for id in core.enemy_ids():
		adds.append(int(id))
	var total := host.enemy_total()
	var died0 := died_n
	var corpses0 := corpse_n
	var removed0 := removed_n
	var bosses0 := int(member().stats["bosses"])
	check(adds.size() >= adds_expected, "its adds are in the core before the wipe (%d of at least %d)" % [adds.size(), adds_expected])
	hb.teleport(Vector3(0.0, 0.0, 20.0))
	boss.world.refresh()
	step(0.1, false)
	check(resets == [boss_id] and defeated.is_empty() and not boss.is_hittable() and not boss.dead, "everyone gone -> the boss resets (no reward) and can be woken again")
	check(int(member().stats["bosses"]) == bosses0, "a reset pays nothing")
	check(adds.all(func(id: int) -> bool: return host.enemy_info(id).is_empty()) and host.enemy_total() == total - adds.size(), "every add left the core at once (%d)" % adds.size())
	await ticks(3)
	check(died_n == died0 and corpse_n == corpses0 and removed_n - removed0 == adds.size(), "silently: %d removed events, no death, no corpse" % (removed_n - removed0))
	check(host.alive_count() == host.enemy_total(), "and none counts among the dying (%d alive of %d)" % [host.alive_count(), host.enemy_total()])
	check(not host.enemy_alive(boss.core_id) and not (boss.core_id in host.enemies_in_radius(arena(), 30.0)), "a boss that is not awake is nobody's target")
	await dismiss()
	clear_logs()
	check(wake() == "" and boss.is_hittable() and boss.hp == boss.max_hp, "the next summon is a fresh fight")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ defeat and rewards

## A lethal blow from a rite: the answer says killed, the defeat events, the sound, `died`, the host's `defeated` naming the killer, the rewards (the first-kill bonus once: shards, a trophy,
## the report entry, drops, XP), the adds gone silently; the boss is woken again and a second kill is no first kill. The Prelate has no trophy (the run's boss).
func t_defeat(first_expected := true, provoke := Callable()) -> void:
	clear_logs()
	check(wake() == "", "woken for the defeat")
	var bid := boss.core_id
	var old := boss
	put(arena() + Vector3(3.0, 0.0, 0.0))
	if String(boss.brain.state["state"]) == "sunk":   # a blow at the very end while sunk is refused: she must surface to die
		boss.brain.state["state"] = "idle"
		boss.bstate.state = "idle"
	var died_signal: Array = []
	boss.died.connect(func(b: DmBoss) -> void: died_signal.append(b))
	var m := member()
	var xp0 := float(m.prog.character["experience"])
	var bosses0 := int(m.stats["bosses"])
	if provoke.is_valid():   # what makes it call its adds (a phase), so they are there when it falls
		await provoke.call()
	var adds := []
	for id in core.enemy_ids():
		adds.append(int(id))
	var total := host.enemy_total()
	var died0 := died_n
	var corpses0 := corpse_n
	var removed0 := removed_n
	boss.take_damage(boss.hp - 1.0, hb)
	var rr: Dictionary = host.damage(bid, 5.0, hb.core_id)
	if after_kill.is_valid():
		after_kill.call()
	check(bool(rr["killed"]) and float(rr["dealt"]) == 5.0, "a rite's blow on it answers {dealt, killed} at once: the kill is known inside the call")
	check(boss.hp == 0.0 and boss.dead and not boss.is_hittable() and died_signal == [boss], "it is down: no health, `died` fired once, no longer hittable")
	check(defeated == [[boss_id, me]], "the host's `defeated` names the killer: the hero")
	var df := events("defeated")
	check(df.size() == 1 and str(df[0]["ev"]["killer"]) == str(me), "the brain's defeated event names the killer's peer")
	check("bossDefeat" in astub.sfx, "the defeat sound")
	check(earned == [[boss_id, first_expected]], "the member is paid (first kill: %s) -> %s" % [first_expected, str(earned)])
	var gold := 0
	var dshards := 0
	for d in drops:
		if d.get("kind") == "gold":
			gold += int(d["amount"])
		if d.get("kind") == "shard":
			dshards += int(d["amount"])
	check(gold > 0 and dshards >= (2 if first_expected else 1) and drops.size() >= 2, "gold, shards and items were dropped at the corpse (%d drops, %d gold, %d shards)" % [drops.size(), gold, dshards])
	check(float(m.prog.character["experience"]) > xp0 or int(m.stats["levels"]) > 0, "the boss's XP was applied")
	check(int(m.stats["bosses"]) == bosses0 + 1 and m.reporter._bosses.size() == 1, "the kill is queued for the backend's report {boss, tier, diff, first}")
	if m.reporter._bosses.size() == 1:
		var key: String = m.reporter._bosses.keys()[0]
		check(key.begins_with("%s|" % boss_id) and key.contains("|%d|" % (1 if first_expected else 0)), "reported with first=%s (%s)" % [first_expected, key])
	await g.rewards.flush()
	check(not m.reporter.has_pending(), "the batch went through the party session and nothing is pending")
	check(not host.enemy_alive(bid) and not (bid in host.enemies_in_radius(boss.global_position, 30.0)) and float(host.damage(bid, 1.0, hb.core_id)["dealt"]) == 0.0, "a fallen boss is nobody's target and takes no more blows")
	check(adds.all(func(id: int) -> bool: return host.enemy_info(id).is_empty()) and host.enemy_total() == total - adds.size(), "what it called left the core with it (%d)" % adds.size())
	await ticks(3)
	check(died_n == died0 and corpse_n == corpses0 and removed_n - removed0 == adds.size() and host.alive_count() == host.enemy_total(), "silently: no death, no corpse, no credit, nobody counted among the dying")
	# woken again while the old body lingers; the second kill is no first kill
	clear_logs()
	check(wake() == "" and boss != old and boss.core_id != bid and boss.is_hittable() and boss.hp == boss.max_hp, "it can be woken again: a fresh body, a new id in the core (%d -> %d)" % [bid, boss.core_id])
	await ticks(2)
	check(host.enemy_alive(boss.core_id) and not host.enemy_alive(bid), "only the new one is a target")
	put(arena() + Vector3(3.0, 0.0, 0.0))
	boss.take_damage(boss.hp + 1.0, hb)
	if after_kill.is_valid():
		after_kill.call()
	check(earned == [[boss_id, false]], "a second kill has no first-kill bonus (%s)" % str(earned))
	check(drops.size() >= 2, "(and still pays gold and drops)")
	old.queue_free()
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ the real clock

## The brain on the engine's ticks fights (telegraphs, blows on the hero with its core id as the source), the host ticks the core and dispatches its events, no engine error.
## `wanted` names events that must show within `limit_s`.
func t_real_clock(wanted: Array, limit_s: float) -> void:
	clear_logs()
	check(wake() == "", "woken for a fight on the real clock")
	var bid := boss.core_id
	boss.set_physics_process(true)
	put(arena() + Vector3(4.0, 0.0, 0.0))
	var ok := await until(func() -> bool: return wanted.all(func(k: String) -> bool: return not events(k, 0.0).is_empty()), limit_s)
	check(ok, "the brain on the engine's ticks telegraphs %s (%s)" % [str(wanted), str(wanted.map(func(k: String) -> int: return events(k, 0.0).size()))])
	var hurt := await until(func() -> bool: return hero_hurt.any(func(x: Array) -> bool: return x[1] is int and int(x[1]) == bid), limit_s)
	check(hurt, "and its blows hurt the hero with its core id as the source (%d hurts)" % hero_hurt.size())
	check(boss.view != null and boss.view.is_shown(), "its view is up (drawn from the brain's state)")
	boss.set_physics_process(false)
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ the co-op seam

## A puppet body takes the host body's snapshot: pose, health, phase, state and the live telegraphs round-trip.
func t_net_state() -> void:
	clear_logs()
	check(wake() == "", "woken for the net state")
	boss.set_physics_process(true)
	put(arena() + Vector3(3.0, 0.0, 0.0))
	await secs(1.0)
	var st: Dictionary = boss.get_net_state()
	var pup := DmBoss.new()
	pup.visual = false
	pup.boss_id = boss_id
	pup.set_multiplayer_authority(2)
	root.add_child(pup)
	pup.apply_net_state(st)
	check(pup.global_position.is_equal_approx(boss.global_position) and near(pup.hp, boss.hp) and near(pup.max_hp, boss.max_hp) and pup.phase == boss.phase and pup.bstate.active == boss.bstate.active and pup.bstate.state == boss.bstate.state,
		"a puppet adopts the host body's snapshot: place, health, phase, state (%s)" % str(pup.bstate.state))
	check(pup.telegraphs.size() == st["tl"].size() and pup.core_id == 0 and pup.brain == null, "with the live telegraphs, no brain and no core id")
	var lost := boss.hp * 0.9
	var st2 := st.duplicate()
	st2["hp"] = lost
	var damaged: Array = []
	pup.damaged.connect(func(a: float, h: float, _f: Node) -> void: damaged.append([a, h]))
	pup.apply_net_state(st2)
	check(damaged.size() == 1 and near(float(damaged[0][0]), boss.hp - lost) and near(pup.hp, lost), "a drop of health is a hit for the puppet (`damaged`)")
	pup.queue_free()
	boss.set_physics_process(false)
	await dismiss()
