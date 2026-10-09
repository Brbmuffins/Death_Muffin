extends SceneTree
## Automated playtest bot for the REBUILD (DmNextGame, godot/next/), offline edition only (DmMockBackend under user://, never the live server).
## The old DmGame twin (bot.gd) is gone: same report JSON as it had (findings / notes / frame / events + a `metrics` block both bots fill the
## same way), same sessions, same real input path (key + mouse events pushed into a 1280x800 SubViewport), but through the rebuild's seams.
##   godot --headless --path godot --script res://tests/playtest/bot_next.gd -- --session=A --disc=2 --out=/abs/report.json [--boss=gravedigger]
##   session A: register + pick the discipline on the REAL front screens, walk to the Graves, fight, loot, level, boss summon + kill, death, window-close save.
##   session B: relaunch, resume / log in, verify the save persisted, fight again.
## Run it through tools/godot/playtest.sh --next (isolated XDG_DATA_HOME so the real offline save is never touched).
## Assists are noted (never hidden): level / shards for the boss, hp floor in the boss fight. Bot artefacts first: a click that lands on a HUD
## control is NOT sent into the world (an earlier "gold decreased" finding was the bot buying Buy Damage through an enemy drawn under it).

const DISCS := {1: "ossuary", 2: "gravecaller", 3: "mourner", 4: "rotweaver"}
const PLAY_BUDGET_MS := 150.0
const LOADING_PHASES := ["boot", "front", "relaunch"]
const PANEL_KEYS := {"inventory": KEY_I, "sheet": KEY_J, "legion": KEY_Y, "forge": KEY_C, "professions": KEY_P, "contracts": KEY_O, "garden": KEY_U,
	"labor": KEY_H, "cosmetics": KEY_N, "vault": KEY_V, "map": KEY_M, "codex": KEY_K, "atlas": KEY_PERIOD, "grimoire": KEY_L}

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _bt: Array) -> void:
		errors.append({"fn": function, "file": file, "line": line, "msg": rationale if rationale != "" else code, "type": error_type})
	func _log_message(_m: String, _e: bool) -> void:
		pass

class Monitor extends Node:
	var bot
	var dts: Array = []
	var play_dts: Array = []
	var skip := 0
	var last_us := 0
	func _process(dt: float) -> void:
		var now := Time.get_ticks_usec()
		bot.game_ms += dt * 1000.0      # dt is already scaled by Engine.time_scale: this is game time
		skip += 1
		if skip > 120 and last_us > 0:
			var ms := (now - last_us) / 1000.0
			dts.append(ms)
			if not bot.phase_name in bot.LOADING_PHASES:
				play_dts.append(ms)
			if ms > 50.0:
				print("HITCH %.0fms phase=%s step=%s area=%s %s%s" % [ms, bot.phase_name, bot.step, bot.g.area_id if bot.g != null and is_instance_valid(bot.g) else "-", bot.hitch_ctx(), " LOADING" if bot.phase_name in bot.LOADING_PHASES else ""])
		last_us = now
		bot.on_frame(dt)

var errlog := ErrLog.new()
var mon: Monitor
var session := "A"
var disc := 2
var boss_pick := "gravedigger"
var out_path := ""
var scale := 3.0
var name_ := "pt"
var stop_after := ""   # dev: end session A after this phase (e.g. dps)
var delay_ms := 0.0
var main: DmMain
var sv: SubViewport
var g: DmNextGame
var ui: DmGameUi
var uh: DmNextUiHost
var findings: Array = []
var notes: Array = []
var ev_counts: Dictionary = {}
var metrics: Dictionary = {}
var phase_name := ""
var boss_t0 := 0.0
var last_boss_ev := ""
var verbose_boss := false   # dev: --boss-events prints every boss brain event with its time (to line up with HITCH lines)
var step := ""   # finer than the phase: which action the bot was in when a long frame hit (HITCH lines)
var t0_ms := 0
var game_ms := 0.0
var sane_t := 0.0
var last_gold := 0
var last_lv := 0.0
var watch := {}
var deaths_seen := 0
var respawns_seen := 0
var kills := 0
var picks := {"gold": 0, "shard": 0, "item": 0}
var max_enemies := 0
var seen_ids: Dictionary = {}   # every enemy id the bot saw alive (sampled 4 Hz) and the sum of their max hp: spawn volume / toughness for the comparison
var seen_hp := 0.0
var seen_dmg := 0.0
var min_hp_frac := 1.0
var max_thralls := 0
var toasts: Array = []
var _rot := 0
var _walk_last := Vector3.ZERO
var _walk_t := 0.0
var walk_soft := false   # loot walks: a drop that lies on unwalkable ground is counted (metrics.loot_unreachable), not a movement bug


func _initialize() -> void:
	OS.add_logger(errlog)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--session="): session = a.substr(10)
		elif a.begins_with("--disc="): disc = int(a.substr(7))
		elif a.begins_with("--out="): out_path = a.substr(6)
		elif a.begins_with("--boss="): boss_pick = a.substr(7)
		elif a.begins_with("--scale="): scale = float(a.substr(8))
		elif a.begins_with("--name="): name_ = a.substr(7)
		elif a.begins_with("--delay="): delay_ms = float(a.substr(8))
		elif a.begins_with("--stop-after="): stop_after = a.substr(13)
		elif a == "--boss-events": verbose_boss = true
	if DisplayServer.get_name() != "headless":
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


