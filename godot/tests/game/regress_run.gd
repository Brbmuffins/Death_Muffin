extends SceneTree
## Small unrelated regressions of the shipped game in ONE process (one DmNextGame boot per game flavour instead of one process each):
##   graphics presets + resolution-governor floors + settings migration | a generated Depths floor in the world builder |
##   Acre panel gold (a delivered contract's / collected laborer's gold is credited and saved) | Legion tier spend adopts the server's gold |
##   quit with live effects must exit 0 (teardown segfault: Vfx follow/getter closures called into a freed game; `-- --alive` quits with the game alive).
## godot --headless --path godot --script res://tests/game/regress_run.gd [-- --alive]
## (Formerly graphics_run, depths_builder_run, acre_gold_run, legion_gold_run, exit_run.)

var _pass := 0
var _fail := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


## Like DmEventFx: a game child whose effects follow through a lambda that reads its own members (freed with the game).
class Clock:
	extends RefCounted
	var time := 0.0


class Owner:
	extends Node
	var world: Object = null

	func start(vfx: Node, p: Vector3) -> void:
		world = Clock.new()   # a plain RefCounted that outlives the game, like the old sim the closure read
		vfx.play("censer_incense", p, {"duration": 60.0, "follow": func() -> Variant: return Vector3(world.time, 0.0, 0.0)})


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_graphics()
	await _depths_builder()
	await _gold_regressions()
	await _exit_with_live_effects()   # last: the process must still exit 0 after it
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## Feed the governor `secs` of frames at `ms` per frame (60 fps budget); returns the lowest scale reached.
func _drive(g: DmResolutionGovernor, secs: float, ms: float) -> float:
	var lowest := g.scale
	var t := 0.0
	while t < secs:
		g.frame(0.1, ms, 60)
		lowest = minf(lowest, g.scale)
		t += 0.1
	return lowest


## Feed `secs` of frames at `ms` per frame with the given GPU / script time; returns the lowest scale reached.
func _drive_cost(g: DmResolutionGovernor, secs: float, ms: float, gpu: float, logic: float) -> float:
	var lowest := g.scale
	var t := 0.0
	while t < secs:
		g.frame(0.1, ms, 60, gpu, logic)
		lowest = minf(lowest, g.scale)
		t += 0.1
	return lowest


