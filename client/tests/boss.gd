extends SceneTree
## The Gravedigger King on the combat core (client/README.md "The bosses"): the real offline game scene (client/next/next_game.tscn)
## with a level-20 Gravecaller, no waves, headless. The King is today's DmBossHost / DmBoss / DmBossBrain, ported: his body is an external of the core (kind 1), his brain stays GDScript.
##   - the brain: today's gravedigger_* scenarios replay tick by tick through the client's copy of the brain (fixtures in tests/bosses);
##   - summoning: the rules of the Graves (far, unknown, busy, dead), key E at his grave, the awaken numbers and event; he is registered with the core (core_id, the host's records);
##   - his fight stepped by hand (exact timing, as archive/old-game:godot/tests/next_bosses/gravedigger_part.gd does): Spade Sweep and Burial (numbers, telegraphs, the blows on the hero and on a thrall), the phases at
##     60 / 30 %, Barrow Ghouls on the arena rim and the elite robber (adds are core bodies of the Graves, the boss's area), the four pits, the double sweep; a wipe resets him and his adds leave
##     the core silently (no death, no corpse, no credit: remove_enemy);
##   - thralls: they pick him by the boss edge rule, hit him through EV_THRALL_HIT_EXTERNAL into the brain with their owner's credit, and he hits them back with `core.damage` on their ids;
##     he is not a target while he cannot be hurt (the external's `alive`);
##   - the rites hit him: the host's queries append him after the enemies (edge distance, his radius), the lane, the cone and the circle helpers, the needle's range and the Scythe's arc count him,
##     a rite's damage goes to his brain with the hero's credit, his statuses are his own DmStatusSet (the brain ignores slow, root and chill), a stun staggers him once;
##   - he dies: the defeat events (the brain's `defeated`, the host's `defeated` signal, `died`, the sound), the adds that stood by him are gone without dying, he can be woken again;
##   - a fight on the real clock (the brain on the engine's physics ticks, the host's tick, the core's events) with no script or engine error; the net state round trip (the co-op step's seam).
## The other six bosses have their own suites (boss_abbess.gd ... boss_mire.gd on boss_base.gd) and the Covenant Seal's Empowered call is boss_meta.gd. ZERO script errors or engine errors in the log (an OS Logger counts them).
## Gets the robber, the hound and the Gravecaller's legionnaire into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --path client --script res://tests/boss.gd
## It plays about 60 s of game time: with the engine argument `--fixed-fps 60` before `--path` it runs faster than real time.

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://boss_test"
const BAKE := ["grave_robber", "bone_hound", "thrall_legionnaire"]
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
var rejected := ""
var defeated: Array = []             ## DmBossHost.defeated
var resets: Array = []               ## DmBossHost.reset
var fight_spawned0 := 0              ## spawn events before the hand-stepped fight


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL boss: " + what)


func near(a: float, b: float, tol := 1e-6) -> bool:
	return absf(a - b) <= tol * maxf(1.0, maxf(absf(a), absf(b)))


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func secs(s: float) -> void:
	await ticks(int(round(s * 60.0)))


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	t_replays()
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 20)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["graves"], "offline": true, "name": "tester", "hud": false, "audio": false, "seed": 20261016, "waves": false, "wander": false, "baked_dir": OUT})
	host = g.core_host
	core = host.core
	hb = g.local_body()
	c = hb.get_node("Rites") as DmRiteCaster
	me = g.session.get_my_id()
	c.random = func() -> float: return 0.5   # no crit, the middle of the needle's jitter
	_wire()
	g.my_member().prog.add_shards(int(DmContent.boss("gravedigger")["shards"]) * 40)   # a summon costs the King's soul shards (t_summon checks the refusal and the price)
	await t_summon()
	await t_hand_fight()
	await t_wipe()
	await t_thralls()
	await t_rites()
	await t_defeat()
	await t_real_clock()
	await t_net_state()
	await finish()


func finish() -> void:
	g.queue_free()   # the scene comes down with his body in it, and the log is read after that
	await process_frame
	await process_frame
	check(errlog.errors.is_empty(), "no script or engine errors in the log, the scene's teardown included (%d)" % errlog.errors.size())
	for e in errlog.errors.slice(0, 8):
		printerr("  ERROR: " + e)
	if fails == 0:
		print("PASS boss %d checks" % checks)
	quit(1 if fails > 0 else 0)


func _wire() -> void:
	check(g.ready_ and hb != null and c != null and g.bosses != null and g.bosses.name == "Bosses" and g.bosses.fx != null, "the game scene is up, the hero has his caster and the scene has a Bosses host with its fx")
	var boss_areas: Array = []
	for bid in DmContent.bosses():
		if not boss_areas.has(String(DmContent.boss(String(bid))["area"])):
			boss_areas.append(String(DmContent.boss(String(bid))["area"]))
	var served: Array = g.bosses.served_areas.duplicate()
	served.sort()
	boss_areas.sort()
	check(not boss_areas.is_empty() and served == boss_areas, "the host wakes the boss of every area the boss data names (the other bosses have their own suites: boss_*.gd)")
	hb.p["stats"]["maxHp"] = 1.0e5   # the fight is about numbers, not about the hero surviving them
	hb.heal(1.0e6)
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
	c.hit_resolved.connect(func(rite: String, id: int, amount: float, crit: bool, killed: bool) -> void: hit_log.append([rite, id, amount, crit, killed]))
	c.cast_rejected.connect(func(_rite: String, why: String) -> void: rejected = why)