func phase(n: String) -> void:
	phase_name = n
	print("== phase %s (game %.0fs, wall %.0fs)" % [n, game_ms / 1000.0, (Time.get_ticks_msec() - t0_ms) / 1000.0])


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
		"play_worst_ms": snappedf(pa[pa.size() - 1], 0.01) if pa.size() > 0 else 0.0, "play_over50ms": pa.filter(func(v): return v > 50.0).size(),
		"play_over100ms": pa.filter(func(v): return v > 100.0).size(), "time_scale": scale}


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


func write_report() -> void:
	var errs := _script_errors()
	for e in errs:
		bug("critical", "SCRIPT ERROR: %s" % String(e["msg"]).left(120), "%s:%d in %s" % [e["file"], e["line"], e["fn"]])
	var pd: Array = mon.play_dts.filter(func(v): return v > PLAY_BUDGET_MS) if mon != null else []
	if not pd.is_empty():
		var worst := 0.0
		for v in pd:
			worst = maxf(worst, v)
		bug("major" if (pd.size() >= 3 or worst > PLAY_BUDGET_MS * 2.0) else "minor", "play frames over the %.0f ms budget" % PLAY_BUDGET_MS,
			"%d frame(s), worst %.0f ms (HITCH lines in the log name the phase)" % [pd.size(), worst])
	metrics["max_enemies"] = max_enemies
	metrics["max_thralls"] = max_thralls
	metrics["deaths_total"] = deaths_seen
	var rep := {"session": session, "game": "next", "disc": disc, "findings": findings, "notes": notes, "frame": frame_stats(), "metrics": metrics, "events": ev_counts,
		"engine_errors": errlog.errors.size(), "wall_s": (Time.get_ticks_msec() - t0_ms) / 1000.0}
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(rep, "  "))
	print("PLAYTEST session=%s game=next disc=%d findings=%d script_errors=%d metrics=%s frame=%s" % [session, disc, findings.size(), errs.size(), str(metrics), str(frame_stats())])


func finish() -> void:
	write_report()
	quit(1 if findings.size() > 0 else 0)


# ---- input helpers (real events through the viewport) ----------------------------------------------------------------------------

func key(code: Key, pressed: bool = true) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
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


func wait(sec: float) -> void:
	var start := game_ms
	var wall := Time.get_ticks_msec()
	while (game_ms - start) < sec * 1000.0:
		await process_frame
		if Time.get_ticks_msec() - wall > (sec * 8.0 + 10.0) * 1000.0:
			bug("major", "game time does not advance (wait %.1fs took >%.0fs wall)" % [sec, sec * 8.0 + 10.0])
			return


