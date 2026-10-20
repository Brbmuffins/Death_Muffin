extends SceneTree
## Shared by the five benchmark suites (benchmark, benchmark_rooms, benchmark_classes, benchmark_launch, benchmark_flags), which split the old single `benchmark` suite so no one run is the slowest by far.
## A suite extends this file, names itself (`suite_name`), and does its checks in `run_suite`; this file boots what every suite needs: the error log, a folder of the run's own (`scratch`: the baked models,
## and in `data` every file the benchmark keeps: history, queue, last setup, reports) so no other run's files change a check and none is left behind, the robber and the hound baked into it, the closing
## "no script or engine errors" check and the PASS / FAIL line. Nothing is sent anywhere: an upload goes to a mock.

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const SCRATCH_ROOT := "user://benchmark_test"   ## every run of this suite makes its own folder in here and removes it at the end
const BAKE := ["grave_robber", "bone_hound"]


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var scratch := ""               ## this run's own folder: the baked models, and in `data` every file the benchmark keeps
var data := ""                  ## DmBenchmark.dir for the whole suite: history, queue, last setup, reports


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL %s: %s" % [suite_name(), what])


## True when a node under `from` runs a script whose class_name is `cls` (`find_children` only knows the engine's classes).
func has_script_class(from: Node, cls: String) -> bool:
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		var sc: Script = nd.get_script()
		if sc != null and String(sc.get_global_name()) == cls:
			return true
	return false


func nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame

## The suite's name for its PASS and FAIL lines (a suite overrides it).
func suite_name() -> String:
	return "benchmark"


## The suite's checks, once the run's folder and the models are ready (a suite overrides it).
func run_suite() -> void:
	pass


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	DmSimData.ensure()
	_remove_stale_runs()
	scratch = SCRATCH_ROOT.path_join("%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	data = scratch.path_join("data")
	DirAccess.make_dir_recursive_absolute(data)
	DmBenchmark.dir = data   # every history, queue, setup and report file of the suite lands in this run's folder: no other run's files are read, none is left for a real session to send
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, scratch.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
	await run_suite()
	finish()


## The boss the boss data puts in `room` ("" = none).
func _boss_in(room: String) -> String:
	for id in DmContent.bosses():
		if String(DmContent.boss(String(id))["area"]) == room:
			return String(id)
	return ""


# ------------------------------------------------------------------------------------------------------------------ a short run

## What a short run showed, read off the running game from the progress line (about once a second; the first comes as the warm-up begins, before the first wave).
class Watch:
	extends RefCounted
	var loaded: Array = []                 ## the area ids the world holds
	var director_area := ""
	var director_kinds: Array = []         ## the kinds the director makes in the room
	var family := ""
	var casts := 0
	var defs := {}                         ## def id -> bodies spawned
	var areas := {}                        ## the area ids the spawns carried
	var hooked := false
	var hero_floor := ""                   ## the area the hero stood in once the fight began
	var looks := 0                         ## progress lines with the game up
	var boss_looks := 0                    ## ... of which a boss was awake
	var boss_ids := {}                     ## the boss ids seen awake
	var boss_floors := {}                  ## the areas the awake boss stood in
	var boss_hittable := 0                 ## looks where the awake boss could be hit (a sunk Mire Mother cannot)

	func look(b: DmBenchmark) -> void:
		if b.game == null or not is_instance_valid(b.game) or b.host == null:
			return
		if not hooked:
			hooked = true
			b.host.enemy_spawned.connect(func(_id: int, def: String, _l: int, _e: bool, area: String, _af: int, _x: float, _z: float, _hp: float) -> void:
				defs[def] = int(defs.get(def, 0)) + 1
				areas[area] = true)
			loaded = b.game.world.loaded.duplicate()
			director_area = b.game.director.area_id
			director_kinds = b.game.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))
			family = String(b.game.local_body().family)
		looks += 1
		hero_floor = b.game.world.area_at(b.game.local_body().position.x, b.game.local_body().position.z)
		casts = int(b.game.input.auto.stats["casts"])
		var boss: DmBoss = b.game.bosses.active_boss()
		if boss != null:
			boss_looks += 1
			boss_ids[boss.boss_id] = true
			boss_floors[b.game.world.area_at(boss.position.x, boss.position.z)] = true
			boss_hittable += 1 if boss.is_hittable() else 0


## One short run: `room` and `disc`, `size`, `warm` s of warm-up and `measure` s measured. Returns {r, watch, b, ms}; the caller frees `b` once it has read it.
func short_run(room: String, disc: int, size := "light", warm := 1.0, measure := 2.0) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var b := DmBenchmark.new()
	b.configure({"room": room, "discipline": disc, "size": size, "length": "quick"})
	b.warm_s = warm
	b.measure_s = measure
	b.hud_rounds = 0
	b.baked_dir = scratch
	var w := Watch.new()
	b.progress.connect(func(_t: String) -> void: w.look(b))
	root.add_child(b)
	var r: Dictionary = await b.run()
	return {"r": r, "watch": w, "b": b, "ms": Time.get_ticks_msec() - t0}


func _tiny_result() -> Dictionary:
	return {"meta": {"version": "dev", "godot": "", "gpu": "", "cpu": "", "cores": 1, "os": "", "renderer": "", "resolution": "", "refresh_hz": 0.0, "preset": "high"}, "setup": DmBenchmark.STANDARD,
		"phases": [{"avg_fps": 50.0}], "breakdown": {}}


# ------------------------------------------------------------------------------------------------------------------ the end

func finish() -> void:
	DmBenchmark.dir = DmBenchmark.DIR
	if scratch != "":   # this run's folder: the baked models, the history, the queue, the reports
		_remove_tree(ProjectSettings.globalize_path(scratch))
	check(errlog.errors.is_empty(), "no script or engine errors in the runs (%d)" % errlog.errors.size())
	for e in errlog.errors.slice(0, 12):
		printerr("ERROR LOG: " + e)
	if fails == 0:
		print("PASS %s %d checks" % [suite_name(), checks])
	else:
		printerr("FAIL %s: %d of %d checks" % [suite_name(), fails, checks])
	quit(1 if fails > 0 else 0)


## The folders of runs of this suite that died before they cleaned up (their process is gone). A folder of a run that is still going stays.
func _remove_stale_runs() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SCRATCH_ROOT)):
		return
	for d in DirAccess.get_directories_at(SCRATCH_ROOT):
		var pid := d.get_slice("_", 0)
		if pid.is_valid_int() and d.contains("_") and int(pid) != OS.get_process_id() and not _pid_alive(int(pid)):
			_remove_tree(ProjectSettings.globalize_path(SCRATCH_ROOT.path_join(d)))


## Whether process `pid` still runs. Not OS.is_process_running: for a process that is not this one's child (another worktree's run of this suite, which
## shares user://) Godot logs an engine error. /proc where there is one; elsewhere the folder is kept.
static func _pid_alive(pid: int) -> bool:
	if not DirAccess.dir_exists_absolute("/proc/self"):
		return true
	return DirAccess.dir_exists_absolute("/proc/%d" % pid)


func _remove_tree(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
