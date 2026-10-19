extends SceneTree
## Combat-readability polish of the rebuilt client (client/next/feel/README.md), one process: godot --headless --path client --script res://tests/next_clarity/run.gd
##   1. the floating-number budget, the action bar's "no corpse / no legion" state, the red legion pips (the core's thrall arrays through the HUD view-model)
##   2. cues: every one of the 35 rites gives a visible AND an audible cue in the 0.25 s after an accepted cast (never silent, never only on landing).
## The enemies are static bodies of the combat core (stunned for an hour, harmless), the corpses and the legion are the core's, as tests/rites.gd has them.
## Not here: the low-health ring on a thrall's own body (a thrall is a core body drawn by the crowd now; the pips are what remains of that polish).

const DT := 1.0 / 60.0
const NONVIS := ["sfx", "loop", "gesture", "shake", "float"]
const RISING := 0
const WARRIOR := {"kind": "warrior", "cap": 6.0, "hp": 500.0, "damage": 10.0, "attackSpeedMult": 1.0, "r": 0.8}


## Recording audio back-end (the same two calls DmRiteFx makes).
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


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var passed := 0
var failed := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var api: DmApi
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var caster: DmRiteCaster
var foes: Array[int] = []
var results := {}   ## rite -> {early, sfx, why}


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func frames(n: int) -> void:
	for i in n:
		await process_frame


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func secs(s: float) -> void:
	await ticks(int(s / DT))


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	_budget()
	_needs_pure()
	await _slot_widget()
	await _game()
	await _cues()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%d passed, %d failed" % [passed, failed])
	print("%s next_clarity %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


# ---- the float budget ----------------------------------------------------------------------------------------------------------------

func _budget() -> void:
	var b := DmFloatBudget.new()
	var ok := 0
	for i in 40:
		if b.allow("thrall", 1000.0):
			ok += 1
	check(ok == DmFloatBudget.CLASS_CAP["thrall"], "thrall numbers are capped at %d alive (got %d)" % [DmFloatBudget.CLASS_CAP["thrall"], ok])
	check(b.allow("thrall", 1000.0 + DmFloatBudget.LIFE_MS["thrall"] + 1.0), "room again once they have faded")
	b = DmFloatBudget.new()
	ok = 0
	for i in 40:
		if b.allow("dot", 0.0):
			ok += 1
	check(ok == DmFloatBudget.CLASS_CAP["dot"], "dot numbers are capped at %d alive (got %d)" % [DmFloatBudget.CLASS_CAP["dot"], ok])
	b = DmFloatBudget.new()
	for i in 30:
		b.allow("hit", 0.0)
	check(not b.allow("hit", 0.0) and b.allow("crit", 0.0), "a full hit class still has room for a crit")
	b = DmFloatBudget.new()
	var shown := 0
	for i in 60:
		for k in ["hit", "dot", "thrall", "crit"]:
			if b.allow(k, 0.0):
				shown += 1
	check(shown <= DmFloatBudget.TOTAL_CAP + 4, "never more than the hard total at once (%d)" % shown)
	check(b.allow("hurt", 0.0) and b.allow("gold", 0.0) and b.allow("heal", 0.0), "hurt / gold / heal floats are never limited")
	var t0 := Time.get_ticks_usec()
	var bb := DmFloatBudget.new()
	for i in 20000:
		bb.allow("hit", float(i % 5000))
	var us := float(Time.get_ticks_usec() - t0) / 20000.0
	print("float budget allow(): %.3f us per call" % us)
	perf_info(us < 20.0, "allow() costs %.2f us" % us)


# ---- action bar --------------------------------------------------------------------------------------------------------------------

func _needs_pure() -> void:
	for id in DmNextHudVm.NEEDS:
		var kind: String = DmNextHudVm.NEEDS[id]
		check(DmNextHudVm.needs_of(id, false, 0) == kind, "%s needs a %s when there is none" % [id, kind])
		check(DmNextHudVm.needs_of(id, true, 3) == "", "%s is usable with a corpse and a legion" % id)
	check(DmNextHudVm.needs_of("marrow_spear", false, 0) == "", "a rite that needs neither is never flagged")
	# every rite whose validate() can refuse no_corpse / no_thralls is listed (read from the sources, so a new one cannot be forgotten)
	for id in DmRiteRegistry.ids():
		var src := FileAccess.get_file_as_string("res://next/rites/rite_%s.gd" % id)
		if src.contains("\"no_corpse\""):
			check(DmNextHudVm.NEEDS.get(id, "") == "corpse", "%s refuses no_corpse, so the bar flags it" % id)
		if src.contains("\"no_thralls\""):
			check(DmNextHudVm.NEEDS.get(id, "") == "legion", "%s refuses no_thralls, so the bar flags it" % id)


func _slot_widget() -> void:
	var s := DmHudSlot.new()
	root.add_child(s)
	await frames(1)
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 0.0, "total_ms": 1000.0, "affordable": true, "needs": "corpse"})
	check(s._need.text == "no corpse", "slot says 'no corpse' (%s)" % s._need.text)
	check(s._dim == DmHudAtlas.DIM_SOFT, "slot icon is dimmed (the atlas's lighter grey: only a need)")
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 1500.0, "total_ms": 3000.0, "affordable": true, "needs": "corpse"})
	check(s._need.text == "", "the note gives way to the cooldown number")
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 0.0, "total_ms": 1000.0, "affordable": true, "needs": ""})
	check(s._need.text == "" and s._dim == 0, "a usable slot is clean")
	s.apply({"icon": "", "key": "2", "cost": 12, "left_ms": 0.0, "total_ms": 1000.0, "affordable": true, "locked": true, "unlock_level": 8, "needs": "corpse"})
	check(s._need.text == "", "a locked slot shows its unlock level, not the note")
	s.queue_free()