# ------------------------------------------------------------------------------------------------------------------------ helpers

func def() -> Dictionary:
	return DmContent.boss("gravedigger")


func arena() -> Vector3:
	return Vector3(float(def()["arena"]["x"]), 0.0, float(def()["arena"]["z"]))


func near_site() -> Vector3:
	return g.bosses.site_pos("gravedigger") + Vector3(0.0, 0.0, 2.0)


func dmg_scale() -> float:
	return (1.0 + 0.15 * (float(boss.brain.state["level"]) - 1.0)) * float(DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]["enemyDamageMult"])


## One brain tick at a time, by hand: the exact timing of the brain's clock (the boss's own physics process is off).
func step(seconds: float) -> void:
	for i in int(round(seconds / DT)):
		hb.heal(1.0e6)
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


func clear_logs() -> void:
	evs.clear()
	hurts.clear()
	hero_hurt.clear()
	thrall_hits.clear()
	thrall_dmg.clear()
	hit_log.clear()
	defeated.clear()
	resets.clear()
	stub.sfx.clear()
	astub.sfx.clear()
	stub.calls.clear()
	astub.calls.clear()


## Wake the King as the Graves' rules say; the body is stepped by hand until a test gives it back to the engine. "" = woken.
func wake() -> String:
	var why := g.bosses.try_summon(me, "gravedigger")
	if why == "":
		boss = g.bosses.active_boss()
		boss.set_physics_process(false)
		boss.world.refresh()
	return why


## Free the body at once (the host frees a fallen one after 8 s) and let the core drop its external.
func dismiss() -> void:
	if boss != null and is_instance_valid(boss):
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


func hp_of(id: int) -> float:
	var i: Dictionary = host.enemy_info(id)
	return float(i["hp"]) if not i.is_empty() else -1.0


func legion() -> DmCoreLegion:
	return c.thralls()


## The hero's cast as the owner does it (cooldown and cast lock cleared first): {ok, reason}.
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


# ------------------------------------------------------------------------------------------------------------------------ the brain, replayed

## Today's recorded Gravedigger scenarios (tests/bosses/fixtures, captured from the TS brain) through this project's copy of the brain, tick by tick, on today's fake world.
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
			if f.begins_with("gravedigger_") and f.ends_with(".json.gz"):
				files.append(f)
	files.sort()
	check(not files.is_empty(), "the King's recorded scenarios are there (%d)" % files.size())
	var ticks_total := 0
	var empty: Array = []
	for f in files:
		var t := _replay(dir.path_join("fixtures").path_join(f), fake, diff)
		ticks_total += t
		if t <= 0:
			empty.append(f)
	check(empty.is_empty(), "every recorded scenario in the folder was loaded and replayed (%s)" % str(empty))
	print("INFO replays: %d scenarios, %d ticks compared, boss state, world calls and entities every tick" % [files.size(), ticks_total])


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

