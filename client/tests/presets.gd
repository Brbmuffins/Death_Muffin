extends SceneTree
## The graphics presets of the rebuilt client (game/dm_graphics_preset.gd, next/perf/dm_next_perf.gd; DECISIONS B45), headless:
##   - the table: the four ids of today's game, an unknown or old value becomes High, every preset has every key, the order of cost (Low cheapest, Ultra dearest);
##   - each preset applied to a real game scene: the moon's shadow, reach, splits and atlas, the soft filter, bloom, ambient occlusion, MSAA, anisotropy and mesh LOD
##     on the viewport, the effects quality, the governor's floor; and the crowd's shadow policy: with 30 robbers round the hero the shadow groups hold the preset's
##     nearest casters (Low none), the thralls cast from Medium up;
##   - the governor: slow frames step the 3D scale down to the preset's floor, upscaled with FSR 1, and full speed brings it back to full size with no upscaler;
##   - ZERO script errors or engine errors in the log.
## Bakes the robber and the legionnaire into a scratch folder first (about 15 s). Run: godot --headless --fixed-fps 60 --path client --script res://tests/presets.gd

const OUT := "user://presets_test"
const BAKE := ["grave_robber", "thrall_legionnaire"]


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL presets: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
	table()
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("presets", "p@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var character: Dictionary = (await api.load_or_create_character(2)).data
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"areas": ["graves"], "name": "presets", "audio": false, "waves": false, "seed": 20261016, "baked_dir": OUT, "settings": {"graphics": "low"}})
	check(g.ready_ and g.perf != null and g.perf.preset == "low", "the game scene applies the preset it is given (opts.settings)")
	await crowd_round(g)
	for id in DmGraphicsPreset.IDS:
		await applied(g, String(id))
	await governor(g)
	g.process_mode = Node.PROCESS_MODE_DISABLED
	g.queue_free()
	await process_frame
	check(errlog.errors.is_empty(), "zero script errors or engine errors in the log (%d: %s)" % [errlog.errors.size(), "; ".join(errlog.errors.slice(0, 3))])
	if fails == 0:
		print("PASS presets %d checks" % checks)
	else:
		print("FAIL presets: %d of %d checks failed" % [fails, checks])
	quit(1 if fails > 0 else 0)


func table() -> void:
	check(DmGraphicsPreset.IDS == ["low", "medium", "high", "ultra"] and DmGraphicsPreset.DEFAULT == "high", "the four presets of today's game, High by default")
	check(DmGraphicsPreset.normalize("bogus") == "high" and DmGraphicsPreset.normalize(null) == "high" and DmGraphicsPreset.normalize("low") == "low", "an unknown or empty value becomes High")
	var keys: Array = DmGraphicsPreset.TABLE["high"].keys()
	var same := true
	for id in DmGraphicsPreset.IDS:
		var p: Dictionary = DmGraphicsPreset.TABLE[id]
		same = same and p.size() == keys.size() and keys.all(func(k: Variant) -> bool: return p.has(k))
	check(same, "every preset has every key")
	var lo: Dictionary = DmGraphicsPreset.TABLE["low"]
	var hi: Dictionary = DmGraphicsPreset.TABLE["high"]
	var ul: Dictionary = DmGraphicsPreset.TABLE["ultra"]
	check(not bool(lo["shadows"]) and not bool(lo["bloom"]) and int(lo["ssao"]) == 0 and int(lo["casters"]) == 0 and not bool(lo["thralls_cast"]) and float(lo["floor"]) < float(hi["floor"]),
		"Low: no shadows, bloom, ambient occlusion or crowd casters, and the lowest resolution floor")
	check(int(ul["msaa"]) > int(hi["msaa"]) and int(ul["ssao"]) > int(hi["ssao"]) and int(ul["shadow_size"]) > int(hi["shadow_size"]) and float(ul["shadow_dist"]) > float(hi["shadow_dist"]) and int(ul["casters"]) > int(hi["casters"]),
		"Ultra costs more than High in every knob that scales")
	# The brightness lift is the calibration against today's game (client/README.md "Graphics presets"): 1.2 for Medium, High and Ultra, 1.15 for Low (no moon shadow).
	check(is_equal_approx(DmGraphicsPreset.LIFT, 1.2) and is_equal_approx(DmGraphicsPreset.LIFT_LOW, 1.15) and is_equal_approx(float(lo["lift"]), 1.15)
		and is_equal_approx(float(DmGraphicsPreset.TABLE["medium"]["lift"]), 1.2) and is_equal_approx(float(hi["lift"]), 1.2) and is_equal_approx(float(ul["lift"]), 1.2), "the brightness lifts are the calibrated ones")
	for id in DmGraphicsPreset.IDS:
		var p: Dictionary = DmGraphicsPreset.TABLE[id]
		var today: Array = {"low": [0, 0], "medium": [8, 6], "high": [12, 8], "ultra": [20, 14]}[id]
		check(int(p["casters"]) == today[0] and int(p["casters_crowd"]) == today[1], "%s: today's crowd caster counts (%s)" % [id, today])


