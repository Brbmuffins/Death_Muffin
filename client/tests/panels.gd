extends SceneTree
## Today's panels on the core (DECISIONS B46): the game scene with today's HUD and panels (DmGameUi on the ported DmNextUiHost), a dev
## character on the local mock backend only (never a real server), headless. Checks:
##   - every panel this build warms opens and closes (DmGameUi.toggle_panel); the menu row's Reliquary button opens the Reliquary;
##   - the Reliquary: equipping the weapon in the bag is the server's (api.equip_item, the bag read back through the loot node) and the hero's build and worn look follow;
##     taking it off again; selling a flask pays its price and the bag holds one fewer; sorting is answered by the server;
##   - the Grimoire's loadout: set_rites puts another rite on key 1 (the game's rite_for_slot follows) and a press on key 1 casts it;
##   - Settings: a graphics preset applied live reaches the game (DmNextPerf); damage numbers off keeps the hit numbers away;
##   - chat: a solo line says nobody hears;
##   - the questions the combat input and the counsel ask a dozen times a second: panel_open() follows the windows' own visibility (a flag they set, no scan), the Ascension
##     guidance asks the Prelate count before it builds a progression (the same answer as the progression's);
##   - ZERO script errors or engine errors in the log.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/panels.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


const HERO_LEVEL := 12   ## the dev character's level: the rites it knows (the Grimoire section) are the ones unlocked by then

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var api: DmApi
var hero: DmHeroBody


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL panels: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while not bool(cond.call()) and Time.get_ticks_msec() < end:
		await process_frame
	return bool(cond.call())


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var reg := await api.register("panels%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, HERO_LEVEL)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["graves"], "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "persist": false})
	hero = g.local_body()
	check(g.ui != null and g.ui_host != null and g.ui.hud != null, "the game scene has today's HUD and panels on the adapter")
	await _every_panel()
	await _reliquary()
	await _grimoire()
	await _settings()
	await _chat()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s panels %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ the panels

func _every_panel() -> void:
	var closed := []
	for p: String in g.ui.warm_panels:
		g.ui.close_panels()
		g.ui.toggle_panel(p)
		await ticks(2)
		var opened := g.ui.is_open(p)
		g.ui.toggle_panel(p)
		await ticks(2)
		if not opened or g.ui.is_open(p):
			closed.append(p)
	check(closed.is_empty(), "every panel this build warms opens and closes (%d panels; not: %s)" % [g.ui.warm_panels.size(), str(closed)])
	g.ui.close_panels()
	await ticks(2)
	check(not g.ui.panel_open(), "with every window closed, panel_open() says so")
	g.ui.hud.menu_btns["inventory"].pressed.emit()
	await ticks(2)
	check(g.ui.is_open("inventory"), "the menu row's Reliquary button opens the Reliquary")
	check(g.ui.panel_open(), "and panel_open() follows it")
	g.ui.close_panels()
	await ticks(2)
	check(not g.ui.panel_open(), "and follows it closing")
	g.ui.toggle_panel("grimoire")
	await ticks(2)
	check(g.ui.panel_open(), "a window of the panel files (the Grimoire) counts too")
	g.ui.close_panels()
	await ticks(2)
	check(not g.ui.panel_open(), "and stops counting when it closes")
	var run: Dictionary = g.ui_host.progress.get("run", {})
	var kills0: Variant = run.get("prelateKills")
	for kills in [0, 1, 2]:
		run["prelateKills"] = kills
		var full := DmProgression.new(g.character, g.ui_host.progress).ashes_on_ascend()
		var st := g.ui.guidance_state()
		check(g.ui._ashes_on_ascend() == full and bool(st["canAscend"]) == (full > 0 and DmAscension.OPEN) and int(st["ascension"]) == (int(g.ui_host.progress.get("ascension", 0)) if DmAscension.OPEN else 0),
			"the Ascension guidance agrees with the progression with %d Prelate kills (%d ashes), and offers nothing while Ascension is out (B36)" % [kills, full])
	run["prelateKills"] = kills0


# ------------------------------------------------------------------------------------------------------------------ the Reliquary

func _row_of(item_id: String) -> Dictionary:
	for r: Dictionary in g.loot.slots():
		if String(r.get("item_id", "")) == item_id:
			return r
	return {}