func _graphics() -> void:
	# --- the table -----------------------------------------------------------------------------
	_check(DmGraphicsPreset.IDS == ["low", "medium", "high", "ultra"], "four presets in order")
	_check(DmGraphicsPreset.DEFAULT == "high", "default preset is High")
	_check(DmGraphicsPreset.normalize("nonsense") == "high" and DmGraphicsPreset.normalize(null) == "high", "unknown -> High")
	_check(DmGraphicsPreset.normalize("low") == "low" and DmGraphicsPreset.normalize("high") == "high", "legacy high/low are presets")
	var low := DmGraphicsPreset.get_preset("low")
	_check(not low["shadows"] and not low["bloom"] and low["lights"] == 3 and low["msaa"] == 0 and low["fx"] == "low" and not low["binbun"], "Low = no shadows/bloom, 3 lights, no MSAA, thin fx")
	var med := DmGraphicsPreset.get_preset("medium")
	_check(med["shadows"] and med["msaa"] == 0, "Medium = shadows, no MSAA")
	_check(DmGraphicsPreset.get_preset("high")["msaa"] == 0 and DmGraphicsPreset.get_preset("high")["bloom"], "High = bloom, no MSAA (opt-in on Ultra)")
	var ult := DmGraphicsPreset.get_preset("ultra")
	_check(ult["msaa"] == 4 and ult["shadow_size"] >= DmGraphicsPreset.get_preset("high")["shadow_size"], "Ultra = MSAA 4x + at least High's shadow atlas")
	_check(float(low["floor"]) == DmResolutionGovernor.MIN, "Low floor = the governor's absolute minimum")
	for id in ["medium", "high", "ultra"]:
		_check(float(DmGraphicsPreset.get_preset(id)["floor"]) >= 0.85, "%s floor >= 0.85" % id)
	var last := -1
	for id in DmGraphicsPreset.IDS:
		var p: Dictionary = DmGraphicsPreset.get_preset(id)
		_check(int(p["msaa"]) >= last, "%s MSAA never below the previous preset" % id)
		last = int(p["msaa"])
	var hi := DmGraphicsPreset.get_preset("high")
	_check(int(hi["lights"]) == DmWorldBuilder.LIGHT_NEAR and float(hi["shadow_dist"]) == 45.0 and int(hi["shadow_size"]) == 2048, "High keeps the old High's lights and shadows (same cost; smoothing + floor are the gain)")
	_check(float(ult["shadow_dist"]) > float(hi["shadow_dist"]) and int(ult["soft"]) > int(hi["soft"]) and int(ult["aniso"]) == 16 and float(ult["lod"]) < 1.0, "Ultra beats High on shadows, softness, aniso, LOD")
	_check(DmGraphicsPreset.options().size() == 4, "Settings panel offers four options")
	_check(DmGraphicsPreset.msaa_mode(4) == Viewport.MSAA_4X and DmGraphicsPreset.msaa_mode(0) == Viewport.MSAA_DISABLED, "msaa samples -> Viewport mode")

	# --- settings migration --------------------------------------------------------------------
	var path := "user://gfx_test_settings.json"
	for old in ["high", "low", "medium", "ultra", "bogus"]:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"graphics": old, "graphics_chosen": true}))
		f.close()
		var want: String = old if old != "bogus" else "high"
		var st2 := DmSettings.new(path, true)
		_check(st2.values["graphics"] == want, "saved graphics '%s' loads as '%s'" % [old, want])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(DmSettings.new("user://nonexistent_gfx.json", false).values["graphics"] == "high", "new players start on High")

	# --- brightness + lighting lift -------------------------------------------------------------
	_check(is_equal_approx(float(DmSettings.new("user://nonexistent_gfx.json", false).values["brightness"]), 1.0), "brightness defaults to 100%")
	for pair in [[0.1, 0.8], [5.0, 1.3], [1.15, 1.15], ["x", 1.0]]:
		var bf := FileAccess.open(path, FileAccess.WRITE)
		bf.store_string(JSON.stringify({"brightness": pair[0]}))
		bf.close()
		_check(is_equal_approx(float(DmSettings.new(path, true).values["brightness"]), float(pair[1])), "saved brightness %s loads as %s" % [str(pair[0]), str(pair[1])])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# --- HUD size (75-130 %, snapped, default 100 %) ------------------------------------------
	_check(is_equal_approx(float(DmSettings.new("user://nonexistent_gfx.json", false).values["hud_scale"]), 1.0), "hud_scale defaults to 100%")
	for pair in [[0.1, 0.75], [5.0, 1.3], [1.15, 1.15], [0.85, 0.85], [1.12, 1.1], ["x", 1.0], [null, 1.0]]:
		var hf := FileAccess.open(path, FileAccess.WRITE)
		hf.store_string(JSON.stringify({"hud_scale": pair[0]}))
		hf.close()
		_check(is_equal_approx(float(DmSettings.new(path, true).values["hud_scale"]), float(pair[1])), "saved hud_scale %s loads as %s" % [str(pair[0]), str(pair[1])])
	var hs := DmSettings.new(path, true)
	hs.update({"hud_scale": 1.3})
	_check(is_equal_approx(float(DmSettings.new(path, true).values["hud_scale"]), 1.3), "hud_scale persists across a reload")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(float(DmGraphicsPreset.get_preset("high")["lift"]) == 1.0 and float(DmGraphicsPreset.get_preset("ultra")["lift"]) == 1.0, "High/Ultra are the lighting reference (lift 1.0)")
	_check(float(DmGraphicsPreset.get_preset("low")["lift"]) > 1.0 and float(DmGraphicsPreset.get_preset("medium")["lift"]) > 1.0, "Low/Medium run a little hotter to match High")

	# --- governor floors -----------------------------------------------------------------------
	var g := DmResolutionGovernor.new()
	_check(g.floor_scale == DmResolutionGovernor.MIN, "governor defaults to the Low floor")
	_check(_drive(g, 400.0, 40.0) <= 0.61 and g.scale >= 0.6, "Low: sustained misses reach the 0.6 floor and stop there")
	for id in ["medium", "high", "ultra"]:
		var g2 := DmResolutionGovernor.new()
		g2.set_floor(float(DmGraphicsPreset.get_preset(id)["floor"]))
		var lowest: float = _drive(g2, 600.0, 60.0)
		_check(lowest >= 0.85 and g2.scale >= 0.85, "%s: never below 0.85 (reached %.2f)" % [id, lowest])
		_check(lowest < 1.0, "%s: still steps down when frames are slow" % id)
	var g3 := DmResolutionGovernor.new()
	_check(_drive(g3, 3.0, 40.0) == 1.0, "timid: 3 s of misses changes nothing")
	var g4 := DmResolutionGovernor.new()
	_drive(g4, 400.0, 40.0)
	g4.set_floor(0.85)
	_check(g4.scale >= 0.85, "raising the floor lifts a lower scale at once")
	g4.reset()
	_check(g4.scale == 1.0 and g4.floor_scale == 0.85, "reset keeps the floor, restores full resolution")
	_check(is_equal_approx(DmResolutionGovernor.budget_fps(0), 60.0), "Max fps is judged against 60")
	# GPU-aware: slow frames the GPU is not the cause of leave the image sharp
	var gc := DmResolutionGovernor.new()
	gc.set_floor(0.85)
	_check(_drive_cost(gc, 300.0, 40.0, 8.0, 5.0) == 1.0, "CPU-bound by the GPU's own timing (8 ms of 40): never steps down")
	var gl := DmResolutionGovernor.new()
	gl.set_floor(0.85)
	_check(_drive_cost(gl, 300.0, 40.0, -1.0, 30.0) == 1.0, "no GPU timing, script time 30 of 40 ms: never steps down")
	var gg := DmResolutionGovernor.new()
	gg.set_floor(0.85)
	_check(_drive_cost(gg, 300.0, 40.0, 35.0, 5.0) < 1.0, "GPU-bound (35 of 40 ms): steps down")
	var gn := DmResolutionGovernor.new()
	gn.set_floor(0.85)
	_check(_drive_cost(gn, 300.0, 40.0, -1.0, 6.0) < 1.0, "no GPU timing, little script time: steps down as before")
	var gs := DmResolutionGovernor.new()
	gs.set_floor(0.85)
	_drive_cost(gs, 100.0, 40.0, 35.0, 5.0)
	var stepped: float = gs.scale
	_drive_cost(gs, 100.0, 40.0, 8.0, 5.0)
	_check(stepped < 1.0 and gs.scale > stepped, "a view stepped down for nothing steps back up (%.2f -> %.2f)" % [stepped, gs.scale])
	_check(DmResolutionGovernor.scalable(40.0) and DmResolutionGovernor.scalable(40.0, 30.0) and not DmResolutionGovernor.scalable(40.0, 20.0) and not DmResolutionGovernor.scalable(40.0, -1.0, 25.0), "scalable(): GPU share 0.7, script share 0.5, unknown = yes")

	# --- renderer choice (DmRenderer): a file in user:// the engine reads at startup; Compatibility = no file -----------------------
	var rp := "user://dm_renderer_test.cfg"
	var gp := "user://dm_renderer_test.guard"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rp))
	_check(ProjectSettings.get_setting("application/config/project_settings_override") == DmRenderer.CFG_PATH, "project.godot reads the renderer override file")
	_check(ProjectSettings.get_setting("rendering/rendering_device/fallback_to_opengl3") == true, "no Vulkan -> the game falls back to OpenGL 3 instead of failing")
	_check(ProjectSettings.get_setting("rendering/renderer/rendering_method") == "gl_compatibility", "the project default stays Compatibility")
	_check(DmRenderer.requested(rp) == DmRenderer.COMPAT, "no file = Compatibility")
	_check(DmRenderer.set_requested(DmRenderer.MOBILE, rp) and DmRenderer.requested(rp) == DmRenderer.MOBILE, "Mobile is saved and read back")
	var cf := ConfigFile.new()
	cf.load(rp)
	_check(cf.get_value("rendering", "renderer/rendering_method") == "mobile", "the file overrides rendering/renderer/rendering_method")
	_check(DmRenderer.set_requested(DmRenderer.COMPAT, rp) and not FileAccess.file_exists(rp) and DmRenderer.requested(rp) == DmRenderer.COMPAT, "Compatibility removes the file")
	_check(DmRenderer.set_requested(DmRenderer.COMPAT, rp), "removing an absent file is fine")
	var bad := FileAccess.open(rp, FileAccess.WRITE)
	bad.store_string("not a cfg [[[")
	bad = null
	_check(DmRenderer.requested(rp) == DmRenderer.COMPAT, "an unreadable file means Compatibility")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rp))
	_check(DmRenderer.flag_choice(PackedStringArray(["--renderer=compat"])) == "compat" and DmRenderer.flag_choice(PackedStringArray(["--x", "--renderer=Mobile"])) == "mobile"
		and DmRenderer.flag_choice(PackedStringArray(["--renderer=vulkan"])) == "" and DmRenderer.flag_choice(PackedStringArray()) == "", "--renderer= parses")
	_check(DmRenderer.strip_flag(PackedStringArray(["--a", "--renderer=compat", "--b"])) == PackedStringArray(["--a", "--b"]), "the flag is not passed on to the relaunch")
	_check(DmRenderer.active() == "compat" and not DmRenderer.is_mobile() and DmRenderer.describe().begins_with("Compatibility"), "this run is Compatibility")
	_check(not DmRenderer.guard_check(false, gp, rp) and not FileAccess.file_exists(gp), "a Compatibility run arms no guard")
	DmRenderer.set_requested(DmRenderer.MOBILE, rp)
	_check(DmRenderer.fell_back(rp), "Mobile asked for but not running = fell back")
	_check(not DmRenderer.guard_check(true, gp, rp) and FileAccess.file_exists(gp), "a Mobile run arms the guard")
	DmRenderer.guard_ok(gp)
	_check(not FileAccess.file_exists(gp) and not DmRenderer.guard_check(true, gp, rp), "a survived run clears the guard; the next launch arms it again")
	_check(DmRenderer.guard_check(true, gp, rp) and DmRenderer.requested(rp) == DmRenderer.COMPAT and not FileAccess.file_exists(gp), "a run that left its guard (crashed): back to Compatibility")
	_check(DmRenderer.was_reverted(), "...and Settings is told")
	DmRenderer.set_requested(DmRenderer.MOBILE, rp)
	_check(not DmRenderer.was_reverted(), "choosing again clears the note")
	DmRenderer.set_requested(DmRenderer.COMPAT, rp)