## Every preset on a running game: the scene's lights, environment and viewport say what the table says.
func applied(g: DmNextGame, id: String) -> void:
	g.perf.apply({"graphics": id, "auto_res": false})
	await process_frame
	var p := DmGraphicsPreset.get_preset(id)
	var b := g.world.builder
	var vp := g.get_viewport()
	check(b.moon.shadow_enabled == bool(p["shadows"]) and is_equal_approx(b.moon.directional_shadow_max_distance, float(p["shadow_dist"])), "%s: the moon's shadow and its reach" % id)
	check(b.moon.directional_shadow_mode == (DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if int(p["shadow_splits"]) == 2 else DirectionalLight3D.SHADOW_ORTHOGONAL), "%s: the shadow splits" % id)
	check(b.env.glow_enabled == bool(p["bloom"]) and b.env.ssao_enabled == (int(p["ssao"]) > 0), "%s: bloom %s, ambient occlusion %s" % [id, b.env.glow_enabled, b.env.ssao_enabled])
	check(vp.msaa_3d == DmGraphicsPreset.msaa_mode(int(p["msaa"])) and vp.anisotropic_filtering_level == DmGraphicsPreset.aniso_mode(int(p["aniso"])) and is_equal_approx(vp.mesh_lod_threshold, float(p["lod"])),
		"%s: MSAA, anisotropy and mesh LOD on the viewport" % id)
	check(is_equal_approx(g.perf.governor.floor_scale, float(p["floor"])), "%s: the governor's floor %.2f" % [id, float(p["floor"])])
	environment(g, id)
	var vfx := root.get_node_or_null("/root/Vfx")
	if vfx != null:
		check(String(vfx.quality) == String(p["fx"]), "%s: the effects quality" % id)


## The environment of the scene is today's (DmWorldBuilder's, the same constants) with the calibrated lift: the ACES tonemapper, the exposure (the world's x EXPOSURE_K, the area's
## easing, the preset's lift, the Settings brightness), the plain-colour ambient at the hemisphere's energy, the depth fog, the moon and the rim light at today's energies; the
## look measured against today's game is only valid while these hold.
func environment(g: DmNextGame, id: String) -> void:
	var p := DmGraphicsPreset.get_preset(id)
	var b := g.world.builder
	var e: Environment = b.env
	var L: Dictionary = b.world.lighting
	check(e.tonemap_mode == Environment.TONE_MAPPER_ACES, "%s: the ACES tonemapper" % id)
	check(is_equal_approx(b.preset_lift, float(p["lift"])), "%s: the builder carries the preset's lift %.2f" % [id, float(p["lift"])])
	check(is_equal_approx(e.tonemap_exposure, float(L.exposure) * DmWorldBuilder.EXPOSURE_K * b.area_exposure * float(p["lift"]) * b.brightness), "%s: the exposure is the world's x %.1f, the area's easing, the lift and the brightness (%.3f)" % [id, DmWorldBuilder.EXPOSURE_K, e.tonemap_exposure])
	check(e.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and is_equal_approx(e.ambient_light_energy, float(L.hemiIntensity) * DmWorldBuilder.HEMI_K), "%s: the plain-colour ambient at the hemisphere's energy" % id)
	check(e.fog_enabled and e.fog_mode == Environment.FOG_MODE_DEPTH and is_equal_approx(e.fog_density, 1.0), "%s: the depth fog" % id)
	check(is_equal_approx(b.moon.light_energy, float(L.moonIntensity) * DmWorldBuilder.MOON_K) and is_equal_approx(b.rim.light_energy, float(L.rimIntensity) * DmWorldBuilder.RIM_K) and not b.rim.shadow_enabled,
		"%s: the moon and the rim light at today's energies, the rim without a shadow" % id)


