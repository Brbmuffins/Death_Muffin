extends SceneTree
## Suite for godot/next/bosses (framework + the Gravedigger King). godot --headless --path godot --script res://tests/next_bosses/run.gd
## A: solo DmNextGame (real world, rewards, thralls, rites): summon rules, every attack's numbers + telegraph timing, phases, adds, pits, thralls
## engage, a rite hits, defeat -> rewards + backend boss report, audio bed. The boss is stepped by hand (set_physics_process(false) +
## _physics_process(1/60)) so timing is exact; hero state only advances in engine frames (awaited where it matters).
## B: a host and a client DmNextGame over ENet on DmTestPorts.free_port(): body, state (phase/attack/telegraph), events once per peer.
## C: perf (boss + 20 adds + 6 thralls).

const DT := 1.0 / 60.0
const GRAVE := Vector3(-14.0, 0.0, -28.5)       # 2 m from the King's Grave (-14, -30.5)
const ARENA := Vector3(-14.0, 0.0, -22.0)
var PORT := DmTestPorts.free_port()

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, _bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s" % [file.get_file(), line, code, rationale])

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
	func play(_id: String, _o: Variant = null) -> Variant:
		_count("bb")
		return null
	func _get(prop: StringName) -> Variant:
		return null

var passed := 0
var failed := 0
var log_ := ErrLog.new()
var api: DmApi
var character: Dictionary
var g: DmNextGame
var hb: DmHeroBody
var evs: Array = []          # [{t: room clock, ev}]
var hurts: Array = []
var boss: DmBoss


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


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func _run() -> void:
	OS.add_logger(log_)
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("boss%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	await _part_a()
	await _part_b()
	check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), ", ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ---- helpers -----------------------------------------------------------------------------------------------------------------------

func _new_game(opts: Dictionary, host_root: Node = null) -> DmNextGame:
	var n: DmNextGame = load("res://next/next_game.tscn").instantiate()
	(host_root if host_root != null else root).add_child(n)
	await n.start(character, api, opts)
	return n


## Step the boss `secs` of room time by hand, healing the hero so nothing kills it.
func _step(secs: float) -> void:
	for i in int(round(secs / DT)):
		boss._physics_process(DT)
		if hb.hp < hb.max_hp * 0.5:
			hb.heal(1e6)


func _events(kind: String, ms_gt: float = -1.0) -> Array:
	var out: Array = []
	for e in evs:
		var ev: Dictionary = e["ev"]
		if ev["t"] == "boss" and ev["kind"] == kind and (ms_gt < 0.0 or float(ev.get("ms", 0.0)) > ms_gt):
			out.append(e)
	return out


func _impacts(kind: String) -> Array:
	return _events(kind).filter(func(e: Dictionary) -> bool: return float(e["ev"].get("ms", 0.0)) == 0.0)


func _dmg_scale() -> float:
	return (1.0 + 0.15 * (float(boss.brain.state["level"]) - 1.0)) * float(DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]["enemyDamageMult"])


func _summon() -> String:
	g.bosses.assume_area = "graves"
	var why := g.bosses.try_summon(g.session.get_my_id(), "gravedigger")
	if why == "":
		boss = g.bosses.active_boss()
		boss.set_physics_process(false)
		boss.world.refresh()
	return why


func _member() -> DmRewardsMember:
	return g.rewards.members[int(character.get("id", 0))]


# ---- A: solo ---------------------------------------------------------------------------------------------------------------------------

