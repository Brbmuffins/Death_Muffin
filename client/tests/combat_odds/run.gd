extends SceneTree
## Combat odds and ends on the rebuilt client. godot --headless --path client --script res://tests/combat_odds/run.gd
## The enemies are static bodies of the combat core (stunned for an hour, harmless, with health to spare), the corpses and the legion are the core's, as tests/rites.gd has them;
## the Gravedigger King is the real one, his brain stepped by hand as tests/boss.gd does.
##   A  player-side Bone Ward / Colossus guard: stat-based on hit exactly as the old game's DmPlayerRules / DmGameCombat.on_hurt (no timed status exists there either)
##   B  bosses ignore slow / root / chill like the old game's boss controller (the brain owns speed; only stun is capped, see DmBoss.stun)
##   C  the necromancer's primary weapon variants (staff pierce, sickle Withered, scythe arc) and the Splinters / Volley / Marrow-Tap runes on them
##   E  the legion's two moments and the toxic pool: a toxic corpse's pool hurts at the level of the area it lies in, a Mourning Bell wraith's blow mends the heroes near it, and a plague bearer
##      that falls leaves its owner's rot pool (the core's events, DmCoreHost -> DmLegionEvents)
##   D  rite sound coverage: every registered rite (the registry lists exactly the rite_<id>.gd files) plays the sounds the old game's DmAbilitySystem played (REF_SOUNDS: a table recorded from it before it was removed; the newer rites' are what they were written to play)
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
	await _legion_events()
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
	var cut := float(DmCombatData.const_table("BULWARK")["damageCut"])
	check(cut > 0.0 and absf(blocked - plain * (1.0 - cut)) < 0.05, "A: a raised Bulwark would cut a frontal blow by %.0f%% on the rebuild's hero too (%.1f vs %.1f)" % [cut * 100.0, blocked, plain])


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
	check(base > 0.02, "B: the boss walks toward the hero (%.2f m in 0.5 s)" % base)
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
	var Ts: Dictionary = T["staff"]
	var behind_z := -26.0 - float(Ts["pierceReach"]) * 0.45   # the enemy behind, well inside the pierce reach
	var off_x := float(Ts["pierceLane"]) + float(Ts["pierceReach"])   # off the lane, and out of reach too
	var every := int(DmSimData.RUNE_TUNING["volley"]["every"])
	var needles := int(DmSimData.RUNE_TUNING["volley"]["needles"])

	# ---- staff: pierce the enemy behind, in the lane, for the pierce fraction
	reset({}, lo_staff)
	e1 = foe(Vector3(0, 0, -26))
	var e2 := foe(Vector3(0, 0, behind_z))
	var side := foe(Vector3(off_x, 0, -26))
	cast_needle(e1)
	await secs(1.0)
	var pierced := float(T["staff"]["pierceDamageMult"])
	check(absf(loss(e1) - base) < 0.02 and absf(loss(e2) - loss(e1) * pierced) < 0.02 and loss(side) == 0.0, "C: staff - the needle pierces into the enemy behind it for x%.2f (%.1f then %.1f), not the one off its lane (%.1f)" % [pierced, loss(e1), loss(e2), loss(side)])
	check(evs_of("bone_needle", "pierce").size() == 1, "C: ...one pierce event is drawn")
	# every volley needle pierces too (as the current client's _needle_arrive); Splinters on a staff needle sends its shard besides
	reset({"bone_needle": "rune_splinter"}, lo_staff)
	e1 = foe(Vector3(0, 0, -26))
	e2 = foe(Vector3(0, 0, behind_z))
	var e3 := foe(Vector3(off_x, 0, -26))
	cast_needle(e1)
	await secs(1.0)
	var shard := float(DmSimData.RUNE_TUNING["splinter"]["damageFrac"])
	check(evs_of("bone_needle", "pierce").size() == 1 and evs_of("bone_needle", "splinter").size() == 1 and absf(loss(e2) - base * (pierced + shard)) < 0.05 and loss(e3) == 0.0, "C: staff + Splinters - the pierce and the shard both happen (the enemy behind takes both: %.1f, want %.1f)" % [loss(e2), base * (pierced + shard)])
	reset({"bone_needle": "rune_volley"}, lo_staff)
	e1 = foe(Vector3(0, 0, -26))
	e2 = foe(Vector3(0, 0, behind_z))
	for i in every - 1:
		cast_needle(e1)
		await secs(0.7)
	hits.clear()
	cast_needle(e1)
	await secs(1.2)
	check(evs_of("bone_needle", "hit").size() == needles and evs_of("bone_needle", "pierce").size() >= needles - 1, "C: staff + Volley - needle %d is a volley of %d, and the volley needles pierce too (%d hits, %d pierces)" % [every, needles, evs_of("bone_needle", "hit").size(), evs_of("bone_needle", "pierce").size()])

	# ---- sickle: every needle adds a Withered stack
	reset({}, lo_sickle)
	e1 = foe(Vector3(0, 0, -26))
	cast_needle(e1)
	await secs(0.9)
	var per_hit := int(lo_sickle["needleWithered"])
	check(status_stacks(e1, &"withered") == per_hit, "C: sickle - a needle leaves %d Withered stack(s) (%d)" % [per_hit, status_stacks(e1, &"withered")])
	cast_needle(e1)
	await secs(0.9)
	check(status_stacks(e1, &"withered") == per_hit * 2, "C: ...and the next adds as many again (%d)" % status_stacks(e1, &"withered"))

	# ---- scythe
	await _scythe(lo_scythe)


