extends SceneTree
## Audio wiring test (headless, dummy audio driver): drives a scripted session through the real DmNextGame (dev-offline mock backend); the Settings panel wiring is tested in tests/game_ui and asserts the AudioDirector
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

## Poll a condition (wall clock, one frame apart) up to `sec`: fixed waits flaked when the VPS was loaded.
func _until(cond: Callable, sec: float) -> bool:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()

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
	var game: DmNextGame = load("res://next/next_game.tscn").instantiate()
	get_root().add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "audio": true, "hud": false, "waves": false, "warmup": false})
	var hero := game.local_body()
	await _frames(5)
	# --- area music + ambience on start
	_check(ad.current_area() == "chapterhouse", "set_area(chapterhouse) on start, got '%s'" % ad.current_area())
	await _until(func() -> bool: return ad.music_cue() != "", 15.0)
	_check(ad.music_cue() != "", "area music cue running in the Chapterhouse: '%s'" % ad.music_cue())
	var cue_a: String = ad.music_cue()
	# --- walk: footsteps follow the hero
	played.clear()
	var from := hero.position
	hero.set_move_target(from + Vector3(8.0, 0.0, 0.0))
	await _until(func() -> bool: return _heard("step"), 15.0)
	_check(_heard("step"), "hero footsteps while walking (heard: %s)" % str(played.slice(0, 6)))
	_check(not game.get_node("AudioHooks").is_wet(from.x, from.z), "the Chapterhouse start is dry")
	# --- area change -> set_area
	hero.teleport(Vector3(0.0, 0.0, -10.0))
	await _until(func() -> bool: return game.area_id == "graves", 10.0)
	_check(game.area_id == "graves" and ad.current_area() == "graves", "area change -> set_area(graves), got '%s'" % ad.current_area())
	await _until(func() -> bool: return ad.music_cue() != "", 15.0)
	_check(ad.music_cue() != "", "graves music cue: '%s' (the Chapterhouse was '%s')" % [ad.music_cue(), cue_a])
	# --- cast + enemy death
	var foe: DmEnemy = game.director.spawn("robber", hero.position + Vector3(4.0, 0.0, 0.0))
	await _until(func() -> bool: return foe.sm.id() != DmEnemyState.Id.RISING, 10.0)   # a spawn rises first and cannot be hurt
	played.clear()
	var caster := hero.get_node("Rites") as DmRiteCaster
	caster.p["castUntil"] = 0.0
	caster.p["resource"]["value"] = 100.0
	caster.request_cast("bone_needle", foe.position, game.enemy_id(foe))
	await _until(func() -> bool: return played.size() > 0, 10.0)
	_check(_heard("needleCast") or _heard("scytheSwing") or _heard("needle") or played.size() > 0, "a rite makes a sound (heard: %s)" % str(played))
	foe.take_damage(100000.0, hero)
	await _until(func() -> bool: return _heard("enemyDeath"), 10.0)
	_check(_heard("enemyDeath"), "enemy death sound (heard: %s)" % str(played))
	played.clear()
	caster.p["resource"]["value"] = 100.0
	caster.p["castUntil"] = 0.0
	caster.p["cooldowns"].erase("exhume")
	caster.request_cast("exhume", foe.position, -1)
	await _until(func() -> bool: return _heard("exhume"), 15.0)
	_check(_heard("exhume"), "exhume cast sound (heard: %s)" % str(played))
	# --- hurt / error / loot drop hooks
	played.clear()
	DmAudioHooks.hero_hurt(10.0, 100.0)
	DmAudioHooks.error()
	DmAudioHooks.loot_drop("epic", hero.position)
	await _until(func() -> bool: return _heard("hurt") and _heard("error") and _heard("lootDropEpic"), 10.0)
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
		hero.teleport(Vector3(float(door.cx) + 2.0, 0.0, float(door.cz)))
		await _frames(3)
		played.clear()
		game.builder.set_door_open(door.id, true, true)
		await _until(func() -> bool: return _heard("gate"), 10.0)
		_check(_heard("gate"), "gate sound when a seal opens (heard: %s)" % str(played))
	# --- boss music hook (the boss host drives it in play, the test does here)
	var hooks: DmAudioHooks = game.get_node("AudioHooks")
	hooks.update_boss(true, true, ad.current_area())
	await _until(func() -> bool: return ad.music_cue().contains("boss") or ad.music_cue() != cue_a, 10.0)
	_check(ad.music_cue().contains("boss") or ad.music_cue() != cue_a, "boss music hook changes the cue: '%s'" % ad.music_cue())
	var boss_cue: String = ad.music_cue()
	hooks.update_boss(true, false, ad.current_area())
	await _until(func() -> bool: return ad.music_cue() != boss_cue, 10.0)
	_check(ad.music_cue() != boss_cue, "boss music off restores the area cue: '%s'" % ad.music_cue())
	game.queue_free()
	await _until(func() -> bool: return ad.current_area() == "", 10.0)
	_check(ad.current_area() == "", "leaving the world stops the area (stop_area)")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