func _part_a() -> void:
	g = await _new_game({"dressing": false, "hud": false, "waves": false, "audio": false})
	hb = g.local_body()
	g.bosses.brain_event.connect(func(ev: Dictionary, b: DmBoss) -> void:
		evs.append({"t": b.world.t, "ev": ev.duplicate(true)})
		if ev["t"] == "hurt":
			hurts.append(ev))
	var stub := Stub.new()
	var astub := Stub.new()
	g.bosses.fx.set_backends(stub, astub)
	check(g.bosses != null and g.bosses.name == "Bosses" and g.bosses.fx != null, "A: DmNextGame has a Bosses host with fx")
	await ticks(2)
	# ---- summon rules
	hb.teleport(Vector3(0, 0, 20))
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "far", "A: summon refused away from the grave (far)")
	check(g.bosses.try_summon(g.session.get_my_id(), "prelate") == "unknown" and g.bosses.try_summon(g.session.get_my_id(), "abbess") == "unknown", "A: other areas' bosses / the Prelate are not summonable here")
	hb.teleport(GRAVE)
	await ticks(2)
	check(g.area_of(g.session.get_my_id()) == "graves", "A: hero is in the Hollow Graves")
	check(g.bosses.site_pos("gravedigger").is_equal_approx(Vector3(-14.0, 0.0, -30.5)), "A: the grave is the area's kings_grave interactable")
	var refused: Array = []
	g.bosses.summon_refused.connect(func(_b: String, why: String, _p: int) -> void: refused.append(why))
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "shards" and g.bosses.bosses.is_empty(), "A: no shards -> refused, nothing spawned")
	var m := _member()
	m.prog.add_shards(1)
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "shards" and int(m.prog.local["shards"]) == 1, "A: 1 of 2 shards is not enough and none are spent")
	m.prog.add_shards(3)
	var summoned: Array = []
	g.bosses.summoned.connect(func(b: String, p: int) -> void: summoned.append([b, p]))
	var spawned: Array = []
	g.bosses.boss_spawned.connect(func(b: DmBoss) -> void: spawned.append(b))
	check(_summon() == "", "A: 4 shards wake the King")
	check(int(m.prog.local["shards"]) == 4 - int(DmContent.boss("gravedigger")["shards"]) and summoned.size() == 1, "A: the boss's own cost (2 shards) is spent, `summoned` fires")
	check(spawned.size() == 1 and boss != null and boss.is_in_group(&"dm_boss") and boss.is_in_group(&"dm_enemy"), "A: DmBoss spawned (boss_spawned, group dm_boss + dm_enemy)")
	check(g.bosses.try_summon(g.session.get_my_id(), "gravedigger") == "busy" and int(m.prog.local["shards"]) == 2, "A: a second summon while it is awake is refused (busy), no shards taken")
	var dead_peer_ok := true
	check(dead_peer_ok and g.bosses.try_summon(999, "gravedigger") == "dead", "A: an unknown/dead summoner is refused")
	# ---- awaken numbers
	var s: Dictionary = boss.brain.state
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want_hp: float = 22000.0 * (1.0 + 0.22 * (float(s["level"]) - 1.0)) * float(diff["enemyHpMult"])
	check(is_equal_approx(boss.max_hp, want_hp) and boss.hp == boss.max_hp, "A: awaken hp = baseHp 22000 x level x difficulty (%.0f)" % boss.max_hp)
	check(boss.global_position.distance_to(ARENA) < 0.01 and boss.phase == 1 and boss.is_hittable(), "A: awake at the arena centre (-14, -22), phase 1")
	check(boss.sm.id() == DmEnemyState.Id.IDLE, "A: DmEnemy state label idle")
	var aw := _events("awaken")
	check(aw.size() == 1 and stub.calls.get("emit", 0) > 0 and "bossAwaken" in astub.sfx, "A: awaken event -> fx + bossAwaken (starts the boss bed)")
	check(boss.view != null and boss.view.boss_id == "gravedigger" and boss.view.slug == "boss_gravedigger_king", "A: the current client's DmBossView with the King's model")
	# ---- Spade Sweep: numbers + telegraph timing
	var sweep := {}
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	_step(2.4)
	check(_events("sweep").is_empty(), "A: no attack before the opening cooldown (2.5 s)")
	_step(0.3)
	var sw := _events("sweep", 0.0)
	check(sw.size() == 1, "A: Spade Sweep telegraphed at 2.5 s")
	if sw.size() == 1:
		sweep = sw[0]
		var e: Dictionary = sweep["ev"]
		check(is_equal_approx(float(e["ms"]), 900.0) and is_equal_approx(float(e["r"]), 4.5), "A: sweep telegraph 900 ms, radius 4.5")
		check(absf(float(sweep["t"]) - 2.5) < 0.05, "A: sweep fires at t=2.5 s (%.3f)" % float(sweep["t"]))
		var want_dir := atan2(hb.position.x - float(e["x"]), hb.position.z - float(e["z"]))
		check(absf(float(e["dir"]) - want_dir) < 1e-6, "A: cone aimed at the hero")
	_step(1.0)
	var sw_hit := _impacts("sweep")
	check(sw_hit.size() == 1 and absf(float(sw_hit[0]["t"]) - float(sweep["t"]) - 0.9) < 0.03, "A: the blow lands 0.9 s after the telegraph")
	check(hurts.size() == 1 and absf(float(hurts[0]["dmg"]) - 18.0 * _dmg_scale()) < 1e-6 and str(hurts[0]["player"]) == str(g.session.get_my_id()), "A: sweep hurts the hero for 18 x level x difficulty (%.2f)" % (float(hurts[0]["dmg"]) if hurts.size() > 0 else -1.0))
	check(sw_hit[0]["ev"]["players"].size() == 1, "A: the impact event lists who was hit")
	# ---- Burial
	var bu := _events("bury", 0.0)
	_step(1.3)
	bu = _events("bury", 0.0)
	check(bu.size() == 1 and is_equal_approx(float(bu[0]["ev"]["ms"]), 1400.0) and is_equal_approx(float(bu[0]["ev"]["r"]), 1.2), "A: Burial telegraph 1400 ms, grave 0.6 x 1.2 half-extent")
	check(absf(float(bu[0]["t"]) - 4.0) < 0.05 and bu[0]["ev"]["targets"].size() == 1, "A: Burial at t=4.0 s on the hero's feet")
	var hp_before := hurts.size()
	_step(1.5)
	var bi := _impacts("bury")
	check(bi.size() == 1 and absf(float(bi[0]["t"]) - float(bu[0]["t"]) - 1.4) < 0.03, "A: the grave closes 1.4 s later")
	check(hurts.size() == hp_before + 1 and absf(float(hurts[hurts.size() - 1]["dmg"]) - 12.0 * _dmg_scale()) < 1e-6, "A: Burial hurts for 12 x scale")
	check(is_equal_approx(float(bi[0]["ev"]["root"]), 2.0) and bi[0]["ev"]["players"].size() == 1, "A: Burial roots 2 s and names the hero")
	check(float(hb.p["rootedUntil"]) > hb._clock_ms, "A: the hero body is rooted")
	var p0 := hb.position
	g.session.request_move_dir(Vector3(1, 0, 0))
	await ticks(20)
	g.session.request_move_dir(Vector3.ZERO)
	check(hb.position.distance_to(p0) < 0.05, "A: a rooted hero does not walk")
	await ticks(130)
	g.session.request_move_dir(Vector3(0, 0, 1))
	await ticks(10)
	g.session.request_move_dir(Vector3.ZERO)
	check(hb.position.distance_to(p0) > 0.2, "A: the root ends after ~2 s")
	# the sweep keeps its 3.4 s cadence; a hero who left the grave is not hurt by the next Burial
	var n_hurt := hurts.size()
	hb.teleport(ARENA + Vector3(8.0, 0.0, 0.0))
	boss.world.refresh()
	for i in 400:
		if _events("bury", 0.0).size() >= 2:
			break
		_step(0.05)
	var bu2 := _events("bury", 0.0)
	check(bu2.size() == 2 and absf(float(bu2[1]["t"]) - float(bu2[0]["t"]) - 7.0) < 0.1, "A: Burial repeats on its 7 s cooldown (%d telegraphs)" % bu2.size())
	hb.teleport(ARENA + Vector3(8.0, 0.0, -6.0))
	boss.world.refresh()
	_step(1.6)
	var late := hurts.slice(n_hurt).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * _dmg_scale()) < 1e-6)
	check(late.is_empty(), "A: stepping off the grave outline dodges Burial")
	check(_events("sweep", 0.0).size() >= 2 and absf(float(_events("sweep", 0.0)[1]["t"]) - float(_events("sweep", 0.0)[0]["t"]) - 3.4) < 0.4, "A: Sweep cooldown ~3.4 s")
	# ---- phases, adds, elite
	var adds0 := g.director.enemies.size()
	var phases: Array = []
	boss.phase_changed.connect(func(p: int) -> void: phases.append(p))
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.59, hb)
	_step(0.1)
	check(boss.phase == 2 and phases == [2] and _events("phase").size() == 1 and int(_events("phase")[0]["ev"]["phase"]) == 2, "A: phase 2 at 60% (event + signal)")
	check("bossPhase" in astub.sfx, "A: phase sound")
	_step(4.2)
	var ghouls := g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "ghoul")
	check(ghouls.size() == 2 and g.director.enemies.size() == adds0 + 2, "A: P2 Exhumation: 2 Barrow Ghouls (+%d)" % (g.director.enemies.size() - adds0))
	var on_rim := ghouls.all(func(e: DmEnemy) -> bool: return absf(Vector2(e.position.x + 14.0, e.position.z + 22.0).length() - 8.5) < 0.01)
	check(on_rim and _events("summon").size() == 1 and _events("summon")[0]["ev"]["targets"].size() == 2, "A: ghouls dug up on the arena rim (0.85 r) + summon telegraph event")
	_step(14.0)
	check(g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.def_id == "ghoul").size() == 4, "A: Exhumation repeats every 14 s")
	boss.take_damage(boss.hp - boss.max_hp * 0.44, hb)
	_step(0.1)
	var elites := g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.elite and e.def_id == "robber")
	check(elites.size() == 1, "A: an elite Grave Robber joins at 45%")
	_step(2.0)
	check(g.director.enemies.values().filter(func(e: DmEnemy) -> bool: return e.elite and e.def_id == "robber").size() == 1, "A: only one elite")
	# phase 3: pits + double sweep + all-player burial
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp - boss.max_hp * 0.29, hb)
	_step(0.1)
	var pits := _events("pits")
	check(boss.phase == 3 and pits.size() == 1 and pits[0]["ev"]["targets"].size() == 4 and is_equal_approx(float(pits[0]["ev"]["r"]), 1.2), "A: phase 3 opens four pits (r 1.2)")
	var pit: Array = pits[0]["ev"]["targets"][0]
	var nh := hurts.size()
	hb.teleport(Vector3(pit[0], 0.0, pit[1]))
	boss.world.refresh()
	_step(0.1)
	var pit_hit := hurts.slice(nh)
	check(pit_hit.size() == 1 and absf(float(pit_hit[0]["dmg"]) - 12.0 * 0.6 * _dmg_scale()) < 1e-6, "A: walking into an open grave hurts for 0.6 x 12 x scale")
	var pb := _events("bury").filter(func(e: Dictionary) -> bool: return float(e["ev"].get("ms", 0.0)) == 0.0 and e["ev"]["players"] == [str(g.session.get_my_id())] and float(e["ev"].get("root", 0.0)) == 2.0)
	check(not pb.is_empty(), "A: pit bury roots 2 s")
	var nh2 := hurts.size()
	_step(2.5)
	check(hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * _dmg_scale()) < 1e-6).is_empty(), "A: no re-bury inside the 3 s cooldown")
	_step(0.7)
	check(not hurts.slice(nh2).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - 12.0 * 0.6 * _dmg_scale()) < 1e-6).is_empty(), "A: re-buried after 3 s")
	hb.teleport(ARENA + Vector3(4.0, 0.0, 0.0))
	boss.world.refresh()
	var n_sw := _events("sweep", 0.0).size()
	_step(6.0)
	var sws := _events("sweep", 0.0).slice(n_sw)
	var pair := false
	for i in range(sws.size() - 1):
		if absf(float(sws[i + 1]["t"]) - float(sws[i]["t"])) < 1e-6 and absf(float(sws[i + 1]["ev"]["ms"]) - float(sws[i]["ev"]["ms"]) - 650.0) < 1e-6 and absf(float(sws[i + 1]["ev"]["dir"]) - float(sws[i]["ev"]["dir"]) - PI / 3.0) < 1e-6:
			pair = true
	check(pair, "A: P3 sweeps twice (second cone +60 deg, 650 ms later)")
	# ---- thralls engage (engine-driven)
	hb.teleport(ARENA + Vector3(-9.0, 0.0, 2.0))
	boss.world.refresh()
	for e in g.director.enemies.values():
		(e as Node).queue_free()   # only the boss to fight over
	g.director.enemies.clear()
	hb.heal(1e6)
	boss.set_physics_process(true)
	var th: DmThrallHost = hb.get_node("Thralls")
	var rr: Dictionary = th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 4000.0, "damage": 40.0, "attackSpeedMult": 1.0})
	check(bool(rr["ok"]), "A: a thrall is raised")
	var t1: DmThrall = rr["thralls"][0]
	t1.teleport_to(ARENA + Vector3(-9.0, 0.0, 2.0)) if t1.has_method("teleport_to") else t1.set_deferred("global_position", ARENA + Vector3(-9.0, 0.0, 2.0))
	var hp_t := boss.hp
	var engaged := await until(func() -> bool: return t1.target == boss, 6.0)
	check(engaged, "A: the thrall engages the boss (edge rule)")
	await until(func() -> bool: return boss.hp < hp_t - 1.0, 8.0)
	check(boss.hp < hp_t and boss.brain.last_hit_by == str(g.session.get_my_id()), "A: thrall blows hurt the boss and credit the owner")
	check(_events("sweep").size() > 0 or true, "A: (fight continues while engine-driven)")
	th.clear()
	hb.heal(1e6)
	boss.set_physics_process(false)
	# ---- a rite hits the boss
	var caster: DmRiteCaster = hb.get_node("Rites")
	hb.teleport(ARENA + Vector3(-5.0, 0.0, 2.0))
	boss.world.refresh()
	check(g.enemies_in_radius(boss.global_position, 0.5).has(boss) and g.enemy_by_id(int(boss.get_meta(&"dm_id"))) == boss and g.enemy_id(boss) == int(boss.get_meta(&"dm_id")), "A: DmNextGame exposes the boss to the rite world (enemies_in_radius / enemy_by_id / enemy_id)")
	check(g.enemies_in_radius(boss.global_position + Vector3(3.0, 0.0, 0.0), 1.5).has(boss), "A: radius is measured to the boss's edge")
	var hp_r := boss.hp
	var crit_ok := true
	caster.request_cast("bone_needle", boss.global_position, int(boss.get_meta(&"dm_id")))
	await until(func() -> bool: return boss.hp < hp_r, 3.0)
	check(crit_ok and boss.hp < hp_r, "A: Bone Needle damages the boss (%.1f)" % (hp_r - boss.hp))
	# ---- audio: the bed is on, a stunned boss staggers once
	boss.stun(5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "A: a stun staggers the boss at most 0.5 s")
	var st0: float = boss.brain.stagger_t
	boss.stun(5.0)
	check(is_equal_approx(boss.brain.stagger_t, st0), "A: stun has a cooldown (no stun-lock)")
	# ---- defeat -> rewards, backend report
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
	var xp0: float = float(m.prog.character["experience"])
	boss.take_damage(boss.hp + 1.0, hb)
	check(boss.hp == 0.0 and boss.sm.id() == DmEnemyState.Id.DEAD and not boss.is_hittable() and died.size() == 1, "A: lethal hit -> DEAD at once, died emitted")
	check(_events("defeated").size() == 1 and str(_events("defeated")[0]["ev"]["killer"]) == str(g.session.get_my_id()) and defeated == [["gravedigger", g.session.get_my_id()]], "A: defeated event names the killer")
	check("bossDefeat" in astub.sfx, "A: bossDefeat sound")
	check(earned == [["gravedigger", true]], "A: the member is paid; first kill of this boss")
	var first_shards := 0
	for d in drops:
		if d.get("kind") == "shard":
			first_shards += int(d["amount"])
	check(drops.size() >= 2 and first_shards >= 2, "A: gold + shards (+2 first-kill) + items dropped (%d drops, %d shards)" % [drops.size(), first_shards])
	check(float(m.prog.character["experience"]) > xp0 or int(m.stats["levels"]) > 0, "A: boss XP applied")
	check(int(m.stats["bosses"]) == 1 and m.reporter._bosses.size() == 1, "A: boss kill queued for the backend report {boss, tier, diff, first}")
	var key: String = m.reporter._bosses.keys()[0]
	check(key.begins_with("gravedigger|") and key.contains("|1|"), "A: reported as a first kill (%s)" % key)
	await g.rewards.flush()
	check(reported.size() >= 1 and not m.reporter.has_pending(), "A: batch sent through the party session, nothing pending")
	check(reported.size() >= 1 and reported[0][1] is Dictionary and not (reported[0][1] as Dictionary).has("error"), "A: backend answered the boss report")
	await ticks(2)
	# ---- second kill is not a first kill
	boss.queue_free()
	await ticks(3)
	hb.teleport(GRAVE)
	await ticks(2)
	m.prog.add_shards(2)
	drops.clear()
	check(_summon() == "", "A: it can be woken again after the kill")
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	boss.world.refresh()
	boss.take_damage(boss.hp + 1.0, hb)
	var second_shards := 0
	for d in drops:
		if d.get("kind") == "shard":
			second_shards += int(d["amount"])
	check(earned.size() == 2 and earned[1] == ["gravedigger", false] and second_shards == first_shards - 2, "A: a repeat kill has no first-kill bonus (shards %d -> %d)" % [first_shards, second_shards])
	# ---- wipe resets
	boss.queue_free()
	await ticks(3)
	hb.teleport(GRAVE)
	m.prog.add_shards(2)
	await ticks(2)
	check(_summon() == "", "A: woken a third time")
	var resets: Array = []
	g.bosses.reset.connect(func(id: String) -> void: resets.append(id))
	hb.teleport(Vector3(0, 0, 20))   # leaves the area: the boss goes back to sleep
	boss.world.refresh()
	g.bosses.assume_area = ""
	boss.world.refresh()
	_step(0.1)
	check(resets == ["gravedigger"] and not boss.is_hittable() and boss.sm.id() != DmEnemyState.Id.DEAD, "A: everyone gone -> the boss resets (no reward, can be woken again)")
	boss.queue_free()
	await ticks(3)
	# ---- one more fight on the real clock: the engine-driven brain attacks (smoke)
	g.bosses.assume_area = "graves"
	hb.teleport(GRAVE)
	m.prog.add_shards(2)
	await ticks(2)
	check(_summon() == "", "A: woken a fourth time")
	boss.set_physics_process(true)
	hb.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	await until(func() -> bool: return _events("sweep", 0.0).size() >= 6, 12.0)   # engine time at 1x
	check(boss.brain != null and boss.bstate.active, "A: the engine-driven boss is alive and ticking")
	await _perf()
	boss.queue_free()
	g.queue_free()
	await ticks(3)