# ---- in the game: the bar, the legion ----------------------------------------------------------------------------------------------

## A static enemy of the core: stunned for an hour (it stands where it is), harmless, with health to spare. Returns its id.
func foe(at: Vector3, def_id := "robber") -> int:
	var id := host.spawn_enemy(def_id, at, 1, 1000.0, 0.0, false, "graves", false)
	core.stun(id, 3600.0)
	foes.append(id)
	return id


func corpse(at: Vector3, kind := "normal") -> int:
	return g.corpses.add_corpse(at.x, at.z, kind, "robber", false, 0.0, 1.0, "graves")


func legion() -> DmCoreLegion:
	return caster.thralls()


## A thrall of the legion at `pos` the way an exhume raises one (a corpse is laid there, the legion raises from it): its id.
func raise_at(pos: Vector3, spec: Dictionary = WARRIOR) -> int:
	corpse(pos)
	var r: Dictionary = legion().raise(spec, pos)
	return int((r["thralls"] as Array)[0]) if bool(r["ok"]) and not (r["thralls"] as Array).is_empty() else 0


func clear_world() -> void:
	for id in core.enemy_ids():
		host.remove_enemy(int(id))
	foes.clear()
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	for id in core.thrall_ids():
		core.kill_thrall(id, "crumbled")
	caster._pending.clear()
	caster._mem.clear()


func reset() -> void:
	clear_world()
	hero.teleport(Vector3(0, 0, -18))
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	caster.p["rootedUntil"] = 0.0
	hero.heal(1e6)


func _game() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("cl%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(1)   # Ossuary
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false, "audio": false, "hud": true, "areas": ["graves"]})
	host = g.core_host
	core = host.core
	var b := g.local_body()
	hero = b
	caster = b.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	await frames(20)
	clear_world()
	var vm: Dictionary = g.ui_host.hud_state()
	var corpse_slot := func() -> bool:
		for sl in vm["slots"]:
			if String(sl.get("needs", "")) == "corpse":
				return true
		return false
	check(corpse_slot.call(), "with no corpse the bar flags a corpse rite (exhume / explosion are in the Ossuary's kit)")
	check(not vm["slots"].is_empty() and vm["primary"].get("needs", "") == "", "the primary is never flagged")
	var cpse := corpse(b.global_position + Vector3(2.0, 0, 0))
	await frames(2)
	vm = g.ui_host.hud_state()
	check(not corpse_slot.call(), "a corpse within reach clears the flag")
	g.corpses.consume(cpse, 1, "consumed")
	corpse(b.global_position + Vector3(40.0, 0, 0))
	g.ui_host.vm._refresh_needs(b)   # the needs are read once per refresh, not at every state build
	vm = g.ui_host.hud_state()
	check(corpse_slot.call(), "a corpse 40 m away does not count")
	# the needs pass costs next to nothing (the whole build is ~0.6 ms headless, of which this is a few us)
	var t0 := Time.get_ticks_usec()
	for i in 500:
		g.ui_host.vm._refresh_needs(b)
		DmNextHudVm._legion_hurt(core, b.core_id)
	var us := float(Time.get_ticks_usec() - t0) / 500.0
	print("needs + legion pass: %.1f us per build" % us)
	perf_info(us < 40.0, "the needs / legion pass stays cheap (%.1f us)" % us)

	# the legion: hurt pips
	clear_world()
	var ts: Array[int] = []
	for k in 3:
		ts.append(raise_at(b.global_position + Vector3(2 + k, 0, 0)))
	check(ts.all(func(t: int) -> bool: return t != 0), "three thralls rise from three corpses")
	await until(func() -> bool: return ts.all(func(t: int) -> bool: return int(legion().info(t)["state"]) != RISING), 8.0)   # until the raised thralls have stood up (sim ticks, no wall-clock timer)
	vm = g.ui_host.hud_state()
	check(int(vm["thrall_hurt"]) == 0, "a healthy legion shows no red pips (%d)" % int(vm["thrall_hurt"]))
	var max0 := float(legion().info(ts[0])["max_hp"])
	core.set_thrall_stats(ts[0], {"hp": max0 * 0.2})
	await frames(3)
	vm = g.ui_host.hud_state()
	check(int(vm["thrall_hurt"]) == 1, "a thrall at 20 %% health turns one pip red (%d)" % int(vm["thrall_hurt"]))
	core.set_thrall_stats(ts[0], {"hp": max0 * 0.8})   # a Rally heal
	await frames(3)
	check(int(g.ui_host.hud_state()["thrall_hurt"]) == 0, "healed past a third: the pip goes back")
	# the HUD part: Diamonds paint a state of 2 red
	var d := DmHudParts.Diamonds.new()
	d.set_state([2, 1, false])
	check(d.on[0] == 2 and d.fill_hurt != d.fill_on, "Diamonds know a hurt state")
	d.free()
	clear_world()