func mouse_to(p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = p
	ev.global_position = p
	sv.push_input(ev)


func click(p: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	mouse_to(p)
	for pr in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.position = p
		ev.global_position = p
		ev.button_index = button
		ev.pressed = pr
		sv.push_input(ev)
		await process_frame


func body() -> DmHeroBody:
	return g.local_body()


func is_alive_enemy(e: Variant) -> bool:
	if e == null or not is_instance_valid(e) or e.sm == null:
		return false
	var sid: int = e.sm.id()
	return sid != DmEnemyState.Id.DEAD and sid != DmEnemyState.Id.RISING and e.hp > 0.0


func alive_enemies() -> Array:
	var out: Array = []
	for e in g.director.enemies.values():
		if is_alive_enemy(e):
			out.append(e)
	return out


func nearest_enemy() -> DmEnemy:
	var b := body()
	var best: DmEnemy = null
	var bd := 1e9
	for e in alive_enemies():
		var d := Vector2(e.global_position.x - b.position.x, e.global_position.z - b.position.z).length()
		if d < bd:
			bd = d
			best = e
	return best


func panel_is_open() -> bool:
	return ui != null and ui.panel_open()


func close_all_panels() -> void:
	if ui != null:
		ui.close_panels()


func gold() -> int:
	return int(g.character.get("gold", 0))


## Lifetime xp (the xp banked in every level below + the bar): comparable across level-ups.
func _cum_xp(ch: Dictionary) -> float:
	var t := float(ch.get("experience", 0))
	for l in range(1, int(ch["level"])):
		t += float(DmStats.xp_to_next(float(l)))
	return t


func xp_total() -> float:
	return float(g.character["level"]) * 1.0e9 + float(g.character.get("experience", 0))


# ---- per-frame monitors --------------------------------------------------------------------------------------------------------

func on_frame(_dt: float) -> void:
	if g == null or not is_instance_valid(g) or not g.ready_:
		return
	sane_t += _dt
	if sane_t < 0.25:
		return
	sane_t = 0.0
	var b := body()
	if b == null:
		return
	if is_nan(b.hp) or is_inf(b.hp) or b.hp < -0.001 or b.hp > b.max_hp * 1.0001 + 0.001:
		bug("major", "hp out of range", "%.2f / %.2f" % [b.hp, b.max_hp])
	if b.resource < -0.001 or b.resource > b.resource_max + 0.001 or is_nan(b.resource):
		bug("major", "resource out of range", "%.2f / %.2f" % [b.resource, b.resource_max])
	if phase_name == "fight" and b.alive:
		min_hp_frac = minf(min_hp_frac, b.hp / maxf(b.max_hp, 1.0))
	var lv := xp_total()
	if lv + 1.0 < last_lv and not watch.get("lv_reset_ok", false):
		bug("major", "level/xp went backwards", "%.0f -> %.0f" % [last_lv, lv])
	last_lv = lv
	var gd := gold()
	if gd < last_gold and not watch.get("gold_drop_ok", false):
		bug("major", "gold decreased without a purchase", "%d -> %d" % [last_gold, gd])
	last_gold = gd
	max_enemies = maxi(max_enemies, g.director.enemies.size())
	for e in g.director.enemies.values():
		var eid := int(e.get_meta(&"dm_id", 0))
		if not seen_ids.has(eid) and is_instance_valid(e):
			seen_ids[eid] = true
			seen_hp += float(e.max_hp)
			seen_dmg += float(e.damage)
	var th := b.get_node_or_null("Thralls")
	if th != null and th.has_method("count"):
		max_thralls = maxi(max_thralls, int(th.count()))


## What the world was doing when a long frame hit: enemy / thrall counts, the awake boss's phase and hp, the last events (HITCH lines).
func hitch_ctx() -> String:
	if g == null or not is_instance_valid(g) or not g.ready_:
		return ""
	var bs: DmBoss = g.bosses.active_boss()
	var bt := "boss=%s phase=%d hp=%.0f%%" % [bs.boss_id, bs.phase, 100.0 * bs.hp / maxf(bs.max_hp, 1.0)] if bs != null else "boss=-"
	return "lastev=%s enemies=%d %s nodes=%d proc=%.0fms phys=%.0fms navt=%.0fms t=%.1fs" % [last_boss_ev, g.director.enemies.size(), bt, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0, (game_ms - boss_t0) / 1000.0]


func on_event(id: String, ctx: Dictionary) -> void:
	ev_counts[id] = int(ev_counts.get(id, 0)) + 1
	if id == "toast":
		toasts.append(String(ctx.get("text", "")))
		if toasts.size() > 6:
			toasts.pop_front()


func recent_toasts() -> String:
	return " | ".join(toasts)


# ---- movement ------------------------------------------------------------------------------------------------------------------

## Click-to-move (the player's path: DmNextInput.click_move, what a ground click calls). True on arrival (or within tol + 1).
func walk_to(x: float, z: float, tol: float = 1.5, timeout: float = 40.0) -> bool:
	var start := game_ms
	g.input.click_move(Vector3(x, 0.0, z))
	_walk_last = body().position
	_walk_t = game_ms
	var re := 0
	while true:
		await process_frame
		var b := body()
		if not b.alive:
			return false
		if Vector2(b.position.x - x, b.position.z - z).length() <= tol:
			return true
		if not b.has_target:
			if Vector2(b.position.x - x, b.position.z - z).length() <= tol + 1.5:
				return true
			re += 1
			if re > 6:
				var wk := b.walkable(Vector3(x, 0.0, z))
				if walk_soft and not wk:
					metrics["loot_unreachable"] = int(metrics.get("loot_unreachable", 0)) + 1
					note("drop at (%.1f,%.1f) lies on unwalkable ground (hero stopped at (%.1f,%.1f), %.1f m short)" % [x, z, b.position.x, b.position.z, Vector2(b.position.x - x, b.position.z - z).length()])
					return false
				bug("major", "click-to-move stops short of a walkable target", "to (%.1f,%.1f) from (%.1f,%.1f) area=%s walkable=%s" % [x, z, b.position.x, b.position.z, g.area_id, str(wk)])
				return false
			g.input.click_move(Vector3(x, 0.0, z))
		if b.position.distance_to(_walk_last) > 0.3:
			_walk_last = b.position
			_walk_t = game_ms
		elif game_ms - _walk_t > 6000.0:
			bug("critical", "hero stuck while walking", "stopped at (%.1f,%.1f) heading to (%.1f,%.1f) area=%s" % [b.position.x, b.position.z, x, z, g.area_id])
			return false
		if game_ms - start > timeout * 1000.0:
			bug("major", "walk timeout %.0fs" % timeout, "at (%.1f,%.1f) heading to (%.1f,%.1f) area=%s" % [b.position.x, b.position.z, x, z, g.area_id])
			return false
	return false


# ---- combat bot ----------------------------------------------------------------------------------------------------------------

## Fight `sec` game-seconds: LMB-click the nearest enemy (the chase + primary), then the hotbar keys / RMB / R aimed at it, flask when low.
## Returns kills made (kill_earned events for the hero).
func fight(sec: float, area: String = "graves", stop_kills: int = 0) -> int:
	var start := game_ms
	var k0 := kills
	var no_enemy := 0.0
	var last := game_ms
	while game_ms - start < sec * 1000.0:
		await process_frame
		var dt := game_ms - last
		last = game_ms
		var b := body()
		if not b.alive:
			await wait(0.5)
			continue
		if area != "" and g.area_id != area:
			var ar: Dictionary = DmContent.area(area)["rect"]
			await walk_to((float(ar["x0"]) + float(ar["x1"])) * 0.5, (float(ar["z0"]) + float(ar["z1"])) * 0.5, 4.0, 60.0)
			continue
		if panel_is_open():
			await tap(KEY_ESCAPE)
			if panel_is_open():
				bug("critical", "panel cannot be closed with Esc during combat")
				close_all_panels()
		if b.hp < b.max_hp * 0.45 and uh.inventory.count("flask_hp_minor") > 0:
			await tap(KEY_Q)
		var e := nearest_enemy()
		if e == null:
			no_enemy += dt
			if no_enemy > 25000.0:
				bug("major", "no enemies for 25 s (spawn stall)", "alive=%d area=%s" % [g.director.enemies.size(), g.area_id])
				no_enemy = 0.0
			_rot += 1
			if _rot % 40 == 0:
				_wander()
			continue
		no_enemy = 0.0
		await _manual_tick(e)
		if stop_kills > 0 and kills - k0 >= stop_kills:
			break
	return kills - k0


func _enemy_screen(e: Node3D, h: float = 0.9) -> Vector2:
	return g.camera.unproject_position(e.global_position + Vector3(0.0, h, 0.0))


func _manual_tick(e: DmEnemy) -> void:
	if delay_ms > 0.0:
		await wait(delay_ms / 1000.0)
		if not is_instance_valid(e) or not is_alive_enemy(e):
			return
	var sp := _enemy_screen(e, 0.9 * e.scale.y)
	var vp := Vector2(sv.size)
	mouse_to(sp)
	await process_frame
	# An enemy drawn under a HUD control (Buy Damage, 40 / 60 gold) must not be clicked through it: a real player's click would buy the upgrade.
	var over_ui := sv.gui_get_hovered_control() != null
	if over_ui or sp.x < 4 or sp.y < 4 or sp.x > vp.x - 4 or sp.y > vp.y - 4 or g.camera.is_position_behind(e.global_position):
		g.input.attack(int(e.get_meta(&"dm_id", 0)), false)   # the same call the click makes, without the pixel the HUD owns
	else:
		await click(sp)
	mouse_to(sp)
	_rot += 1
	var slot := (_rot % 6) + 1
	if slot == 5:
		await click(sp, MOUSE_BUTTON_RIGHT)
	elif slot == 6:
		await tap(KEY_R, 1)
	else:
		await tap([KEY_1, KEY_2, KEY_3, KEY_4][slot - 1], 1)
	var b := body()
	if b.hp < b.max_hp * 0.45 and uh.inventory.count("flask_hp_minor") == 0:
		uh.inventory.add({"item_id": "flask_hp_minor", "quantity": 5})
		watch["assist"] = int(watch.get("assist", 0)) + 1
	await frames(6)


func _wander() -> void:
	var a: Dictionary = DmContent.area(g.area_id)
	if a.is_empty() or a.get("rect") == null:
		return
	var r: Dictionary = a["rect"]
	g.input.click_move(Vector3(randf_range(float(r["x0"]) + 4.0, float(r["x1"]) - 4.0), 0.0, randf_range(float(r["z0"]) + 4.0, float(r["z1"]) - 4.0)))


# ---- the run -------------------------------------------------------------------------------------------------------------------

func _wait_world() -> bool:
	for i in 4000:
		if main.slice != null and main.slice.ready_ and DmLoadingScreen.current == null:
			g = main.slice
			uh = g.ui_host
			ui = g.ui
			return true
		await process_frame
	return false


func _hook_game() -> void:
	g.rewards.kill_earned.connect(func(cid: int, _d: String, _p: Vector3) -> void:
		if cid == int(g.character.get("id", -1)):
			kills += 1)
	g.hero_died.connect(func(_b: DmHeroBody) -> void: deaths_seen += 1)
	g.hero_respawned.connect(func(_b: DmHeroBody) -> void: respawns_seen += 1)
	uh.game_event.connect(on_event)
	g.bosses.brain_event.connect(func(ev: Dictionary, _b: DmBoss) -> void:
		if String(ev.get("t", "")) != "hurt":
			last_boss_ev = "%s@%.1f" % [str(ev.get("t", ev.keys())), (game_ms - boss_t0) / 1000.0]
			if verbose_boss:
				print("BOSSEV %.2fs %s" % [(game_ms - boss_t0) / 1000.0, str(ev).left(160)]))
	var m: DmRewardsMember = g.rewards.members.get(int(g.character["id"]))
	if m != null:
		m.loot_view.picked.connect(func(ev: Dictionary) -> void:
			picks[String(ev["kind"])] = int(picks.get(String(ev["kind"]), 0)) + (int(ev.get("amount", 1)) if ev["kind"] != "item" else 1))
	last_gold = gold()
	last_lv = xp_total()


func _run() -> void:
	phase("boot")
	sv = SubViewport.new()
	sv.size = Vector2i(1280, 800)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sv)
	main = load("res://main/main.tscn").instantiate()
	main.mode = "dev_offline"   # the local testing backend, never the live server
	sv.add_child(main)
	mon = Monitor.new()
	mon.bot = self
	mon.process_priority = -100000
	root.add_child(mon)
	await frames(8)
	chk(main.mode == "dev_offline" and main.api.base_url == "", "dev-offline backend (never the live server)", "", "critical")
	if session == "A":
		chk(main.flow != null and main.flow.current_name == "login", "login screen first", "got %s" % (main.flow.current_name if main.flow != null else "-"))
		await _session_a()
	else:
		await _session_b()
	finish()


func _account() -> Dictionary:
	return {"user": "bot_%d" % disc, "pw": "pw1234x"}


## The REAL front flow: register on the login screen, pick the discipline card, wait for the rebuild behind the loading screen.
func _enter_world_fresh() -> bool:
	phase("front")
	var acct := _account()
	var l := main.flow.current as DmLoginScreen
	if not chk(l != null, "login screen is a DmLoginScreen", "", "critical"):
		return false
	l.toggle_mode()
	await process_frame
	l.user_edit.text = acct["user"]
	if l.pass_edit != null:
		l.pass_edit.text = acct["pw"]
	if l.email_edit != null:
		l.email_edit.text = "bot@example.com"
	var ok: bool = await l.submit()
	if not chk(ok, "register on the login screen", String(l.error_label.text), "critical"):
		return false
	for i in 600:
		if main.flow != null and main.flow.current_name == "select":
			break
		await process_frame
	chk(main.flow != null and main.flow.current_name == "select", "new account -> discipline select", main.flow.current_name if main.flow != null else "-", "critical")
	var sel := main.flow.current as DmCharSelectScreen
	if sel == null:
		return false
	var t_load := Time.get_ticks_msec()
	await sel.choose(disc)
	var up := await _wait_world()
	chk(up, "the rebuild comes up behind the front", "", "critical")
	if not up:
		return false
	note("world load %.1fs wall" % ((Time.get_ticks_msec() - t_load) / 1000.0))
	_hook_game()
	await frames(30)
	return true


func _session_a() -> void:
	if not await _enter_world_fresh():
		return
	var did: String = body().discipline_id
	chk(did == DISCS.get(disc, did), "discipline matches the picked card", "%s vs %s" % [did, DISCS.get(disc)])
	note("discipline %s primary %s keys %s sig %s" % [did, uh.primary, str(uh.keys), uh.signature])
	await _p_start()
	await _p_panels()
	await _p_walk_to_graves()
	await _p_dps()
	if stop_after == "dps":
		return
	await _p_fight()
	await _p_loot_equip()
	await _p_levelup()
	await _p_boss()
	await _p_death()
	await _p_persist_snapshot()


func _p_start() -> void:
	phase("start")
	mouse_to(Vector2(333, 222))
	await frames(2)
	chk(g.area_id == "chapterhouse", "new character starts in the Chapterhouse", g.area_id)
	var vm: Dictionary = uh.hud_state()
	chk(float(vm["max_hp"]) > 0 and float(vm["hp"]) > 0, "hud hp populated", str(vm.get("hp")))
	chk(int(g.character["level"]) == 1, "level 1 at start", str(g.character["level"]), "minor")
	metrics["hero_lv1_max_hp"] = snappedf(body().max_hp, 0.1)
	var errs0 := errlog.errors.size()
	await wait(2.0)
	chk(errlog.errors.size() == errs0, "no engine errors in the first 2 s idle", str(errlog.errors.slice(errs0, errs0 + 2)), "major")


func _p_panels() -> void:
	phase("panels")
	for pid in PANEL_KEYS:
		var code: Key = PANEL_KEYS[pid]
		await tap(code)
		await frames(4)
		chk(ui.is_open(pid) or panel_is_open(), "key opens panel %s" % pid, "is_open=%s any=%s area=%s" % [str(ui.is_open(pid)), str(panel_is_open()), g.area_id], "major")
		await tap(KEY_ESCAPE)
		await frames(4)
		if panel_is_open():
			await tap(KEY_ESCAPE)
			await frames(3)
		if panel_is_open():
			bug("critical", "panel %s cannot be closed with Esc" % pid, "two Esc presses and a panel is still visible")
			close_all_panels()
	await tap(KEY_ESCAPE)
	await frames(4)
	chk(ui.is_open("settings"), "Esc with nothing open opens Settings", "", "major")
	await tap(KEY_ESCAPE)
	await frames(4)
	if ui.is_open("settings"):
		bug("critical", "Settings cannot be closed with Esc", "second Esc leaves Settings open")
		close_all_panels()


func _p_walk_to_graves() -> void:
	phase("walk")
	var gr := await walk_to(0.0, -8.0, 2.0, 60.0)
	chk(gr, "walk Chapterhouse -> Graves", "ended at (%.1f,%.1f) %s" % [body().position.x, body().position.z, g.area_id], "critical")
	await frames(3)
	chk(g.area_id == "graves", "area_id is graves after the walk", g.area_id)


## Controlled damage probe: waves paused, the Graves emptied, then 3 single robbers killed with ONE left click each (the primary's chase and
## hold-repeat only, no rites, no thralls), and one pack of 6 killed with the full bot rotation. Time to kill is the comparison: it isolates hero damage /
## enemy toughness from wave pacing and bot retargeting.
func _p_dps() -> void:
	phase("dps")
	g.director.enabled = false
	for e in g.director.enemies.values().duplicate():
		if is_instance_valid(e):
			e.queue_free()
	await frames(10)
	var b := body()
	var times: Array = []
	for i in 3:
		b.restore_vitals()
		var e := g.director.spawn("robber", b.position + Vector3(5.0, 0.0, 0.0), [b])
		await wait(2.0)   # rising
		var t0 := game_ms
		var sp := _enemy_screen(e, 0.9 * e.scale.y)
		mouse_to(sp)
		await frames(2)
		if sv.gui_get_hovered_control() == null:
			await click(sp)
		else:
			g.input.attack(int(e.get_meta(&"dm_id", 0)), false)
		while is_alive_enemy(e) and game_ms - t0 < 40000.0 and b.alive:
			await frames(3)
		times.append(snappedf((game_ms - t0) / 1000.0, 0.1))
		if is_instance_valid(e) and is_alive_enemy(e):
			e.queue_free()
		await wait(1.0)
	metrics["dps_single_ttk_s"] = times
	metrics["dps_enemy_hp"] = snappedf(float(DmSimData.ENEMIES["robber"]["hp"]) * DmEnemyStats.hp_scale(1.0), 0.1)
	var t1 := game_ms
	var k0 := kills
	var th0 := max_thralls
	for i in 6:
		var a := float(i) / 6.0 * TAU
		g.director.spawn("robber", b.position + Vector3(cos(a) * 7.0, 0.0, sin(a) * 7.0), [b])
	b.restore_vitals()
	await wait(2.0)
	var pack_hp := 1.0
	var min_hp := b.hp
	while alive_enemies().size() > 0 and game_ms - t1 < 60000.0 and b.alive:
		var e2 := nearest_enemy()
		await _manual_tick(e2)
		min_hp = minf(min_hp, b.hp)
	metrics["dps_pack6_hp_lost"] = snappedf(b.max_hp - min_hp, 0.1)
	metrics["dps_pack6_ttk_s"] = snappedf((game_ms - t1) / 1000.0, 0.1)
	metrics["dps_pack6_kills"] = kills - k0
	metrics["dps_pack6_alive_after"] = alive_enemies().size()
	metrics["dps_pack6_hero_alive"] = b.alive
	note("dps probe: single robber ttk %s s, pack of 6 cleared in %.1f s (%d kills)" % [str(times), (game_ms - t1) / 1000.0, kills - k0])
	for e3 in alive_enemies():
		e3.queue_free()
	g.director.enabled = true
	b.restore_vitals()
	await wait(1.0)


func _p_fight() -> void:
	phase("fight")
	uh.inventory.add({"item_id": "flask_hp_minor", "quantity": 6})
	var fl0 := uh.inventory.count("flask_hp_minor")
	watch["assist"] = 0
	var gold0 := gold()
	var xp0 := xp_total()
	var xp0c := _cum_xp(g.character)
	var d0 := deaths_seen
	var picks0 := picks.duplicate()
	var loot0 := int(ev_counts.get("loot", 0))
	var shards0 := int(uh.prog.local.get("shards", 0))
	var k := await fight(75.0, "graves")
	var gain := gold() - gold0
	note("manual fight 75 s (reaction delay %d ms): %d kills, gold %+d, max enemies %d, max thralls %d, hero deaths %d" % [int(delay_ms), k, gain, max_enemies, max_thralls, deaths_seen - d0])
	metrics["fight_kills_75s"] = k
	metrics["fight_gold_gain"] = gain
	metrics["fight_xp_gain"] = int(_cum_xp(g.character) - xp0c)
	metrics["fight_level_after"] = int(g.character["level"])
	metrics["fight_deaths"] = deaths_seen - d0
	metrics["fight_flasks_used"] = fl0 + 5 * int(watch.get("assist", 0)) - uh.inventory.count("flask_hp_minor")
	metrics["fight_min_hp_frac"] = snappedf(min_hp_frac, 0.01)
	metrics["enemy_avg_damage"] = snappedf(seen_dmg / maxf(seen_ids.size(), 1.0), 0.1)
	metrics["enemies_seen"] = seen_ids.size()
	metrics["enemy_avg_max_hp"] = snappedf(seen_hp / maxf(seen_ids.size(), 1.0), 0.1)
	metrics["fight_loot_items"] = int(ev_counts.get("loot", 0)) - loot0
	metrics["fight_shards"] = int(uh.prog.local.get("shards", 0)) - shards0
	chk(k >= 3, "manual combat kills enemies (%d in 75 s)" % k, "enemies=%d hp=%.0f/%.0f" % [alive_enemies().size(), body().hp, body().max_hp], "critical")
	chk(xp_total() > xp0, "xp rises from kills", "", "major")
	chk(gold() >= gold0, "gold does not fall during combat", "", "major")
	chk(max_thralls >= 1, "raised at least one thrall", "max_thralls=%d" % max_thralls, "major")


func _p_loot_equip() -> void:
	phase("loot")
	await fight(20.0, "graves")
	var m: DmRewardsMember = g.rewards.members.get(int(g.character["id"]))
	var drops: Array = m.loot_view.debug_drops()
	note("%d drops on the ground" % drops.size())
	var bag0: int = uh.slots.size()
	var gold0 := gold()
	var loot0 := int(ev_counts.get("loot", 0))
	var shards0 := int(uh.prog.local.get("shards", 0))
	for d in drops.slice(0, 12):
		var guard := 0
		while (not body().alive or g.area_id != "graves") and guard < 40:
			guard += 1
			await wait(1.0)
			if body().alive and g.area_id != "graves":
				await walk_to(0.0, -10.0, 3.0, 20.0)
		if g.area_id != "graves":
			break
		walk_soft = true
		await walk_to(float(d["x"]), float(d["z"]), 0.8, 15.0)
		walk_soft = false
	await wait(1.0)
	var picked := int(ev_counts.get("loot", 0)) - loot0
	metrics["loot_drops_seen"] = drops.size()
	metrics["loot_items_picked"] = picked
	metrics["loot_gold_gained"] = gold() - gold0
	metrics["loot_shards_gained"] = int(uh.prog.local.get("shards", 0)) - shards0
	if drops.size() > 0:
		chk(uh.slots.size() > bag0 or gold() > gold0 or m.loot_view.count() < drops.size() or picked > 0, "walking over drops picks them up", "bag %d->%d gold %d->%d drops left %d" % [bag0, uh.slots.size(), gold0, gold(), m.loot_view.count()], "major")
	# equip / unequip through the Reliquary
	var gear_id := ""
	for id in DmContent.items():
		var meta: Dictionary = DmContent.items()[id]
		if String(meta.get("type", "")) in ["weapon", "chest_armor", "head_armor", "armor"] and String(meta.get("rarity", "common")) == "common":
			gear_id = id
			break
	if gear_id != "":
		uh.inventory.add({"item_id": gear_id, "quantity": 1})
	await tap(KEY_I)
	await frames(6)
	var equippable: Dictionary = {}
	for s in uh.slots:
		if DmGear.equip_slot_of(s) != "" and int(s.get("equipped", 0)) == 0:
			equippable = s
			break
	if equippable.is_empty():
		note("no equippable gear in the bag (gear_id=%s)" % gear_id)
	else:
		await ui.inv.toggle_equip(equippable)
		await frames(10)
		chk(_is_equipped(equippable["item_id"]), "equip moves the item to the equipped set", equippable["item_id"], "major")
		for s in uh.slots:
			if s["item_id"] == equippable["item_id"] and int(s.get("equipped", 0)) != 0:
				await ui.inv.toggle_equip(s)
				break
		await frames(10)
		chk(not _is_equipped(equippable["item_id"]), "unequip returns it to the bag", equippable["item_id"], "major")
		for s in uh.slots:
			if s["item_id"] == equippable["item_id"] and int(s.get("equipped", 0)) == 0:
				await ui.inv.toggle_equip(s)
				break
		await frames(10)
	await tap(KEY_ESCAPE)
	close_all_panels()
	await frames(3)


func _is_equipped(item_id: String) -> bool:
	for s in uh.slots:
		if s["item_id"] == item_id and int(s.get("equipped", 0)) != 0:
			return true
	return false


func _p_levelup() -> void:
	phase("levelup")
	var lv0 := int(g.character["level"])
	var hp0 := body().max_hp
	g.progress.grant_xp(float(DmStats.xp_to_next(float(lv0))) * 2.5)
	await frames(5)
	chk(int(g.character["level"]) > lv0, "xp grant levels the hero up", "%d -> %d" % [lv0, int(g.character["level"])], "major")
	chk(body().max_hp >= hp0, "max hp does not fall on level up", "%.0f -> %.0f" % [hp0, body().max_hp], "minor")
	note("events seen: %s" % str(ev_counts.keys()))


func _p_boss() -> void:
	for bid in boss_pick.split(","):
		await _p_boss_one(String(bid))


func _p_boss_one(boss_id: String) -> void:
	phase("boss")
	var def: Dictionary = DmContent.boss(boss_id)
	step = "assist-xp"
	# assists (noted): a level-30 hero with the shards in hand; the fight itself is unassisted except an hp floor of 35%
	var b := body()
	for i in 40:   # the real xp path (what a Depths floor grants), so the level is banked like any other
		if int(g.character["level"]) >= 30:
			break
		g.progress.grant_xp(float(DmStats.xp_to_next(float(g.character["level"]))))
		await frames(2)   # one level-up per frame, like play: 29 in one frame is a bot-made hitch
	await frames(3)
	uh.prog.local["shards"] = 99
	note("assist: level 30, 99 shards, hp floor 35%")
	var guard := 0
	while not b.alive and guard < 20:   # a hero that died in an earlier phase must respawn first (it would be sent home again)
		guard += 1
		await wait(1.0)
	step = "teleport"
	var site := g.bosses.site_pos(boss_id)
	b.teleport(Vector3(site.x, 0.0, site.z + 2.0))
	await frames(5)
	b.restore_vitals()
	for i in 20:
		if g.bosses.active_boss() == null:
			break
		await wait(1.0)
	step = "summon"
	var t_summon := game_ms
	await tap(KEY_E)   # the real input: E at the grave
	await wait(3.0)
	var bs: DmBoss = g.bosses.active_boss()
	if bs == null:
		note("E did not wake it (toasts: %s): calling request_summon" % recent_toasts())
		g.bosses.request_summon(boss_id)
		await wait(3.0)
		bs = g.bosses.active_boss()
	chk(bs != null, "%s wakes when summoned at its site" % boss_id, "shards=%s toasts: %s" % [str(uh.prog.local["shards"]), recent_toasts()], "critical")
	if bs == null:
		return
	step = "boss-fight"
	boss_t0 = game_ms
	var life0: float = g.chron.life("boss." + boss_id)
	var start := game_ms
	var d0 := deaths_seen
	var trace: Array = []
	var tr_next := 0.0
	var arena: Dictionary = def["arena"]
	while g.bosses.active_boss() != null and game_ms - start < 420000.0:
		bs = g.bosses.active_boss()
		b = body()
		if not b.alive:
			await wait(5.0)
			b.teleport(Vector3(float(arena["x"]), 0.0, float(arena["z"]) + float(arena["r"]) * 0.7))
			continue
		if verbose_boss and game_ms - start < 6000.0:
			var near: Array = []
			for e in g.director.enemies.values():
				if is_instance_valid(e) and e.global_position.distance_to(b.position) < 8.0:
					near.append("%s(%.0f)" % [str(e.def.get("id", e.name)) if e.def is Dictionary else str(e.name), e.damage])
			print("BOSSDBG %.1fs hero hp %.0f/%.0f at %s boss at %s phase %d near=%s" % [(game_ms - start) / 1000.0, b.hp, b.max_hp, str(b.position), str(bs.global_position), bs.phase, str(near).left(150)])
		if b.hp < b.max_hp * 0.35:
			b.heal(b.max_hp * 0.35 - b.hp)
		if b.resource < 40.0:
			b.p["resource"]["value"] = 40.0
			b.resource = 40.0
		var sp := _enemy_screen(bs, 1.7)
		mouse_to(sp)
		if bs.global_position.distance_to(b.position) > 12.0:
			g.input.click_move(bs.global_position + Vector3(3.0, 0.0, 3.0))
		elif sv.gui_get_hovered_control() == null and not g.camera.is_position_behind(bs.global_position):
			await click(sp)
		_rot += 1
		var codes := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_R]
		await tap(codes[_rot % 5], 1)
		await frames(10)
		if game_ms > tr_next:
			tr_next = game_ms + 20000.0
			trace.append(snappedf(float(bs.hp) / maxf(float(bs.max_hp), 1.0), 0.01))
	var dur := (game_ms - start) / 1000.0
	await wait(1.5)
	var k_before: float = life0   # a boss that went back to sleep because the hero died is NOT a kill: the chronicle's count is the truth
	var dead := g.bosses.active_boss() == null and g.chron.life("boss." + boss_id) > k_before
	note("boss %s: defeated=%s after %.0fs game, boss hp trace %s, hero deaths %d" % [boss_id, str(dead), dur, str(trace), deaths_seen - d0])
	metrics["boss_id"] = boss_id
	metrics["boss_defeated"] = dead
	metrics["boss_time_s"] = snappedf(dur, 0.1)
	metrics["boss_deaths"] = deaths_seen - d0
	if boss_id in ["saint", "regent", "mire"]:
		# the late area bosses burst a level-30 hero that stands in melee: this bot has no dodge (the current game's bot never beat them either)
		chk(dead, "%s is defeated within 7 min of game time" % boss_id, "hero died %d time(s), boss at %.0f%% (bot has no dodge)" % [deaths_seen - d0, 100.0 * float(trace.back() if not trace.is_empty() else 1.0)], "minor")
	else:
		chk(dead, "%s is defeated within 7 min of game time" % boss_id, "hero died %d time(s)" % (deaths_seen - d0), "critical")
	if not dead:
		return
	var m: DmRewardsMember = g.rewards.members.get(int(g.character["id"]))
	chk(g.chron.life("boss." + boss_id) >= 1.0, "boss kill is recorded in the chronicle (boss.%s)" % boss_id, "keys=%s" % str(g.chron.chronicle.view()["life"].keys().filter(func(k): return String(k).begins_with("boss"))), "major")
	b.restore_vitals()
	if m != null:
		note("loot on the ground after the boss: %d" % m.loot_view.count())