func _reliquary() -> void:
	var staff := _row_of("staff_oak")
	check(not staff.is_empty() and int(staff.get("equipped", 0)) == 0, "the bag holds the new character's oak staff, not worn")
	var build0: Dictionary = g.build_for(g.session.get_my_id())
	await g.ui.inv.toggle_equip(staff)
	await ticks(3)   # the stats re-read on the next frame (DmNextProgress.request_stats)
	staff = _row_of("staff_oak")
	check(int(staff.get("equipped", 0)) != 0, "equipping is the server's: the bag read back shows the staff worn")
	var build1: Dictionary = g.build_for(g.session.get_my_id())
	check(JSON.stringify(build1["stats"]) != JSON.stringify(build0["stats"]), "the hero's build follows the worn staff (its stats changed)")
	check(g.look._gear.has("main_hand") and String(g.look._gear["main_hand"][0]) == "staff_oak", "the worn look shows the staff in the main hand (%s)" % str(g.look._gear))
	await g.ui.inv.toggle_equip(staff)
	await ticks(3)
	check(int(_row_of("staff_oak").get("equipped", 0)) == 0 and not g.look._gear.has("main_hand"), "taking it off again empties the hand")
	var flask := _row_of("flask_hp_minor")
	var n0 := int(flask.get("quantity", 0))
	var gold0 := int(g.character.get("gold", 0))
	var r: DmResult = await g.ui_host.sell_items([{"slot_index": int(flask["slot_index"]), "quantity": 1}])
	check(r.ok and int(_row_of("flask_hp_minor").get("quantity", 0)) == n0 - 1, "selling a flask: the bag holds one fewer (%d -> %d)" % [n0, int(_row_of("flask_hp_minor").get("quantity", 0))])
	check(int(g.character.get("gold", 0)) > gold0, "and the server paid its price (%d -> %d)" % [gold0, int(g.character.get("gold", 0))])
	var why: String = await g.ui_host.bag_sort()
	check(why == "", "sorting the bag is answered by the server (%s)" % why)


# ------------------------------------------------------------------------------------------------------------------ the Grimoire

func _grimoire() -> void:
	var host := g.ui_host
	var other := ""
	for id: String in host.kit["primaries"] + host.kit["grimoire"]:
		if not host.keys.has(id) and id != host.primary and DmAbilities.unlock_level(id) <= HERO_LEVEL and DmRiteRegistry.has(id) and not DmNextHudVm.NEEDS.has(id):
			other = id
			break
	check(other != "", "a rite the character knows that is not on the hotbar (%s)" % other)
	var keys: Array = host.keys.duplicate()
	keys[0] = other
	host.set_rites(host.primary, keys)
	check(host.rite_at(1) == other and g.rite_for_slot(1) == other, "the Grimoire's loadout puts %s on key 1" % other)
	var caster := hero.get_node("Rites") as DmRiteCaster
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	var foe := g.core_host.spawn_enemy("robber", hero.position + Vector3(4, 0, 0), 1, 50.0, 0.0, false, "graves", false)   # something to aim at
	await ticks(2)
	var why := [""]
	caster.cast_rejected.connect(func(_r: String, reason: String) -> void: why[0] = reason)
	g.ui_host._on_hotbar(1, g.enemy_position(foe), foe)
	await ticks(5)
	check(caster.cooldown_left(other) > 0.0, "a press on key 1 casts it at an enemy: its cooldown runs (%s: %.2f s%s)" % [other, caster.cooldown_left(other), "" if why[0] == "" else ", refused: " + why[0]])
	g.core_host.remove_enemy(foe)


# ------------------------------------------------------------------------------------------------------------------ Settings

func _settings() -> void:
	var s: Dictionary = g.ui_host.settings.duplicate()
	s["graphics"] = "low"
	g.ui_host.apply_settings(s)
	await ticks(2)
	check(String(g.perf.preset) == "low", "a graphics preset applied in Settings reaches the game live (%s)" % str(g.perf.preset))
	var off := g.ui_host.settings.duplicate()
	off["damage_numbers"] = false
	g.ui_host.apply_settings(off)
	var floats0 := [0]
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void:
		if id == "float" and String(ctx.get("kind", "")) == "hit":
			floats0[0] += 1)
	g.ui_host.float_text(hero.position, "12", "hit")
	check(floats0[0] == 0, "damage numbers off: no hit number reaches the HUD")
	# the Co-op note tells the truth about the Depths: solo only, the stair turns a party away (it used to say a party steps out and rejoins)
	g.ui.set_ui.open()
	await ticks(2)
	var notes: Array = []
	var stack: Array = [g.ui]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Label and (n as Label).text.contains("Social window (O)") and (n as Label).text.contains("Catacomb Depths"):
			notes.append((n as Label).text)
		stack.append_array(n.get_children())
	check(notes.size() == 1 and notes[0].contains("solo descent") and notes[0].contains("turns a party away") and not notes[0].to_lower().contains("rejoin"),
		"Settings says the Depths are solo and the stair turns a party away (%s)" % str(notes))
	g.ui.close_panels()


# ------------------------------------------------------------------------------------------------------------------ chat

func _chat() -> void:
	var lines := []
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void:
		if id == "chat":
			lines.append(String(ctx.get("text", ""))))
	g.ui_host.send_chat("anyone?")
	check(lines.size() == 1 and lines[0].contains("Nobody hears you"), "a solo chat line says nobody hears (%s)" % str(lines))
