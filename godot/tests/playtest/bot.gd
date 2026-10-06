extends SceneTree
## Automated playtest bot for the Godot client (offline edition only: DmMockBackend under user://, never the live server).
## Drives the real Main scene (front flow -> DmGame -> DmGameUi) with real key / mouse events where the camera allows it.
##   godot [--headless] --path godot --script res://tests/playtest/bot.gd -- --session=A --disc=2 --out=/abs/report.json [--boss=gravedigger]
##   session A: new account + character, every flow, then window-close save.  session B: relaunch, log in, verify the save persisted.
## Run it through tools/godot/playtest.sh (isolated XDG_DATA_HOME so the real offline save is never touched).
## Findings are recorded (not fatal): the report JSON holds every failed check + bug with severity; the process exits non-zero when any exist.

const PANEL_KEYS := {"inventory": KEY_I, "sheet": KEY_J, "legion": KEY_Y, "forge": KEY_C, "professions": KEY_P, "contracts": KEY_O, "garden": KEY_U,
	"labor": KEY_H, "cosmetics": KEY_N, "vault": KEY_V, "map": KEY_M, "codex": KEY_K, "atlas": KEY_PERIOD, "grimoire": KEY_L}

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _bt: Array) -> void:
		errors.append({"fn": function, "file": file, "line": line, "msg": rationale if rationale != "" else code, "type": error_type})
	func _log_message(_m: String, _e: bool) -> void:
		pass

## Runs after every other node's _process: with Monitor (first) it brackets the frame's process phase.
class Tail extends Node:
	var bot
	func _process(_dt: float) -> void:
		bot.tail_us = Time.get_ticks_usec()

class Monitor extends Node:
	var bot
	var dts: Array = []
	var play_dts: Array = []   # frames outside the loading phases (boot/front/relaunch): what a player sees
	var skip := 0
	var last_us := 0
	func _process(dt: float) -> void:
		var now := Time.get_ticks_usec()
		# The slice of the previous frame: [head .. tail] = every node's _process, [tail .. signal] = deferred calls + engine
		# (physics, render), [signal .. head] = the bot's own coroutines resumed on process_frame (key presses, panel opens, checks).
		bot.sl_proc = (bot.tail_us - bot.head_us) / 1000.0
		bot.sl_engine = (bot.pf_us - bot.tail_us) / 1000.0
		bot.sl_bot = (now - bot.pf_us) / 1000.0
		bot.head_us = now
		skip += 1
		if skip > 120 and last_us > 0:
			var ms := (now - last_us) / 1000.0
			dts.append(ms)   # wall-clock frame time (Engine.time_scale does not distort it)
			if not bot.phase_name in bot.LOADING_PHASES:
				play_dts.append(ms)
			if ms > 50.0:
				bot.on_hitch(ms)
		last_us = now
		bot.on_frame(dt)
		bot.on_frame_prof()

## Phases where the game builds its world behind the loading screen: their long frames are loads, not play stalls.
const PLAY_BUDGET_MS := 150.0
const LOADING_PHASES := ["boot", "front", "relaunch"]
var tail_us := 0
var head_us := 0
var pf_us := 0
var sl_proc := 0.0
var sl_engine := 0.0
var sl_bot := 0.0
var errlog := ErrLog.new()
var mon: Monitor
var session := "A"
var disc := 2
var boss_pick := "gravedigger"
var out_path := ""
var scale := 3.0
var shots_dir := ""
var name_ := "pt"
var main: DmMain
var sv: SubViewport   # the game lives in a 1280x800 SubViewport: headless root is 64x64 and ignores pushed mouse input
var g: DmGame
var ui
var findings: Array = []
var notes: Array = []
var ev_counts: Dictionary = {}
var overlay: DmPerfOverlay
var rendered := false
var _shot_n := 0
var watch := {"gold_drop_ok": false}
var last_gold := 0
var last_lv := 0.0
var last_pos := Vector2.ZERO
var last_pos_t := 0.0
var walking := false
var moved_flag := false
var sane_t := 0.0
var deaths_seen := 0
var respawns_seen := 0
var stats := {"kills": 0, "max_enemies": 0, "max_thralls": 0}
var phase_name := ""
var t0_ms := 0
var _rot := 0
var overlay_note_ms := 0
var skip_to := ""
var delay_ms := 0.0   # extra reaction delay between bot actions (difficulty check: compare 0 vs 300 ms)
var assist_hp := 0.0   # >0: keep the hero above this hp fraction (noted assist for depths/boss flows)
var toasts: Array = []


func _initialize() -> void:
	OS.add_logger(errlog)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--session="): session = a.substr(10)
		elif a.begins_with("--disc="): disc = int(a.substr(7))
		elif a.begins_with("--out="): out_path = a.substr(6)
		elif a.begins_with("--boss="): boss_pick = a.substr(7)
		elif a.begins_with("--scale="): scale = float(a.substr(8))
		elif a.begins_with("--shots="): shots_dir = a.substr(8)
		elif a.begins_with("--name="): name_ = a.substr(7)
		elif a.begins_with("--skip-to="): skip_to = a.substr(10)
		elif a.begins_with("--delay="): delay_ms = float(a.substr(8))
	rendered = DisplayServer.get_name() != "headless"
	if rendered:
		scale = minf(scale, 1.0)
	Engine.time_scale = scale
	t0_ms = Time.get_ticks_msec()
	_run.call_deferred()


# ---- reporting ---------------------------------------------------------------------------------------------------------------

func bug(sev: String, title: String, detail: String = "") -> void:
	for f in findings:
		if f["title"] == title:
			f["count"] += 1
			return
	findings.append({"sev": sev, "title": title, "detail": detail, "phase": phase_name, "disc": disc, "session": session, "count": 1})
	printerr("[BUG %s] %s | %s (%s)" % [sev, title, detail, phase_name])


func chk(ok: bool, title: String, detail: String = "", sev: String = "major") -> bool:
	if not ok:
		bug(sev, title, detail)
	else:
		print("  ok: ", title)
	return ok


func note(s: String) -> void:
	notes.append("[%s] %s" % [phase_name, s])
	print("  note: ", s)


## Slow frame: where the bot was and which DmGame.tick section grew most since the last frame (prof_on is set at world entry).
var _prof_prev: Dictionary = {}
func on_hitch(ms: float) -> void:
	var top := ""
	if g != null and is_instance_valid(g):
		var best := 0
		for k in g.prof:
			var dv: int = int(g.prof[k]) - int(_prof_prev.get(k, 0))
			if dv > best:
				best = dv
				top = "%s %.0fms" % [k, dv / 1000.0]
	print("HITCH %.0fms phase=%s area=%s tick-top=%s slices(proc/engine+deferred/bot-coroutines)=%.0f/%.0f/%.0f%s" % [ms, phase_name, (g.area_id if g != null and is_instance_valid(g) else "-"), top, sl_proc, sl_engine, sl_bot, " LOADING" if phase_name in LOADING_PHASES else ""])


func on_frame_prof() -> void:
	if g != null and is_instance_valid(g):
		g.prof_on = true
		_prof_prev = g.prof.duplicate()


