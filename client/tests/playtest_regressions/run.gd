extends SceneTree
## Regressions found by the rebuild playtest bot (tests/playtest/bot_next.gd). godot --headless --path client --script res://tests/playtest_regressions/run.gd
##   1 a free rite's cooldown runs down on the host even when the essence never changes (DmRiteCaster.cooldown_left read a stale replicated snapshot, so
##     the click-attack's primary repeat stalled after one cast at a full pool: a lone robber killed the hero in 16 s)
##   2 one left click on an enemy chases and repeats the primary until it dies (end to end, no rites, no thralls)
##   3 the first tooltip of a session (its layer joins the tree a frame later) does not log an engine error, and is placed one frame later
##   (the old suite's 4th part, the playtest bot's own contract in tools/godot/playtest.sh, is the old game's tool and not here)

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
	await g.start(c.data, api, {"dressing": false, "persist": false, "waves": false, "hud": true})
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

	# 2: one click-attack kills a lone robber with the primary alone. The robber's health is a share of the primary's own damage, so it takes the primary several casts
	# whatever the primary hits for: first one click-attack on a body that cannot die measures what a cast takes off, then the robber is made with six casts' worth.
	g.director.enabled = false
	var host := g.core_host
	var casts0 := int(g.input.combat.stats["primary_casts"])
	var soak: int = host.spawn_enemy("robber", hero.position + Vector3(5, 0, 0), 1, 1000.0, 0.0, false, "graves", false)   # a soak body: it does not hurt
	await ticks(150)   # rising
	var soak_max := float(host.core.enemy_info(soak)["max_hp"])
	g.input.attack(soak, false)
	var t_soak := Time.get_ticks_msec()
	while int(g.input.combat.stats["primary_casts"]) < casts0 + 4 and Time.get_ticks_msec() - t_soak < 12000:
		await physics_frame
	await ticks(60)   # the last cast lands
	var soak_casts := int(g.input.combat.stats["primary_casts"]) - casts0
	var per_cast := (soak_max - float(host.core.enemy_info(soak)["hp"])) / maxf(1.0, float(soak_casts))
	host.remove_enemy(soak)
	check(soak_casts >= 3 and per_cast > 0.0, "2: the primary repeated on the soak body and took %.1f off a cast (%d casts)" % [per_cast, soak_casts])
	var hp_mult := per_cast * 6.0 / (soak_max / 1000.0)   # six casts of health, in multiples of the robber's own
	var e: int = host.spawn_enemy("robber", hero.position + Vector3(5, 0, 0), 1, hp_mult, 0.0, false, "graves", false)
	await ticks(150)   # rising
	var casts1 := int(g.input.combat.stats["primary_casts"])
	g.input.attack(e, false)
	var t0 := Time.get_ticks_msec()
	while g.core_host.enemy_alive(e) and Time.get_ticks_msec() - t0 < 12000 and hero.alive:
		await physics_frame
	check(not g.core_host.enemy_alive(e), "2: a single click-attack kills the robber (%d primary casts, hero alive %s)" % [int(g.input.combat.stats["primary_casts"]) - casts1, str(hero.alive)])
	check(int(g.input.combat.stats["primary_casts"]) - casts1 >= 3, "2: the primary repeated (%d casts)" % [int(g.input.combat.stats["primary_casts"]) - casts1])

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

	g.queue_free()
	await ticks(3)
	print("%d passed, %d failed" % [passed, failed])
	print("%s playtest_regressions %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)
