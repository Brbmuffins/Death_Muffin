extends SceneTree
## The graphics presets of the rebuilt client (game/dm_graphics_preset.gd, next/perf/dm_next_perf.gd; DECISIONS B45), headless:
##   - the table: the four ids of today's game, an unknown or old value becomes High, every preset has every key, the order of cost (Low cheapest, Ultra dearest);
##   - the exposure lift: one number per area (DmWorldBuilder.AREA_LIFT, calibrated against today's game with the look probe), the preset's own factor on top (Low 0.96, the others 1),
##     the blend on an area change (nothing runs outside it);
##   - what the lift leaves alone: the creatures and the effects (lit by the real-time lights alone, not in the lightmap) divide it out in their shaders by the global `dm_lift_inv` (1 / (the area's lift x the
##     preset's)), which follows the exposure through a blend; the creature material and the crowd's convert their colours as Compatibility does (the emission too, the tinted albedo in sRGB numbers); the hero's
##     ring and contact shadow are today's strength (DmHeroLook.RING_K, SHADOW_A);
##   - each preset applied to a real game scene: the moon's shadow, reach, splits and atlas, the soft filter, bloom, ambient occlusion, MSAA, anisotropy and mesh LOD
##     on the viewport, the effects quality, the governor's floor; and the crowd's shadow policy: with 30 robbers round the hero the shadow groups hold the preset's
##     nearest casters (Low none), the thralls cast from Medium up;
##   - (the governor's stream of slow and fast frames is tests/next_perfctl's);
##   - ZERO script errors or engine errors in the log.
## Gets the robber and the legionnaire into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --fixed-fps 60 --path client --script res://tests/presets.gd

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
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
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
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
	await lift_blend(g)
	hero_look(g)
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
	# The preset's own factor on the area's lift: 1 for Medium, High and Ultra, 0.96 for Low (its moon casts no shadow).
	check(is_equal_approx(DmGraphicsPreset.LIFT_LOW, 0.96) and is_equal_approx(float(lo["lift"]), 0.96)
		and is_equal_approx(float(DmGraphicsPreset.TABLE["medium"]["lift"]), 1.0) and is_equal_approx(float(hi["lift"]), 1.0) and is_equal_approx(float(ul["lift"]), 1.0), "the presets' own lift factors are Low 0.96, the others 1")
	area_lifts()
	for id in DmGraphicsPreset.IDS:
		var p: Dictionary = DmGraphicsPreset.TABLE[id]
		var today: Array = {"low": [0, 0], "medium": [8, 6], "high": [12, 8], "ultra": [20, 14]}[id]
		check(int(p["casters"]) == today[0] and int(p["casters_crowd"]) == today[1], "%s: today's crowd caster counts (%s)" % [id, today])


## The calibrated exposure lift of each area (client/README.md "The look against today's game"): the value that puts the rebuilt frame's mean luminance in the world region within 5 % of
## today's on the same camera (the look probe, Ultra, 2026-10-17). A change of a number here is a new calibration: measure it again with the probe, then change this table with it.
## The hero's ring and contact shadow at the strength calibrated against today's ring (DmHeroLook.RING_K, SHADOW_A; the look probe's `ring=K/S` variants, 2026-10-17): a new calibration changes both.
const RING_K := 0.4
const SHADOW_A := 0.75
const AREA_LIFTS := {
	"chapterhouse": 1.52, "acre": 1.11, "alchemist_wing": 2.08, "graves": 1.35, "warren": 1.35, "ossuary": 1.38,
	"nave": 1.33, "coliseum": 1.8, "sanctum": 1.36, "cloister": 1.37, "pyre": 1.34, "fen": 0.8,
}


func area_lifts() -> void:
	var scenes: Array = []
	for f in DirAccess.get_files_at("res://areas"):
		if f.ends_with(".tscn"):
			scenes.append(f.get_basename())
	scenes.sort()
	var keys: Array = DmWorldBuilder.AREA_LIFT.keys()
	keys.sort()
	check(keys == scenes and not scenes.is_empty(), "a lift for each area scene, and only for them (%s)" % str(scenes))
	var same := true
	var inside := true
	for id in AREA_LIFTS:
		same = same and is_equal_approx(DmWorldBuilder.area_lift_of(String(id)), float(AREA_LIFTS[id]))
		inside = inside and float(AREA_LIFTS[id]) >= 0.5 and float(AREA_LIFTS[id]) <= 2.5
	check(same and DmWorldBuilder.AREA_LIFT.size() == AREA_LIFTS.size(), "every area's lift is the calibrated one")
	check(inside, "every lift lies between 0.5 and 2.5 (a number beyond that is a slip, not a calibration)")
	check(is_equal_approx(DmWorldBuilder.area_lift_of("depths"), DmWorldBuilder.LIFT_DEFAULT) and is_equal_approx(DmWorldBuilder.LIFT_DEFAULT, 1.2), "an area the table does not list (the Depths) keeps the lift of 1.2 the whole game had")