func _p_death() -> void:
	phase("death")
	var b := body()
	var guard := 0
	while not b.alive and guard < 20:   # a hero that died in the boss phase must be back first
		guard += 1
		await wait(1.0)
	b.teleport(Vector3(0.0, 0.0, -10.0))
	await frames(5)
	var gold0 := gold()
	var xp0 := xp_total()
	var d0 := deaths_seen
	var r0 := respawns_seen
	b.take_damage(b.max_hp * 9.0, null)
	await frames(3)
	chk(not b.alive and deaths_seen == d0 + 1, "lethal hit kills the hero once", "deaths %d->%d" % [d0, deaths_seen], "major")
	var p0 := b.position
	await tap(KEY_W, 10)
	chk(b.position.distance_to(p0) < 0.5, "a dead hero does not walk", "", "major")
	await wait(5.5)
	chk(b.alive and respawns_seen == r0 + 1, "hero respawns after the death timer", "alive=%s respawns %d->%d" % [str(b.alive), r0, respawns_seen], "critical")
	chk(g.area_id == "chapterhouse", "respawn point is the Chapterhouse", g.area_id, "major")
	chk(b.hp > 0.0, "respawned with hp > 0", "%.1f" % b.hp, "major")
	chk(gold() >= gold0 and xp_total() >= xp0, "death takes nothing", "gold %d->%d" % [gold0, gold()], "major")