func t_summon() -> void:
	await ticks(2)
	hb.teleport(Vector3(0.0, 0.0, 20.0))
	check(g.bosses.try_summon(me, "gravedigger") == "far", "summon refused away from the grave (far)")
	check(g.bosses.try_summon(me, "nobody") == "unknown" and g.bosses.try_summon(me, "abbess") == "far", "a boss that is not live is unknown, and another area's boss is far from here")
	check(g.bosses.try_summon(999, "gravedigger") == "dead", "an unknown summoner is refused")
	hb.teleport(near_site())
	await ticks(2)
	check(g.area_of(me) == "graves", "the hero is in the Hollow Graves")
	check(g.bosses.site_pos("gravedigger").is_equal_approx(Vector3(-14.0, 0.0, -30.5)), "the grave is the area's kings_grave interactable")
	check(g.bosses.site_near(hb.position, 4.0) == "gravedigger", "at the grave the site is the King's")
	var prog := g.my_member().prog
	var held := int(prog.local["shards"])
	var cost := int(DmContent.boss("gravedigger")["shards"])
	prog.local["shards"] = cost - 1
	check(g.bosses.try_summon(me, "gravedigger") == "shards" and g.bosses.active_boss() == null, "a summon without the King's %d soul shards is refused (shards)" % cost)
	prog.local["shards"] = held
	# key E at the grave wakes him
	var kev := InputEventKey.new()
	kev.physical_keycode = KEY_E
	kev.pressed = true
	g.bosses._unhandled_input(kev)
	boss = g.bosses.active_boss()
	check(boss != null and boss.boss_id == "gravedigger", "key E at the grave wakes the King")
	check(int(prog.local["shards"]) == held - cost, "the summon took the King's soul shards (%d -> %d)" % [held, int(prog.local["shards"])])
	check(g.bosses.try_summon(me, "gravedigger") == "busy", "a second summon while he is awake is refused (busy)")
	await dismiss()
	check(g.bosses.active_boss() == null and g.bosses.bosses.is_empty(), "a freed body leaves the host")
	clear_logs()
	var summoned: Array = []
	g.bosses.summoned.connect(func(b: String, p: int) -> void: summoned.append([b, p]))
	var spawned: Array = []
	g.bosses.boss_spawned.connect(func(b: DmBoss) -> void: spawned.append(b))
	check(wake() == "" and summoned == [["gravedigger", me]] and spawned.size() == 1, "he wakes: `summoned` and `boss_spawned` fire once")
	check(boss.is_in_group(&"dm_boss") and boss.get_parent().get_parent() == g.bosses, "the body is a DmBoss under the Bosses host")
	# the awaken numbers
	var s: Dictionary = boss.brain.state
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want_hp: float = 22000.0 * (1.0 + 0.22 * (float(s["level"]) - 1.0)) * float(diff["enemyHpMult"])
	check(near(boss.max_hp, want_hp) and boss.hp == boss.max_hp, "awaken hp = baseHp 22000 x level x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(arena()) < 0.01 and boss.phase == 1 and boss.is_hittable() and boss.is_awake(), "awake at the arena centre (-14, -22), phase 1")
	var aw := events("awaken")
	check(aw.size() == 1 and stub.calls.get("emit", 0) > 0 and "bossAwaken" in astub.sfx, "the awaken event reaches the fx and starts the boss bed (bossAwaken)")
	check(boss.view != null and boss.view.boss_id == "gravedigger" and boss.view.slug == "boss_gravedigger_king", "the current client's DmBossView with the King's model")
	# he is an external of the core
	check(boss.core_id > 0 and host.boss_for(boss.core_id) == boss, "the body registered with the core's host as an external (id %d)" % boss.core_id)
	var info: Dictionary = host.enemy_info(boss.core_id)
	check(not info.is_empty() and bool(info["boss"]) and info["def"] == "boss_gravedigger" and near(float(info["radius"]), 1.6) and near(float(info["hp"]), boss.hp) and info["area"] == "graves", "the host's record of him: boss, def, radius 1.6, health, area (%s)" % str(info.get("def")))
	check(core.enemy_info(boss.core_id).is_empty(), "the core's own table has no enemy of that id")
	await ticks(2)   # the host writes his place into the core: `step` has run with him registered
	check(host.enemy_alive(boss.core_id) and host.enemy_position(boss.core_id).distance_to(arena()) < 0.01, "he is alive for the queries, at the arena centre")
	await dismiss()
	check(host.boss_for(0) == null and host.enemy_info(1 << 29).is_empty(), "a freed body is no longer registered")


# ------------------------------------------------------------------------------------------------------------------------ the fight, by hand

func t_hand_fight() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for the fight")
	fight_spawned0 = spawned_n
	var total0 := host.enemy_total()
	# Spade Sweep: numbers and telegraph timing
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	step(2.4)
	check(events("sweep", 0.0).is_empty(), "no attack before the opening cooldown (2.5 s)")
	step(0.3)
	var sw := events("sweep", 0.0)
	check(sw.size() == 1, "Spade Sweep telegraphed at 2.5 s")
	var sweep := {}
	if sw.size() == 1:
		sweep = sw[0]
		var e: Dictionary = sweep["ev"]
		check(near(float(e["ms"]), 900.0) and near(float(e["r"]), 4.5), "the sweep telegraph is 900 ms, radius 4.5")
		check(absf(float(sweep["t"]) - 2.5) < 0.05, "the sweep fires at t=2.5 s (%.3f)" % float(sweep["t"]))
		check(absf(float(e["dir"]) - atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))) < 1e-6, "the cone is aimed at the hero")
	# a thrall in the cone: raised by the core, hurt by the King through the core (his blows on thralls)
	var th := int(core.raise_thrall({"kind": "warrior", "hp": 500.0, "maxHp": 500.0, "damage": 10.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false}, hb.core_id,
		Vector2(boss.global_position.x + 2.0, boss.global_position.z), 0.0, 8.0))
	check(th > 0 and core.thrall_info(th)["hp"] == 500.0, "a thrall stands in the cone, 2 m from the King")
	step(1.0)
	var sw_hit := impacts("sweep")
	check(sw_hit.size() == 1 and absf(float(sw_hit[0]["t"]) - float(sweep["t"]) - 0.9) < 0.03, "the blow lands 0.9 s after the telegraph")
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - 18.0 * dmg_scale()) < 1e-6 and str(hurts[0]["player"]) == str(me), "the sweep hurts the hero for 18 x level x difficulty (%.2f)" % (float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0))
	check(hero_hurt.size() == 1 and hero_hurt[0][1] is int and int(hero_hurt[0][1]) == boss.core_id and float(hero_hurt[0][0]) > 0.0, "the blow reached the hero's body with the King's core id as its source (%s)" % str(hero_hurt))
	check(sw_hit[0]["ev"]["players"].size() == 1, "the impact event lists who was hit")
	var ti: Dictionary = core.thrall_info(th)
	check(near(float(ti["hp"]), 500.0 - boss.brain._dmg(20.0)), "the thrall in the cone lost 20 x level x difficulty through core.damage on its id (%.2f of 500)" % (500.0 - float(ti["hp"])))
	await ticks(1)   # the core's event for it
	check(thrall_dmg.size() == 1 and thrall_dmg[0][0] == th and thrall_dmg[0][1] == boss.core_id and near(float(thrall_dmg[0][2]), boss.brain._dmg(20.0)), "the core reported it: the King's id as the source (%s)" % str(thrall_dmg))
	core.kill_thrall(th, "crumbled")
	# Burial
	step(1.3)
	var bu := events("bury", 0.0)
	check(bu.size() == 1 and near(float(bu[0]["ev"]["ms"]), 1400.0) and near(float(bu[0]["ev"]["r"]), 1.2), "Burial telegraph 1400 ms, grave 0.6 x 1.2 half-extent")
	check(bu.size() == 1 and absf(float(bu[0]["t"]) - 4.0) < 0.05 and bu[0]["ev"]["targets"].size() == 1, "Burial at t=4.0 s on the hero's feet")
	var n_hurt := hurts.size()
	step(1.5)
	var bi := impacts("bury")
	check(bi.size() == 1 and absf(float(bi[0]["t"]) - float(bu[0]["t"]) - 1.4) < 0.03, "the grave closes 1.4 s later")
	check(hurts.size() == n_hurt + 1 and absf(float(hurts[hurts.size() - 1]["dmg"]) - 12.0 * dmg_scale()) < 1e-6, "Burial hurts for 12 x scale")
	check(near(float(bi[0]["ev"]["root"]), 2.0) and bi[0]["ev"]["players"].size() == 1 and float(hb.p["rootedUntil"]) > hb._clock_ms, "Burial roots 2 s and the hero's body is rooted")
	# phases, adds, elite
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	check(boss.take_damage(boss.hp - boss.max_hp * 0.59, hb), "a blow of the hero's takes him to 59 %")
	step(0.1)
	check(boss.phase == 2 and phases == [2] and events("phase").size() == 1 and int(events("phase")[0]["ev"]["phase"]) == 2, "phase 2 at 60 % (event + signal)")
	check("bossPhase" in astub.sfx, "the phase sound")
	var ghouls0 := bodies("ghoul").size()
	step(4.2)
	var ghouls := bodies("ghoul")
	check(ghouls.size() - ghouls0 == 2 and host.enemy_total() == total0 + 2, "Exhumation: two Barrow Ghouls are core bodies (%d in the table)" % ghouls.size())
	var on_rim := ghouls.all(func(id: int) -> bool: return absf(Vector2(core.enemy_info(id)["pos"]).distance_to(Vector2(-14.0, -22.0)) - 8.5) < 0.01)
	check(on_rim and events("summon").size() == 1 and events("summon")[0]["ev"]["targets"].size() == 2, "dug up on the arena rim (0.85 r) with the summon telegraph event")
	var gi: Dictionary = core.enemy_info(ghouls[0])
	check(gi["area"] == "graves" and int(gi["level"]) == int(boss.brain.state["level"]) and not bool(gi["elite"]), "the adds belong to the King's area, at its level")
	# the brain's reads of the core's world (the later bosses use them): one body, all bodies, the corpses and their removal
	var wg := boss.world.enemy_get(ghouls[0])
	check(wg["id"] == ghouls[0] and wg["def"] == "ghoul" and wg["area"] == "graves" and wg["state"] == "burrow" and near(float(wg["hp"]), float(wg["max_hp"])) and boss.world.enemy_get(1 << 29).is_empty(),
		"world.enemy_get reads a body of the core (%s)" % str(wg))
	check(boss.world.enemies().size() == host.enemy_total(), "world.enemies lists the core's table (%d)" % host.enemy_total())
	var cid := host.corpses.add_corpse(arena().x + 1.0, arena().z, "normal", "robber", false, 0.0, 1.0, "graves")
	var wc: Array = boss.world.corpses()
	check(wc.size() == 1 and wc[0]["id"] == cid and wc[0]["area"] == "graves" and near(float(wc[0]["x"]), arena().x + 1.0), "world.corpses lists the core's field (%s)" % str(wc))
	boss.world.remove_corpse(cid, "devoured")
	check(boss.world.corpses().is_empty() and host.corpses.get_corpse(cid) == null, "world.remove_corpse consumes it")
	step(14.0)
	check(bodies("ghoul").size() - ghouls0 == 4, "Exhumation repeats every 14 s")
	boss.take_damage(boss.hp - boss.max_hp * 0.44, hb)
	step(0.1)
	var elites := bodies("robber").filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"]))
	check(elites.size() == 1, "an elite Grave Robber joins at 45 %")
	step(2.0)
	check(bodies("robber").filter(func(id: int) -> bool: return bool(core.enemy_info(id)["elite"])).size() == 1, "only one elite")
	# phase 3: pits, the double sweep
	hb.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	step(0.1)
	var pits := events("pits")
	check(boss.phase == 3 and pits.size() == 1 and pits[0]["ev"]["targets"].size() == 4 and near(float(pits[0]["ev"]["r"]), 1.2), "phase 3 opens four pits (r 1.2)")
	var pit: Array = pits[0]["ev"]["targets"][0]
	var nh := hurts.size()
	hb.teleport(Vector3(pit[0], 0.0, pit[1]))
	boss.world.refresh()
	step(0.1)
	var pit_hit := hurts.slice(nh)
	check(pit_hit.size() == 1 and absf(float(pit_hit[0]["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6, "walking into an open grave hurts for 0.6 x 12 x scale")
	var nh2 := hurts.size()
	step(2.5)
	check(hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6).is_empty(), "no re-bury inside the 3 s cooldown")
	step(0.7)
	check(not hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * dmg_scale()) < 1e-6).is_empty(), "re-buried after 3 s")
	hb.teleport(arena() + Vector3(4.0, 0.0, 0.0))
	boss.world.refresh()
	var n_sw := events("sweep", 0.0).size()
	step(6.0)
	var sws := events("sweep", 0.0).slice(n_sw)
	var pair := false
	for i in range(sws.size() - 1):
		if absf(float(sws[i + 1]["t"]) - float(sws[i]["t"])) < 1e-6 and absf(float(sws[i + 1]["ev"]["ms"]) - float(sws[i]["ev"]["ms"]) - 650.0) < 1e-6 and absf(float(sws[i + 1]["ev"]["dir"]) - float(sws[i]["ev"]["dir"]) - PI / 3.0) < 1e-6:
			pair = true
	check(pair, "phase 3 sweeps twice (the second cone +60 degrees, 650 ms later)")


## Everyone gone from the arena: he goes back to sleep without a reward, and what he called leaves with him: no death, no corpse, no credit.
func t_wipe() -> void:
	await ticks(1)   # the core's events of the hand-stepped fight reach the host
	var adds := bodies("ghoul") + bodies("robber")
	var total := host.enemy_total()
	var died0 := died_n
	var corpses0 := corpse_n
	var removed0 := removed_n
	check(adds.size() >= 5 and total >= adds.size(), "the King's adds are in the core before the wipe (%d)" % adds.size())
	check(spawned_n - fight_spawned0 == adds.size(), "and the core announced each one (%d spawn events)" % (spawned_n - fight_spawned0))
	hb.teleport(Vector3(0.0, 0.0, 20.0))
	boss.world.refresh()
	step(0.1)
	check(resets == ["gravedigger"] and defeated.is_empty() and not boss.is_hittable() and not boss.dead, "everyone gone -> the boss resets (no reward) and can be woken again")
	check(adds.all(func(id: int) -> bool: return host.enemy_info(id).is_empty()) and host.enemy_total() == total - adds.size(), "every add left the core at once (%d)" % adds.size())
	await ticks(3)
	check(died_n == died0 and corpse_n == corpses0 and removed_n - removed0 == adds.size(), "they left silently: %d removed events, no died, no corpse" % (removed_n - removed0))
	check(host.alive_count() == host.enemy_total(), "and none of them counts among the dying (%d alive of %d)" % [host.alive_count(), host.enemy_total()])
	check(not host.enemy_alive(boss.core_id) and not (boss.core_id in host.enemies_in_radius(arena(), 30.0)), "a boss that is not awake is nobody's target")
	await dismiss()
	hb.teleport(near_site())
	await ticks(2)
	check(wake() == "" and boss.is_hittable() and boss.hp == boss.max_hp, "and the next summon is a fresh fight")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ thralls

func t_thralls() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for the thralls")
	boss.set_physics_process(false)   # he stands where he is while the engine ticks the core and the thralls
	# the hero 8 m from his centre, a thrall 11.2 m from it: its centre is farther than the 10 m engage range, his edge is not (11.2 - 1.6 = 9.6)
	var toward := Vector3(-1.0, 0.0, 0.0)
	hb.teleport(arena() + toward * 8.0)
	boss.world.refresh()
	await ticks(2)
	var stats := {"kind": "warrior", "hp": 4000.0, "maxHp": 4000.0, "damage": 40.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false}
	var t1 := int(core.raise_thrall(stats, hb.core_id, Vector2(arena().x - 11.2, arena().z), 0.0, 8.0))
	core.set_thrall_stats(t1, {"hp": 4000.0})
	var hp0 := boss.hp
	var engaged := await until(func() -> bool: return int(core.thrall_info(t1)["target"]) == boss.core_id, 3.0)
	check(engaged, "the thrall picks the King though his centre is 11.2 m away: the boss rule counts from his edge")
	var hit := await until(func() -> bool: return thrall_hits.size() >= 3, 6.0)
	check(hit and thrall_hits.all(func(h: Array) -> bool: return h[0] == t1 and h[1] == boss.core_id and h[2] == "warrior"), "its blows come back as EV_THRALL_HIT_EXTERNAL naming the thrall, the King and its kind")
	var sum := 0.0
	for h in thrall_hits:
		sum += float(h[3])
	check(near(hp0 - boss.hp, sum) and sum > 0.0 and near(float(thrall_hits[0][3]), float(core.thrall_info(t1)["damage"])), "each one went to his brain: he lost exactly their damage (%.1f in %d blows)" % [sum, thrall_hits.size()])
	check(boss.brain.last_hit_by == str(me), "and the credit is the thrall's owner (%s)" % boss.brain.last_hit_by)
	# not a target while he cannot be hurt: the external's alive flag
	boss.bstate.state = "sunk"
	check(not boss.is_hittable(), "(a sunk body cannot be hurt)")
	await ticks(3)
	check(int(core.thrall_info(t1)["target"]) == 0 and not (boss.core_id in host.enemies_in_radius(arena(), 30.0)), "while he cannot be hurt the thrall lets go and the queries skip him")
	var n_hits := thrall_hits.size()
	await secs(1.0)
	check(thrall_hits.size() == n_hits, "no blow lands on him meanwhile")
	boss.bstate.state = "idle"
	check(await until(func() -> bool: return int(core.thrall_info(t1)["target"]) == boss.core_id, 3.0), "and picks him again when he can")
	# he hits it back: his brain runs on the engine now
	boss.set_physics_process(true)
	hb.teleport(arena() + toward * 5.0)
	boss.world.refresh()
	thrall_dmg.clear()
	var struck := await until(func() -> bool: return thrall_dmg.any(func(d: Array) -> bool: return d[0] == t1 and d[1] == boss.core_id), 10.0)
	check(struck, "his sweep reaches the thrall that stands by him: core.damage on its id with his id as the source")
	if struck:
		var d: Array = thrall_dmg.filter(func(x: Array) -> bool: return x[0] == t1 and x[1] == boss.core_id)[0]
		check(near(float(d[2]), boss.brain._dmg(20.0)), "for 20 x level x difficulty (%.2f)" % float(d[2]))
	boss.set_physics_process(false)
	core.kill_thrall(t1, "crumbled")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ rites

func t_rites() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for the rites")
	var bid := boss.core_id
	var bp := boss.global_position
	await ticks(2)
	hb.teleport(bp + Vector3(8.0, 0.0, 0.0))
	boss.world.refresh()
	var here := hb.position
	# the queries: his edge, his radius, after the enemies
	var robber := host.spawn_enemy("robber", bp + Vector3(9.0, 0.0, 5.0), 1, 1.0, 0.0, false, "graves", false)
	core.stun(robber, 3600.0)
	await ticks(2)
	check(g.enemies_in_radius(bp + Vector3(5.0, 0.0, 0.0), 3.4).has(bid) and g.enemies_in_radius(bp + Vector3(5.0, 0.0, 0.0), 3.39).has(bid) == false, "the query measures to his edge: 5 m away, radius 3.4 reaches him (5 - 1.6) and 3.39 does not")
	var ids := host.enemies_in_radius(bp + Vector3(8.0, 0.0, 0.0), 12.0)
	check(Array(ids) == [robber, bid], "he comes after the enemies though the robber is farther: %s" % str(ids))
	var foes := host.foes_in_radius(bp + Vector3(8.0, 0.0, 0.0), 12.0)
	check(foes.size() == 2 and foes[1].boss and foes[1].id == bid and near(foes[1].radius, 1.6) and not foes[0].boss and foes[1].def == "boss_gravedigger" and foes[1].alive() and foes[1].hittable(), "as DmFoe snapshots: the second is the boss, radius 1.6")
	check(near(foes[1].scale_x(), 1.0), "(the model scale of his def)")
	check(c.foe(bid) != null and c.foe(bid).boss and c.foes_in_radius(bp, 2.0).size() == 1, "the caster's foe queries know him")
	var lane := DmRiteModule.lane(c, bp.x + 8.0, bp.z + 1.5, -1.0, 0.0, 14.0, 0.6, false)
	check(lane.size() == 1 and lane[0]["e"].id == bid and near(float(lane[0]["along"]), 8.0), "a lane 1.5 m beside his centre (half width 0.6 + his radius 1.6) strikes him (along %.1f)" % (float(lane[0]["along"]) if lane.size() > 0 else -1.0))
	check(DmRiteModule.lane(c, bp.x + 8.0, bp.z + 2.3, -1.0, 0.0, 14.0, 0.6, false).is_empty(), "and one 2.3 m beside it misses (2.3 > 2.2)")
	var circle := DmRiteModule.enemies_in_circle(c, bp.x - 8.0, bp.z, 6.5)
	check(circle.size() == 1 and circle[0].id == bid, "a circle of 6.5 m centred 8 m from him reaches his edge (6.4 from his centre to it) and not the robber on the other side")
	check(DmRiteModule.enemies_in_circle(c, bp.x - 8.2, bp.z, 6.5).is_empty(), "and one 8.2 m away (6.6 to his edge) does not")
	# Bone Needle: the range counts his radius, the blow goes to his brain with the hero's credit
	c.p["resource"]["value"] = 50.0
	hb.teleport(bp + Vector3(12.0, 0.0, 0.0))
	boss.world.refresh()
	var r := cast("bone_needle", bp, bid)
	check(bool(r["ok"]), "Bone Needle at 12 m is accepted (range 11 + his radius 1.6); a robber's 0.4 would not reach (%s)" % r["reason"])
	var hp0 := boss.hp
	var nc := DmAbilities.needle_cast(sp_now(), c.p["loadout"], "", 0, 0.5)
	var hit := DmAbilities.needle_hit(nc["dmg"], 0.5)
	await secs(0.8)
	check(near(hp0 - boss.hp, float(hit["amount"])), "the needle took %.3f from him (the formula %.3f)" % [hp0 - boss.hp, float(hit["amount"])])
	var h := hits_of("bone_needle")
	check(h.size() == 1 and h[0][1] == bid and not bool(h[0][3]) and not bool(h[0][4]) and boss.brain.last_hit_by == str(me), "one hit credited to the hero on his id, not a kill; the brain's credit is the hero")
	hb.teleport(bp + Vector3(13.0, 0.0, 0.0))
	r = cast("bone_needle", bp, bid)
	check(not bool(r["ok"]) and r["reason"] == "range", "at 13 m it is refused `range` (%s)" % r["reason"])
	# Bone Fan: the cone strikes him and the robber behind
	await ticks(2)
	hb.teleport(bp + Vector3(7.0, 0.0, 0.0))
	boss.world.refresh()
	c.p["resource"]["value"] = 50.0
	hp0 = boss.hp
	var fan_dmg := DmAbilities.rite_damage(sp_now(), "bone_fan")
	r = cast("bone_fan", bp, bid)
	await secs(0.8)
	check(bool(r["ok"]) and near(hp0 - boss.hp, fan_dmg), "Bone Fan struck him for %.3f (%.3f)" % [hp0 - boss.hp, fan_dmg])
	# Rot Lance: the lane through him
	hp0 = boss.hp
	var mark := hit_log.size()
	r = cast("rot_lance", bp, bid)
	await secs(0.8)
	var lh := hits_of("rot_lance", mark)
	check(bool(r["ok"]) and lh.any(func(x: Array) -> bool: return x[1] == bid and float(x[2]) > 0.0) and boss.hp < hp0, "Rot Lance struck him (%.1f)" % (hp0 - boss.hp))
	# Marrow Spear with Legion Champion 5: the nearest enemy it struck is marked, the legion turns on it (set_thrall_target takes his id) and hits it harder
	var rally := int(core.raise_thrall({"kind": "warrior", "hp": 4000.0, "maxHp": 4000.0, "damage": 1.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false},
		hb.core_id, Vector2(hb.position.x - 1.0, hb.position.z), 0.0, 8.0))
	hb.teleport(bp + Vector3(7.0, 0.0, 0.0))
	boss.world.refresh()
	await secs(1.0)   # it rises for 0.9 s
	c.mods["spearRally"] = 0.5
	c.p["resource"]["value"] = 50.0
	hp0 = boss.hp
	r = cast("marrow_spear", bp, bid)
	await secs(0.5)
	check(bool(r["ok"]) and boss.hp < hp0 and int(core.thrall_info(rally)["target"]) == bid and near(float(core.thrall_info(rally)["mark_mult"]), 1.5),
		"Marrow Spear struck him and its rally marked him: the legion's thrall fights him with the mark's x1.5 (%s)" % str(core.thrall_info(rally)["mark_mult"]))
	c.mods.erase("spearRally")
	core.kill_thrall(rally, "crumbled")
	DmStatusSet.of(boss).clear()   # the Spear's bleed and the Lance's rot burn him meanwhile
	# the Scythe's arc: he counts with his own reach and one of the arc's hits
	await ticks(2)
	hb.teleport(bp + Vector3(3.5, 0.0, 0.0))
	boss.world.refresh()
	c.p["loadout"]["reap"] = true
	var near_robber := host.spawn_enemy("robber", hb.position + Vector3(-2.0, 0.0, 0.5), 1, 1000.0, 0.0, false, "graves", false)
	core.stun(near_robber, 3600.0)
	await ticks(2)
	hp0 = boss.hp
	var rb0 := hp_of(near_robber)
	var rc := DmAbilities.reap_cast(sp_now(), "", 0.5, 2)
	c.p["resource"]["value"] = 50.0
	r = cast("bone_needle", bp, bid)
	await ticks(3)
	check(bool(r["ok"]) and near(hp0 - boss.hp, float(rc["dmg"])) and near(rb0 - hp_of(near_robber), float(rc["dmg"])), "the Scythe's arc cut him and the robber in front of him for %.3f each (two landed)" % float(rc["dmg"]))
	c.p["loadout"]["reap"] = false
	# statuses are his own set: Withered burns him with the hero's credit; slow, root and chill show but the brain ignores them
	await ticks(2)
	hp0 = boss.hp
	var w0 := c.status_stacks(bid, &"withered")   # Rot Lance left some
	c.apply_status(bid, &"withered", 2.0, -1.0, {"dps": 30.0})
	check(c.has_status(bid, &"withered") and c.status_stacks(bid, &"withered") == w0 + 2 and DmStatusSet.of(boss).stacks(&"withered") == w0 + 2, "Withered sits in his own DmStatusSet (%d stacks)" % c.status_stacks(bid, &"withered"))
	boss.set_physics_process(true)
	await secs(1.0)
	boss.set_physics_process(false)
	check(boss.hp < hp0 - 20.0 and boss.brain.last_hit_by == str(me), "and burns him for the hero (%.1f in a second)" % (hp0 - boss.hp))
	var x0 := boss.global_position
	c.apply_status(bid, &"chill")
	c.apply_status(bid, &"root")
	check(c.has_status(bid, &"chill") and c.has_status(bid, &"root") and c.remove_status(bid, &"chill") and not c.has_status(bid, &"chill") and not c.remove_status(bid, &"chill"), "chill and root are shown and removable")
	check(boss.global_position.is_equal_approx(x0), "(he has not moved)")
	# a stun staggers him once
	c.apply_status(bid, &"stun", 1.0, 5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "a stun staggers him at most 0.5 s (%.2f)" % boss.brain.stagger_t)
	var st0: float = boss.brain.stagger_t
	boss.stun(5.0)
	check(near(boss.brain.stagger_t, st0), "and has a cooldown (no stun-lock)")
	core.damage(robber, 1.0e9, 0)
	core.damage(near_robber, 1.0e9, 0)
	DmStatusSet.of(boss).clear()
	# Colossus Mantle's reflect turns a share of a blow back at its source: the hero is hurt with the King's core id as the source, and the reflect finds him by it
	c.mods["wardReflect"] = 0.5
	hp0 = boss.hp
	(DmRiteRegistry.module("black_litany") as DmRiteModule).call(&"hurt_legend", c, 400.0, 0.5, bid, 0.0)
	var back := DmLegend.ward_reflect_damage(400.0, 0.5, 0.5)
	check(back >= 1.0 and near(hp0 - boss.hp, back), "Colossus Mantle's reflect hit him for %.2f (the formula %.2f)" % [hp0 - boss.hp, back])
	c.mods.erase("wardReflect")
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ defeat

func t_defeat() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for the defeat")
	var bid := boss.core_id
	var old := boss
	hb.teleport(arena() + Vector3(8.0, 0.0, 0.0))
	boss.world.refresh()
	boss.set_physics_process(true)
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	var got := await until(func() -> bool: return bodies("ghoul").size() >= 2, 8.0)
	check(got, "the engine-driven brain calls his ghouls into the core (%d)" % bodies("ghoul").size())
	var adds := bodies("ghoul")
	var total := host.enemy_total()
	var died0 := died_n
	var corpses0 := corpse_n
	var removed0 := removed_n
	boss.set_physics_process(false)
	var died_signal: Array = []
	boss.died.connect(func(b: DmBoss) -> void: died_signal.append(b))
	var fx_defeat0 := astub.sfx.count("bossDefeat")
	# the lethal blow comes from a rite: the reply says killed at once
	c.p["resource"]["value"] = 50.0
	boss.take_damage(boss.hp - 1.0, hb)
	hb.teleport(boss.global_position + Vector3(6.0, 0.0, 0.0))
	boss.world.refresh()
	var rr: Dictionary = host.damage(bid, 5.0, hb.core_id)
	check(bool(rr["killed"]) and float(rr["dealt"]) == 5.0, "a rite's blow on him answers {dealt, killed} at once: the kill is known inside the call")
	check(boss.hp == 0.0 and boss.dead and not boss.is_hittable() and died_signal == [boss], "he is down: no health, `died` fired once, no longer hittable")
	check(defeated == [["gravedigger", me]], "the host's `defeated` names the killer: the hero")
	var df := events("defeated")
	check(df.size() == 1 and str(df[0]["ev"]["killer"]) == str(me), "the brain's defeated event names the killer's peer")
	check(astub.sfx.count("bossDefeat") - fx_defeat0 == 1, "the defeat sound")
	check(not host.enemy_alive(bid) and not (bid in host.enemies_in_radius(boss.global_position, 30.0)) and not host.damage(bid, 1.0, hb.core_id)["killed"] and float(host.damage(bid, 1.0, hb.core_id)["dealt"]) == 0.0, "a fallen King is nobody's target and takes no more blows")
	check(adds.all(func(id: int) -> bool: return host.enemy_info(id).is_empty()) and host.enemy_total() == total - adds.size(), "his ghouls left the core with him (%d)" % adds.size())
	await ticks(3)
	check(died_n == died0 and corpse_n == corpses0 and removed_n - removed0 == adds.size() and host.alive_count() == host.enemy_total(), "silently: no death, no corpse, no credit, nobody counted among the dying")
	await ticks(2)
	check(not host.enemy_alive(bid) and old.dead, "(the body lingers 8 s and is not a target)")
	# woken again while the old body lingers
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "" and boss != old and boss.core_id != bid and boss.is_hittable() and boss.hp == boss.max_hp, "he can be woken again: a fresh body, a new id in the core (%d -> %d)" % [bid, boss.core_id])
	await ticks(2)
	check(host.enemy_alive(boss.core_id) and not host.enemy_alive(bid), "only the new one is a target")
	old.queue_free()
	await dismiss()


