extends SceneTree
## Audio wiring test (headless, dummy audio driver): drives a scripted session through the real main scene and asserts the AudioDirector
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

func _run() -> void:
	var ad: Node = get_root().get_node("AudioDirector")
	ad.sfx_played.connect(func(n: String) -> void: played.append(n))
	var main: DmMain = load("res://main/main.tscn").instantiate()
	get_root().add_child(main)
	main.spawning_enabled = false
	main.settings_menu.cfg_path = CFG
	await _frames(5)
	# --- area music + ambience on start (a safe area)
	_check(ad.current_area() == "chapterhouse", "set_area(chapterhouse) on start, got '%s'" % ad.current_area())
	await _wait(1.0)
	_check(ad.music_cue() != "", "area music cue running in the chapterhouse: '%s'" % ad.music_cue())
	var cue_a: String = ad.music_cue()
	# --- walk: footsteps follow the hero (listener + stride)
	var h: DmHero = main.hero
	var start := h.global_position
	played.clear()
	for i in 90:
		h.global_position += Vector3(0.08, 0, 0.0)
		await process_frame
		await _wait(0.02)
	_check(_heard("step"), "hero footsteps while walking (heard: %s)" % str(played.slice(0, 6)))
	_check(not main.audio_hooks.is_wet(start.x, start.z), "start is dry")
	# wet surface detection from the world's water rects
	var wr: Dictionary = main.world.water[0]
	_check(main.audio_hooks.is_wet((wr.x0 + wr.x1) / 2.0, (wr.z0 + wr.z1) / 2.0), "is_wet inside a nave pool")
	# --- area change -> set_area
	var gr: Dictionary = main.world.areas.graves.rect
	h.teleport(Vector3((gr.x0 + gr.x1) / 2.0, 0, (gr.z0 + gr.z1) / 2.0))
	main.cam.snap(h.global_position)
	await _frames(4)
	_check(main.area_id == "graves" and ad.current_area() == "graves", "area change -> set_area(graves), got '%s'" % ad.current_area())
	await _wait(1.0)
	_check(ad.music_cue() != "", "graves music cue: '%s' (chapterhouse was '%s')" % [ad.music_cue(), cue_a])
	# --- cast + impact + enemy death + loot
	var foe := main.spawn_enemy("robber", h.global_position + Vector3(4, 0, 0))
	foe.rising = 0.0
	await _frames(2)
	played.clear()
	h.fire_at(foe.global_position)
	await _wait(0.1)
	_check(_heard("needleCast"), "Bone Needle cast sound")
	await _wait(0.8)
	_check(_heard("needleHit"), "Bone Needle impact sound (heard: %s)" % str(played))
	foe.take_damage(100000.0)
	await _frames(2)
	_check(_heard("enemyDeath"), "enemy death sound")
	# --- raise a thrall from the corpse
	h.essence = h.max_essence
	h._exhume_cd = 0.0
	played.clear()
	_check(h.do_exhume(foe.global_position), "exhume succeeded")
	await _wait(1.3)
	_check(_heard("exhume"), "exhume cast sound")
	_check(_heard("thrallRise"), "thrall rise sound (heard: %s)" % str(played))
	# --- thrall hit / death, hero hurt, error, loot drop (static hooks used by the scripts)
	played.clear()
	DmAudioHooks.thrall_hit("shieldbearer", h.global_position + Vector3(2, 0, 0))
	await _wait(0.1)
	_check(_heard("thrallMelee"), "thrall melee hit sound")
	DmAudioHooks.hero_hurt(10.0, 100.0)
	DmAudioHooks.error()
	DmAudioHooks.loot_drop("epic", h.global_position)
	await _wait(0.2)
	_check(_heard("hurt"), "hero hurt sound")
	_check(_heard("error"), "error sound (no corpse / essence)")
	_check(_heard("lootDropEpic"), "epic loot drop sound")
	# --- door / seal sound when a gate opens near the hero
	var door: Dictionary = {}
	for d in main.world.doors:
		if not main.builder.gates.get(d.id, {"open": true}).open:
			door = d
			break
	_check(not door.is_empty(), "a sealed door exists")
	if not door.is_empty():
		h.teleport(Vector3(door.cx, 0, door.cz) + Vector3(2, 0, 0))
		await _frames(3)
		played.clear()
		main.builder.set_door_open(door.id, true, true)
		await _frames(3)
		_check(_heard("gate"), "gate sound when a seal opens (heard: %s)" % str(played))
	# --- boss music hook
	main.audio_hooks.update_boss(true, true, ad.current_area())
	await _frames(2)
	_check(ad.music_cue().contains("boss") or ad.music_cue() != cue_a, "boss music hook changes the cue: '%s'" % ad.music_cue())
	var boss_cue: String = ad.music_cue()
	main.audio_hooks.update_boss(true, false, ad.current_area())
	await _frames(2)
	_check(ad.music_cue() != boss_cue, "boss music off restores the area cue: '%s'" % ad.music_cue())
	# --- settings: Esc opens the panel, sliders drive apply_settings, persisted + reloaded
	var sm: DmSettingsMenu = main.settings_menu
	_check(not sm.is_open(), "settings closed at first")
	played.clear()
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	sm._unhandled_key_input(esc)
	await _frames(3)
	_check(sm.is_open(), "Esc opens Settings")
	_check(_heard("panelOpen"), "panel open sound")
	_check(is_equal_approx(ad.settings.musicVolume, 0.85), "web default musicVolume 0.85 applied (got %s)" % str(ad.settings.musicVolume))
	sm.panel._put("vol_master", 0.2)
	sm.panel._put("vol_music", 0.4)
	_check(is_equal_approx(ad.settings.volume, 0.2) and is_equal_approx(ad.settings.musicVolume, 0.4), "sliders drive AudioDirector.apply_settings")
	var cf := ConfigFile.new()
	_check(cf.load(CFG) == OK and is_equal_approx(float(cf.get_value("settings", "volume", -1.0)), 0.2) and is_equal_approx(float(cf.get_value("settings", "musicVolume", -1.0)), 0.4), "settings persisted to the cfg with the web keys")
	var sm2 := DmSettingsMenu.new()
	main.add_child(sm2)
	sm2.setup(ad, CFG)
	_check(is_equal_approx(float(sm2.panel.values.vol_master), 0.2) and is_equal_approx(ad.settings.musicVolume, 0.4), "settings load on start")
	sm2.queue_free()
	sm.panel._put("vol_master", 0.7)
	sm.panel._put("vol_music", 0.85)
	sm._unhandled_key_input(esc)
	await _frames(3)
	_check(not sm.is_open(), "Esc closes Settings")
	_check(_heard("panelClose"), "panel close sound")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))
	main.queue_free()
	await _frames(3)
	_check(ad.current_area() == "", "leaving the world stops the area (stop_area)")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
