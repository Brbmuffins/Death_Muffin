extends SceneTree
## Combat odds and ends on the rebuilt client. godot --headless --path client --script res://tests/combat_odds/run.gd
## The enemies are static bodies of the combat core (stunned for an hour, harmless, with health to spare), the corpses and the legion are the core's, as tests/rites.gd has them;
## the Gravedigger King is the real one, his brain stepped by hand as tests/boss.gd does.
##   A  player-side Bone Ward / Colossus guard: stat-based on hit exactly as the old game's DmPlayerRules / DmGameCombat.on_hurt (no timed status exists there either)
##   B  bosses ignore slow / root / chill like the old game's boss controller (the brain owns speed; only stun is capped, see DmBoss.stun)
##   C  the necromancer's primary weapon variants (staff pierce, sickle Withered, scythe arc) and the Splinters / Volley / Marrow-Tap runes on them
##   D  rite sound coverage: every registered rite (the registry lists exactly the rite_<id>.gd files) plays the sounds the old game's DmAbilitySystem played (REF_SOUNDS: a table recorded from it before it was removed; the Reaper's are new)
##      and gives a visible and an audible cue in the 0.25 s after the press (never silent, never only on landing)

const TICK := 1.0 / 60.0
const NONVIS := ["sfx", "loop", "gesture", "shake", "float"]   ## the effect counters that are not something to see

const SCYTHE_SPEC := {"kind": "warrior", "cap": 8.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0, "r": 0.8}

class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var passed := 0
var failed := 0
var errlog := ErrorLog.new()
var mock: DmMockBackend   ## must outlive the suite: the api's transport is its callable
var api: DmApi
var character: Dictionary
var g: DmNextGame
var host: DmCoreHost
var core: RefCounted
var hb: DmHeroBody
var me := 0                   ## the hero's peer id
var boss: DmBoss
var caster: DmRiteCaster
var foes: Array[int] = []
var hits: Array = []
var DOC := {}   ## rite -> {ref: [..], new: [..]} for the report


## Recording audio back-end (the same two calls DmRiteFx / DmAbilitySystem make).
class RecAudio:
	extends RefCounted
	var sfx: Array = []
	var loops: Array = []
	func play_sfx(id, _p, _i) -> void:
		if not sfx.has(id):
			sfx.append(id)
	func loop_sfx(id, _ms, _p, _f) -> void:
		if not loops.has(id):
			loops.append(id)


class RecAvatar:
	extends RefCounted
	var calls: Array = []
	func cast(kind: String, seconds: float, yaw: float, gesture_s: float, ability: String = "") -> void:
		calls.append([kind, seconds, gesture_s, ability])


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
	var end := Engine.get_physics_frames() + int(limit_s * 60.0)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func secs(s: float) -> void:
	await ticks(int(s / TICK))


## A static enemy of the core: stunned for an hour (it stands where it is), harmless, with health to spare. Returns its id.
func foe(at: Vector3, def_id := "robber") -> int:
	var id := host.spawn_enemy(def_id, at, 1, 1000.0, 0.0, false, "graves", false)
	core.stun(id, 3600.0)
	foes.append(id)
	return id


func eid(e: int) -> int:
	return e


func pos_of(e: int) -> Vector3:
	return host.enemy_position(e)


## What the core took from an enemy: its maximum health less its health (-1 when it is gone).
func loss(e: int) -> float:
	var i: Dictionary = core.enemy_info(e)
	return float(i["max_hp"]) - float(i["hp"]) if not i.is_empty() else -1.0


func status_stacks(id: int, name: StringName) -> int:
	var b: PackedByteArray = core.statuses(id)
	var want := DmStatusSet.IDS.find(name)
	for i in range(0, b.size(), 4):
		if int(b[i]) == want:
			return int(b[i + 1])
	return 0


func legion() -> DmCoreLegion:
	return caster.thralls()


func evs_of(rite: String, t: String) -> Array:
	return hits.filter(func(h: Dictionary) -> bool: return h["rite"] == rite and h["t"] == t)


func corpse(at: Vector3, kind := "normal") -> int:
	return g.corpses.add_corpse(at.x, at.z, kind, "robber", false, 0.0, 1.0, "graves")