func _scythe(lo: Dictionary) -> void:
	var T: Dictionary = DmSimData.NECRO_WEAPON_TUNING["scythe"]
	var reach := float(T["reach"])
	var hits_max := int(T["maxHits"])
	reset({}, lo)
	hb.set_facing(PI)   # -z, toward the foes; (0, -18) -> aim (0, -21)
	var in_arc: Array[int] = []   # one enemy more than the swing can strike, spread over the middle of the arc, well inside its reach
	for k in hits_max + 1:
		var ang := lerpf(-0.3, 0.3, float(k) / float(hits_max)) * deg_to_rad(float(T["arcDeg"]))
		in_arc.append(foe(Vector3(sin(ang) * reach * 0.8, 0, -18.0 - cos(ang) * reach * 0.8)))
	var near1 := in_arc[int(hits_max * 0.5)]   # the cast aims at the middle one
	var behind := foe(Vector3(0, 0, -18.0 + reach * 0.8))   # inside the reach, behind the hero: outside the arc
	var far := foe(Vector3(0, 0, -18.0 - reach * 2.5))
	caster.p["resource"]["value"] = 0.0
	var want := float(DmAbilities.reap_cast(DmAbilities.sp(caster.p, 0.0), "", 0.5, hits_max)["dmg"])
	caster.request_cast("bone_needle", pos_of(near1), eid(near1))
	await secs(0.3)
	var struck := in_arc.filter(func(e: int) -> bool: return loss(e) > 0.0)
	check(struck.size() == hits_max and loss(behind) == 0.0 and loss(far) == 0.0, "C: scythe - %d enemies in the arc are cut (maxHits), nothing behind or beyond reach (hit: %d)" % [hits_max, struck.size()])
	check(struck.all(func(e: int) -> bool: return absf(loss(e) - want) < 0.05), "C: ...each for %.1f, no projectile, no crit (%s)" % [want, str(struck.map(func(e: int) -> float: return snappedf(loss(e), 0.01)))])
	var ess := float(caster.p["resource"]["value"])
	check(ess >= float(T["essencePerHit"]) * float(struck.size()) - 0.1 and ess < float(T["essencePerHit"]) * float(struck.size()) + 3.5, "C: ...+%d essence a hit (%.1f)" % [int(T["essencePerHit"]), ess])
	check(evs_of("bone_needle", "reap").size() == 1 and evs_of("bone_needle", "cast").is_empty(), "C: ...one reap event, no needle shot")
	var cd := caster.cooldown_left("bone_needle")
	check(cd <= float(T["cooldownMs"]) + 5.0 and absf(cd - maxf(0.0, float(T["cooldownMs"]) - 300.0)) < 100.0, "C: ...the swing's own cooldown, 0.3 s into it (%.0f left of %d ms)" % [cd, int(T["cooldownMs"])])
	# range: past the scythe's reach the swing is refused
	reset({}, lo)
	var distant := foe(Vector3(0, 0, -18.0 - reach * 2.5))
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
		var v := foe(Vector3(0, 0, -18.0 - reach * 0.8))
		var miss := foe(Vector3(0, 0, -18.0 - reach - 2.5))   # past the victim: out of the swing's reach, inside the shard's
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
	var vv := foe(Vector3(0, 0, -18.0 - reach * 0.8))
	for i in 5:
		caster.p["cooldowns"].clear()
		caster.p["castUntil"] = 0.0
		caster.request_cast("bone_needle", pos_of(vv), eid(vv))
		await secs(0.2)
	check(evs_of("bone_needle", "reap").size() == 5 and evs_of("bone_needle", "cast").is_empty(), "C: scythe + Volley - no volley (it is the needle's rune, as the current client): %d swings, %d shots" % [evs_of("bone_needle", "reap").size(), evs_of("bone_needle", "cast").size()])

	# ---- the soul window: a kill of a reaped enemy banks one more soul (1.2 s), asked once
	reset({}, lo)
	hb.set_facing(PI)
	var s1 := foe(Vector3(0, 0, -18.0 - reach * 0.8))
	var s2 := foe(Vector3(0, 0, -18.0 - reach * 4.0))
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
	var plain_soul := after_other - after_again   # what an enemy the swing never touched banks
	check(plain_soul > 0.0 and after_reaped == plain_soul + float(T["soulsPerKill"]) and after_again - after_reaped == plain_soul, "C: scythe souls - the reaped kill banks %d more than a plain one, a second kill of it a plain one (%s)" % [int(T["soulsPerKill"]), str([after_reaped, after_again - after_reaped, plain_soul])])
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.request_cast("bone_needle", pos_of(s1), eid(s1))
	await secs(float(T["reapWindowMs"]) / 1000.0 + 0.3)
	hb.p["souls"] = 0.0
	g.rewards.killer_paid.emit(cid, "robber", s1)
	check(float(hb.p["souls"]) == plain_soul, "C: ...and nothing more once the %.1f s window has passed (%s)" % [float(T["reapWindowMs"]) / 1000.0, str(hb.p["souls"])])

	# ---- the swing's gesture (the current client plays "attack" 2.6 with the scythe's own 0.3 s, no weapon clip) instead of the needle's cast
	var av := RecAvatar.new()
	var row: Array = DmRiteGestures.REAP
	check(DmRiteGestures.has(DmRiteGestures.REAP_KEY) and DmRiteGestures.play(av, DmRiteGestures.REAP_KEY, 0.0) and av.calls == [[row[0], row[1], float(T["gestureSeconds"]), row[3]]], "C: the scythe's gesture row is what the swing plays, with the scythe's own gesture time (%s)" % str(av.calls))
	reset({}, lo)
	var g0 := caster.gestures_played
	var gy := foe(Vector3(0, 0, -18.0 - reach * 0.8))
	caster.request_cast("bone_needle", pos_of(gy), eid(gy))
	await secs(0.2)
	check(caster.gestures_played == g0 + 1, "C: an accepted swing plays one gesture")

	# ---- the boss is struck with its own reach (bossReach) and counted besides maxHits
	reset({}, lo)
	check(summon() == "", "C: summon the King for the scythe")
	step(2.5)
	var bp := boss.global_position
	hb.teleport(bp + Vector3(0, 0, (reach + float(T["bossReach"])) * 0.5 + 0.7))   # between the plain reach and the boss reach
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