## An area change eases the lift (DmWorldBuilder.LIFT_BLEND) and the exposure with it; the preset's factor multiplies the area's; nothing runs outside the blend.
func lift_blend(g: DmNextGame) -> void:
	var b := g.world.builder
	g.perf.apply({"graphics": "ultra", "auto_res": false})
	b.set_area("graves")
	while b.lift_blending():
		b.step_lift(0.25)
	var gr := float(AREA_LIFTS["graves"])
	var exp_of := func(lift: float, preset: float) -> float:
		return float(b.world.lighting.exposure) * DmWorldBuilder.EXPOSURE_K * b.area_exposure * lift * preset * b.brightness
	check(is_equal_approx(b.area_lift, gr) and is_equal_approx(b.env.tonemap_exposure, exp_of.call(gr, 1.0)) and not b.is_processing() and not b.lift_blending(),
		"in the Graves the lift is the Graves' %.2f and nothing runs per frame" % gr)
	check(is_equal_approx(b.lift_inv, 1.0 / gr), "the shaders' `dm_lift_inv` is 1 / the Graves' lift (%.4f)" % b.lift_inv)
	b.set_area("graves")
	check(not b.lift_blending() and not b.is_processing(), "entering the area the hero stands in starts no blend")
	var ac := float(AREA_LIFTS["acre"])
	var before := b.env.tonemap_exposure
	var gr_ease := b.area_exposure
	var sky := Color.html(str(b.world.areas["acre"].ambient.hemiSky))
	var ac_ease := clampf(1.0 - (maxf(sky.r, maxf(sky.g, sky.b)) - 0.5) * 0.8, 0.88, 1.0)   # the area's own easing of the exposure (today's, set_area)
	b.set_area("acre")   # the Acre's lift is lower than the Graves': the exposure falls, easing
	check(b.lift_blending() and b.is_processing() and is_equal_approx(b.area_lift, gr) and is_equal_approx(b.area_exposure, gr_ease) and is_equal_approx(b.env.tonemap_exposure, before),
		"an area change starts a blend from the old area's lift and exposure easing: the exposure does not jump on the first frame")
	var prev := gr
	var monotone := true
	var steps := 0
	while b.lift_blending() and steps < 100:
		b.step_lift(DmWorldBuilder.LIFT_BLEND / 8.0)
		steps += 1
		monotone = monotone and b.area_lift <= prev + 1.0e-6 and b.area_lift >= ac - 1.0e-6 and b.area_exposure <= gr_ease + 1.0e-6 and b.area_exposure >= ac_ease - 1.0e-6 and is_equal_approx(b.env.tonemap_exposure, exp_of.call(b.area_lift, 1.0))
		monotone = monotone and is_equal_approx(b.lift_inv, 1.0 / b.area_lift)   # the creatures' compensation follows the exposure through the blend
		prev = b.area_lift
	check(steps >= 8 and steps <= 9 and monotone, "the blend takes LIFT_BLEND (8 steps of an eighth), falls without overshoot, and the exposure follows the lift (%d steps)" % steps)
	check(is_equal_approx(b.area_lift, ac) and is_equal_approx(b.area_exposure, ac_ease) and not b.is_processing() and is_equal_approx(b.env.tonemap_exposure, exp_of.call(ac, 1.0)), "at the end the lift is the Acre's %.2f, the exposure easing its own and the blend stops running" % ac)
	# a change in the middle of a blend starts from where the lift is, and a preset change keeps the product
	b.set_area("graves")
	b.step_lift(DmWorldBuilder.LIFT_BLEND * 0.5)
	var mid := b.area_lift
	check(mid > ac and mid < gr, "half-way between the Acre's lift and the Graves' (%.3f)" % mid)
	b.set_area("chapterhouse")
	check(is_equal_approx(b.area_lift, mid) and b.lift_blending(), "an area change in the middle of a blend starts from the lift it is at")
	g.perf.apply({"graphics": "low", "auto_res": false})
	check(is_equal_approx(b.env.tonemap_exposure, exp_of.call(mid, DmGraphicsPreset.LIFT_LOW)), "the preset's factor multiplies the area's lift, in the middle of a blend too")
	check(is_equal_approx(b.lift_inv, 1.0 / (mid * DmGraphicsPreset.LIFT_LOW)), "and so does the creatures' compensation (Low's 0.96 too)")
	while b.lift_blending():
		b.step_lift(0.25)
	check(is_equal_approx(b.area_lift, float(AREA_LIFTS["chapterhouse"])) and is_equal_approx(b.env.tonemap_exposure, exp_of.call(float(AREA_LIFTS["chapterhouse"]), DmGraphicsPreset.LIFT_LOW)),
		"Low in the Chapterhouse: its lift %.2f x 0.96" % float(AREA_LIFTS["chapterhouse"]))
	# the game's own path: `DmNextWorld.enter_area` (what the area event calls) reaches the builder
	g.perf.apply({"graphics": "ultra", "auto_res": false})
	g.world.enter_area("graves")
	while b.lift_blending():
		b.step_lift(0.25)
	check(b.current_area == "graves" and is_equal_approx(b.area_lift, gr), "the world's `enter_area` sets the area's lift")