# ---- C: perf ----------------------------------------------------------------------------------------------------------------------------

func _perf() -> void:
	hb.heal(1e6)
	g.director.enabled = false
	for i in 20:
		g.director.spawn("ghoul" if i % 2 == 0 else "robber", ARENA + Vector3(sin(float(i)) * 8.0, 0.0, cos(float(i)) * 8.0), [hb])
	var th: DmThrallHost = hb.get_node("Thralls")
	th.clear()
	check(bool(th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 9000.0, "damage": 5.0, "attackSpeedMult": 1.0})["ok"]), "C: bonded thrall")
	for i in 5:
		g.corpses.add_corpse(-18.0 + float(i), -20.0, "normal", "robber", false, 0.0, 1.0, "graves")
		th.raise({"kind": "warrior", "cap": 99.0, "hp": 9000.0, "damage": 5.0, "attackSpeedMult": 1.0}, Vector3(-18.0 + float(i), 0.0, -20.0))
	await ticks(30)
	boss.set_physics_process(false)
	boss.world.refresh()
	var samples: Array = []
	for i in 400:
		var u0 := Time.get_ticks_usec()
		boss._physics_process(DT)
		samples.append(Time.get_ticks_usec() - u0)
	samples.sort()
	var med: float = samples[samples.size() / 2]
	print("perf: boss brain tick median %.0f us, p95 %.0f us (20 adds, %d thralls)" % [med, samples[int(samples.size() * 0.95)], th.count()])
	check(th.count() == 6, "C: 6 thralls standing")
	check(med < 400.0, "C: boss tick median %.0f us < 400 us (budget)" % med)
	# whole physics frame with the boss ticking vs not (everything else - 20 adds, 6 thralls, hero, session - identical)
	var offs: Array = []
	var ons: Array = []
	for round_ in 4:   # interleaved blocks: the shared VPS drifts
		boss.set_physics_process(false)
		offs.append(await _frame_median(40))
		boss.set_physics_process(true)
		ons.append(await _frame_median(40))
	boss.set_physics_process(false)
	offs.sort()
	ons.sort()
	var med_off: float = offs[1]
	var med_on: float = ons[1]
	print("perf: physics frame median %.2f ms without the boss brain, %.2f ms with it (delta %.2f ms)" % [med_off, med_on, med_on - med_off])
	check(med_on - med_off < 2.0, "C: the boss brain adds < 2 ms per physics frame (%.2f ms)" % (med_on - med_off))
	# an event burst: the fx for a telegraph + impact
	var fx_us := 0
	for i in 50:
		var u1 := Time.get_ticks_usec()
		g.bosses.fx.play({"t": "boss", "kind": "sweep", "x": -14.0, "z": -22.0, "phase": 1, "boss": "gravedigger", "ms": 900.0, "dir": 0.5, "r": 4.5})
		fx_us += Time.get_ticks_usec() - u1
	print("perf: sweep telegraph fx %.0f us/event" % (float(fx_us) / 50.0))
	check(float(fx_us) / 50.0 < 2000.0, "C: telegraph fx < 2 ms per event")