# =========================================================================================================================== E: the legion's events, the toxic pool's level

## Every "toxic" blow on the hero and every bell heal / plague pool the core told, for the cases below (a lambda cannot count into a local, so a Dictionary).
var _seen := {"toxic": [], "heals": 0, "swings": 0, "pools": []}


func _legion_events() -> void:
	host.target_hit.connect(func(_id: int, target: int, kind: int, damage: float) -> void:
		if target == hb.core_id and DmCoreEvents.HIT_KINDS[kind] == "toxic":
			(_seen["toxic"] as Array).append(damage))
	host.thrall_bell_heal.connect(func(_id: int, _x: float, _z: float, _f: float) -> void: _seen["heals"] = int(_seen["heals"]) + 1)
	host.thrall_swing.connect(func(_id: int, _sw: int, _t: int, _ax: float, _az: float, _d: float) -> void: _seen["swings"] = int(_seen["swings"]) + 1)
	host.thrall_plague_pool.connect(func(id: int, x: float, z: float, r: float, secs_: float, dps: float) -> void: (_seen["pools"] as Array).append([id, x, z, r, secs_, dps]))
	await _toxic_level()
	await _bell()
	await _plague_pool()


## The damage a toxic pool's pulse does at an area level, from the data (the core's TOXIC_DMG x the damage scale of combat/enemies.json).
func toxic_pulse(level: int) -> float:
	var ds: Dictionary = DmCombatData.enemies()["damage_scale"]
	return float(core.tuning()["TOXIC_DMG"]) * (float(ds["base"]) + float(ds["per_level"]) * float(level - 1))


