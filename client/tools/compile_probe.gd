extends SceneTree
## The pipelines each fresh game compiles, on a real renderer: the stutter scenario (DmQaStutter) on a few disciplines, one fresh game after the
## other, printing each game's compilations per kind and its casts that compiled. A game that compiles again what the one before it did shows here
## without a team PC. The VPS's software Vulkan driver is slow: one short run at a time, under the shared renderer lock, e.g.
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock env VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json nice -n 10 \
##     xvfb-run -a -s "-screen 0 960x540x24" timeout 400 /home/ubuntu/tools/godot/godot --rendering-driver vulkan --resolution 640x360 \
##     --path client --script res://tools/compile_probe.gd -- --disc=1,2 --rites=6 [--warmup]   (or `-- --why`, below)
## A team PC's stutter test stays the measure of what players feel (client/main/RELEASE-CHECKS.md).


func _initialize() -> void:
	await process_frame
	var discs: Array = [1, 2]
	var rites := 6
	var warm := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--disc="):
			discs = Array(a.substr(7).split(",")).map(func(s: String) -> int: return int(s))
		elif a.begins_with("--rites="):
			rites = int(a.substr(8))
		elif a == "--warmup":
			warm = true
		elif a == "--why":
			quit(await _why())
			return
	var st := DmQaStutter.new()
	st.name = "Scenario"
	st.disciplines = discs
	st.max_rites = rites
	st.window_s = 0.6
	st.gap_s = 0.1
	st.settle_s = 0.5
	st.boot_opts = {"warmup": warm}
	root.add_child(st)
	var code: int = await st.run()
	var by := {}
	for r: Dictionary in st.rows:
		var d := String(r["discipline"])
		if not by.has(d):
			by[d] = {"canvas": 0, "mesh": 0, "surface": 0, "draw": 0, "specialization": 0}
		for k in r["kinds"]:
			by[d][k] += int(r["kinds"][k])
		if int(r["compilations"]) > 0:
			print("PROBE %s %s %s" % [d, r["rite"], str(r["kinds"])])
	for d in by:
		print("PROBE game %s: %s" % [d, str(by[d])])
	print("PROBE renderer %s, warm-up %s, exit %d, errors %s" % [st.results.get("renderer", "?"), warm, code, str(st.errors)])
	quit(code)


## `--why`: one game, Bone Needle cast again after each step that could drop the compiled pipelines. Every line but the first and the preset switch
## should read zero: a step that compiles again throws away what the loading screen compiled (DmGraphicsPreset.apply_render).
func _why() -> int:
	var st := DmQaStutter.new()
	st.name = "Scenario"
	root.add_child(st)
	var settings := {"graphics": "high", "fps": 0, "auto_res": false, "brightness": 1.0, "ui_scale": 1.0, "vsync": false}
	var fight: Dictionary = await DmBenchFight.boot(st, 2, {"settings": settings, "warmup": false}, "graves")
	var game: DmNextGame = fight["game"]
	var hero: DmHeroBody = fight["hero"]
	var caster: DmRiteCaster = fight["caster"]
	game.perf.apply(settings)
	game.input.auto.gate_probe = func() -> bool: return false
	game.director.enabled = false
	game.director.surge = null
	game.core_host.core.set_wander(false)
	var origin := hero.position
	var spots := DmQaClips.layout("pack", 8, origin)
	var ids := DmQaClips.stand_ins(game, spots)
	for i in 30:
		await process_frame
	var aim := DmQaClips.aim_at(spots, origin)
	var vp := game.get_viewport()
	var steps := [
		["first cast", func() -> void: pass],
		["again", func() -> void: pass],
		["perf.apply(same)", func() -> void: game.perf.apply(settings)],
		["environment (same)", func() -> void: DmGraphicsPreset.apply_environment(game.world.builder.env, "high")],
		["ssao quality (same)", func() -> void: RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_MEDIUM, true, 0.5, 2, 50.0, 300.0)],
		["moon shadow (same)", func() -> void: game.world.builder.moon.shadow_enabled = true],
		["perf.apply(ultra, high)", func() -> void:
			game.perf.apply(settings.merged({"graphics": "ultra"}, true))
			game.perf.apply(settings)],
	]
	for step in steps:
		(step[1] as Callable).call()
		for i in 3:
			await process_frame
		ids = st._prepare(game, hero, caster, spots, ids, origin)
		await process_frame
		var before := DmQaPerf.compilations_by_kind()
		caster.request_cast("bone_needle", aim, -1)
		for i in 40:
			await process_frame
		print("WHY %-22s %s" % [step[0], str(DmQaPerf.kinds_between(before, DmQaPerf.compilations_by_kind()))])
	await game.leave()
	game.queue_free()
	await process_frame
	return 0