## A thrall of the legion at `pos` the way an exhume raises one (a corpse is laid there, the legion raises from it): its id.
func raise_at(pos: Vector3, spec: Dictionary = SCYTHE_SPEC) -> int:
	corpse(pos)
	var r: Dictionary = legion().raise(spec, pos)
	return int((r["thralls"] as Array)[0]) if bool(r["ok"]) and not (r["thralls"] as Array).is_empty() else 0


func clear_world() -> void:
	for id in core.enemy_ids():
		if boss == null or not is_instance_valid(boss) or int(id) != boss.core_id:
			host.remove_enemy(int(id))
	foes.clear()
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	for id in core.thrall_ids():
		core.kill_thrall(id, "crumbled")
	caster._pending.clear()
	caster._mem.clear()


func reset(runes := {}, loadout: Variant = null) -> void:
	clear_world()
	hb.teleport(Vector3(0, 0, -18))
	caster.set_runes(runes)
	caster.p["loadout"] = loadout if loadout != null else DmWeaponLine.no_loadout()
	caster.p["stats"]["level"] = 60.0   # every rite unlocked (a level-up or a stats refresh would reset it)
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.p["rootedUntil"] = 0.0
	hb.heal(1e6)
	hits.clear()


func weapon(kind: String) -> Dictionary:
	for w: Dictionary in DmCombatData.load_json("necro_weapons")["weapons"]:
		if w["kind"] == kind:
			return DmWeaponLine.resolve({"main_hand": {"item_id": w["id"]}}, "gravecaller")
	return {}