## A Carrion Sac made at `level` in `area` falls beside the hero and its toxic corpse ruptures into a pool under him: the first pulse's damage (-1 when none came).
func first_pulse(area: String, level: int, where: Vector3) -> float:
	reset()
	hb.teleport(where)
	(_seen["toxic"] as Array).clear()
	var sac := host.spawn_enemy("sac", where + Vector3(0.5, 0.0, 0.0), level, 1.0, 1.0, false, area, false)
	core.stun(sac, 3600.0)
	host.damage(sac, 1.0e9, 0)
	var wait := float(core.tuning()["TOXIC_RUPTURE"]) + 2.0 * float(core.tuning()["TOXIC_TICK"]) + 1.5   # the rupture, then the first pulse
	await until(func() -> bool: return not (_seen["toxic"] as Array).is_empty(), wait)
	var got: Array = _seen["toxic"]
	hb.teleport(where + Vector3(0.0, 0.0, 12.0))   # out of the pool, which runs on for its seconds
	hb.heal(1e6)
	return float(got[0]) if not got.is_empty() else -1.0


func _toxic_level() -> void:
	var lv_a := 9
	var lv_b := 23
	var lv_c := 14
	var a := await first_pulse("graves", lv_a, Vector3(0, 0, -18))
	check(a > 0.0 and absf(a - toxic_pulse(lv_a)) < 0.001, "E: a toxic corpse's pool hurts at the area's level: level %d, %.2f a pulse, want %.2f (level 1 would be %.2f)" % [lv_a, a, toxic_pulse(lv_a), toxic_pulse(1)])
	var b := await first_pulse("graves", lv_b, Vector3(14, 0, -18))
	check(b > 0.0 and absf(b - toxic_pulse(lv_b)) < 0.001, "E: ...and follows the area when its enemies are made at another level: level %d, %.2f, want %.2f" % [lv_b, b, toxic_pulse(lv_b)])
	var c := await first_pulse("ossuary", lv_c, Vector3(28, 0, -18))
	check(c > 0.0 and absf(c - toxic_pulse(lv_c)) < 0.001, "E: ...each area has its own: the Ossuary at level %d, %.2f, want %.2f (the Graves are at %d)" % [lv_c, c, toxic_pulse(lv_c), lv_b])