func phase(n: String) -> void:
	phase_name = n
	print("== phase %s (game %.0fs, wall %.0fs)" % [n, (g.now_ms / 1000.0) if g != null else 0.0, (Time.get_ticks_msec() - t0_ms) / 1000.0])


func shot(tag: String) -> void:
	if shots_dir == "" or not rendered:
		return
	DirAccess.make_dir_recursive_absolute(shots_dir)
	_shot_n += 1
	sv.get_texture().get_image().save_png("%s/%s_%02d_%s.png" % [shots_dir, name_, _shot_n, tag])


func write_report() -> void:
	var errs := _script_errors()
	for e in errs:
		bug("critical", "SCRIPT ERROR: %s" % String(e["msg"]).left(120), "%s:%d in %s" % [e["file"], e["line"], e["fn"]])
	# Perf gate: a play frame (outside the loading phases) over PLAY_BUDGET_MS is a stall a player feels. The VPS is shared, so one
	# over-budget frame is only a minor finding (noise is possible); several, or one over 2x the budget, is major.
	var pd: Array = mon.play_dts.filter(func(v): return v > PLAY_BUDGET_MS) if mon != null else []
	if not pd.is_empty():
		var worst := 0.0
		for v in pd:
			worst = maxf(worst, v)
		bug("major" if (pd.size() >= 3 or worst > PLAY_BUDGET_MS * 2.0) else "minor", "play frames over the %.0f ms budget" % PLAY_BUDGET_MS,
			"%d frame(s), worst %.0f ms (HITCH lines in the log name the phase and slice)" % [pd.size(), worst])
	var rep := {"session": session, "disc": disc, "findings": findings, "notes": notes, "frame": frame_stats(), "stats": stats, "events": ev_counts,
		"engine_errors": errlog.errors.size(), "wall_s": (Time.get_ticks_msec() - t0_ms) / 1000.0, "rendered": rendered}
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(rep, "  "))
	print("PLAYTEST session=%s disc=%d findings=%d script_errors=%d frame=%s" % [session, disc, findings.size(), errs.size(), str(frame_stats())])


func finish() -> void:
	write_report()
	quit(1 if findings.size() > 0 else 0)


func _script_errors() -> Array:
	var out: Array = []
	var seen := {}
	for e in errlog.errors:
		if e["type"] == Logger.ERROR_TYPE_SCRIPT or e["type"] == Logger.ERROR_TYPE_SHADER or String(e["file"]).begins_with("res://"):
			var k := "%s:%d" % [e["file"], e["line"]]
			if not seen.has(k):
				seen[k] = true
				out.append(e)
	return out


func frame_stats() -> Dictionary:
	if mon == null or mon.dts.size() < 10:
		return {}
	var a: Array = mon.dts.duplicate()
	var pa: Array = mon.play_dts.duplicate()
	pa.sort()
	a.sort()
	var n := a.size()
	var sum := 0.0
	for v in a:
		sum += v
	return {"n": n, "avg_ms": snappedf(sum / n, 0.01), "p50_ms": snappedf(a[n / 2], 0.01), "p95_ms": snappedf(a[int(n * 0.95)], 0.01), "p99_ms": snappedf(a[int(n * 0.99)], 0.01),
		"worst_ms": snappedf(a[n - 1], 0.01), "over50ms": a.filter(func(v): return v > 50.0).size(),
		# play = every frame outside the loading phases (the world build behind the loading screen is one long frame by design)
		"play_worst_ms": snappedf(pa[pa.size() - 1], 0.01) if pa.size() > 0 else 0.0, "play_over50ms": pa.filter(func(v): return v > 50.0).size(),
		"play_over100ms": pa.filter(func(v): return v > 100.0).size(), "time_scale": scale}


# ---- input helpers (real events through the viewport) --------------------------------------------------------------------------

