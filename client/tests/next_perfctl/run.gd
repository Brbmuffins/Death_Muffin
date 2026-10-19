extends SceneTree
## Performance controls + GPU warm-up of the rebuilt client (client/next/perf). godot --headless --fixed-fps 60 --path client --script res://tests/next_perfctl/run.gd
## No synthetic load: the governor is fed a simulated frame stream (pace(dt) with made-up dt), never real slow frames.
## What a preset does to the scene (shadows, reach, bloom, MSAA, the crowd's shadow policy) is tests/presets.gd's, and the moon shadow casters and the creature cull list of the old game
## (DmCasterBudget) are the crowd's shadow policy now; here: the Settings that are not a preset's, the governor's stream, the warm-up's residency.

var passed := 0
var failed := 0
var api: DmApi
var character: Dictionary


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func _game(opts: Dictionary) -> DmNextGame:
	var n: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(n)
	await n.start(character, api, opts)
	return n


## Ends a game; the next one's nodes tick before its session.host() runs, so the shared API gets its default peer back (as at boot).
func _drop(g: DmNextGame) -> void:
	await g.leave()
	g.queue_free()
	await process_frame
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


func _run() -> void:
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("perfctl%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	character = (await api.load_or_create_character(2)).data
	var only := OS.get_cmdline_user_args()
	# Each section says when it starts: a wait that never ends then shows where it is (GitHub's runner times this suite out, 2026-10-16; the VPS never does).
	if only.is_empty() or "settings" in only:
		print("perfctl: settings")
		await _settings()
	if only.is_empty() or "gov" in only:
		print("perfctl: governor")
		await _governor()
	if only.is_empty() or "warm" in only:
		print("perfctl: warm-up")
		await _warmup()
	print("%d passed, %d failed" % [passed, failed])
	# Background loads the games started (effect materials on worker threads) can outlive the last check: quitting under them aborts the engine
	# in its teardown when the worker pool is small (4 threads: GitHub's runner, 2026-10-16). Give them up to 3 real seconds.
	var until := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < until:
		await process_frame
		OS.delay_msec(10)
	print("%s next_perfctl %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


func _settings() -> void:
	var g := await _game({"dressing": true, "hud": true, "persist": false, "waves": false})
	var b := g.world.builder
	var st := g.ui_host.settings_store
	check(g.perf != null and Engine.max_fps == 0, "settings: perf node exists, fps uncapped by default")
	st.update({"graphics": "low", "fps": 30, "auto_res": true})   # live: the Settings panel's path
	check(Engine.max_fps == 30, "fps 30 caps Engine.max_fps (%d)" % Engine.max_fps)
	st.update({"graphics": "high", "fps": 60})
	check(Engine.max_fps == 60, "fps 60 (%d)" % Engine.max_fps)
	# (each preset's governor floor reaching the perf node is tests/presets.gd's `applied`; the unknown value below goes through the store)
	# Settings -> Brightness is a plain multiplier on the exposure; Interface size is the window's content scale
	st.update({"graphics": "high", "brightness": 1.0})
	var e1 := b.env.tonemap_exposure
	st.update({"brightness": 1.3})
	check(is_equal_approx(b.brightness, 1.3) and is_equal_approx(b.env.tonemap_exposure, e1 * 1.3), "brightness 130%% scales the rebuild's exposure (%.3f -> %.3f)" % [e1, b.env.tonemap_exposure])
	g.perf.enabled = true   # the client's perf node touches the window only when there is one (not headless, dm_next_perf.gd): switched on to see the content scale
	st.update({"brightness": 1.0, "ui_scale": 1.25})
	check(is_equal_approx(g.get_window().content_scale_factor, 1.25), "Interface size 125%% reaches the window content scale (%.2f)" % g.get_window().content_scale_factor)
	st.update({"ui_scale": 1.0})
	check(is_equal_approx(g.get_window().content_scale_factor, 1.0), "Interface size back to 100%")
	g.perf.enabled = false
	check(DmSettings.clamp_window_mode("fullscreen") == "fullscreen" and DmSettings.clamp_window_mode("borderless") == "borderless", "window mode keeps the offered values")
	check(DmSettings.clamp_window_mode("bogus") == "windowed" and DmSettings.clamp_window_mode(null) == "windowed", "any other window mode is windowed")
	check(DmSettings.defaults()["vsync"] == true, "V-Sync is on by default")
	st.update({"vsync": false})
	check(st.values["vsync"] == false, "V-Sync off is kept in the settings")
	st.update({"vsync": true})
	st.update({"graphics": "bogus"})
	check(DmGraphicsPreset.normalize("bogus") == "high" and is_equal_approx(g.perf.governor.floor_scale, float(DmGraphicsPreset.TABLE["high"]["floor"])), "unknown graphics value behaves as High")
	st.update({"graphics": "high"})
	st.update({"fps": 0})
	check(Engine.max_fps == 0, "fps Max = uncapped")
	# culling / streaming / shadow range are the builder's constants, driven by DmNextWorld.update every frame
	check(DmWorldBuilder.PROP_CELL == 12.0 and DmWorldBuilder.SHADOW_RANGE == 32.0 and DmWorldBuilder.LIGHT_NEAR == 8, "culling: prop cell 12 m, shadow range 32 m, 8 prop lights (as the current client)")
	# auto_res off: a stepped-down view returns to full resolution at once
	g.perf.governor.scale = 0.7
	g.perf._apply_render_scale()
	st.update({"auto_res": false})
	check(g.get_viewport().scaling_3d_scale == 1.0, "auto_res off = full resolution")
	st.update({"auto_res": true})
	await _drop(g)


func _governor() -> void:
	var g := await _game({"dressing": false, "hud": false, "persist": false, "waves": false, "settings": {"graphics": "high", "fps": 60, "auto_res": true}})
	var p := g.perf
	var vp := g.get_viewport()
	check(vp.scaling_3d_scale == 1.0 and p.governor.scale == 1.0 and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR, "governor: starts at full resolution, no upscaler")
	# 25 s of 50 ms frames (a GPU at 20 fps against a 60 fps budget); the first 10 s are held (a load)
	for i in 500:
		p.pace(0.05)
	var low: float = p.governor.scale
	check(low < 1.0 and low >= DmResolutionGovernor.MIN, "governor: steps down under a slow stream (%.2f)" % low)
	check(is_equal_approx(vp.scaling_3d_scale, low) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR, "governor: the viewport's 3D scale follows, upscaled with FSR 1 (%.2f)" % vp.scaling_3d_scale)
	# a long fast stream: back up to the ceiling
	for i in 6000:
		p.pace(0.012)
	check(p.governor.scale > low and is_equal_approx(vp.scaling_3d_scale, p.governor.scale), "governor: steps back up with headroom (%.2f)" % p.governor.scale)
	check(is_equal_approx(vp.scaling_3d_scale, 1.0) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR, "governor: back at full size with no upscaler (%.2f)" % vp.scaling_3d_scale)
	# an area entry holds: slow frames right after hold() change nothing
	var before: float = p.governor.scale
	p.hold()
	for i in 100:
		p.pace(0.1)
	check(p.governor.scale == before, "governor: held through an area entry")
	# the 30 fps cap judges against 33 ms: a 40 ms stream is not a miss by 1.3x
	p.apply({"graphics": "high", "fps": 30, "auto_res": true})
	check(p.governor.scale == 1.0 and DmResolutionGovernor.budget_fps(30) == 30 and DmResolutionGovernor.budget_fps(0) == 60, "governor: restarts at full resolution on a setting change, budget follows the cap")
	for i in 600:
		p.pace(0.033)
	check(p.governor.scale == 1.0, "governor: frames at the 30 fps budget are not a miss")
	# the same constants as the current client
	check(DmResolutionGovernor.MIN == 0.6 and DmResolutionGovernor.STEP == 0.9 and DmResolutionGovernor.DOWN_AFTER_S == 3.5 and DmResolutionGovernor.UP_AFTER_S == 15.0 and DmResolutionGovernor.MIN_GAP_S == 20.0, "governor: constants unchanged (the quality pass retunes them)")
	# the floor follows the preset: Low steps down to 0.6, High / Ultra never below 0.85
	for pair in [["low", 0.6], ["medium", 0.85], ["high", 0.85], ["ultra", 0.85]]:
		p.apply({"graphics": pair[0], "fps": 60, "auto_res": true})
		p.hold()
		for i in 6000:
			p.pace(0.05)
		check(p.governor.scale >= float(pair[1]) - 0.0001 and p.governor.scale < float(pair[1]) / 0.9 + 0.0001, "governor: %s bottoms out at its floor %.2f (%.3f)" % [pair[0], pair[1], p.governor.scale])
	# auto_res off: no stepping at all
	p.apply({"graphics": "high", "fps": 60, "auto_res": false})
	for i in 800:
		p.pace(0.05)
	check(vp.scaling_3d_scale == 1.0, "governor: auto_res off never steps")
	await _drop(g)


func _warmup() -> void:
	var t0 := Time.get_ticks_msec()
	var g := await _game({"dressing": true, "hud": false, "persist": false, "waves": false, "warmup": true})
	var ms := Time.get_ticks_msec() - t0
	var vfx := root.get_node("/root/Vfx")
	print("warm-up: %d ms (%d bodies, %d effects, %d crowd rows) of a %d ms start" % [DmNextWarmup.last_ms, DmNextWarmup.models, DmNextWarmup.effects, DmNextWarmup.crowd_rows, ms])
	check(DmNextWarmup.models > 0 and DmNextWarmup.effects > 0 and DmNextWarmup.crowd_rows > 0, "warm-up: ran (%d bodies, %d effects, %d crowd rows)" % [DmNextWarmup.models, DmNextWarmup.effects, DmNextWarmup.crowd_rows])
	check(g.get_node_or_null("WarmupStage") == null and g.local_body() != null and g.is_processing(), "warm-up: stage removed, game processing again")
	var home := g.local_body().global_position
	check(Vector2(g.camera.focus.x - home.x, g.camera.focus.z - home.z).length() < 40.0, "warm-up: camera back at the hero")
	# (the old game's scripted tour of every enemy kind as a node is the crowd's rehearsal rows now: tests/benchmark.gd counts them)
	# (what the warm-up keeps resident and the hero kits it releases cannot be seen headless: the client's warm-up skips its threaded loads without a GPU, dm_next_warmup.gd; the old
	# game's residency, "no model or effect loaded from disk" and counter-control checks are not ported)
	await _drop(g)