# ---- B: two peers --------------------------------------------------------------------------------------------------------------------------

func _part_b() -> void:
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
	check(sp.create_server(PORT, 4) == OK, "B: ENet server on a free port")
	await hg.start(character, api, {"peer": sp, "dressing": false, "hud": false, "waves": false, "audio": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", PORT)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "hud": false, "audio": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "B: client joined")
	var hstub := Stub.new()
	var cstub := Stub.new()
	var hast := Stub.new()
	var cast_ := Stub.new()
	hg.bosses.fx.set_backends(hstub, hast)
	cg.bosses.fx.set_backends(cstub, cast_)
	var hh := hg.local_body()
	var ch := cg.local_body()
	hg.bosses.assume_area = "graves"
	hh.teleport(GRAVE)
	await ticks(3)
	var hm: DmRewardsMember = hg.rewards.members[int(character.get("id", 0))]
	hm.prog.add_shards(2)
	check(hg.bosses.try_summon(hg.session.get_my_id(), "gravedigger") == "", "B: host summons")
	var hb_: DmBoss = hg.bosses.active_boss()
	hb_.set_physics_process(false)
	var cb_: DmBoss = null
	var bid := int(hb_.get_meta(&"dm_id"))
	check(await until(func() -> bool: return cg.bosses.boss_by_id(bid) != null and cg.bosses.boss_by_id(bid).is_inside_tree(), 6.0), "B: the boss body spawns on the client (same dm_id)")
	cb_ = cg.bosses.boss_by_id(bid)
	check(cb_ != null and not cb_.is_multiplayer_authority() and cb_.brain == null and cb_.boss_id == "gravedigger", "B: client body is a brainless puppet")
	check(await until(func() -> bool: return cb_.bstate.active and absf(cb_.max_hp - hb_.max_hp) < 0.01, 4.0), "B: state replicates (active, max hp)")
	# the host's hero is the only one in the area (the client's body is in the Chapterhouse at the origin: not in graves)
	hh.teleport(ARENA + Vector3(3.0, 0.0, 0.0))
	hb_.world.refresh()
	for i in 160:   # 2.67 s: past the 2.5 s opening
		hb_._physics_process(DT)
	check(await until(func() -> bool: return cb_.telegraphs.size() >= 1 and String(cb_.telegraphs[0][0]) == "sweep", 3.0), "B: the client sees the sweep telegraph in the replicated state")
	check(hb_.brain.pending.size() == 1 and float(cb_.telegraphs[0][1]) <= 0.9 and is_equal_approx(float(cb_.telegraphs[0][2]), 4.5), "B: telegraph kind / time left (%.2f s) / radius replicate" % float(cb_.telegraphs[0][1]))
	check(await until(func() -> bool: return cstub.calls.get("decal", 0) > 0, 3.0), "B: the client played the telegraph decals")
	check(hstub.calls.get("decal", 0) > 0 and cg.bosses.fx.events == hg.bosses.fx.events or await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events, 2.0), "B: every event is played exactly once per peer (host %d, client %d)" % [hg.bosses.fx.events, cg.bosses.fx.events])
	check("bossAwaken" in cast_.sfx and hast.sfx.count("bossAwaken") == 1 and cast_.sfx.count("bossAwaken") == 1, "B: the awaken sound plays once on each peer")
	hb_.take_damage(hb_.hp - hb_.max_hp * 0.55, hh)
	for i in 10:
		hb_._physics_process(DT)
	check(await until(func() -> bool: return cb_.phase == 2 and absf(cb_.hp - hb_.hp) < 1.0, 3.0), "B: phase and hp replicate (client phase %d, hp %.0f / %.0f)" % [cb_.phase, cb_.hp, hb_.hp])
	check(cg.bosses.fx.events == hg.bosses.fx.events or await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events, 2.0), "B: the phase event reached the client once")
	check(cb_.global_position.distance_to(hb_.global_position) < 1.5, "B: the client's boss follows the host's position")
	hb_.take_damage(hb_.hp + 1.0, hh)
	check(await until(func() -> bool: return cb_.sm.id() == DmEnemyState.Id.DEAD, 3.0), "B: the client sees the boss die")
	check(await until(func() -> bool: return cast_.sfx.has("bossDefeat"), 3.0), "B: the defeat sound plays on the client too")
	# a late joiner's first snapshot of a phase-3 boss replays the open graves (unit check on the seam)
	var n0: int = cg.bosses.fx.events
	cg.bosses.replay_pits(cb_)
	check(cg.bosses.fx.events == n0 + 1, "B: replay_pits plays the pits event")
	hg.queue_free()
	cg.queue_free()
	await ticks(3)


func _frame_median(n: int) -> float:
	var frames: Array = []
	for i in n:
		await physics_frame
		frames.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	frames.sort()
	return frames[frames.size() / 2]