# ---- every rite gives a cue --------------------------------------------------------------------------------------------------------

func _vis(s: Dictionary) -> int:
	var n := 0
	for k in s:
		if not NONVIS.has(k):
			n += int(s[k])
	return n


func _cues() -> void:
	var ids: Array = DmRiteRegistry.ids()
	check(ids.size() == 35, "35 rites are registered (%d)" % ids.size())
	for id in ids:
		await audit_rite(id)
		var r: Dictionary = results[id]
		check((r["why"] as Array).is_empty(), "%s casts in the audit scene (refused %s)" % [id, str(r["why"])])
		check(int(r["early"]) >= 3, "%s shows a visible cue at the cast (%d visual calls in 0.25 s)" % [id, int(r["early"])])
		check(not (r["sfx"] as Array).is_empty(), "%s makes a sound at the cast (%s)" % [id, str(r["sfx"])])


## One rite cast in a scene of seven enemies, six corpses and two thralls: the visual primitives DmRiteFx fires in the cast window (the first 0.25 s after the
## accepted cast) and the sounds it plays. A rite with none in the cast window gives no cue at the moment of the press.
func audit_rite(id: String) -> void:
	reset()
	hero.teleport(Vector3(0, 0, -16))
	for i in 7:
		var a := float(i) / 7.0 * TAU
		foe(Vector3(cos(a) * 3.5, 0, -16.0 + sin(a) * 3.5))
	var best := -1
	var best_at := Vector3(3, 0, -16)
	for i in 6:
		var a2 := float(i) / 6.0 * TAU + 0.3
		var at := Vector3(cos(a2) * 2.2, 0, -16.0 + sin(a2) * 2.2)
		var cp := corpse(at)
		if best == -1:
			best = cp
			best_at = at
	for k in 2:
		raise_at(hero.global_position + Vector3(2 + k, 0, 0))
	await until(func() -> bool: return core.thrall_ids().size() >= 2 and Array(core.thrall_ids()).all(func(t: int) -> bool: return int(legion().info(t)["state"]) != RISING), 6.0)   # Command: Rend needs a standing legion
	var rec := RecAudio.new()
	caster.fx.audio = rec
	caster.p["castUntil"] = 0.0
	caster.p["cooldowns"].clear()
	caster.p["resource"]["value"] = 900.0
	var why: Array = []
	var rj := func(_r: String, w: String) -> void: why.append(w)
	caster.cast_rejected.connect(rj)
	var before: Dictionary = caster.fx.stats.duplicate()
	var def := DmAbilities.def(id)
	if String(def.get("targeting", "ground")) == "enemy":
		caster.request_cast(id, host.enemy_position(foes[0]), foes[0])
	else:
		caster.request_cast(id, best_at, -1)
	await secs(0.25)
	var early := {}
	for k in caster.fx.stats:
		early[k] = int(caster.fx.stats[k]) - int(before[k])
	caster.cast_rejected.disconnect(rj)
	results[id] = {"early": _vis(early), "sfx": rec.sfx.duplicate(), "why": why}
	print("RITE %-16s early_vis=%2d sfx=%s%s" % [id, _vis(early), str(rec.sfx), ("  REJECTED " + str(why)) if not why.is_empty() else ""])


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
