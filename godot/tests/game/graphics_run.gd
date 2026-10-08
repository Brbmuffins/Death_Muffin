extends SceneTree
## Graphics presets + resolution-governor floors (headless): godot --headless --path godot --script res://tests/game/graphics_run.gd

var _pass := 0
var _fail := 0

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

## Feed the governor `secs` of frames at `ms` per frame (60 fps budget); returns the lowest scale reached.
func _drive(g: DmResolutionGovernor, secs: float, ms: float) -> float:
	var lowest := g.scale
	var t := 0.0
	while t < secs:
		g.frame(0.1, ms, 60)
		lowest = minf(lowest, g.scale)
		t += 0.1
	return lowest

func _run() -> void:
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
	_check(int(ult["lights"]) > int(hi["lights"]) and float(ult["shadow_dist"]) > float(hi["shadow_dist"]) and int(ult["soft"]) > int(hi["soft"]) and int(ult["aniso"]) == 16 and float(ult["lod"]) < 1.0, "Ultra beats High on lights, shadows, softness, aniso, LOD")
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

	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