func cast_needle(at: int) -> void:
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.request_cast("bone_needle", pos_of(at), eid(at))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	OS.add_logger(errlog)
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("odds%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	character = (await api.load_or_create_character(0)).data   # a Gravecaller
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(character, api, {"areas": ["graves"], "dressing": false, "hud": false, "waves": false, "audio": false})
	host = g.core_host
	core = host.core
	hb = g.local_body()
	me = g.session.get_my_id()
	await ticks(2)
	caster = hb.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	caster.random = func() -> float: return 0.5   # jitter 1.0, no crit: damage is exact
	caster.event_played.connect(func(ev: Dictionary) -> void: hits.append({"rite": String(ev["rite"]), "t": String(ev["t"]), "ev": ev}))
	await _weapons()
	await _bosses()
	await _player_ward()
	await _sounds()
	check(errlog.errors.is_empty(), "no engine errors in the log (%d: %s)" % [errlog.errors.size(), ", ".join(errlog.errors.slice(0, 3))])
	OS.remove_logger(errlog)
	print("%d passed, %d failed" % [passed, failed])
	print("%s combat_odds %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


# ---- the King, as tests/boss.gd has him: woken at his grave, his brain stepped by hand

func arena() -> Vector3:
	var a: Dictionary = DmContent.boss("gravedigger")["arena"]
	return Vector3(float(a["x"]), 0.0, float(a["z"]))


## Wake the Gravedigger King with the hero at his site and `shards` to pay for it; the body is stepped by hand. Returns the refusal ("" = woken).
func summon(shards: int = 20) -> String:
	hb.teleport(g.bosses.site_pos("gravedigger") + Vector3(0.0, 0.0, 2.0))
	g.my_member().prog.local["shards"] = shards
	var why := g.bosses.try_summon(me, "gravedigger")
	if why == "":
		boss = g.bosses.active_boss()
		boss.set_physics_process(false)
		boss.world.refresh()
	return why


## One brain tick at a time, by hand: the exact timing of the brain's clock (the boss's own physics process is off).
func step(seconds: float) -> void:
	for i in int(round(seconds / TICK)):
		hb.heal(1.0e6)
		boss._physics_process(TICK)


func put(p: Vector3) -> void:
	hb.teleport(p)
	boss.world.refresh()


## Free the body at once (the host frees a fallen one after 8 s) and let the core drop its external.
func end_fight() -> void:
	if boss != null and is_instance_valid(boss):
		boss.queue_free()
	await ticks(3)
	boss = null


# =========================================================================================================================== A: ward / guard

func _player_ward() -> void:
	reset()
	hb.mods = hb.mods.duplicate()
	hb.mods["wardPerThrall"] = 0.1
	hb.heal(1e6)
	var none := hb.take_damage(50.0, null)
	hb.heal(1e6)
	var spec := {"kind": "warrior", "cap": 8.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0, "r": 0.8}
	var seen: Array = [none]
	for k in 2:
		raise_at(hb.global_position + Vector3(2 + k, 0, 0), spec)
		await ticks(2)
		seen.append(hb.take_damage(50.0, null))
		hb.heal(1e6)
	var ok := legion().count() == 2 and absf(float(seen[0]) - 50.0) < 0.01
	for k in 2:
		ok = ok and absf(float(seen[k + 1]) - 50.0 * DmLegend.damage_taken_mult(0.1 * (k + 1), 0.0)) < 0.01
	check(ok, "A: Bone Ward is wardPerThrall x living thralls at the moment of each hit, the number the current client's onHurt gives (none %.1f, one %.1f, two %.1f of 50)" % [seen[0], seen[1], seen[2]])
	check(float(seen[2]) < float(seen[1]) and float(seen[1]) < float(seen[0]), "A: ...nothing to expire, it follows the thrall count at once (it is no timed status on the current client either)")
	hb.mods["wardPerThrall"] = 0.0
	# Colossus guard is table-proven in tests/runes (C); here: the Bulwark branch of the rules a hero would use is the shared DmPlayerRules one
	check(DmRiteRegistry.ids().filter(func(id: String) -> bool: return id.contains("bulwark")).is_empty() and hb.p.has("bulwarkUntil"), "A: Bulwark (knight family, no necromancer kit casts it): the state + DmPlayerRules branch are shared, no rite yet - N/A for now")
	var p: Dictionary = hb.p
	p["bulwarkUntil"] = hb.clock_ms() + 5000.0
	p["facing"] = 0.0   # looking +z
	var src := foe(hb.position + Vector3(0, 0, 2.0))
	hb.heal(1e6)
	var blocked := hb.take_damage(50.0, src)
	p["bulwarkUntil"] = 0.0
	hb.heal(1e6)
	var plain := hb.take_damage(50.0, src)
	check(blocked < plain * 0.8, "A: a raised Bulwark would cut a frontal blow on the rebuild's hero too (%.1f vs %.1f)" % [blocked, plain])


# =========================================================================================================================== B: boss statuses

func _chase_dist(secs_: float) -> float:
	var s: Dictionary = boss.brain.state
	for cd in ["_sweep_cd", "_bury_cd", "_exhume_cd"]:
		boss.brain.set(cd, 99.0)   # no attack interrupts the walk we measure
	boss.brain.pending.clear()
	var x0 := float(s["x"])
	var z0 := float(s["z"])
	step(secs_)
	return Vector2(float(s["x"]) - x0, float(s["z"]) - z0).length()


func _bosses() -> void:
	reset()
	check(summon() == "", "B: the Gravedigger King wakes")
	step(2.5)   # the rise
	var a := arena()
	put(a + Vector3(10.0, 0, 0))
	boss.brain.state["x"] = a.x - 6.0
	boss.brain.state["z"] = a.z
	boss.world.refresh()
	var base := _chase_dist(0.5)
	check(base > 0.3, "B: the boss walks toward the hero (%.2f m in 0.5 s)" % base)
	var ss := DmStatusSet.of(boss)
	check(ss != null, "B: it carries a status set")
	var ok_all := true
	var msgs: Array = []
	for st in [&"slow", &"ward_slow", &"root", &"chill"]:
		ss.clear()
		ss.apply(st, hb, 1, 30.0)
		var sm: Variant = boss.get("speed_mult")   # the old body kept the status set's move multiplier here; the status set of this one owns it
		boss.brain.state["x"] = a.x - 6.0
		boss.brain.state["z"] = a.z
		put(a + Vector3(10.0, 0, 0))
		var d := _chase_dist(0.5)
		var same := absf(d - base) < 0.02
		ok_all = ok_all and same
		msgs.append("%s: speed_mult %s, walked %.2f" % [st, str(sm), d])
		check(ss.has(st), "B: the %s status lands on the boss (shown, replicated)" % st)
	check(ok_all, "B: slow / ward_slow / root / chill do not change what the boss's brain walks, as the current client (immune): %s vs %.2f" % [", ".join(msgs), base])
	ss.clear()
	# stun stays what it was: capped (0.5 s) and rate-limited
	boss._stun_icd = 0.0
	boss.stun(5.0)
	check(float(boss.brain.stagger_t) <= DmBoss.STUN_CAP_S + 1e-6 and float(boss.brain.stagger_t) > 0.0, "B: a stun staggers the boss at most %.1f s (%.2f)" % [DmBoss.STUN_CAP_S, float(boss.brain.stagger_t)])
	await end_fight()


# =========================================================================================================================== C: weapon variants + runes

func _weapons() -> void:
	var T: Dictionary = DmSimData.NECRO_WEAPON_TUNING
	var lo_staff := weapon("staff")
	var lo_sickle := weapon("sickle")
	var lo_scythe := weapon("scythe")
	check(float(lo_staff["needlePierce"]) > 0.0 and float(lo_sickle["needleWithered"]) > 0.0 and bool(lo_scythe["reap"]), "C: the loadouts resolve from the data (staff pierce %s, sickle withered %s, scythe)" % [str(lo_staff["needlePierce"]), str(lo_sickle["needleWithered"])])

	# ---- the plain needle, the baseline every variant is measured against
	reset()
	var base := 0.0
	var e1 := foe(Vector3(0, 0, -26))
	cast_needle(e1)
	await secs(1.0)
	base = loss(e1)
	check(base > 0.0, "C: plain needle %.1f" % base)

	# ---- staff: pierce the enemy behind, in the lane, for the pierce fraction
	reset({}, lo_staff)
	e1 = foe(Vector3(0, 0, -26))
	var e2 := foe(Vector3(0, 0, -28.0))
	var side := foe(Vector3(5, 0, -26))
	cast_needle(e1)
	await secs(1.0)
	var pierced := float(T["staff"]["pierceDamageMult"])
	check(absf(loss(e1) - base) < 0.02 and absf(loss(e2) - loss(e1) * pierced) < 0.02 and loss(side) == 0.0, "C: staff - the needle pierces into the enemy behind it for x%.2f (%.1f then %.1f), not the one off its lane (%.1f)" % [pierced, loss(e1), loss(e2), loss(side)])
	check(evs_of("bone_needle", "pierce").size() == 1, "C: ...one pierce event is drawn")
	# every volley needle pierces too (as the current client's _needle_arrive); Splinters on a staff needle sends its shard besides
	reset({"bone_needle": "rune_splinter"}, lo_staff)
	e1 = foe(Vector3(0, 0, -26))
	e2 = foe(Vector3(0, 0, -28.0))
	var e3 := foe(Vector3(5, 0, -26))
	cast_needle(e1)
	await secs(1.0)
	var shard := float(DmSimData.RUNE_TUNING["splinter"]["damageFrac"])
	check(evs_of("bone_needle", "pierce").size() == 1 and evs_of("bone_needle", "splinter").size() == 1 and absf(loss(e2) - base * (pierced + shard)) < 0.05 and loss(e3) == 0.0, "C: staff + Splinters - the pierce and the shard both happen (the enemy behind takes both: %.1f, want %.1f)" % [loss(e2), base * (pierced + shard)])
	reset({"bone_needle": "rune_volley"}, lo_staff)
	e1 = foe(Vector3(0, 0, -26))
	e2 = foe(Vector3(0, 0, -28.0))
	for i in 3:
		cast_needle(e1)
		await secs(0.7)
	hits.clear()
	cast_needle(e1)
	await secs(1.2)
	check(evs_of("bone_needle", "hit").size() == 3 and evs_of("bone_needle", "pierce").size() >= 2, "C: staff + Volley - the 4th needle is three, and the volley needles pierce too (%d hits, %d pierces)" % [evs_of("bone_needle", "hit").size(), evs_of("bone_needle", "pierce").size()])

	# ---- sickle: every needle adds a Withered stack
	reset({}, lo_sickle)
	e1 = foe(Vector3(0, 0, -26))
	cast_needle(e1)
	await secs(0.9)
	check(status_stacks(e1, &"withered") == 1, "C: sickle - a needle leaves one Withered stack (%d)" % status_stacks(e1, &"withered"))
	cast_needle(e1)
	await secs(0.9)
	check(status_stacks(e1, &"withered") == 2, "C: ...and the next adds another (%d)" % status_stacks(e1, &"withered"))

	# ---- scythe
	await _scythe(lo_scythe)


func _scythe(lo: Dictionary) -> void:
	var T: Dictionary = DmSimData.NECRO_WEAPON_TUNING["scythe"]
	reset({}, lo)
	hb.set_facing(PI)   # -z, toward the foes; (0, -18) -> aim (0, -21)
	var near1 := foe(Vector3(0, 0, -20.5))
	var near2 := foe(Vector3(1.2, 0, -20.4))
	var near3 := foe(Vector3(-1.2, 0, -20.4))
	var near4 := foe(Vector3(0.6, 0, -20.0))   # the fourth in the arc: maxHits (3) leave it out
	var behind := foe(Vector3(0, 0, -14.0))
	var far := foe(Vector3(0, 0, -26.0))
	caster.p["resource"]["value"] = 0.0
	var want := float(DmAbilities.reap_cast(DmAbilities.sp(caster.p, 0.0), "", 0.5, 3)["dmg"])
	caster.request_cast("bone_needle", pos_of(near1), eid(near1))
	await secs(0.3)
	var struck := [near1, near2, near3, near4].filter(func(e: int) -> bool: return loss(e) > 0.0)
	check(struck.size() == int(T["maxHits"]) and loss(behind) == 0.0 and loss(far) == 0.0, "C: scythe - %d enemies in the arc are cut (maxHits), nothing behind or beyond reach (hit: %d)" % [int(T["maxHits"]), struck.size()])
	check(struck.all(func(e: int) -> bool: return absf(loss(e) - want) < 0.05), "C: ...each for %.1f, no projectile, no crit (%s)" % [want, str(struck.map(func(e: int) -> float: return snappedf(loss(e), 0.01)))])
	check(not struck.has(near4) or loss(near1) > 0.0, "C: ...the nearest ones first")
	var ess := float(caster.p["resource"]["value"])
	check(ess >= float(T["essencePerHit"]) * 3.0 - 0.1 and ess < float(T["essencePerHit"]) * 3.0 + 3.5, "C: ...+%d essence a hit (%.1f)" % [int(T["essencePerHit"]), ess])
	check(evs_of("bone_needle", "reap").size() == 1 and evs_of("bone_needle", "cast").is_empty(), "C: ...one reap event, no needle shot")
	var cd := caster.cooldown_left("bone_needle")
	check(cd > 100.0 and cd <= float(T["cooldownMs"]) + 5.0, "C: ...the swing's own cooldown (%.0f of %d ms)" % [cd, int(T["cooldownMs"])])
	# range: past the scythe's reach the swing is refused
	reset({}, lo)
	var distant := foe(Vector3(0, 0, -25.0))
	var rej: Array = []
	caster.cast_rejected.connect(func(r: String, why: String) -> void: rej.append(why), CONNECT_ONE_SHOT)
	caster.request_cast("bone_needle", pos_of(distant), eid(distant))
	await secs(0.3)
	check(loss(distant) == 0.0 and rej == ["range"], "C: scythe - an enemy past its %.0f m reach is out of range (%s)" % [float(T["reach"]), str(rej)])

	# ---- runes on the scythe: Splinters (a shard to the nearest enemy the arc missed), Marrow-Tap (x damage, +essence once per swing), Volley is the needle's
	var dmg1 := 0.0
	for rn in ["", "rune_splinter", "rune_marrow_tap"]:
		reset({"bone_needle": rn} if rn != "" else {}, lo)
		hb.set_facing(PI)
		var v := foe(Vector3(0, 0, -20.5))
		var miss := foe(Vector3(0, 0, -23.5))   # 3 m past the victim: out of reach, inside the shard's range
		caster.p["resource"]["value"] = 0.0
		caster.request_cast("bone_needle", pos_of(v), eid(v))
		await secs(0.4)
		if rn == "":
			dmg1 = loss(v)
			check(dmg1 > 0.0 and loss(miss) == 0.0, "C: scythe alone cuts only its arc (%.1f / %.1f)" % [dmg1, loss(miss)])
		elif rn == "rune_splinter":
			check(absf(loss(v) - dmg1) < 0.05 and absf(loss(miss) - dmg1 * float(DmSimData.RUNE_TUNING["splinter"]["damageFrac"])) < 0.05 and evs_of("bone_needle", "splinter").size() == 1, "C: scythe + Splinters - a shard cuts the enemy the arc missed for %.0f%% (%.1f of %.1f)" % [float(DmSimData.RUNE_TUNING["splinter"]["damageFrac"]) * 100.0, loss(miss), dmg1])
		else:
			var mt: Dictionary = DmSimData.RUNE_TUNING["marrowTap"]
			check(absf(loss(v) - dmg1 * float(mt["damageMult"])) < 0.05 and float(caster.p["resource"]["value"]) >= float(T["essencePerHit"]) + float(mt["essenceBonus"]) - 0.1, "C: scythe + Marrow-Tap - x%.1f damage (%.1f) and +%d essence once (%.1f)" % [float(mt["damageMult"]), loss(v), int(mt["essenceBonus"]), float(caster.p["resource"]["value"])])
	reset({"bone_needle": "rune_volley"}, lo)
	hb.set_facing(PI)
	var vv := foe(Vector3(0, 0, -20.5))
	for i in 5:
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("bone_needle", pos_of(vv), eid(vv))
		await secs(0.2)
	check(evs_of("bone_needle", "reap").size() == 5 and evs_of("bone_needle", "cast").is_empty(), "C: scythe + Volley - no volley (it is the needle's rune, as the current client): %d swings, %d shots" % [evs_of("bone_needle", "reap").size(), evs_of("bone_needle", "cast").size()])

	# ---- the soul window: a kill of a reaped enemy banks one more soul (1.2 s), asked once
	reset({}, lo)
	hb.set_facing(PI)
	var s1 := foe(Vector3(0, 0, -20.5))
	var s2 := foe(Vector3(0, 0, -30.0))
	caster.request_cast("bone_needle", pos_of(s1), eid(s1))
	await secs(0.3)
	var cid := int(character.get("id", 0))
	hb.p["souls"] = 0.0
	g.rewards.killer_paid.emit(cid, "robber", s1)
	var after_reaped := float(hb.p["souls"])
	g.rewards.killer_paid.emit(cid, "robber", s1)
	var after_again := float(hb.p["souls"])
	g.rewards.killer_paid.emit(cid, "robber", s2)
	var after_other := float(hb.p["souls"])
	check(after_reaped == 2.0 and after_again == 3.0 and after_other == 4.0, "C: scythe souls - the reaped kill banks 2, a second kill of it 1, an unreaped enemy 1 (%s)" % str([after_reaped, after_again - after_reaped, after_other - after_again]))
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.request_cast("bone_needle", pos_of(s1), eid(s1))
	await secs(1.5)
	hb.p["souls"] = 0.0
	g.rewards.killer_paid.emit(cid, "robber", s1)
	check(float(hb.p["souls"]) == 1.0, "C: ...and nothing once the 1.2 s window has passed (%s)" % str(hb.p["souls"]))

	# ---- the swing's gesture (the current client plays "attack" 2.6 with the scythe's own 0.3 s, no weapon clip) instead of the needle's cast
	var av := RecAvatar.new()
	check(DmRiteGestures.has(DmRiteGestures.REAP_KEY) and DmRiteGestures.play(av, DmRiteGestures.REAP_KEY, 0.0) and av.calls == [["attack", 2.6, float(T["gestureSeconds"]), ""]], "C: the scythe's gesture row matches the current client's _gesture call (%s)" % str(av.calls))
	reset({}, lo)
	var g0 := caster.gestures_played
	var gy := foe(Vector3(0, 0, -20.5))
	caster.request_cast("bone_needle", pos_of(gy), eid(gy))
	await secs(0.2)
	check(caster.gestures_played == g0 + 1, "C: an accepted swing plays one gesture")

	# ---- the boss is struck with its own reach (bossReach) and counted besides maxHits
	reset({}, lo)
	check(summon() == "", "C: summon the King for the scythe")
	step(2.5)
	var bp := boss.global_position
	hb.teleport(bp + Vector3(0, 0, 4.2))   # edge-to-edge ~2.6 m: past the plain reach (3) measured to the centre, inside bossReach (4) to its edge
	boss.world.refresh()
	hb.set_facing(PI)
	var hp0 := boss.hp
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.request_cast("bone_needle", bp, boss.core_id)
	await secs(0.3)
	var got := hp0 - boss.hp
	check(got > 0.0 and absf(got - want) < 0.05 * 3.0, "C: scythe on the boss - struck from %.1f m (%.1f of %.1f)" % [hb.position.distance_to(bp), got, want])
	await end_fight()
	reset()


# =========================================================================================================================== D: sounds

const REF_SOUNDS := {   ## rite -> the sfx (and "loop:"-prefixed loops) the old DmAbilitySystem played for a standard cast, recorded from it before it was removed (2026-10-09)
	"bone_needle": ["needleCast", "needleHit"],
	"miasma": ["miasma", "loop:miasmaLoop"],
	"exhume": ["exhume"],
	"corpse_explosion": ["corpseExplode"],
	"black_litany": ["litany"],
	"grave_offering": ["graveOffering"],
	"bone_mantle": ["boneHit", "mantle"],
	"carrion_seed": ["carrionSeed", "seedBurst"],
	"bone_fan": ["boneFan", "needleHit"],
	"rot_lance": ["needleHit", "rotLance"],
	"marrow_spear": ["spear"],
	"wailing_skull": ["needleHit", "wail"],
	"ivory_cleave": ["boneHit", "ivoryCleave"],
	"bone_storm": ["boneHit", "storm", "loop:boneStormLoop"],
	"soul_siphon": ["siphon", "loop:siphonLoop"],
	"grave_step": ["bloodStep"],
	"veil_step": ["veilStep"],
	"grave_frost": ["frost"],
	"bone_prison": ["prison"],
	"grave_hands": ["hands", "loop:handsLoop"],
	"rally_dead": ["rallyDead"],
	"ossuary_wall": ["sigWall"],
	"command_rend": ["sigRend"],
	"dirge": ["sigDirge", "loop:dirgeLoop"],
	"plague_bloom": ["sigBloom", "loop:bloomPulse"],
	# The Reaper's six (2026-10-11): new rites, no old client to record from; these are the sounds they were written to play.
	"scythe_sweep": ["boneHit", "ivoryCleave"],
	"scythe_throw": ["boneHit", "storm"],
	"reap": ["boneHit", "ivoryCleave"],
	"wraith_walk": ["wail", "banshee"],
	"soul_burst": ["boneHit", "ivoryCleave", "wail"],
	"harvest_spin": ["boneHit", "ivoryCleave"],
	"unleash_souls": ["wail", "boneHit"],
	"soul_harvest": ["boneHit", "ivoryCleave", "wail"],
	"scythe_weave": ["boneHit", "ivoryCleave"],
	"haunting_wraith": ["wail", "banshee", "boneHit"],   # 2026-10-19, new: the sounds it was written to play
}


func _new_sounds(id: String) -> Dictionary:
	reset()
	hb.teleport(Vector3(0, 0, -16))
	for i in 7:
		var a := float(i) / 7.0 * TAU
		foe(Vector3(cos(a) * 3.5, 0, -16.0 + sin(a) * 3.5))
	var best_at := Vector3.INF
	var bd := INF
	for i in 10:
		var a2 := float(i) / 10.0 * TAU + 0.3
		var at := Vector3(cos(a2) * 2.2, 0, -16.0 + sin(a2) * 2.2)
		corpse(at, "resonant" if i == 3 else "normal")
		var d := Vector2(at.x, at.z + 16.0).length()
		if d < bd and i != 3:
			bd = d
			best_at = at
	var spec := {"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0, "r": 0.8}
	for k in 2:
		raise_at(hb.global_position + Vector3(2 + k, 0, 0), spec)
	await until(func() -> bool: return Array(core.thrall_ids()).all(func(t: int) -> bool: return int(legion().info(t)["state"]) != 0), 6.0)   # Command: Rend needs a standing legion
	var rec := RecAudio.new()
	var old_audio: Variant = caster.fx.audio
	caster.fx.audio = rec
	caster.p["castUntil"] = 0.0
	caster.p["cooldowns"].clear()
	caster.p["resource"]["value"] = 900.0
	caster.p["stats"]["level"] = 60.0
	var why: Array = []
	var rj := func(_r: String, w: String) -> void: why.append(w)
	caster.cast_rejected.connect(rj)
	var before: Dictionary = caster.fx.stats.duplicate()
	var def := DmAbilities.def(id)
	if String(def.get("targeting", "ground")) == "enemy":
		var e := -1
		var ed := INF
		for f: int in foes:
			var dd := Vector2(pos_of(f).x, pos_of(f).z + 16.0).length()
			if dd < ed:
				ed = dd
				e = f
		caster.request_cast(id, pos_of(e), eid(e))
	else:
		var aim := Vector3(best_at.x, 0, best_at.z) if best_at != Vector3.INF else Vector3(3.0, 0, -16.0)
		caster.request_cast(id, aim, -1)
	await secs(0.25)
	var early := 0
	for k in caster.fx.stats:
		if not NONVIS.has(k):
			early += int(caster.fx.stats[k]) - int(before[k])
	var early_sounds := rec.sfx.size() + rec.loops.size()
	await secs(3.75)
	caster.cast_rejected.disconnect(rj)
	caster.fx.audio = old_audio
	var out := {"why": why, "early": early, "early_sounds": early_sounds, "sfx": rec.sfx.duplicate(), "loops": rec.loops.duplicate()}
	out["sfx"].sort()
	out["loops"].sort()
	return out


## Sounds the current client plays that the rebuild must too, per rite (the table the audit is written against; filled from the recorded reference
## below and kept here so a regression names the rite). Scenario-dependent extras (hit sounds that need a kill / a particular landing) are listed in
## OPTIONAL and may differ either way.
const OPTIONAL := ["boneHit", "needleHit", "soulRelease", "tollSmall", "toll", "burst", "corpseExplode", "seedBurst"]


## The rite modules on disk (client/next/rites/rite_<id>.gd), sorted: the registry must list exactly these (a new rite = a file + a registry line).
static func rite_files() -> Array:
	var out: Array = []
	for f: String in DirAccess.get_files_at("res://next/rites"):
		if f.begins_with("rite_") and f.ends_with(".gd"):
			out.append(f.trim_prefix("rite_").trim_suffix(".gd"))
	out.sort()
	return out


static func sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return b


func _sounds() -> void:
	var rites: Array = DmRiteRegistry.ids()
	check(not rites.is_empty() and sorted(rites) == rite_files(), "D: every rite file is registered, and only those (%d rites)" % rites.size())
	var missing: Array = []
	for id: String in rites:
		var got := await _new_sounds(id)
		var rs: Array = REF_SOUNDS.get(id, [])   # a rite newer than the table: it only has to make a sound
		var ns: Array = got["sfx"] + got["loops"].map(func(l: String) -> String: return "loop:" + l)
		var lost := rs.filter(func(s: String) -> bool: return not ns.has(s) and not OPTIONAL.has(s))
		# (that it casts, draws and makes a sound at all is tests/spells/run.gd's, for every spell of the playable kits: the same 35 rites)
		check(lost.is_empty(), "D: %s - the rebuild plays every sound the old client did (missing %s; rejected: %s)" % [id, str(lost), str(got["why"])])
		check(int(got["early"]) >= 3, "D: %s shows a visible cue at the cast (%d visual calls in 0.25 s)" % [id, int(got["early"])])
		check(int(got["early_sounds"]) > 0, "D: %s makes a sound at the cast" % id)
		if not lost.is_empty():
			missing.append([id, lost])