func _snapshot() -> Dictionary:
	var eq: Array = []
	var bag := 0
	for s in uh.slots:
		if int(s.get("equipped", 0)) != 0:
			eq.append(String(s["item_id"]))
		else:
			bag += int(s["quantity"])
	eq.sort()
	return {"level": int(g.character["level"]), "xp": int(g.character["experience"]), "gold": gold(), "equipped": eq, "bag_qty": bag,
		"graves_kills": uh.prog.kills("graves"), "boss_kills": int(g.chron.life("boss.gravedigger")), "class": int(g.character["class_index"]),
		"id": int(g.character["id"])}


func _p_persist_snapshot() -> void:
	phase("persist")
	await g.flush_all()
	var snap := _snapshot()
	var f := FileAccess.open("user://playtest_snapshot.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(snap))
	f.close()
	note("snapshot %s" % str(snap))
	write_report()
	main._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)   # the real window-close path (Main flushes, then quits)
	await frames(30)


func _session_b() -> void:
	phase("relaunch")
	var f := FileAccess.open("user://playtest_snapshot.json", FileAccess.READ)
	if not chk(f != null, "snapshot from session A exists in user://", "", "critical"):
		return
	var snap: Dictionary = JSON.parse_string(f.get_as_text())
	await frames(20)
	if main.slice == null and main.flow != null and main.flow.current_name == "login":
		note("relaunch showed the login screen (no resumed session): logging in on the screen")
		var l := main.flow.current as DmLoginScreen
		l.user_edit.text = _account()["user"]
		if l.pass_edit != null:
			l.pass_edit.text = _account()["pw"]
		var ok: bool = await l.submit()
		if not chk(ok, "offline account survives relaunch (login)", String(l.error_label.text), "critical"):
			return
	else:
		note("relaunch resumed the saved session straight into the world")
	if not await _wait_world():
		bug("critical", "world does not come up after relaunch")
		return
	_hook_game()
	await frames(30)
	var now: Dictionary = JSON.parse_string(JSON.stringify(_snapshot()))
	for k in ["level", "gold", "equipped", "graves_kills", "boss_kills", "class", "id", "xp"]:
		chk(str(now[k]) == str(snap[k]), "persisted across relaunch: %s" % k, "%s -> %s" % [str(snap[k]), str(now[k])], "critical")
	chk(int(now["bag_qty"]) == int(snap["bag_qty"]), "persisted across relaunch: bag quantity", "%s -> %s" % [snap["bag_qty"], now["bag_qty"]], "major")
	await walk_to(0.0, -10.0, 3.0, 40.0)
	var k := await fight(20.0, "graves")
	metrics["relaunch_fight_kills_20s"] = k
	chk(k >= 1, "combat works after relaunch (%d kills)" % k, "", "major")
	write_report()
	main._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await frames(30)