func key(code: Key, pressed: bool = true, shift: bool = false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	ev.shift_pressed = shift
	if (code >= KEY_A and code <= KEY_Z) or (code >= KEY_0 and code <= KEY_9):
		ev.unicode = code + (32 if code >= KEY_A else 0)
	sv.push_input(ev)


func tap(code: Key, hold_frames: int = 2) -> void:
	key(code, true)
	await frames(hold_frames)
	key(code, false)
	await frames(1)


func frames(n: int) -> void:
	for i in n:
		await process_frame


## Wait `sec` of game time (scaled by Engine.time_scale), at most sec*8+10 wall seconds.
func wait(sec: float) -> void:
	var start := g.now_ms if g != null else 0.0
	var wall := Time.get_ticks_msec()
	while (g.now_ms - start) < sec * 1000.0:
		await process_frame
		if Time.get_ticks_msec() - wall > (sec * 8.0 + 10.0) * 1000.0:
			bug("major", "game time does not advance (wait %.1fs took >%.0fs wall)" % [sec, sec * 8.0 + 10.0])
			return


func screen_of(x: float, y: float, z: float) -> Vector2:
	return g.camera.unproject_position(Vector3(x, y, z))


func mouse_to(p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = p
	ev.global_position = p
	sv.push_input(ev)


func click(p: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, shift: bool = false) -> void:
	mouse_to(p)
	for pr in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.position = p
		ev.global_position = p
		ev.button_index = button
		ev.pressed = pr
		ev.shift_pressed = shift
		sv.push_input(ev)
		await process_frame


func alive_enemies() -> Array:
	var out: Array = []
	for e in g.sim.enemies.values():
		if e.state != "dead" and e.hp > 0.0:
			out.append(e)
	return out


func nearest_enemy(area: String = "") -> DmSimEnemy:
	var best: DmSimEnemy = null
	var bd := 1e9
	for e in alive_enemies():
		if area != "" and e.area != area:
			continue
		var d := Vector2(e.x - g.player.x, e.z - g.player.z).length()
		if d < bd:
			bd = d
			best = e
	return best


func panel_is_open() -> bool:
	return ui != null and ui.panel_open()


func hero_xy() -> Vector2:
	return Vector2(g.player.x, g.player.z)


# ---- per-frame monitors --------------------------------------------------------------------------------------------------------

func on_frame(dt: float) -> void:
	if g == null or not g.ready_:
		return
	sane_t += dt
	if sane_t < 0.25:
		return
	sane_t = 0.0
	var p := g.player
	if assist_hp > 0.0 and p.alive and p.hp < p.max_hp() * assist_hp:
		p.hp = p.max_hp() * assist_hp
	var hp := p.hp
	if is_nan(hp) or is_inf(hp) or hp < -0.001 or hp > p.max_hp() * 1.0001 + 0.001:
		bug("major", "hp out of range", "%.2f / %.2f" % [hp, p.max_hp()])
	var res: Dictionary = g.p["resource"]
	if float(res["value"]) < -0.001 or float(res["value"]) > float(res["max"]) + 0.001 or is_nan(float(res["value"])):
		bug("major", "resource out of range", "%s / %s" % [str(res["value"]), str(res["max"])])
	var lv := float(g.character["level"]) * 1.0e9 + float(g.character.get("experience", 0))
	if lv + 1.0 < last_lv and not watch.get("lv_reset_ok", false):
		bug("major", "level/xp went backwards", "%.0f -> %.0f" % [last_lv, lv])
	last_lv = lv
	var gold := int(g.character.get("gold", 0))
	if gold < last_gold and not watch.get("gold_drop_ok", false):
		bug("major", "gold decreased without a purchase", "%d -> %d" % [last_gold, gold])
	last_gold = gold
	stats["max_enemies"] = maxi(stats["max_enemies"], g.sim.enemies.size())
	var cap: int = int(DmContent.get_export("areas", "GLOBAL_ENEMY_CAP"))
	if g.sim.enemies.size() > cap + 12:
		bug("minor", "enemy count well above GLOBAL_ENEMY_CAP", "%d vs cap %d" % [g.sim.enemies.size(), cap])
	var tc: int = g.combat.my_thralls().size()
	stats["max_thralls"] = maxi(stats["max_thralls"], tc)
	if tc > int(g.discipline["mods"]["thrallCap"]) + 3:
		bug("major", "thralls exceed cap", "%d vs %s" % [tc, str(g.discipline["mods"]["thrallCap"])])
	var pos := hero_xy()
	if walking and g.player.alive:
		if pos.distance_to(last_pos) > 0.3:
			last_pos = pos
			last_pos_t = g.now_ms
		elif g.now_ms - last_pos_t > 6000.0:
			moved_flag = true
	else:
		last_pos = pos
		last_pos_t = g.now_ms
	if overlay != null and overlay.panel.visible and scale <= 1.0 and Time.get_ticks_msec() - overlay_note_ms > 30000:
		overlay_note_ms = Time.get_ticks_msec()
		var s := overlay.summary()
		if not s.is_empty():
			note("F3 overlay fps=%.1f avg=%.1fms p50=%.1f worst=%.0f hitches/s=%.2f" % [s["fps"], s["avg"], s["p50"], s["worst"], s["hitches"]])


func on_event(id: String, ctx: Dictionary) -> void:
	ev_counts[id] = int(ev_counts.get(id, 0)) + 1
	if id == "toast":
		toasts.append(String(ctx.get("text", "")))
		if toasts.size() > 6:
			toasts.pop_front()


func recent_toasts() -> String:
	return " | ".join(toasts)


# ---- movement ------------------------------------------------------------------------------------------------------------------

## Minimap-click travel (the player's real path). Returns true on arrival.
func walk_to(x: float, z: float, tol: float = 1.5, timeout: float = 40.0) -> bool:
	walking = true
	moved_flag = false
	last_pos_t = g.now_ms
	var start := g.now_ms
	var ok := g.navigate(x, z)
	while true:
		await process_frame
		if not g.player.alive:
			break
		if hero_xy().distance_to(Vector2(x, z)) <= tol:
			walking = false
			return true
		if not g.player.has_path():
			if hero_xy().distance_to(Vector2(x, z)) <= tol + 1.5:
				walking = false
				return true
			ok = g.navigate(x, z)
			if not ok:
				bug("major", "navigate() refuses a walkable target", "to (%.1f,%.1f) from (%.1f,%.1f) area=%s" % [x, z, g.player.x, g.player.z, g.player.area])
				break
		if moved_flag:
			bug("critical", "hero stuck while walking", "stopped at (%.1f,%.1f) heading to (%.1f,%.1f) area=%s" % [g.player.x, g.player.z, x, z, g.player.area])
			break
		if g.now_ms - start > timeout * 1000.0:
			bug("major", "walk timeout %.0fs" % timeout, "at (%.1f,%.1f) heading to (%.1f,%.1f) area=%s" % [g.player.x, g.player.z, x, z, g.player.area])
			break
	walking = false
	return false


# ---- combat bot ------------------------------------------------------------------------------------------------------------

## Fight for `sec` game-seconds. Mouse-aims at the nearest enemy, real hotkeys, flask when low, exhume corpses.
## mode "manual" (LMB chase + hotbar keys) or "auto" (G). Returns kills made.
func fight(sec: float, mode: String = "manual", area: String = "", stop_kills: int = 0) -> int:
	var start := g.now_ms
	var kills0: int = int(g.chronicle.view()["life"].get("kills", 0.0))
	var no_enemy_ms := 0.0
	var last := g.now_ms
	while g.now_ms - start < sec * 1000.0:
		await process_frame
		var dt := g.now_ms - last
		last = g.now_ms
		if not g.player.alive:
			await wait(0.5)
			continue
		if area != "" and g.area_id != area and not g.sim.boss.state.active:
			# respawned in the Chapterhouse (or recalled): walk back to the fight like a player would
			var ar: Dictionary = DmContent.area(area)["rect"] if area != "depths" else {}
			if not ar.is_empty():
				await walk_to((float(ar["x0"]) + float(ar["x1"])) * 0.5, (float(ar["z0"]) + float(ar["z1"])) * 0.5, 4.0, 60.0)
				continue
		if panel_is_open():
			await tap(KEY_ESCAPE)
			if panel_is_open():
				bug("critical", "panel cannot be closed with Esc during combat")
				close_all_panels()
		if g.player.hp < g.player.max_hp() * 0.45 and g.inventory.count("flask_hp_minor") > 0:
			await tap(KEY_Q)
		var e := nearest_enemy(area)
		if e == null:
			no_enemy_ms += dt
			if no_enemy_ms > 25000.0 and not g.sim.boss.state.active:
				bug("major", "no enemies for 25 s (spawn stall)", "alive=%d area=%s" % [g.sim.enemies.size(), g.area_id])
				no_enemy_ms = 0.0
			if mode == "manual":
				_rot += 1
				if _rot % 40 == 0:
					_wander()
			continue
		no_enemy_ms = 0.0
		if mode == "auto":
			if not bool(g.settings["autoCombat"]):
				await tap(KEY_G)
			continue
		await _manual_tick(e)
		if stop_kills > 0 and int(g.chronicle.view()["life"].get("kills", 0.0)) - kills0 >= stop_kills:
			break
	var k: int = int(g.chronicle.view()["life"].get("kills", 0.0)) - kills0
	stats["kills"] += maxi(k, 0)
	return k


func _manual_tick(e: DmSimEnemy) -> void:
	if delay_ms > 0.0:
		await wait(delay_ms / 1000.0)
		if not is_instance_valid(e) or e.state == "dead":
			return
	var sp := screen_of(e.x, 0.9 * e.scale, e.z)
	var vp := Vector2(sv.size)
	if sp.x < 4 or sp.y < 4 or sp.x > vp.x - 4 or sp.y > vp.y - 4:
		g.input.set_ground(e.x, e.z)
		g.input.hover = {"kind": "enemy", "id": e.id}
		g.input.on_primary_click()
	else:
		await click(sp)
	mouse_to(sp)
	_rot += 1
	var slot := (_rot % 6) + 1
	if g.sim.corpses.size() > 0 and g.actions.legion_places() < int(g.discipline["mods"]["thrallCap"]) and g.hotbar.has("exhume"):
		var c: DmSimCorpse = g.sim.corpses.values()[0]
		mouse_to(screen_of(c.x, 0.2, c.z))
		slot = g.hotbar.find("exhume") + 1
	var codes := [KEY_1, KEY_2, KEY_3, KEY_4]
	if slot == 5:
		await click(sp, MOUSE_BUTTON_RIGHT)
	elif slot == 6:
		await tap(KEY_R, 1)
	else:
		await tap(codes[slot - 1], 1)
	if g.player.hp < g.player.max_hp() * 0.45 and g.inventory.count("flask_hp_minor") == 0:
		g.inventory.add({"item_id": "flask_hp_minor", "quantity": 5})
		watch["assist"] = int(watch.get("assist", 0)) + 1
	await frames(6)


func _wander() -> void:
	var a: Dictionary = DmContent.area(g.area_id)
	if a.is_empty() or a.get("rect") == null:
		return
	var r: Dictionary = a["rect"]
	g.navigate(randf_range(float(r["x0"]) + 4.0, float(r["x1"]) - 4.0), randf_range(float(r["z0"]) + 4.0, float(r["z1"]) - 4.0))


func close_all_panels() -> void:
	if ui != null:
		ui.close_panels()


# ---- the run ---------------------------------------------------------------------------------------------------------------

func _wait_world() -> bool:
	for i in 3000:
		if main.game != null and main.game.ready_:
			g = main.game
			ui = main.ui
			return true
		await process_frame
	return false


func _run() -> void:
	phase("boot")
	sv = SubViewport.new()
	sv.size = Vector2i(1280, 800)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sv)
	main = load("res://main/main.tscn").instantiate()
	sv.add_child(main)
	mon = Monitor.new()
	mon.bot = self
	mon.process_priority = -100000
	root.add_child(mon)
	var tl := Tail.new()
	tl.bot = self
	tl.process_priority = 100000
	root.add_child(tl)
	process_frame.connect(func(): pf_us = Time.get_ticks_usec())
	await frames(8)
	chk(main.mode == "offline", "no args = offline edition (never the live server)", "", "critical")
	if session == "A":
		chk(main.flow != null and main.flow.current_name == "login", "login screen first", "got %s" % (main.flow.current_name if main.flow != null else "-"))
	if session == "A":
		await _session_a()
	else:
		await _session_b()
	finish()


func _account() -> Dictionary:
	return {"user": "bot_%d" % disc, "pw": "pw1234x"}


func _enter_world_fresh() -> bool:
	phase("front")
	var acct := _account()
	var r := await main.api.register(acct["user"], "bot@example.com", acct["pw"])
	if not chk(r.ok, "register offline account", str(r.error), "critical"):
		return false
	main.api.set_token(r.data["token"])
	await main.flow.resume()
	chk(main.flow.current_name == "select", "new account -> discipline select", main.flow.current_name)
	var c := await main.api.load_or_create_character(disc)
	if not chk(c.ok, "create character class %d" % disc, str(c.error), "critical"):
		return false
	var t_load := Time.get_ticks_msec()
	main.flow.go_world(c.data)
	var up := await _wait_world()
	chk(up, "world comes up", "", "critical")
	if not up:
		return false
	note("world load %.1fs wall" % ((Time.get_ticks_msec() - t_load) / 1000.0))
	g.game_event.connect(on_event)
	g.hero_died.connect(func(): deaths_seen += 1)
	g.hero_respawned.connect(func(): respawns_seen += 1)
	await frames(30)
	return true


func _session_a() -> void:
	if not await _enter_world_fresh():
		return
	var fam: String = g.discipline["id"]
	var want := {1: "ossuary", 2: "gravecaller", 3: "mourner", 4: "rotweaver", 0: "gravecaller"}
	chk(fam == want.get(disc, fam), "discipline matches class index", "%s vs %s" % [fam, want.get(disc)])
	note("discipline %s hotbar %s primary %s" % [fam, str(g.hotbar), g.primary])
	if skip_to != "":
		# developer shortcut: jump straight to a late phase with the prerequisites set directly (not a real run)
		g.character["level"] = 20
		g.refresh_stats()
		var need: int = g.prog.unlock_kills(float(DmContent.area("warren")["unlock"]["kills"]))
		for i in need:
			g.prog.record_kill("graves")
		g.check_unlocks()
		g.player.teleport(-52.0, -30.0)
		await frames(5)
		if skip_to == "depths":
			await _p_depths()
		await _p_boss()
		await _p_death()
		await _p_persist_snapshot()
		return
	await _p_start()
	_p_contract()
	await _p_panels()
	await _p_events()
	await _p_walk_to_graves()
	await _p_overlay()
	await _p_fight()
	await _p_loot_equip()
	await _p_levelup()
	await _p_seal_depths()
	await _p_boss()
	await _p_death()
	await _p_persist_snapshot()


const UI_GAME_METHODS := ["use_item", "set_belt", "set_rites", "near_grinder", "counsel_busy", "counsel_tick_ctx", "stop_gathering", "afk_active", "afk_status", "start_afk",
	"stop_player", "talk_key", "travel", "dial_wave", "send_chat", "leave_world", "party_create", "party_join", "party_leave", "summon_boss", "summon_boss_empowered",
	"enter_depths", "set_auto_combat", "buy_upgrade", "apply_settings", "refresh_character", "refresh_inventory", "refresh_progress", "hud_state"]

## DmGame <-> DmGameUi seam (GAME_CONTRACT.md): every method the UI calls through has_method guards must exist, or the feature silently does nothing.
func _p_contract() -> void:
	phase("contract")
	for m in UI_GAME_METHODS:
		chk(g.has_method(m), "DmGame implements contract method %s()" % m, "DmGameUi guards the call with has_method, so a missing method is a silent no-op", "major")
	# every game_event id DmGame can emit must be handled by the UI or be a counsel event (an unknown one logs a warning every time)
	var ui_src := FileAccess.get_file_as_string("res://game_ui/dm_game_ui.gd")
	var game_src := ""
	for f in DirAccess.get_files_at("res://game"):
		if f.ends_with(".gd"):
			game_src += FileAccess.get_file_as_string("res://game/" + f)
	var re := RegEx.new()
	re.compile("(?:emit_game_event|game_event\\.emit)\\(\"([a-z_0-9.]+)\"")
	var ids := {}
	for m in re.search_all(game_src):
		ids[m.get_string(1)] = true
	var unhandled: Array = []
	for id in ids:
		var counsel: bool = not (DmCounselEvents.table().get(id, []) as Array).is_empty()
		var handled: bool = ui_src.contains('"%s"' % id)
		if not counsel and not handled:
			unhandled.append(id)
	unhandled.sort()
	chk(unhandled.is_empty(), "every event DmGame emits is handled by the UI or is a counsel event", "unhandled: %s" % str(unhandled), "major")


## UI reacts to the events DmGame emits for world interactions (waystone, altar, grinder...): emit and look.
func _p_events() -> void:
	phase("events")
	close_all_panels()
	for pair in [["map", "map"], ["ascension", "ascension"], ["salvage", "salvage"], ["codex", "codex"]]:
		g.game_event.emit("panel_toggle", {"panel": pair[0]})
		await frames(4)
		var op := panel_is_open()
		chk(op, "game_event panel_toggle {%s} opens the window (waystone/altar/grinder/lectern clicks)" % pair[0], "no panel visible after the event", "major")
		close_all_panels()
		await frames(2)
	g.game_event.emit("escape", {"panel_open": false})
	await frames(4)
	if ui.is_open("settings"):
		close_all_panels()


func _p_start() -> void:
	phase("start")
	mouse_to(Vector2(333, 222))
	await frames(2)
	note("viewport mouse after push_input motion: %s (sent 333,222); cursor ground %s hover %s" % [str(sv.get_mouse_position()), str(g.input.ground), str(g.input.hover)])
	chk(g.area_id == "acre", "new character starts in the Acre", g.area_id)
	var vm := g.hud_state()
	chk(vm["max_hp"] > 0 and vm["hp"] > 0, "hud hp populated", str(vm["hp"]))
	chk(int(vm["level"]) == 1, "level 1 at start", str(vm["level"]), "minor")
	var errs0 := errlog.errors.size()
	await wait(2.0)
	chk(errlog.errors.size() == errs0, "no engine errors in the first 2 s idle", str(errlog.errors.slice(errs0, errs0 + 2)), "major")
	shot("acre")


func _p_panels() -> void:
	phase("panels")
	for pid in PANEL_KEYS:
		var code: Key = PANEL_KEYS[pid]
		await tap(code)
		await frames(4)
		var opened: bool = ui.is_open(pid)
		var any := panel_is_open()
		chk(opened or any, "key opens panel %s" % pid, "is_open=%s any=%s area=%s" % [str(opened), str(any), g.area_id], "major")
		chk(g.panel_open == any, "game.panel_open follows the UI (%s)" % pid, "game.panel_open=%s ui=%s" % [str(g.panel_open), str(any)], "major")
		if pid in ["inventory", "sheet", "grimoire", "map", "professions"]:
			shot("panel_" + pid)
		await tap(KEY_ESCAPE)
		await frames(4)
		if panel_is_open():
			await tap(KEY_ESCAPE)
			await frames(3)
		if panel_is_open():
			bug("critical", "panel %s cannot be closed with Esc" % pid, "two Esc presses and a panel is still visible")
			close_all_panels()
		chk(not g.panel_open, "game.panel_open cleared after closing %s" % pid, "", "major")
		await tap(code)
		await frames(3)
		await tap(code)
		await frames(3)
		if panel_is_open():
			bug("major", "pressing the panel key twice leaves %s open" % pid)
			close_all_panels()
	await tap(KEY_ESCAPE)
	await frames(4)
	chk(ui.is_open("settings"), "Esc with nothing open opens Settings", "", "major")
	await tap(KEY_ESCAPE)
	await frames(4)
	if ui.is_open("settings"):
		bug("critical", "Settings cannot be closed with Esc", "second Esc leaves Settings open")
		close_all_panels()
	chk(not g.panel_open, "game.panel_open false after all panels closed", "", "major")


func _p_overlay() -> void:
	phase("overlay")
	await tap(KEY_F3)
	await frames(3)
	var found: DmPerfOverlay = null
	for n in sv.find_children("*", "CanvasLayer", true, false):
		if n is DmPerfOverlay:
			found = n
	if found == null:
		bug("major", "F3 does nothing: DmPerfOverlay is never instantiated", "main/perf_overlay.gd exists but nothing adds it to the tree; README controls promise F3")
		overlay = DmPerfOverlay.new()
		sv.add_child(overlay)
		overlay.set_shown(true)
	else:
		overlay = found
		chk(overlay.panel.visible, "F3 shows the overlay", "", "major")


func _p_walk_to_graves() -> void:
	phase("walk")
	var cr := await walk_to(0.0, 20.0, 2.0, 60.0)
	chk(cr, "walk Acre -> Chapterhouse", "ended at (%.1f,%.1f) %s" % [g.player.x, g.player.z, g.player.area], "critical")
	chk(g.area_id == "chapterhouse", "area_id follows to chapterhouse", g.area_id)
	var gr := await walk_to(0.0, -8.0, 2.0, 60.0)
	chk(gr, "walk Chapterhouse -> Graves", "ended at (%.1f,%.1f) %s" % [g.player.x, g.player.z, g.player.area], "critical")
	await frames(3)
	chk(g.area_id == "graves", "area_id is graves after the walk", g.area_id)
	shot("graves_arrive")


func _p_fight() -> void:
	phase("fight")
	chk(g.prog.mode == "server", "progress runs in server mode against the offline backend", "mode=%s" % g.prog.mode, "major")
	g.inventory.add({"item_id": "flask_hp_minor", "quantity": 6})
	var gold0 := int(g.character["gold"])
	var xp0 := int(g.character["experience"])
	var lv0 := int(g.character["level"])
	var k := await fight(75.0, "manual", "graves")
	note("manual fight 75 s (reaction delay %d ms): %d kills, max enemies %d, max thralls %d, hero deaths %d" % [int(delay_ms), k, stats["max_enemies"], stats["max_thralls"], deaths_seen])
	chk(k >= 3, "manual combat kills enemies (%d in 75 s)" % k, "enemies=%d hp=%.0f/%.0f" % [alive_enemies().size(), g.player.hp, g.player.max_hp()], "critical")
	chk(int(g.character["experience"]) > xp0 or int(g.character["level"]) > lv0, "xp rises from kills", "", "major")
	chk(int(g.character["gold"]) >= gold0, "gold does not fall during combat", "", "major")
	if g.discipline["family"] == "necromancer":
		chk(stats["max_thralls"] >= 1, "raised at least one thrall", "max_thralls=%d corpses=%d hotbar=%s" % [stats["max_thralls"], g.sim.corpses.size(), str(g.hotbar)], "major")
	shot("fight")
	if g.settings_store.can_use_auto_combat():
		g.settings_store.update({"difficulty": "easy"})
		await frames(3)
		var ka := await fight(25.0, "auto", "graves")
		note("auto combat 25 s: %d kills" % ka)
		chk(ka >= 1, "auto combat kills enemies (%d)" % ka, "", "major")
		if bool(g.settings["autoCombat"]):
			await tap(KEY_G)
	else:
		note("auto combat not allowed on this character (auto_combat_allowed false): skipped")
	g.input.attack_target = null
	g.input.pending_interact = null
	g.player.stop()
	# Any hit cancels Recall (web: onHurt -> cancelRecall), so with enemies on top of the hero a single press can legitimately fail.
	# Retry a few times from a quiet spot; the check then measures the key routing, not the Graves' crowd.
	# A dead hero cannot Recall (web: startRecall returns when !alive): wait out the respawn first.
	for attempt in 4:
		var guard := 0
		while not g.player.alive and guard < 20:
			guard += 1
			await wait(1.0)
		await tap(KEY_T)
		await wait(0.5)
		if g.recall_at > 0.0:
			break
		g.player.hp = g.player.max_hp()
		g.player.teleport(0.0, -10.0)
		await frames(3)
	chk(g.recall_at > 0.0, "T starts Recall", "alive=%s area=%s hp=%.0f panel_open=%s cast_until=%s keys=%s" % [str(g.player.alive), g.area_id, g.player.hp, str(g.panel_open), str(g.p.get("castUntil")), str(g.input.keys)], "minor")
	g.actions.cancel_recall()


func _p_loot_equip() -> void:
	phase("loot")
	await fight(20.0, "manual", "graves")
	var drops: Array = g.lootview.debug_drops() if g.lootview != null else []
	note("%d drops on the ground" % drops.size())
	if drops.size() > 0:
		note("drop shape: %s" % str(drops[0]))
	var bag0: int = g.inventory.slots.size()
	var gold0 := int(g.character["gold"])
	for d in drops.slice(0, 12):
		var pos := Vector3.ZERO
		if d.has("pos"):
			pos = d["pos"]
		elif d.has("x"):
			pos = Vector3(float(d["x"]), 0.0, float(d["z"]))
		# A dead hero (or one sent home by a respawn) cannot pick anything up: wait for the respawn and go back, like a player would.
		var guard := 0
		while (not g.player.alive or g.area_id != "graves") and guard < 40:
			guard += 1
			await wait(1.0)
			if g.player.alive and g.area_id != "graves":
				g.navigate(0.0, -10.0)
				await wait(3.0)
		if g.area_id != "graves":
			break
		var reached := await walk_to(pos.x, pos.z, 0.8, 15.0)
		note("loot walk to (%.1f,%.1f) reached=%s hero (%.1f,%.1f) area=%s drops=%d" % [pos.x, pos.z, str(reached), g.player.x, g.player.z, g.area_id, g.lootview.count()])
	await wait(1.0)
	if drops.size() > 0:
		chk(g.inventory.slots.size() > bag0 or int(g.character["gold"]) > gold0 or g.lootview.count() < drops.size(), "walking over drops picks them up", "bag %d->%d gold %d->%d drops left %d" % [bag0, g.inventory.slots.size(), gold0, int(g.character["gold"]), g.lootview.count()], "major")
	var gear_id := ""
	for id in DmContent.items():
		var m: Dictionary = DmContent.items()[id]
		if String(m.get("type", "")) in ["weapon", "chest_armor", "head_armor", "armor"] and String(m.get("rarity", "common")) == "common":
			gear_id = id
			break
	if gear_id != "":
		g.inventory.add({"item_id": gear_id, "quantity": 1})
	await tap(KEY_I)
	await frames(6)
	var equippable: Dictionary = {}
	for s in g.inventory.slots:
		if DmGear.equip_slot_of(s) != "" and int(s.get("equipped", 0)) == 0:
			equippable = s
			break
	if equippable.is_empty():
		note("no equippable gear in the bag (gear_id=%s)" % gear_id)
	else:
		await ui.inv.toggle_equip(equippable)
		await frames(10)
		chk(_is_equipped(equippable["item_id"]), "equip moves the item to the equipped set", equippable["item_id"], "major")
		g.refresh_stats()
		for s in g.inventory.slots:
			if s["item_id"] == equippable["item_id"] and int(s.get("equipped", 0)) != 0:
				await ui.inv.toggle_equip(s)
				break
		await frames(10)
		chk(not _is_equipped(equippable["item_id"]), "unequip returns it to the bag", equippable["item_id"], "major")
		for s in g.inventory.slots:
			if s["item_id"] == equippable["item_id"] and int(s.get("equipped", 0)) == 0:
				await ui.inv.toggle_equip(s)
				break
		await frames(10)
	shot("inventory")
	await tap(KEY_ESCAPE)
	close_all_panels()
	await frames(3)


func _is_equipped(item_id: String) -> bool:
	for s in g.inventory.slots:
		if s["item_id"] == item_id and int(s.get("equipped", 0)) != 0:
			return true
	return false


func _p_levelup() -> void:
	phase("levelup")
	var lv0 := int(g.character["level"])
	var hp0 := g.player.max_hp()
	g.rewards.gain_xp(float(DmStats.xp_to_next(float(lv0))) * 2.5, g.player.x, g.player.z)
	await frames(5)
	chk(int(g.character["level"]) > lv0, "xp grant levels the hero up", "%d -> %d" % [lv0, int(g.character["level"])], "major")
	g.refresh_stats()
	chk(g.player.max_hp() >= hp0, "max hp does not fall on level up", "%.0f -> %.0f" % [hp0, g.player.max_hp()], "minor")
	note("events seen: %s" % str(ev_counts.keys()))


func _p_seal_depths() -> void:
	phase("seals")
	var need: int = g.prog.unlock_kills(float(DmContent.area("warren")["unlock"]["kills"]))
	chk(not g.nav.is_unlocked("warren"), "Warren sealed at the start")
	await fight(15.0, "manual", "graves")
	var have: int = g.prog.kills("graves")
	for i in maxi(0, need - 1 - have):
		g.prog.record_kill("graves")
	g.player.hp = g.player.max_hp()
	var guard := 0
	while not g.nav.is_unlocked("warren") and guard < 12:
		guard += 1
		await fight(15.0, "manual", "graves", 2)
	chk(g.nav.is_unlocked("warren"), "taking the last kills breaks the Warren seal (need %d)" % need, "kills=%d" % g.prog.kills("graves"), "major")
	chk(g.prog.really_unlocked("warren"), "seal recorded in progress", "", "major")
	if not g.nav.is_unlocked("warren"):
		return
	var ok := await walk_to(-52.0, -30.0, 3.0, 90.0)
	chk(ok and g.area_id == "warren", "walk through the broken seal into the Warren", "area=%s pos=(%.1f,%.1f)" % [g.area_id, g.player.x, g.player.z], "critical")
	if g.area_id != "warren":
		return
	shot("warren")
	await _p_depths()


func _p_depths() -> void:
	phase("depths")
	if int(g.character["level"]) < 15:
		g.character["level"] = 15   # assist (noted): the depths flow is under test, not a level-5 hero's survival
		g.refresh_stats()
		g.player.hp = g.player.max_hp()
		note("assist: raised level to 15 before the Depths")
	var st: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	var arrived := await walk_to(float(st["x"]) + 2.3, float(st["z"]), 2.5, 60.0)
	chk(arrived, "walk to the Depths stair", "pos=(%.1f,%.1f)" % [g.player.x, g.player.z], "critical")
	var stair := {"id": "stair", "kind": "stair", "x": float(st["x"]), "z": float(st["z"])}
	var found := false
	for it in g.input.interactables_near():
		if it["kind"] == "stair":
			stair = it
			found = true
	chk(found, "stair is an interactable near the hero", "", "major")
	g.actions.interact(stair)
	await frames(5)
	chk(g.depths.active(), "entering the Depths starts a run", g.area_id, "critical")
	if not g.depths.active():
		return
	chk(g.area_id == "depths" and g.in_depths, "area is depths", g.area_id, "major")
	var d1 := await _clear_depth_floor()
	chk(d1, "floor 1 can be cleared (stair opens)", "toasts: %s" % recent_toasts(), "critical")
	shot("depths")
	var chest: Variant = null
	for it in g.depths.interactables():
		if it["kind"] == "depths_chest":
			chest = it
	if chest != null:
		await walk_to(float(chest["x"]), float(chest["z"]) + 1.2, 2.0, 60.0)
		g.actions.interact(chest)
		await frames(5)
		chk(g.depths._chest_opened, "the chest opens", "", "major")
	var dep0 := int(g.sim.depths["depth"]) if g.depths.active() else 0
	var down: Dictionary = {}
	for it in g.depths.interactables():
		if it["kind"] == "depths_down":
			down = it
	if not down.is_empty():
		await walk_to(float(down["x"]), float(down["z"]) + 1.4, 2.0, 60.0)
		g.actions.interact(down)
		await frames(5)
		chk(g.depths.active() and int(g.sim.depths["depth"]) == dep0 + 1, "stairs lead to depth %d" % (dep0 + 1), "depth=%s" % (str(g.sim.depths["depth"]) if g.depths.active() else "-"), "critical")
	var peak := int(g.chronicle.view()["life"].get("peak.depth", 0.0))
	g.combat.on_hurt(g.player.max_hp() * 9.0, "melee", g.player.x + 1.0, g.player.z)
	await frames(3)
	chk(not g.player.alive, "death in the Depths", "", "major")
	await wait(5.5)
	chk(g.player.alive, "respawn after Depths death", "", "critical")
	chk(g.area_id == "chapterhouse", "respawn lands in the Chapterhouse", g.area_id, "major")
	chk(not g.depths.active(), "the Depths run ends on death", "", "major")
	chk(peak >= 2, "peak depth recorded >= 2", "peak=%d" % peak, "major")
	g.player.teleport(float(st["x"]) + 2.3, float(st["z"]))
	await frames(5)
	var resume_ev := {"n": 0}
	var cb := func(id: String, ctx: Dictionary):
		if id == "depths_stair_prompt" or id == "depths_stair_offer":
			resume_ev["n"] += 1
			resume_ev["ctx"] = ctx
	g.game_event.connect(cb)
	g.actions.interact(stair)
	await frames(5)
	g.game_event.disconnect(cb)
	chk(resume_ev["n"] > 0, "stair offers resume at the deepest floor", "resume_at=%d" % g.depths.resume_at(), "major")
	if resume_ev["n"] > 0:
		var resume := int(resume_ev["ctx"].get("resume", resume_ev["ctx"].get("deepest", 0)))
		chk(resume >= 2, "resume depth >= 2", "resume=%d" % resume, "major")
		g.depths.enter(maxi(resume, 2))
		await frames(5)
		chk(g.depths.active() and int(g.sim.depths["depth"]) >= 2, "resume enters the deepest floor", "", "major")
		var up: Dictionary = {}
		for it in g.depths.interactables():
			if it["kind"] == "depths_up":
				up = it
		if not up.is_empty():
			g.actions.interact(up)
			await wait(0.3)
			g.actions.interact(up)
			await wait(1.0)
			chk(not g.depths.active(), "the way up ends the run", "", "major")
			chk(g.area_id == "warren", "leaving the Depths puts you back in the Warren", g.area_id, "major")


func stall_dump() -> String:
	var parts: Array = []
	parts.append("hero (%.1f,%.1f) hp %.0f cast_until-now=%.0f res=%.0f has_path=%s atk_target=%s hover=%s panel=%s" % [g.player.x, g.player.z, g.player.hp, float(g.p["castUntil"]) - g.now_ms, float(g.p["resource"]["value"]), str(g.player.has_path()), str(g.input.attack_target), str(g.input.hover), str(g.panel_open)])
	for e in alive_enemies().slice(0, 8):
		parts.append("%s#%d st=%s hp=%.0f d=%.1f at (%.1f,%.1f)" % [e.def, e.id, e.state, e.hp, Vector2(e.x - g.player.x, e.z - g.player.z).length(), e.x, e.z])
	return " ; ".join(parts)


func _clear_depth_floor() -> bool:
	assist_hp = 0.6
	var dbg_ms := 0
	var last_kills: Variant = -1
	var last_kill_t := g.now_ms
	var stall_dumped := false
	var start := g.now_ms
	while g.now_ms - start < 240000.0:
		var r: Variant = g.depths.run()
		if r == null:
			return false
		if bool(r["stairOpen"]):
			return true
		var e := nearest_enemy("depths")
		if int(g.now_ms) - dbg_ms > 4000:
			dbg_ms = int(g.now_ms)
			note("depths floor: kills=%s/%s hp=%.0f/%.0f enemies=%d alive=%s area=%s deaths=%d" % [str(r["kills"]), str(r["need"]), g.player.hp, g.player.max_hp(), alive_enemies().size(), str(g.player.alive), g.player.area, deaths_seen])
		if r["kills"] != last_kills:
			last_kills = r["kills"]
			last_kill_t = g.now_ms
		elif g.now_ms - last_kill_t > 40000.0 and not stall_dumped:
			stall_dumped = true
			note("STALL dump: " + stall_dump())
		if e == null:
			await wait(1.0)
			continue
		if Vector2(e.x - g.player.x, e.z - g.player.z).length() > 12.0:
			g.navigate(e.x, e.z)
			await wait(1.0)
		await fight(8.0, "manual", "depths", 3)
	bug("critical", "Depths floor 1 not cleared in 240 s of game time", "kills=%s need=%s" % [str(g.depths.run()["kills"]), str(g.depths.run()["need"])])
	return false


func _p_boss() -> void:
	for bid in boss_pick.split(","):
		if bid == "all":
			for x in DmContent.get_export("bosses", "BOSS_IDS"):
				await _p_boss_one(String(x))
		else:
			await _p_boss_one(bid)


func _p_boss_one(boss_id: String) -> void:
	phase("boss")
	assist_hp = 0.0
	for i in 3:
		if g.depths.active():
			g.depths.leave()
			await wait(0.3)
			g.depths.leave()
			await wait(0.5)
	if g.depths.active():
		bug("major", "cannot leave the Depths via the way-up twice (run stays active)")
	var id := boss_id
	# The web allows ONE awake boss (summonBossNormal returns while bossState().active): a previous fight that timed out must be put down
	# first, or this summon is refused by design (not a product bug).
	for i in 20:
		if not g.sim.boss.state.active:
			break
		note("a previous boss is still awake: putting it down before summoning %s" % id)
		g.sim.boss.damage(1.0e9, g.self_id, 0.0)
		await wait(1.0)
	var def: Dictionary = DmContent.boss(id)
	var ar: Dictionary = def["arena"]
	g.character["level"] = maxi(int(g.character["level"]), 30)
	g.refresh_stats()
	g.player.hp = g.player.max_hp()
	g.prog.local["shards"] = 99
	g.nav.set_unlocked(DmContent.area_order())
	g.player.teleport(float(ar["x"]), float(ar["z"]) + float(ar["r"]) * 0.7)
	await frames(3)
	chk(g.player.area == def["area"], "teleported into %s arena" % id, g.player.area, "minor")
	var b = g.sim.boss.state
	var hp_trace: Array = []
	note("before summon: area=%s depths_active=%s shards=%s" % [g.player.area, str(g.depths.active()), str(g.prog.local["shards"])])
	g.actions.summon_boss_normal(id)
	await wait(3.0)
	b = g.sim.boss.state   # sim.boss follows the awake boss id: re-read after the summon
	chk(b.active, "%s wakes when summoned" % id, "shards=%s toasts: %s" % [str(g.prog.local["shards"]), recent_toasts()], "critical")
	if not b.active:
		return
	shot("boss_wake")
	var start := g.now_ms
	var deaths0 := deaths_seen
	var tr_next := 0.0
	while true:
		b = g.sim.boss.state
		if not b.active or g.now_ms - start >= 420000.0:
			break
		if not g.player.alive:
			await wait(5.0)
			g.player.teleport(float(ar["x"]), float(ar["z"]) + float(ar["r"]) * 0.7)
			continue
		g.player.hp = maxf(g.player.hp, g.player.max_hp() * 0.35)
		g.p["resource"]["value"] = maxf(float(g.p["resource"]["value"]), 40.0)
		g.input.set_ground(b.x, b.z)
		g.input.hover = {"kind": "boss"}
		if Vector2(b.x - g.player.x, b.z - g.player.z).length() > 14.0:
			g.navigate(b.x + 4.0, b.z + 4.0)
		mouse_to(screen_of(b.x, 2.0, b.z))
		_rot += 1
		var codes := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_R]
		await tap(codes[_rot % 5], 1)
		await frames(10)
		if g.now_ms > tr_next:
			tr_next = g.now_ms + 20000.0
			hp_trace.append(snappedf(float(b.hp) / maxf(float(b.maxHp), 1.0), 0.01))
	var dur := (g.now_ms - start) / 1000.0
	b = g.sim.boss.state
	note("boss %s: active=%s after %.0fs game, boss hp trace %s, hero deaths %d" % [id, str(b.active), dur, str(hp_trace), deaths_seen - deaths0])
	chk(not b.active, "%s is defeated within 7 min of game time" % id, "hp=%.0f/%.0f phase=%s" % [float(b.hp), float(b.maxHp), str(b.phase)], "critical")
	await wait(1.5)
	chk(float(g.chronicle.view()["life"].get("boss." + id, 0.0)) >= 1.0, "boss kill is recorded in the chronicle (boss.%s)" % id, "life=%s" % str(g.chronicle.view()["life"].keys().filter(func(k): return String(k).begins_with("boss"))), "major")
	shot("boss_dead")
	g.player.hp = g.player.max_hp()