## A wraith raised with the Mourning Bell strikes a foe: each blow mends the hero near it for the bell's share of HIS maximum health. Out of the bell's range nothing.
func _bell() -> void:
	reset()
	var tuning: Dictionary = DmCombatData.load_json("necro_weapons")["tuning"]["mourning_bell"]
	var frac := float(tuning["allyHealFrac"])
	var spec := SCYTHE_SPEC.duplicate()
	spec["kind"] = "wraith"
	spec["allyHeal"] = frac
	_seen["heals"] = 0
	_seen["swings"] = 0
	var wraith := raise_at(hb.position + Vector3(2.0, 0.0, 0.0), spec)
	check(wraith != 0 and absf(float(core.thrall_info(wraith)["ally_heal"]) - frac) < 1e-6, "E: a wraith raised with the Mourning Bell carries its share (%.3f)" % frac)
	foe(hb.position + Vector3(2.0, 0.0, 5.0))
	var max_hp := float(hb.p["stats"]["maxHp"])
	hb.p["hp"] = max_hp * 0.3
	var plain: Array[float] = []   # what a tick with no bell heal gives the hero (his own regeneration)
	var healed: Array[float] = []  # a tick with one
	var heals_before := 0
	var prev := float(hb.p["hp"])
	for i in 900:
		await physics_frame
		var now_hp := float(hb.p["hp"])
		if int(_seen["heals"]) > heals_before:
			healed.append(now_hp - prev)
		else:
			plain.append(now_hp - prev)
		heals_before = int(_seen["heals"])
		prev = now_hp
		if healed.size() >= 3:
			break
	check(healed.size() >= 3 and int(_seen["heals"]) == int(_seen["swings"]), "E: the wraith strikes and the core tells a bell heal at each blow (%d heals, %d blows)" % [int(_seen["heals"]), int(_seen["swings"])])
	plain.sort()
	var regen := plain[plain.size() / 2] if not plain.is_empty() else 0.0
	var ok := not healed.is_empty()
	for d in healed:
		ok = ok and absf((d - regen) - max_hp * frac) < max_hp * 0.0005
	check(ok, "E: each blow mends the hero by %.2f%% of his maximum health (%s beyond the %.3f a tick he mends alone)" % [frac * 100.0, ", ".join(healed.map(func(d: float) -> String: return "%.2f" % (d - regen))), regen])
	# The reach, exactly: the point of the blow 1 m inside the bell's range heals him, 1 m outside does not (the signal the core's event becomes).
	var reach := float(tuning["allyHealRange"])
	hb.p["hp"] = max_hp * 0.3
	var at := hb.position
	host.thrall_bell_heal.emit(0, at.x + reach + 1.0, at.z, frac)
	check(absf(float(hb.p["hp"]) - max_hp * 0.3) < 1e-6, "E: a blow %.0f m from him (the bell reaches %.0f) mends nobody" % [reach + 1.0, reach])
	host.thrall_bell_heal.emit(0, at.x + reach - 1.0, at.z, frac)
	check(absf(float(hb.p["hp"]) - (max_hp * 0.3 + max_hp * frac)) < 1e-3, "E: a blow %.0f m from him mends him %.2f" % [reach - 1.0, max_hp * frac])
	hb.p["hp"] = 0.0
	hb.p["alive"] = false
	host.thrall_bell_heal.emit(0, at.x, at.z, frac)
	check(float(hb.p["hp"]) == 0.0, "E: ...and a fallen hero is not mended")
	hb.p["alive"] = true
	hb.heal(1e6)


