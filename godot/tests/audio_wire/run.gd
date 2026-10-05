extends SceneTree
## Audio wiring test (headless, dummy audio driver): drives a scripted session through the real DmGame (offline mock backend); the Settings panel wiring is tested in tests/game_ui and asserts the AudioDirector
## received the expected calls.   godot --headless --audio-driver Dummy --path godot --script res://tests/audio_wire/run.gd

var _fail := 0
var _pass := 0
var played: Array[String] = []
const CFG := "user://settings_test.cfg"

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _wait(sec: float) -> void:
	await create_timer(sec).timeout

func _heard(prefix: String) -> bool:
	for s in played:
		if s.begins_with(prefix):
			return true
	return false

func _initialize() -> void:
	_run.call_deferred()

var _mock: DmMockBackend

func _run() -> void:
	var ad: Node = get_root().get_node("AudioDirector")
	ad.sfx_played.connect(func(n: String) -> void: played.append(n))
	_mock = DmOffline.make_mock("")
	var api := DmOffline.make_api(_mock)
	var r := await api.register("audiotest", "a@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	get_root().add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "seed": 3, "local_progress": true})
	await _frames(5)
	# --- area music + ambience on start
	_check(ad.current_area() == "acre", "set_area(acre) on start, got '%s'" % ad.current_area())
	await _wait(1.0)
	_check(ad.music_cue() != "", "area music cue running in the acre: '%s'" % ad.music_cue())
	var cue_a: String = ad.music_cue()
	# --- walk: footsteps follow the hero
	played.clear()
	game.player.move_to(-26.0, 10.0)
	for i in 120:
		await process_frame
		await _wait(0.02)
	_check(_heard("step"), "hero footsteps while walking (heard: %s)" % str(played.slice(0, 6)))
	_check(not game.audio_hooks.is_wet(-26.0, 20.0), "acre start is dry")
	# --- area change -> set_area
	game.player.teleport(0.0, -10.0)
	await _frames(4)
	_check(game.area_id == "graves" and ad.current_area() == "graves", "area change -> set_area(graves), got '%s'" % ad.current_area())
	await _wait(1.0)
	_check(ad.music_cue() != "", "graves music cue: '%s' (acre was '%s')" % [ad.music_cue(), cue_a])
	# --- cast + enemy death + thrall
	var foe := game.sim.spawn_enemy("robber", "graves", game.player.x + 4.0, game.player.z, false, false)
	await _frames(2)
	played.clear()
	game.p["castUntil"] = 0.0
	game.abilities.cast(game.primary, {"x": foe.x, "z": foe.z, "enemyId": foe.id}, game.now_ms)
	await _wait(0.5)
	_check(_heard("needleCast") or _heard("scytheSwing") or _heard("needle") or played.size() > 0, "a rite makes a sound (heard: %s)" % str(played))
	foe.hp = 1.0
	game.sim.damage_enemy(foe, 100000.0, game.self_id)
	await _frames(3)
	_check(_heard("enemyDeath"), "enemy death sound (heard: %s)" % str(played))
	played.clear()
	game.p["resource"]["value"] = 100.0
	game.p["castUntil"] = 0.0
	game.p["cooldowns"].erase("exhume")
	game.abilities.cast("exhume", {"x": foe.x, "z": foe.z}, game.now_ms)
	await _wait(1.3)
	_check(_heard("exhume"), "exhume cast sound (heard: %s)" % str(played))
	# --- hurt / error / loot drop hooks
	played.clear()
	DmAudioHooks.hero_hurt(10.0, 100.0)
	DmAudioHooks.error()
	DmAudioHooks.loot_drop("epic", Vector3(game.player.x, 0, game.player.z))
	await _wait(0.2)
	_check(_heard("hurt"), "hero hurt sound")
	_check(_heard("error"), "error sound")
	_check(_heard("lootDropEpic"), "epic loot drop sound")
	# --- door / seal sound when a gate opens
	var door: Dictionary = {}
	for d in DmData.world().doors:
		if not game.builder.gates.get(d.id, {"open": true}).open:
			door = d
			break
	_check(not door.is_empty(), "a sealed door exists")
	if not door.is_empty():
		game.player.teleport(float(door.cx) + 2.0, float(door.cz))
		await _frames(3)
		played.clear()
		game.builder.set_door_open(door.id, true, true)
		await _frames(3)
		_check(_heard("gate"), "gate sound when a seal opens (heard: %s)" % str(played))
	# --- boss music hook (the game loop stops driving it, the test does)
	game.set_process(false)
	game.audio_hooks.update_boss(true, true, ad.current_area())
	await _frames(2)
	_check(ad.music_cue().contains("boss") or ad.music_cue() != cue_a, "boss music hook changes the cue: '%s'" % ad.music_cue())
	var boss_cue: String = ad.music_cue()
	game.audio_hooks.update_boss(true, false, ad.current_area())
	await _frames(2)
	_check(ad.music_cue() != boss_cue, "boss music off restores the area cue: '%s'" % ad.music_cue())
	game.queue_free()
	await _frames(3)
	_check(ad.current_area() == "", "leaving the world stops the area (stop_area)")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