func _p_death() -> void:
	phase("death")
	g.recall_at = 0.0
	g.player.teleport(0.0, -10.0)
	await frames(3)
	var gold0 := int(g.character["gold"])
	var xp0 := int(g.character["experience"])
	var d0 := deaths_seen
	var r0 := respawns_seen
	g.combat.on_hurt(g.player.max_hp() * 9.0, "melee", g.player.x + 1.0, g.player.z)
	await frames(3)
	chk(not g.player.alive and deaths_seen == d0 + 1, "lethal hit kills the hero once", "deaths %d->%d" % [d0, deaths_seen], "major")
	var p0 := hero_xy()
	await tap(KEY_W, 10)
	chk(hero_xy().distance_to(p0) < 0.5, "a dead hero does not walk", "", "major")
	await wait(5.0)
	chk(g.player.alive and respawns_seen == r0 + 1, "hero respawns after the death timer", "alive=%s respawns %d->%d" % [str(g.player.alive), r0, respawns_seen], "critical")
	chk(g.area_id == "chapterhouse", "respawn point is the Chapterhouse", g.area_id, "major")
	chk(g.player.hp > 0.0, "respawned with hp > 0", "%.1f" % g.player.hp, "major")
	chk(int(g.character["gold"]) >= gold0 and int(g.character["experience"]) >= xp0, "death takes nothing", "gold %d->%d xp %d->%d" % [gold0, int(g.character["gold"]), xp0, int(g.character["experience"])], "major")


