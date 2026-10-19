extends Node
## QA driver, started by the boot (`DmMain.start_qa`, a child named Driver) only for a dev-offline run with `-- --qa`, `-- --shot-plan` or `-- --clip-plan`: a release export never honours a testing flag, and no other start
## compiles this script (it names most of the game). Inactive unless the game is started with user args:  -- --qa [--shots=<dir>] [--seconds=N] [--shot-plan=<plan.json>] [--clip-plan=<plan.json> --clips=<dir> [--clip-fps=N] [--clip-width=N]] [--preset=<low|medium|high|ultra>] [--tune=<data.json>]
## (`--preset=` is read by the boot, `DmMain.qa_preset`, and applied by the game scene; the driver only says which preset the run has. `--tune=` is applied by the boot, `DmQaTune`, before the game is built.)
## Launch it with the dev-offline quick start (`--dev-offline --class=2`, or its alias `--world-demo`): the game scene (DmNextGame) as the test account `tester`; client/tools/qa_shots.sh renders it.
## Default: scripted fight in the Hollow Graves, a wave of the dead around the hero, the real rites cast at the nearest enemy; one
## screenshot a second (qa_NN.png); quits N seconds into the fight. With --shot-plan: the UI shot plan (main/qa_ui_shots.gd) instead of the fight. With --clip-plan: the clips (main/qa_clips.gd) instead of either.
## The fight reads and spawns through the combat core (enemies are ids: `core_host.enemies_in_radius`, `enemy_position`, `director.spawn`),
## the game is the boot's child `NextGame`, and a start that makes no game (no quick start, or the boot refused it) ends the run at once with a line saying so.

const NO_GAME_S := 90.0   ## the boot makes the game node when the quick start begins; no node this long after the start = the launch had no `--class=N`

var active := false
var shots := "res://../shots"
var seconds := 20.0
var t := 0.0
var n := 0
var casts := 0        ## the fight's casts so far (printed when it ends)
var nxt: DmNextGame   ## the game scene, found once "../NextGame" is ready; driven through its own seams (director.spawn, DmNextInput.cast_at)
var _cast_t := 0.0
var _setup := false
var _game_seen := false   ## the boot made the game node (it exists while it loads)
var plan_path := ""   ## --shot-plan=<abs json>: UI shot plan (main/qa_ui_shots.gd) instead of the fight
var clip_path := ""   ## --clip-plan=<abs json>: clip plan (main/qa_clips.gd) instead of the fight or the shots
var clips := ""       ## --clips=<abs dir>: where the clips are written (needed with --clip-plan)


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--qa":
			active = true
		elif a.begins_with("--shot-plan="):
			plan_path = a.substr(12)
		elif a.begins_with("--clip-plan="):
			clip_path = a.substr(12)
		elif a.begins_with("--clips="):
			clips = a.substr(8)
		elif a.begins_with("--shots="):
			shots = a.substr(8)
		elif a.begins_with("--seconds="):
			seconds = float(a.substr(10))
	if clip_path != "" and plan_path != "":
		print("QA-CLIPS note: --shot-plan is ignored in a clip run (one plan per run)")
		plan_path = ""
	set_process(active or plan_path != "" or clip_path != "")


func _process(dt: float) -> void:
	t += dt
	if nxt != null:
		if plan_path != "" or clip_path != "":
			if nxt.ui == null or nxt.ui.warming or DmLoadingScreen.current != null or t < 3.0:
				return
			set_process(false)
			if clip_path != "":
				var o := DmQaClips.options(OS.get_cmdline_user_args())
				for note in o["notes"]:
					print("QA-CLIPS note: ", note)
				DmQaClips.run(self, nxt, clip_path, clips, Callable(), int(o["fps"]), int(o["width"]))
			else:
				DmQaUiShots.run(self, nxt, plan_path, shots)
			return
		_process_next(dt)
		return
	var nm := get_node_or_null("../NextGame") as DmNextGame
	if nm != null:
		_game_seen = true
		if nm.ready_:
			nxt = nm
			if nm.opts.has("qa_preset"):   # `--preset=` (DmMain.qa_preset): the line the team app's log shows, and the test reads
				print("QA-SHOTS preset %s (from --preset=, never saved to the player's settings)" % nm.perf.preset)
			if plan_path == "" and clip_path == "":
				t = 0.0   # the fight's clock (its steps, its shots, `seconds`) starts with the game: a slow start no longer spends it
	elif _game_seen or t > NO_GAME_S:
		print("QA-SHOTS no game: the boot made none (a QA run needs the dev quick start: -- --dev-offline --class=N), see the log")
		set_process(false)
		get_tree().quit(2)


## The scripted fight (the default): the hero stands at the Graves' waystone, a pack of robbers keeps arriving, the primary rite is cast at the nearest one every 0.4 s, the RMB rite now
## and then; hp / essence are topped up. Same screenshots and quit rule. Runs only with `--qa`; a few timers per second, nothing per frame beyond the clock.
func _process_next(dt: float) -> void:
	var b := nxt.local_body()
	if b == null:
		return
	if not _setup and t > 4.0:
		_setup = true
		DmQaUiShots.go_area(nxt, "graves")
	if _setup and t > 9.0:
		var foes := nxt.core_host.enemies_in_radius(b.position, 99.0)
		if foes.size() < 6 and fmod(t, 3.0) < dt:
			for i in 5:
				nxt.director.spawn("robber", b.position + Vector3(randf_range(-6.0, 6.0), 0.0, -randf_range(5.0, 10.0)))
		_cast_t -= dt
		if _cast_t <= 0.0:
			_cast_t = 0.4
			var best := 0
			var bd := 99.0
			for id in foes:
				var at := nxt.core_host.enemy_position(id)
				var d := Vector2(at.x - b.position.x, at.z - b.position.z).length()
				if d < bd:
					bd = d
					best = id
			if best != 0:
				var aim := nxt.core_host.enemy_position(best)
				var slot := 5 if fmod(t, 4.0) < 0.5 else 0
				nxt.input.cast_at(slot, Vector3(aim.x, 0.0, aim.z), best, false)
				casts += 1
				var caster := b.get_node_or_null("Rites") as DmRiteCaster
				if caster != null:
					caster.p["resource"]["value"] = caster.p["resource"]["max"]
				b.heal(1e6)
	if t > float(n + 1):
		n += 1
		var img := DmQaUiShots.grab(self)   # null on a headless run: nothing to shoot, the fight still runs
		if img != null:
			DirAccess.make_dir_recursive_absolute(shots)
			img.save_png("%s/qa_%02d.png" % [shots, n])
	if t > seconds:
		print("QA-SHOTS fight: %d casts, %d seconds" % [casts, int(t)])
		get_tree().quit()