## What the lift leaves alone (client/README.md "The look against today's game"): the project declares the global the shaders read, the creature material, the crowd's and the effects' shaders divide the lift
## out and convert their colours as Compatibility does, and the hero's ring and shadow are the calibrated strength. A shader's text is what is checked here (the renderer is the probe's).
func hero_look(g: DmNextGame) -> void:
	check(ProjectSettings.has_setting("shader_globals/dm_lift_inv") and String(ProjectSettings.get_setting("shader_globals/dm_lift_inv").get("type", "")) == "float" and DmWorldBuilder.LIFT_INV_PARAM == &"dm_lift_inv",
		"the project declares the global float `dm_lift_inv` the builder sets with the exposure")
	var plain := DmCreatureMat.shader(false, false, false).code
	var gear := DmCreatureMat.shader(false, false, true).code
	var fade := DmCreatureMat.shader(true, false, false).code
	var ok := true
	for code: String in [plain, gear, fade, DmCreatureMat.shader(false, true, true, true).code]:
		ok = ok and code.contains("global uniform float dm_lift_inv;") and code.contains("ALBEDO = alb * dm_lift_inv;") and code.contains("SPECULAR = 0.5 * dm_lift_inv;") \
			and code.contains("EMISSION = dm_s2l(emis * emis_k + rimc + glow) * dm_lift_inv;") and not code.contains("albedo_col : source_color")
	check(ok, "every creature variant divides the lift out of albedo, specular and emission, converts the emission like Compatibility and reads the glTF's colour as it is")
	check(plain.contains("alb = dm_s2l(dm_l2s(alb) * k);") and gear.contains("vec3 alb = dm_l2s(a.rgb) * k;") and gear.contains("alb = dm_s2l(alb);") and fade.contains("ALPHA = opacity * alpha;"),
		"a tinted material and the gear's tints are multiplied in sRGB numbers and converted once, as Compatibility does")
	var crowd := FileAccess.get_file_as_string("res://crowd/crowd_vat.gdshader")
	check(crowd.contains("global uniform float dm_lift_inv;") and crowd.contains("alb = dm_s2l(dm_l2s(alb) * tk);") and crowd.contains("ALBEDO = alb * dm_lift_inv;") and crowd.contains("SPECULAR = 0.5 * dm_lift_inv;")
		and crowd.contains("EMISSION = dm_s2l(mix(v_glow.rgb, FLASH_COLOR, v_flash)") and crowd.contains("* dm_lift_inv;") and not crowd.contains("albedo_col : source_color"),
		"the crowd's shader does the same")
	var fx := true
	for kind in ["particle", "decal", "sprite", "decal_sheet", "sprite_sheet", "beam"]:
		for add in [false, true]:
			var code: String = DmFxTex.shader(kind, add).code
			fx = fx and code.contains("global uniform float dm_lift_inv;") and code.contains("ALBEDO = dm_lift_inv * dm_srgb(")
	check(fx, "every effect shader (six kinds, mixed and additive) divides the lift out")
	check(is_equal_approx(DmHeroLook.RING_K, RING_K) and is_equal_approx(DmHeroLook.SHADOW_A, SHADOW_A) and is_equal_approx(g.look.ring_k, RING_K) and is_equal_approx(g.look.shadow_a, SHADOW_A),
		"the hero's ring decals are drawn at %.2f of their opacity and his contact shadow at %.2f (the calibration against today's ring)" % [RING_K, SHADOW_A])
	var hb := g.local_body()
	var accent := DmCreature.lin(int(hb.avatar.accent_hex))
	var cr: DmCreature = hb.avatar.c
	check(cr._params["emis"].is_equal_approx(accent) and is_equal_approx(float(cr._params["emis_k"]), 0.04) and cr._params["tint"] == Vector3.ONE,
		"the hero's accent emissive is still 0.04 of the accent as a linear number (the shader converts it: a twelfth of itself, as Compatibility)")


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
	if bool(p["bloom"]):   # the glow reaches as far as today's does (DmWfxBloom): the two finest mips, today's threshold, scale and cap, 0.8 of the web's strength
		var weights := DmWfxBloom.mip_weights(float(DmWfxData.get_data().bloom.radius))
		var mips_ok := true
		for i in 7:
			mips_ok = mips_ok and is_equal_approx(b.env.get_glow_level(i), float(weights[i]) if i < DmWfxBloom.LEVELS else 0.0)
		check(mips_ok and DmWfxBloom.LEVELS == 2 and is_equal_approx(b.env.glow_intensity, float(DmWfxData.get_data().bloom.strength) * DmWfxBloom.GAIN) and is_equal_approx(b.env.glow_hdr_threshold, 0.85)
			and is_equal_approx(b.env.glow_hdr_scale, 2.0) and is_equal_approx(b.env.glow_hdr_luminance_cap, 12.0) and b.env.glow_blend_mode == Environment.GLOW_BLEND_MODE_ADDITIVE,
			"%s: the glow is today's reach (the two finest mips), threshold, scale and luminance cap" % id)
	check(vp.msaa_3d == DmGraphicsPreset.msaa_mode(int(p["msaa"])) and vp.anisotropic_filtering_level == DmGraphicsPreset.aniso_mode(int(p["aniso"])) and is_equal_approx(vp.mesh_lod_threshold, float(p["lod"])),
		"%s: MSAA, anisotropy and mesh LOD on the viewport" % id)
	check(is_equal_approx(g.perf.governor.floor_scale, float(p["floor"])), "%s: the governor's floor %.2f" % [id, float(p["floor"])])
	environment(g, id)
	var vfx := root.get_node_or_null("/root/Vfx")
	if vfx != null:
		check(String(vfx.quality) == String(p["fx"]), "%s: the effects quality" % id)