## 30 robbers and 6 thralls round the hero: the crowd's shadow groups hold the preset's nearest casters (and the thralls), the rest draw without a shadow.
func crowd_round(g: DmNextGame) -> void:
	var host := g.core_host
	var hero := g.local_body()
	for i in 30:
		var a := TAU * float(i) / 30.0
		host.spawn_enemy("robber", hero.position + Vector3(cos(a), 0, sin(a)) * (4.0 + float(i % 5)), 3, 2.0, 0.0, false, "graves", false, PackedStringArray())
	for i in 6:   # warriors; raised while Low is in force, so the switch to Medium must reach thralls already drawn
		var st := DmThralls.raise_stats({"kind": "warrior", "hp": 1e6, "damage": 1.0, "attackSpeedMult": 1.0}, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, i + 1, 0.0)
		host.core.raise_thrall(st, hero.core_id, Vector2(hero.position.x + 1.5 * cos(float(i)), hero.position.z + 1.5 * sin(float(i))), 0.0, -1.0)
	for id in ["low", "medium", "ultra"]:
		g.perf.apply({"graphics": id, "auto_res": false})
		await ticks(12)   # the crowd re-picks its casters every 10th frame
		await process_frame
		var cast := _shadow_instances(g)
		var p := DmGraphicsPreset.get_preset(id)
		var want_enemies := int(p["casters"])   # 30 in the field: under the crowd's 32, so not the crowded count
		var want := want_enemies + (6 if bool(p["thralls_cast"]) else 0)
		check(cast == want, "%s: %d bodies cast a shadow (%d nearest robbers%s)" % [id, cast, want_enemies, " + 6 thralls" if bool(p["thralls_cast"]) else ""])


func _shadow_instances(g: DmNextGame) -> int:
	var view := g.core_host.view
	var n := 0
	for slug in view.model_slots():
		var slot: int = view.model_slots()[slug]
		for lod in view.lod_distances.size() + 1:
			n += int(view.crowd.instance_count(slot, lod, true))
	return n


## Slow frames step the 3D scale down to the floor (FSR 1 upscales it), full-speed frames bring it back to full size.
func governor(g: DmNextGame) -> void:
	g.perf.apply({"graphics": "medium", "auto_res": true, "fps": 60})
	var vp := g.get_viewport()
	check(is_equal_approx(vp.scaling_3d_scale, 1.0) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR, "full size at the start, no upscaler")
	for i in 900:
		g.perf.pace(1.0 / 30.0)   # 30 fps against a 60 fps cap
	check(vp.scaling_3d_scale < 0.999 and vp.scaling_3d_scale >= float(DmGraphicsPreset.get_preset("medium")["floor"]) - 0.001, "slow frames lower the 3D scale to the floor at most (%.2f)" % vp.scaling_3d_scale)
	check(vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR, "a lowered scale is upscaled with FSR 1")
	for i in 4000:   # 20 s of headroom: the governor steps up after 15 s of it (smoothed frame time)
		g.perf.pace(1.0 / 200.0)
	check(is_equal_approx(vp.scaling_3d_scale, 1.0) and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR, "fast frames bring it back to full size (%.2f)" % vp.scaling_3d_scale)
	g.perf.apply({"graphics": "high", "auto_res": false})