func _depths_builder() -> void:
	DmSimData.ensure()
	var b := DmWorldBuilder.new()
	root.add_child(b)
	b.build(DmData.world())
	var f := DmDepthsFloor.generate_floor(DmDepthsFloor.floor_seed(5, 5), 5, 5)
	b.open_instance("depths", true)
	b.build_depths_floor(f)
	b.set_depths_stair_open(true)
	b.set_depths_chest_opened(true)
	var fr: Node = b.area_nodes["depths"].get_node_or_null("DepthsFloor")
	_check(fr != null and fr.get_child_count() > 10, "depths: floor root built")
	b.clear_depths_floor()
	await process_frame
	_check(b.area_nodes["depths"].get_node_or_null("DepthsFloor") == null, "depths: floor cleared")
	b.build_depths_floor(f)
	b.clear_depths_floor()
	b.queue_free()
	await process_frame


## Acre gold: the server returns a delivered contract's gold and a laborer's collected gold but never writes it (contracts.cjs: the client owns the
## total, like a gather reply), so the game must credit it and the next save must keep it.  Legion: buying a tier spends gold on the server and the
## client must adopt it (psync.spend_on_server), or the next save writes the old gold back and the tier was free.  One game serves both.
func _gold_regressions() -> void:
	var mock := DmMockBackend.new("")
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var r := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(game)
	await game.start(c.data, api, {"visual": false, "persist": false, "waves": false, "audio": false})
	var host := game.ui_host   # the DmGameUi contract: character, progression, Acre / Legion hooks
	await process_frame
	# ---- Acre panels' gold
	_check(host.has_method("on_contract_delivered") and host.has_method("on_labor_collected") and host.has_method("on_garden_result") and game.acre != null, "the game has the Acre panel hooks")
	var g0 := int(host.character["gold"])
	host.on_contract_delivered({"contracts": [], "gold": 120})
	_check(int(host.character["gold"]) == g0 + 120, "contract gold credited: %d -> %d" % [g0, int(host.character["gold"])])
	host.on_contract_delivered({"contracts": [], "gold": 30, "paidBonus": {"gold": 30, "item": {}}})
	_check(int(host.character["gold"]) == g0 + 150, "contract + bonus gold credited")
	host.on_labor_collected({"collected": {"skill": "mining", "gold": 25, "items": [], "hours": 1.0, "xp": 0}}, 0)
	await process_frame
	_check(int(host.character["gold"]) == g0 + 175, "labor gold credited: %d" % int(host.character["gold"]))
	host.prog.save_dirty = true
	await game.flush_all()
	var server: Dictionary = (await api.get_character()).data
	_check(int(server["gold"]) == g0 + 175, "the save keeps it: backend %s" % str(server["gold"]))
	# ---- Legion tier spend
	host.character["gold"] = 5000
	host.prog.add_gold(0.0)
	await game.flush_all()
	var tier0 := int(host.progress.get("legionTier", 0))
	var res: DmResult = await host.psync.spend_on_server(func() -> DmResult: return await host.api.necro_purchase(host.hero_id, "legion"))
	_check(res.ok, "legion purchase succeeds: %s" % res.error)
	await host.refresh_progress()
	await host.refresh_character()
	var cost := 5000 - int(host.character["gold"])
	_check(cost > 0, "the client paid for the tier: %d gold" % cost)
	_check(int(host.progress.get("legionTier", 0)) == tier0 + 1, "legion tier %d -> %s" % [tier0, str(host.progress.get("legionTier", 0))])
	host.prog.save_dirty = true
	await game.flush_all()
	server = (await api.get_character()).data
	_check(int(server["gold"]) == 5000 - cost, "the next save keeps the spend: client %d, backend %s" % [int(host.character["gold"]), str(server["gold"])])
	game.queue_free()
	for i in 3:
		await process_frame


