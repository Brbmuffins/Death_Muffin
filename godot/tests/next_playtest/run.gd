extends SceneTree
## Regressions found by the rebuild playtest bot (tests/playtest/bot_next.gd). godot --headless --path godot --script res://tests/next_playtest/run.gd
##   1 a free rite's cooldown runs down on the host even when the essence never changes (DmRiteCaster.cooldown_left read a stale replicated snapshot, so
##     the click-attack's primary repeat stalled after one cast at a full pool: a lone robber killed the hero in 16 s)
##   2 one left click on an enemy chases and repeats the primary until it dies (end to end, no rites, no thralls)
##   3 the first tooltip of a session (its layer joins the tree a frame later) does not log an engine error, and is placed one frame later
##   4 the bot's own contract: the playtest scripts parse and the --next flag is wired in tools/godot/playtest.sh

class TipLog extends Logger:
	var errors: Array
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, _bt: Array) -> void:
		errors.append("%s:%d %s %s" % [file.get_file(), line, code, rationale])

var passed := 0
var failed := 0
var g: DmNextGame
var hero: DmHeroBody


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


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("pp%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false})
	hero = g.local_body()
	await ticks(3)
	var caster := hero.get_node("Rites") as DmRiteCaster

	# 1: cooldown of the free primary, essence full the whole time
	caster.p["resource"]["value"] = caster.p["resource"]["max"]
	caster.p["cooldowns"].clear()
	caster.p["castUntil"] = 0.0
	hero.teleport(Vector3(0.0, 0.0, -8.0))
	await ticks(3)
	caster.p["cooldowns"]["bone_needle"] = caster._now_ms + 380.0   # what an accepted primary cast sets (a free rite: no essence change, no state push)
	caster.push_state()
	await ticks(1)
	check(caster.cooldown_left("bone_needle") > 0.0, "1: the primary is cooling down")
	var full := float(caster.p["resource"]["max"])
	await ticks(60)   # 1 s: far past the 380 ms cooldown
	check(is_equal_approx(float(caster.p["resource"]["value"]), full), "1: the essence stayed full (the primary is free), so no state push was forced")
	check(caster.cooldown_left("bone_needle") == 0.0, "1: the cooldown ran out on the host (%.0f ms left)" % caster.cooldown_left("bone_needle"))

	# 2: one click-attack kills a lone robber with the primary alone
	g.director.enabled = false
	var e: DmEnemy = g.director.spawn("robber", hero.position + Vector3(5, 0, 0), [hero])
	await ticks(150)   # rising
	g.input.attack(int(e.get_meta(&"dm_id", 0)), false)
	var t0 := Time.get_ticks_msec()
	while DmRiteCaster.alive_enemy(e) and Time.get_ticks_msec() - t0 < 12000 and hero.alive:
		await physics_frame
	check(not DmRiteCaster.alive_enemy(e), "2: a single click-attack kills the robber (%d primary casts, hero alive %s)" % [g.input.combat.stats["primary_casts"], str(hero.alive)])
	check(int(g.input.combat.stats["primary_casts"]) >= 3, "2: the primary repeated (%d casts)" % g.input.combat.stats["primary_casts"])

	# 3: first tooltip
	var errs: Array = []
	var lg := TipLog.new()
	lg.errors = errs
	OS.add_logger(lg)
	var owner_ctl := Button.new()
	owner_ctl.size = Vector2(60, 40)
	owner_ctl.position = Vector2(200, 300)
	root.add_child(owner_ctl)
	var tip := DmTip.of(owner_ctl)
	var card := Label.new()
	card.text = "Bone Needle"
	tip.show_anchor(owner_ctl, card)
	await process_frame
	await process_frame
	await process_frame
	check(errs.is_empty(), "3: the first tooltip raised no engine error (%s)" % [errs])
	check(card.is_inside_tree() and card.get_parent() == tip and card.size.x > 0.0, "3: the card is in the tree and sized after the layer joined")
	tip.hide_now()
	OS.remove_logger(lg)
	owner_ctl.queue_free()

	# 4: bot wiring
	var sh := FileAccess.get_file_as_string("res://../tools/godot/playtest.sh")
	check(sh.contains("--next") and sh.contains("bot_next.gd"), "4: playtest.sh drives the rebuild with --next")
	for f in ["res://tests/playtest/bot_next.gd"]:
		check(load(f) != null, "4: %s loads" % f)

	g.queue_free()
	await ticks(3)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
