extends SceneTree
## Performance controls + GPU warm-up of the rebuild (godot/next/perf). godot --headless --path godot --script res://tests/next_perfctl/run.gd
## No synthetic load: the governor is fed a simulated frame stream (pace(dt) with made-up dt), never real slow frames.

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
	if only.is_empty() or "settings" in only: await _settings()
	if only.is_empty() or "gov" in only: await _governor()
	if only.is_empty() or "warm" in only: await _warmup()
	if only.is_empty() or "casters" in only: await _casters()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Moon shadow casters (DmCasterBudget) + the creature cull list.
func _casters() -> void:
	DmSimData.ensure()
	var scn: PackedScene = load("res://enemies/robber.tscn")
	var list: Array = []
	for i in 40:
		var e: DmEnemy = scn.instantiate()
		root.add_child(e)
		e.global_position = Vector3(float(i) + 1.0, 0, 0)
		list.append(e)
	await process_frame
	var near: Array = list.slice(0, 12)
	var grp := root.get_tree().get_nodes_in_group(&"dm_enemy")
	var on := DmCasterBudget.update(grp, 0.0, 0.0, 12, 8)
	var cast_n := 0
	var near_ok := true
	for i in list.size():
		var c: bool = (list[i] as DmEnemy).creature._shadow_on
		cast_n += int(c)
		if i < 8 and not c:
			near_ok = false
		if i >= 8 and c:
			near_ok = false
	check(on == 8 and cast_n == 8 and near_ok, "casters: 40 enemies = crowded, the nearest 8 cast (%d)" % cast_n)
	for i in 10:
		(list[39 - i] as DmEnemy).queue_free()
	await process_frame
	await process_frame
	list = list.slice(0, 30)
	on = DmCasterBudget.update(root.get_tree().get_nodes_in_group(&"dm_enemy"), 0.0, 0.0, 12, 8)
	check(on == 12 and (list[11] as DmEnemy).creature._shadow_on and not (list[12] as DmEnemy).creature._shadow_on, "casters: 30 enemies, the nearest 12 cast (%d)" % on)
	on = DmCasterBudget.update(root.get_tree().get_nodes_in_group(&"dm_enemy"), 29.0, 0.0, 12, 8)
	check(on == 12 and (list[29] as DmEnemy).creature._shadow_on and not (list[0] as DmEnemy).creature._shadow_on, "casters: follows the hero (%d)" % on)
	on = DmCasterBudget.update(root.get_tree().get_nodes_in_group(&"dm_enemy"), 0.0, 0.0, 0, 0)
	check(on == 0 and not (list[0] as DmEnemy).creature._shadow_on, "casters: a budget of 0 (Low) = none")
	for e in list:
		(e as DmEnemy).queue_free()
	await process_frame
	for id in DmGraphicsPreset.IDS:
		var gp: Dictionary = DmGraphicsPreset.TABLE[id]
		check(int(gp["casters"]) >= int(gp["casters_crowd"]) and (id == "low" or int(gp["casters_crowd"]) > 0), "preset %s: caster budget %d / %d crowded" % [id, gp["casters"], gp["casters_crowd"]])
	# creature cull list: every slug is a real model; the closed-body shader is back-face culled, the rest stay double-sided
	for sl in DmCreatureMat.CULL_BACK_SLUGS:
		check(DmCreature.rows().has(sl), "cull list: %s is a model" % sl)
	check(DmCreatureMat.shader(false, false, false, true).code.contains("cull_back") and DmCreatureMat.shader(false, false, false).code.contains("cull_disabled"), "creature shader: cull_back on closed bodies, cull_disabled otherwise")
	var cb := DmCreature.new("necromancer", {})
	var wg := DmCreature.new("hero_ossuary", {})
	var sp := DmCreature.new("necromancer", {"spectral": true})
	check(cb._cull_back and not wg._cull_back and not sp._cull_back, "creature: necromancer culls back faces, open-mesh hero_ossuary and spectral bodies stay double-sided")