func _snapshot() -> Dictionary:
	var eq: Array = []
	var bag := 0
	for s in g.inventory.slots:
		if int(s.get("equipped", 0)) != 0:
			eq.append(String(s["item_id"]))
		else:
			bag += int(s["quantity"])
	eq.sort()
	return {"level": int(g.character["level"]), "xp": int(g.character["experience"]), "gold": int(g.character["gold"]), "equipped": eq, "bag_qty": bag,
		"warren": g.prog.really_unlocked("warren"), "graves_kills": g.prog.kills("graves"), "peak_depth": int(g.chronicle.view()["life"].get("peak.depth", 0.0)),
		"boss_kills": int(g.prog.local.get("bossKills", 0)), "class": int(g.character["class_index"]), "id": int(g.character["id"])}


func _p_persist_snapshot() -> void:
	phase("persist")
	var snap := _snapshot()
	await g.psync.flush()
	await g.flush_all()
	var f := FileAccess.open("user://playtest_snapshot.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(snap))
	f.close()
	note("snapshot %s" % str(snap))
	write_report()
	# the real window-close path (Main flushes everything, then quits)
	main._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await frames(30)


func _session_b() -> void:
	phase("relaunch")
	var f := FileAccess.open("user://playtest_snapshot.json", FileAccess.READ)
	if not chk(f != null, "snapshot from session A exists in user://", "", "critical"):
		return
	var snap: Dictionary = JSON.parse_string(f.get_as_text())
	var acct := _account()
	await frames(20)
	# a saved offline session resumes straight into the world (web parity); otherwise log in through the real API
	if main.game == null and main.flow != null and main.flow.current_name == "login":
		note("relaunch showed the login screen (no resumed session): logging in")
		var r := await main.api.login(acct["user"], acct["pw"])
		if not chk(r.ok, "offline account survives relaunch (login)", str(r.error), "critical"):
			return
		main.api.set_token(r.data["token"])
		await main.flow.resume()
		chk(main.flow == null or main.flow.current_name == "", "existing account skips discipline select", "", "major")
	else:
		note("relaunch resumed the saved session straight into the world")
	if not await _wait_world():
		bug("critical", "world does not come up after relaunch")
		return
	g.game_event.connect(on_event)
	await frames(30)
	var now: Dictionary = JSON.parse_string(JSON.stringify(_snapshot()))   # same float/int normalisation as the saved snapshot
	for k in ["level", "gold", "equipped", "warren", "graves_kills", "peak_depth", "boss_kills", "class", "id", "xp"]:
		chk(str(now[k]) == str(snap[k]), "persisted across relaunch: %s" % k, "%s -> %s" % [str(snap[k]), str(now[k])], "critical")
	chk(int(now["bag_qty"]) == int(snap["bag_qty"]), "persisted across relaunch: bag quantity", "%s -> %s" % [snap["bag_qty"], now["bag_qty"]], "major")
	chk(g.nav.is_unlocked("warren") == bool(snap["warren"]), "Warren door state after relaunch", "", "major")
	chk(g.depths.resume_at() >= 2 or int(snap["peak_depth"]) < 2, "deepest Depths floor still offered after relaunch", "resume_at=%d" % g.depths.resume_at(), "major")
	g.player.teleport(0.0, -10.0)
	await frames(3)
	var k := await fight(20.0, "manual", "graves")
	chk(k >= 1, "combat works after relaunch (%d kills)" % k, "", "major")
	write_report()
	main._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await frames(30)