## A plague bearer falls beside a foe: the pool it leaves is the owner's rot cloud, it slows and withers what stands in it, and it runs out. A crumbled bearer leaves none.
func _plague_pool() -> void:
	reset()
	var P: Dictionary = DmCombatData.statuses()["PLAGUE_BURST"]
	var at := hb.position + Vector3(3.0, 0.0, 0.0)
	var bearer := _bearer(at)
	check(bearer != 0 and String(core.thrall_info(bearer)["kind"]) == "plaguebearer", "E: a corpse of a Carrion Sac rises as a plague bearer")
	var victim := foe(at + Vector3(float(P["poolRadius"]) * 0.5, 0.0, 0.0))
	(_seen["pools"] as Array).clear()
	var dmg := float(core.thrall_info(bearer)["damage"])
	var zones_before := (caster.mem("miasma").get("zones", []) as Array).size()
	core.kill_thrall(bearer, "killed")
	await ticks(3)
	var pools: Array = _seen["pools"]
	check(pools.size() == 1 and absf(float(pools[0][3]) - float(P["poolRadius"])) < 1e-4 and absf(float(pools[0][4]) - float(P["poolMs"]) / 1000.0) < 1e-4 and absf(float(pools[0][5]) - dmg * float(P["poolDpsShare"])) < 1e-3 * dmg,
		"E: the core tells one pool, %s m wide for %s s at the bearer's damage x %s" % [str(P["poolRadius"]), str(float(P["poolMs"]) / 1000.0), str(P["poolDpsShare"])])
	var zones: Array = caster.mem("miasma").get("zones", [])
	var made: Dictionary = zones.back() if zones.size() > zones_before else {}
	check(not made.is_empty() and made["kind"] == "rot" and absf(float(made["x"]) - at.x) < 0.01 and absf(float(made["z"]) - at.z) < 0.01 and absf(float(made["r"]) - float(P["poolRadius"])) < 1e-4,
		"E: the fallen bearer's owner now has a rot pool where it stood (%d zones, was %d)" % [zones.size(), zones_before])
	check(not made.is_empty() and absf(float(made["dps"]) - dmg * float(P["poolDpsShare"])) < 1e-3 * dmg, "E: ...its Withered does the bearer's damage x the pool share a second")
	var drawn := evs_of("miasma", "pool")
	check(drawn.size() == 1 and absf(float(drawn[0]["ev"]["r"]) - float(P["poolRadius"])) < 1e-4 and absf(float(drawn[0]["ev"]["life"]) - float(P["poolMs"]) / 1000.0) < 1e-4, "E: ...and every peer is told to draw it (one \"pool\" event, %d)" % drawn.size())
	await secs(1.3)   # the first pulse
	check(status_stacks(victim, &"withered") >= 1 and status_stacks(victim, &"slow") >= 1, "E: a foe in the pool is withered (%d) and slowed (%d)" % [status_stacks(victim, &"withered"), status_stacks(victim, &"slow")])
	await secs(float(P["poolMs"]) / 1000.0)
	zones = caster.mem("miasma").get("zones", [])
	check(zones.size() == zones_before and status_stacks(victim, &"slow") == 0, "E: the pool runs out after %s s and the slow lifts with it" % str(float(P["poolMs"]) / 1000.0))
	# A bearer that crumbles (over the cap, its owner gone) does not burst and leaves nothing.
	var crumbler := _bearer(hb.position + Vector3(-3.0, 0.0, 0.0))
	(_seen["pools"] as Array).clear()
	core.kill_thrall(crumbler, "crumbled")
	await ticks(3)
	check((_seen["pools"] as Array).is_empty() and (caster.mem("miasma").get("zones", []) as Array).size() == zones_before, "E: a crumbled plague bearer leaves no pool")


## A plague bearer of the hero's legion at `pos`: a toxic corpse of a Carrion Sac raised by an ordinary exhume (the rising thrall stands up after a moment).
func _bearer(pos: Vector3) -> int:
	g.corpses.add_corpse(pos.x, pos.z, "toxic", "sac", false, 0.0, 1.0, "graves")
	var r: Dictionary = legion().raise(SCYTHE_SPEC, pos)
	return int((r["thralls"] as Array)[0]) if bool(r["ok"]) and not (r["thralls"] as Array).is_empty() else 0


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
		# (that it casts, draws and makes a sound at all is tests/spells/run.gd's, for every spell of the playable kits)
		check(lost.is_empty(), "D: %s - the rebuild plays every sound the old client did (missing %s; rejected: %s)" % [id, str(lost), str(got["why"])])
		check(int(got["early"]) >= 3, "D: %s shows a visible cue at the cast (%d visual calls in 0.25 s)" % [id, int(got["early"])])
		check(int(got["early_sounds"]) > 0, "D: %s makes a sound at the cast" % id)
		if not lost.is_empty():
			missing.append([id, lost])