func _settings() -> void:
	var g := await _game({"dressing": true, "hud": true, "persist": false, "waves": false})
	var b := g.world.builder
	var st := g.ui_host.settings_store
	check(g.perf != null and Engine.max_fps == 0, "settings: perf node exists, fps uncapped by default")
	check(b.moon.shadow_enabled and b.light_near == DmWorldBuilder.LIGHT_NEAR and g.world.dressing.features.get("bloom", true), "settings: High = shadows, %d prop lights, bloom" % b.light_near)
	var vfx := root.get_node("/root/Vfx")
	st.update({"graphics": "low", "fps": 30, "auto_res": true})   # live: the Settings panel's path
	check(not b.moon.shadow_enabled, "graphics low: no moon shadows")
	check(b.light_near == 3, "graphics low: prop lights capped at 3 (%d)" % b.light_near)
	check(not bool(g.world.dressing.features.get("bloom", true)), "graphics low: bloom off")
	check(g.world.dressing.atmosphere.quality_low and vfx.quality == "low", "graphics low: lighter weather + effects quality low")
	check(Engine.max_fps == 30, "fps 30 caps Engine.max_fps (%d)" % Engine.max_fps)
	st.update({"graphics": "high", "fps": 60})
	check(b.moon.shadow_enabled and b.light_near == DmWorldBuilder.LIGHT_NEAR and bool(g.world.dressing.features.get("bloom", true)) and not g.world.dressing.atmosphere.quality_low and vfx.quality == "high", "graphics high restores everything")
	check(Engine.max_fps == 60, "fps 60 (%d)" % Engine.max_fps)
	# every preset: the whole DmGraphicsPreset row reaches the builder, dressing, Vfx, viewport and governor
	var vp := g.get_viewport()
	for id in DmGraphicsPreset.IDS:
		st.update({"graphics": id})
		var gp: Dictionary = DmGraphicsPreset.TABLE[id]
		check(b.moon.shadow_enabled == bool(gp["shadows"]) and b.light_near == int(gp["lights"]), "preset %s: shadows %s, %d prop lights" % [id, gp["shadows"], b.light_near])
		check(is_equal_approx(b.shadow_range, float(gp["prop_shadow"])) and is_equal_approx(b.moon.directional_shadow_max_distance, float(gp["shadow_dist"])), "preset %s: prop shadow range %.0f, moon reach %.0f" % [id, b.shadow_range, b.moon.directional_shadow_max_distance])
		check((b.moon.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS) == (int(gp["shadow_splits"]) == 2), "preset %s: shadow splits" % id)
		check(bool(g.world.dressing.features.get("bloom", false)) == bool(gp["bloom"]) and g.world.dressing.atmosphere.quality_low == (gp["fx"] == "low"), "preset %s: bloom + weather quality" % id)
		check(vfx.quality == String(gp["fx"]) and vfx.binbun.enabled == bool(gp["binbun"]), "preset %s: fx quality %s, binbun %s" % [id, vfx.quality, vfx.binbun.enabled])
		check(vp.msaa_3d == DmGraphicsPreset.msaa_mode(int(gp["msaa"])) and vp.anisotropic_filtering_level == DmGraphicsPreset.aniso_mode(int(gp["aniso"])) and is_equal_approx(vp.mesh_lod_threshold, float(gp["lod"])), "preset %s: msaa %d, aniso %d, lod %.1f on the viewport" % [id, gp["msaa"], gp["aniso"], gp["lod"]])
		check(is_equal_approx(g.perf.governor.floor_scale, float(gp["floor"])), "preset %s: governor floor %.2f" % [id, g.perf.governor.floor_scale])
		check(is_equal_approx(b.preset_lift, float(gp["lift"])) and is_equal_approx(b.env.tonemap_exposure, b.base_exposure * b.brightness * b.area_exposure * float(gp["lift"])), "preset %s: lighting lift %.2f reaches the exposure (%.3f)" % [id, b.preset_lift, b.env.tonemap_exposure])
	# Settings -> Brightness is a plain multiplier on the exposure; Interface size is the window's content scale
	st.update({"graphics": "high", "brightness": 1.0})
	var e1 := b.env.tonemap_exposure
	st.update({"brightness": 1.3})
	check(is_equal_approx(b.brightness, 1.3) and is_equal_approx(b.env.tonemap_exposure, e1 * 1.3), "brightness 130%% scales the rebuild's exposure (%.3f -> %.3f)" % [e1, b.env.tonemap_exposure])
	st.update({"brightness": 1.0, "ui_scale": 1.25})
	check(is_equal_approx(g.get_window().content_scale_factor, 1.25), "Interface size 125%% reaches the window content scale (%.2f)" % g.get_window().content_scale_factor)
	st.update({"ui_scale": 1.0})
	check(is_equal_approx(g.get_window().content_scale_factor, 1.0), "Interface size back to 100%")
	st.update({"graphics": "ultra"})
	check(b.light_near > DmWorldBuilder.LIGHT_NEAR and DmGraphicsPreset.get_preset("high")["lights"] == DmWorldBuilder.LIGHT_NEAR, "ultra is richer than high; high keeps the old High's lights")
	st.update({"graphics": "bogus"})
	check(DmGraphicsPreset.normalize("bogus") == "high" and b.light_near == DmWorldBuilder.LIGHT_NEAR, "unknown graphics value behaves as High")
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
	check(vp.scaling_3d_scale == 1.0 and p.governor.scale == 1.0, "governor: starts at full resolution")
	# 25 s of 50 ms frames (a GPU at 20 fps against a 60 fps budget); the first 10 s are held (a load)
	for i in 500:
		p.pace(0.05)
	var low: float = p.governor.scale
	check(low < 1.0 and low >= DmResolutionGovernor.MIN, "governor: steps down under a slow stream (%.2f)" % low)
	check(is_equal_approx(vp.scaling_3d_scale, low) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR, "governor: the viewport's 3D scale follows (%.2f)" % vp.scaling_3d_scale)
	# a long fast stream: back up to the ceiling
	for i in 6000:
		p.pace(0.012)
	check(p.governor.scale > low and is_equal_approx(vp.scaling_3d_scale, p.governor.scale), "governor: steps back up with headroom (%.2f)" % p.governor.scale)
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
	print("warm-up: %d ms (%d bodies, %d effects) of a %d ms start" % [DmNextWarmup.last_ms, DmNextWarmup.models, DmNextWarmup.effects, ms])
	check(DmNextWarmup.models >= DmNextWarmup.creature_slugs().size(), "warm-up: ran, a body per model slug (%d)" % DmNextWarmup.models)
	check(g.get_node_or_null("WarmupStage") == null and g.local_body() != null and g.is_processing(), "warm-up: stage removed, game processing again")
	var home := g.local_body().global_position
	check(Vector2(g.camera.focus.x - home.x, g.camera.focus.z - home.z).length() < 40.0, "warm-up: camera back at the hero")
	# scripted tour: every enemy kind, thrall, boss, effect; nothing loads from disk
	DmModels.cold_loads = 0
	DmFxBinbun.cold_loads = 0
	var kinds := 0
	for id in DmSimData.ENEMIES:
		if g.director.scene_for(String(id)) != null:
			var e := g.director.spawn(String(id), home + Vector3(3, 0, 3), [g.local_body()], true)
			check(e != null, "tour: %s spawns" % id)
			kinds += 1
	for slug in DmNextWarmup.creature_slugs():
		DmCreature.new(String(slug), {}).dispose()
	# residency: the hero kits a session can show (playable disciplines + the local hero) stay loaded, the greyed-out ones are released
	var in_play := DmWarmup.hero_slugs_in_play()
	var kept := 0
	var freed := 0
	for p in DmWarmup._model_paths():
		var slug: String = String(p).trim_prefix(DmWarmup.MODELS).get_slice("/", 0)
		if not slug.begins_with("hero_"):
			continue
		if in_play.has(slug):
			kept += 1
			check(ResourceLoader.has_cached(p), "residency: %s (playable) stays loaded" % slug)
			DmCreature.new(slug, {}).dispose()   # (cold_loads below proves a playable hero never loads from disk)
		else:
			freed += 1
			check(not ResourceLoader.has_cached(p), "residency: %s (not playable) is released" % slug)
	check(kept >= 4 and freed >= 1 and DmWarmup.released_heroes == freed, "residency: %d hero kits kept, %d released (%d)" % [kept, freed, DmWarmup.released_heroes])
	if vfx.binbun != null and vfx.binbun.enabled:
		for id in DmFxData.data().get("effects", {}).keys():
			vfx.binbun._scene(String(id))
	await process_frame
	check(kinds >= 20, "tour: %d enemy kinds spawned" % kinds)
	check(DmModels.cold_loads == 0, "tour: no model loaded from disk (%d)" % DmModels.cold_loads)
	check(DmFxBinbun.cold_loads == 0, "tour: no effect scene loaded from disk (%d)" % DmFxBinbun.cold_loads)
	# control: the counter does count a model nobody loaded (any model file still uncached)
	var cold := ""
	for p in DmWarmup._model_paths():
		if not ResourceLoader.has_cached(p):
			cold = p
			break
	if cold != "":
		DmModels.analyze(cold.trim_prefix(DmModels.BASE), 1.0)
		check(DmModels.cold_loads == 1, "tour: control, an unloaded model is counted (%s)" % cold.get_file())
	else:
		print("tour: control skipped, every model file is cached")
	check(g.director.enemies.size() >= kinds, "tour: enemies alive in the director")
	await _drop(g)