## Plays a burst of every Binbun effect + the Effects.ts primitives in a real dev-offline DmNextGame, then quits the way main.gd does (game still
## alive), after freeing the game first (leaving the world); `-- --alive` skips the free.
func _exit_with_live_effects() -> void:
	var freed := not OS.get_cmdline_user_args().has("--alive")
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("exit%d" % (Time.get_ticks_usec() % 100000), "e@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "audio": false})
	var vfx: Node = root.get_node("Vfx")
	var p: Vector3 = game.local_body().position
	var n := 0
	for id in DmFxData.catalog("effects"):
		vfx.play(String(id), p + Vector3(float(n % 7) - 3.0, 0.0, float(n / 7) - 3.0), {"duration": 30.0})
		n += 1
	var owner_n := Owner.new()
	game.add_child(owner_n)
	owner_n.start(vfx, p)
	vfx.emit({"x": p.x, "y": 0.5, "z": p.z, "count": 40, "color": 0xffcc66, "spread": 1.0, "speed": 2.0, "up": 2.0, "life": 2.0, "size": 0.2})
	vfx.emit_smoke({"x": p.x, "y": 0.5, "z": p.z, "count": 10, "color": 0x444444})
	vfx.decal({"tex": "ring", "color": 0xd9a441, "x": p.x, "z": p.z, "r": 3.0, "duration": 5.0, "opacity": 1.0})
	vfx.decal({"tex": "glow", "color": 0xd9a441, "x": p.x, "z": p.z, "r": 3.0, "duration": 1e9, "opacity": 1.0, "follow": func() -> Variant: return p})
	vfx.spike_ring(p.x, p.z, 4.0, 8)
	vfx.light_flash(p, Color.WHITE, 1.0, 0.5)
	for i in 30:
		await process_frame
	print("effects playing: ", vfx.binbun_count(), " of ", n)
	if freed:
		game.queue_free()
		for i in 3:
			await process_frame
	_check(true, "exit: effects played and the game was %s without a crash" % ("freed" if freed else "left alive"))
