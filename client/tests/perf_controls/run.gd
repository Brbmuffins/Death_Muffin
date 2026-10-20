extends SceneTree
## Performance controls + GPU warm-up of the rebuilt client (client/next/perf). godot --headless --fixed-fps 60 --path client --script res://tests/perf_controls/run.gd
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
	print("%s perf_controls %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
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
	# culling / streaming / shadow range are the builder's constants, driven by DmNextWorld.update every frame: the running builder starts at them
	check(DmWorldBuilder.PROP_CELL > 0.0 and b.shadow_range == DmWorldBuilder.SHADOW_RANGE and b.light_near == DmWorldBuilder.LIGHT_NEAR, "culling: the builder starts at its prop cell, shadow range and prop light constants")
	# auto_res off: a stepped-down view returns to full resolution at once
	g.perf.governor.scale = 0.7
	g.perf._apply_render_scale()
	st.update({"auto_res": false})
	check(g.get_viewport().scaling_3d_scale == 1.0, "auto_res off = full resolution")
	st.update({"auto_res": true})
	await _drop(g)


## Feeds the governor `seconds` of frames, each `dt` long (a simulated stream; the frame count follows from the length, so a retuned timing keeps the stream long enough).
func _stream(p: DmNextPerf, seconds: float, dt: float) -> void:
	for i in ceili(seconds / dt):
		p.pace(dt)


## Seconds of slow frames the governor needs to step from full size down to `to`: the hold, then a step per MIN_GAP_S (each after sustained misses), with a step to spare.
func _down_seconds(to: float) -> float:
	var steps := ceili(log(to) / log(DmResolutionGovernor.STEP)) + 1
	return DmResolutionGovernor.HOLD_S + steps * (DmResolutionGovernor.MIN_GAP_S + DmResolutionGovernor.DOWN_AFTER_S + 1.0)


func _governor() -> void:
	var g := await _game({"dressing": false, "hud": false, "persist": false, "waves": false, "settings": {"graphics": "high", "fps": 60, "auto_res": true}})
	var p := g.perf
	var vp := g.get_viewport()
	check(vp.scaling_3d_scale == 1.0 and p.governor.scale == 1.0 and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR, "governor: starts at full resolution, no upscaler")
	# a GPU at 20 fps against a 60 fps budget, from the end of the load hold until the first step down
	_stream(p, DmResolutionGovernor.HOLD_S + DmResolutionGovernor.DOWN_AFTER_S + 2.0, 0.05)
	var low: float = p.governor.scale
	check(low < 1.0 and low >= DmResolutionGovernor.MIN, "governor: steps down under a slow stream (%.2f)" % low)
	check(is_equal_approx(vp.scaling_3d_scale, low) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR, "governor: the viewport's 3D scale follows, upscaled with FSR 1 (%.2f)" % vp.scaling_3d_scale)
	# a long fast stream: back up to the ceiling, one step per gap
	var up_steps := ceili(log(low) / log(DmResolutionGovernor.STEP)) + 1
	_stream(p, up_steps * (maxf(DmResolutionGovernor.UP_AFTER_S, DmResolutionGovernor.MIN_GAP_S) + 2.0), 0.012)
	check(p.governor.scale > low and is_equal_approx(vp.scaling_3d_scale, p.governor.scale), "governor: steps back up with headroom (%.2f)" % p.governor.scale)
	check(is_equal_approx(vp.scaling_3d_scale, 1.0) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR, "governor: back at full size with no upscaler (%.2f)" % vp.scaling_3d_scale)
	# an area entry holds: slow frames right after hold() change nothing
	var before: float = p.governor.scale
	p.hold()
	_stream(p, DmResolutionGovernor.HOLD_S * 0.9, 0.1)
	check(p.governor.scale == before, "governor: held through an area entry")
	# the 30 fps cap judges against 33 ms: a stream of 33 ms frames is not a miss (the budget for Max is a 60 fps one: a 144 Hz miss is not a GPU problem)
	p.apply({"graphics": "high", "fps": 30, "auto_res": true})
	check(p.governor.scale == 1.0 and DmResolutionGovernor.budget_fps(30) == 30 and DmResolutionGovernor.budget_fps(0) == 60, "governor: restarts at full resolution on a setting change, budget follows the cap")
	_stream(p, DmResolutionGovernor.HOLD_S + DmResolutionGovernor.DOWN_AFTER_S + 2.0, 1.0 / 30.0)
	check(p.governor.scale == 1.0, "governor: frames at the 30 fps budget are not a miss")
	# the governor's range holds together (its timings and steps are the quality pass's to retune)
	check(DmResolutionGovernor.MIN > 0.0 and DmResolutionGovernor.MIN < 1.0 and DmResolutionGovernor.STEP > 0.0 and DmResolutionGovernor.STEP < 1.0, "governor: the lowest scale and the step are fractions of full size")
	# the floor follows the preset: it bottoms out at its floor, within one step above it
	for id in DmGraphicsPreset.IDS:
		var floor_scale := float(DmGraphicsPreset.TABLE[id]["floor"])
		p.apply({"graphics": id, "fps": 60, "auto_res": true})
		p.hold()
		_stream(p, _down_seconds(floor_scale), 0.05)
		check(p.governor.scale >= floor_scale - 0.0001 and p.governor.scale < floor_scale / DmResolutionGovernor.STEP + 0.0001, "governor: %s bottoms out at its floor %.2f (%.3f)" % [id, floor_scale, p.governor.scale])
	# auto_res off: no stepping at all
	p.apply({"graphics": "high", "fps": 60, "auto_res": false})
	_stream(p, _down_seconds(DmResolutionGovernor.MIN), 0.05)
	check(vp.scaling_3d_scale == 1.0, "governor: auto_res off never steps")
	await _drop(g)


func _warmup() -> void:
	var g := await _game({"dressing": true, "hud": false, "persist": false, "waves": false, "warmup": true})
	check(DmNextWarmup.models > 0 and DmNextWarmup.effects > 0 and DmNextWarmup.crowd_rows > 0, "warm-up: ran (%d bodies, %d effects, %d crowd rows)" % [DmNextWarmup.models, DmNextWarmup.effects, DmNextWarmup.crowd_rows])
	check(g.get_node_or_null("WarmupStage") == null and g.local_body() != null and g.is_processing(), "warm-up: stage removed, game processing again")
	var home := g.local_body().global_position
	check(Vector2(g.camera.focus.x - home.x, g.camera.focus.z - home.z).length() < 40.0, "warm-up: camera back at the hero")
	# (the old game's scripted tour of every enemy kind as a node is the crowd's rehearsal rows now: tests/benchmark.gd counts them)
	# (what the warm-up keeps resident and the hero kits it releases cannot be seen headless: the client's warm-up skips its threaded loads without a GPU, dm_next_warmup.gd; the old
	# game's residency, "no model or effect loaded from disk" and counter-control checks are not ported)
	await _drop(g)