## The environment of the scene is today's (DmWorldBuilder's, the same constants) with the calibrated lift: the ACES tonemapper, the exposure (the world's x EXPOSURE_K, the area's
## easing, the area's lift, the preset's factor, the Settings brightness), the plain-colour ambient at the hemisphere's energy, the depth fog, the moon and the rim light at today's energies; the
## look measured against today's game is only valid while these hold.
func environment(g: DmNextGame, id: String) -> void:
	var p := DmGraphicsPreset.get_preset(id)
	var b := g.world.builder
	var e: Environment = b.env
	var L: Dictionary = b.world.lighting
	check(e.tonemap_mode == Environment.TONE_MAPPER_ACES, "%s: the ACES tonemapper" % id)
	check(is_equal_approx(b.preset_lift, float(p["lift"])), "%s: the builder carries the preset's lift factor %.2f" % [id, float(p["lift"])])
	check(is_equal_approx(b.area_lift, DmWorldBuilder.area_lift_of(b.current_area)) and not b.lift_blending(), "%s: the area's lift %.2f (%s)" % [id, b.area_lift, b.current_area])
	check(is_equal_approx(e.tonemap_exposure, float(L.exposure) * DmWorldBuilder.EXPOSURE_K * b.area_exposure * b.area_lift * float(p["lift"]) * b.brightness),
		"%s: the exposure is the world's x %.1f, the area's easing, the area's lift, the preset's factor and the brightness (%.3f)" % [id, DmWorldBuilder.EXPOSURE_K, e.tonemap_exposure])
	check(e.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and is_equal_approx(e.ambient_light_energy, float(L.hemiIntensity) * DmWorldBuilder.HEMI_K), "%s: the plain-colour ambient at the hemisphere's energy" % id)
	check(e.fog_enabled and e.fog_mode == Environment.FOG_MODE_DEPTH and is_equal_approx(e.fog_density, 1.0), "%s: the depth fog" % id)
	# the background past everything comes out of the tonemapper as today's Compatibility shows it, the world's colour as it is (#07060a: 7, 6, 10)
	var lin := e.background_color.srgb_to_linear()
	var out := DmCompatAlbedo.aces(Vector3(lin.r, lin.g, lin.b) * e.tonemap_exposure)
	var shown := Color(out.x, out.y, out.z).linear_to_srgb()
	var want_bg := Color.html(str(L.background))
	check(absf(shown.r - want_bg.r) < 1.0 / 255.0 and absf(shown.g - want_bg.g) < 1.0 / 255.0 and absf(shown.b - want_bg.b) < 1.0 / 255.0,
		"%s: the background beyond everything shows as %s after the tonemapper (%d, %d, %d)" % [id, str(L.background), roundi(shown.r * 255.0), roundi(shown.g * 255.0), roundi(shown.b * 255.0)])
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