# ------------------------------------------------------------------------------------------------------------------------ the real clock

func t_real_clock() -> void:
	hb.teleport(near_site())
	await ticks(2)
	clear_logs()
	check(wake() == "", "woken for a fight on the real clock")
	var bid := boss.core_id
	boss.set_physics_process(true)   # the engine ticks his brain; the host ticks the core and dispatches its events
	hb.teleport(arena() + Vector3(4.0, 0.0, 0.0))
	boss.world.refresh()
	var spawned0 := spawned_n
	# the thrall that stands by him, a rite now and then
	var t1 := int(core.raise_thrall({"kind": "warrior", "hp": 4000.0, "maxHp": 4000.0, "damage": 40.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false}, hb.core_id,
		Vector2(arena().x + 3.0, arena().z), 0.0, 8.0))
	var swept := await until(func() -> bool: return events("sweep", 0.0).size() >= 3, 14.0)
	check(swept, "the brain on the engine's ticks telegraphs sweeps (%d)" % events("sweep", 0.0).size())
	var bury := events("bury", 0.0).size() >= 1
	check(bury or await until(func() -> bool: return events("bury", 0.0).size() >= 1, 6.0), "and Burial")
	check(hero_hurt.size() >= 1 and hero_hurt.all(func(x: Array) -> bool: return x[1] is int and int(x[1]) == bid), "the hero was hurt by the King's blows, each with his core id as the source (%d)" % hero_hurt.size())
	check(thrall_hits.size() >= 1 and boss.hp < boss.max_hp, "the thrall hit him through the core meanwhile (%d blows)" % thrall_hits.size())
	check(boss.view != null and boss.view.is_shown(), "his view is up (drawn from the brain's state)")
	# a seeded, headless cost for the INFO line: the brain's tick
	var t0 := Time.get_ticks_usec()
	var n := 200
	for i in n:
		boss.world.refresh()
		boss.brain.update(0.0)
	print("INFO the brain's refresh + update costs %.1f us a tick (headless, %d ticks)" % [float(Time.get_ticks_usec() - t0) / n, n])
	core.kill_thrall(t1, "crumbled")
	check(spawned_n == spawned0, "(phase 1 called nothing)")


# ------------------------------------------------------------------------------------------------------------------------ the co-op seam

## A puppet body takes the host body's snapshot (the co-op step replicates the King beside the core): pose, health, phase, state and the live telegraphs round-trip.
func t_net_state() -> void:
	var st: Dictionary = boss.get_net_state()
	var pup := DmBoss.new()
	pup.visual = false
	pup.boss_id = "gravedigger"
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
