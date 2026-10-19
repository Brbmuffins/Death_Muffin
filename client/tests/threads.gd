extends SceneTree
## Work off the main thread (client/README.md "Threads"). Godot's message "caller thread can't call propagate_notification() on /root" is the crash handler's own: when a
## thread other than the main one crashes, handle_crash tells the main loop (SceneTree -> /root.propagate_notification), and that call is refused off the main thread. So the
## message names a crash on some thread, not code touching the tree; the one such crash with frames in a log (a headless run, 2026-10-07) is the mixer's, which AudioServer.add_bus
## and set_bus_send do not lock against. Checks:
##   A every place that starts work off the main thread is on the list below (a new one fails here until it is listed and read), and the C++ core starts no thread;
##   B the audio bus layout is only edited under the mixer's lock: one place adds a bus, one changes a send, each locks and unlocks, nothing else in the client does either;
##   C the Depths' floor generator on a worker returns what the main thread makes, from data no one writes any more (DmDb's cache is not touched by the run);
##   D the Gear Atlas' verdicts on a worker return what the main thread makes, and the static tables they read do not change under the run;
##   E DmThreadGuard (the apply paths' check) and DmDbWarm;
##   ZERO script errors or engine errors in the log (an engine thread-guard error from a worker, or a crash message, would be one).
## Run: godot --headless --path client --script res://tests/threads.gd

class ErrorLog:
	extends Logger
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## What starts work off the main thread in the client's own code (not tests, tools or addons), by file. Each line is read in client/README.md "Threads".
const STARTERS := ["Thread.new", "WorkerThreadPool.add_task", "WorkerThreadPool.add_group_task", "load_threaded_request", "bake_from_source_geometry_data_async", "call_thread_safe",
	"call_deferred_thread_group", "set_thread_safety_checks_enabled", "Semaphore.new"]
const LISTED := {
	"audio/audio_samples.gd": ["load_threaded_request"],
	"game/dm_gear_models.gd": ["load_threaded_request"],
	"game_ui/dm_ui_panels_a.gd": ["WorkerThreadPool.add_task"],
	"main/main.gd": ["load_threaded_request"],
	"next/depths/dm_depths.gd": ["WorkerThreadPool.add_task"],
	"next/depths/dm_depths_ground.gd": ["bake_from_source_geometry_data_async"],
	"next/perf/dm_next_warmup.gd": ["load_threaded_request"],
}
const TREE_CALLS := ["get_tree(", "add_child(", "remove_child(", "queue_free(", "call_deferred(", "Engine.get_main_loop(", "extends Node", "SceneTree", "get_node(", "get_node_or_null(", "Input.", "DisplayServer",
	"RenderingServer", "AudioServer", "NavigationServer", "PhysicsServer", "ResourceLoader", "Callable(self"]
const NATIVE_STARTERS := ["std::thread", "std::jthread", "std::async", "pthread_create", "WorkerThreadPool", "#pragma omp", "Thread::", "std::mutex", "std::atomic"]
const SKIP_DIRS := ["tests", "tools", "addons", ".godot"]

var fails := 0
var checks := 0
var errlog := ErrorLog.new()


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL threads: " + what)


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	_a_inventory()
	_b_audio_layout()
	DmSimData.ensure()
	await _c_depths_worker()
	await _d_atlas_worker()
	await _e_guard_and_warm()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s threads %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


# ---- helpers ------------------------------------------------------------------------------------------------------------------------------------

## Every .gd under res:// (relative paths) outside the skipped folders.
func _scripts(dir := "res://", rel := "") -> PackedStringArray:
	var out := PackedStringArray()
	for d in DirAccess.get_directories_at(dir):
		if rel == "" and SKIP_DIRS.has(d):
			continue
		out.append_array(_scripts(dir.path_join(d), rel.path_join(d) if rel != "" else d))
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(rel.path_join(f) if rel != "" else f)
	return out


## The source with its comments and string-free lines left: `#` to the end of a line goes (a `#` inside a string only hides what follows it, never adds a match).
func _code(path: String) -> String:
	var lines := PackedStringArray()
	for l in FileAccess.get_file_as_string("res://" + path).split("\n"):
		lines.append(l.get_slice("#", 0))
	return "\n".join(lines)


## Runs `work` on a pool thread and returns once it has finished, polling like the game does (the main thread keeps drawing). The thread the body ran on goes to `on[0]`.
func _on_worker(work: Callable, on: Array) -> void:
	var task := WorkerThreadPool.add_task(func() -> void:
		on[0] = OS.get_thread_caller_id()
		work.call(), false, "threads test")
	while not WorkerThreadPool.is_task_completed(task):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task)


# ---- A: what starts a thread -------------------------------------------------------------------------------------------------------------------

func _a_inventory() -> void:
	var found := {}
	for path in _scripts():
		var src := _code(path)
		for tag in STARTERS:
			if src.contains(tag):
				if not found.has(path):
					found[path] = []
				found[path].append(tag)
	var unlisted := PackedStringArray()
	for path in found:
		for tag in found[path]:
			if not (LISTED.has(path) and (LISTED[path] as Array).has(tag)):
				unlisted.append("%s (%s)" % [path, tag])
	check(unlisted.is_empty(), "these start work off the main thread and are not on the list: list them here and in client/README.md \"Threads\" once their thread has been read: %s" % ", ".join(unlisted))
	var gone := PackedStringArray()
	for path in LISTED:
		for tag in LISTED[path]:
			if not (found.has(path) and (found[path] as Array).has(tag)):
				gone.append("%s (%s)" % [path, tag])
	check(gone.is_empty(), "these no longer start anything: take them off the list (and out of client/README.md \"Threads\"): %s" % ", ".join(gone))
	check(found.size() == LISTED.size(), "the client has %d files that start off-thread work" % found.size())
	# What the workers run is pure: the rules and the sim (the Atlas' verdicts are rules/gear, the Depths' floor is sim/depths_floor.gd) and the run's generator call no node, tree or server.
	var tree_calls := PackedStringArray()
	for path in _scripts():
		if not (path.begins_with("rules/") or path.begins_with("sim/") or path == "next/depths/dm_depths_run.gd"):
			continue
		var src := _code(path)
		for tag in TREE_CALLS:
			if src.contains(tag):
				tree_calls.append("%s (%s)" % [path, tag])
	check(tree_calls.is_empty(), "the rules and the sim touch no node, tree or server: %s" % ", ".join(tree_calls))
	# The C++ core: no thread, no lock, no atomic (a core that waited on another thread would stall the tick; one that wrote from two would corrupt it).
	var native := ProjectSettings.globalize_path("res://").path_join("../native/src").simplify_path()
	if DirAccess.dir_exists_absolute(native):
		var hits := PackedStringArray()
		var stack := [native]
		while not stack.is_empty():
			var dir: String = stack.pop_back()
			for d in DirAccess.get_directories_at(dir):
				stack.append(dir.path_join(d))
			for f in DirAccess.get_files_at(dir):
				if f.ends_with(".cpp") or f.ends_with(".h"):
					var src := FileAccess.get_file_as_string(dir.path_join(f))
					for tag in NATIVE_STARTERS:
						if src.contains(tag):
							hits.append("%s (%s)" % [dir.path_join(f).trim_prefix(native + "/"), tag])
		check(hits.is_empty(), "the combat core starts no thread (a core that runs think and move in parallel, DECISIONS B42, comes through here: read it, then list it): %s" % ", ".join(hits))
	else:
		print("INFO threads: native/src not found next to the project: the core's source was not scanned")


# ---- B: the bus layout ---------------------------------------------------------------------------------------------------------------------------

func _b_audio_layout() -> void:
	var forbidden := ["AudioServer.add_bus(", "AudioServer.set_bus_send(", "AudioServer.remove_bus(", "AudioServer.move_bus(", "AudioServer.swap_bus(", "AudioServer.set_bus_layout(",
		"AudioServer.set_bus_name(", "AudioServer.lock("]
	var strays := PackedStringArray()
	for path in _scripts():
		if path == "audio/audio_director.gd":
			continue
		var src := _code(path)
		for tag in forbidden:
			if src.contains(tag):
				strays.append("%s (%s)" % [path, tag])
	check(strays.is_empty(), "nothing but the director edits the bus layout: %s" % ", ".join(strays))
	var edits := 0
	var locks := 0
	var unlocks := 0
	var misplaced := PackedStringArray()
	var fn := ""
	for l in _code("audio/audio_director.gd").split("\n"):
		if l.begins_with("func "):
			fn = l.get_slice("(", 0).trim_prefix("func ")
		if l.contains("AudioServer.add_bus("):
			edits += 1
			if fn != "_add_bus":
				misplaced.append("add_bus in " + fn)
		if l.contains("AudioServer.set_bus_send("):
			edits += 1
			if fn != "_add_bus" and fn != "_set_bus_send":
				misplaced.append("set_bus_send in " + fn)
		for tag in ["AudioServer.remove_bus(", "AudioServer.move_bus(", "AudioServer.swap_bus(", "AudioServer.set_bus_layout("]:
			if l.contains(tag):
				misplaced.append("%s in %s" % [tag, fn])
		if l.contains("AudioServer.lock()"):
			locks += 1
			if fn != "_add_bus" and fn != "_set_bus_send":
				misplaced.append("lock in " + fn)
		if l.contains("AudioServer.unlock()"):
			unlocks += 1
	check(misplaced.is_empty(), "the director edits the layout only in its two locked helpers: %s" % ", ".join(misplaced))
	check(edits == 3, "the director has three layout edits (add_bus, and set_bus_send in two helpers), found %d" % edits)
	check(locks == 2 and unlocks == 2, "each helper takes the lock once and gives it back once (%d locks, %d unlocks)" % [locks, unlocks])
	# the director that came up with this process (an autoload) made its layout through them
	var ad := root.get_node_or_null("AudioDirector")
	check(ad != null, "the AudioDirector autoload is up")
	if ad != null:
		var made: int = int(ad.get("layout_edits")) if "layout_edits" in ad else -1
		check(made == AudioServer.bus_count - 1, "every bus the director made went through the locked helper (%d edits, %d buses besides Master)" % [made, AudioServer.bus_count - 1])
		check(AudioServer.bus_count > 50, "the voices' buses exist (%d buses)" % AudioServer.bus_count)


# ---- C: the Depths' floor generator ---------------------------------------------------------------------------------------------------------

func _c_depths_worker() -> void:
	DmDbWarm.all()
	var keys0 := DmDb._cache.keys()
	var combos: Array = []
	for s in [1, 13, 20261017]:
		for dep in [1, 3, 5, 9, 15]:
			combos.append([s, dep])
	var expect: Array = []
	for c in combos:
		expect.append(DmDepthsRun.generate(c[0], c[1]))
	check(DmDb._cache.keys() == keys0, "generating floors on the main thread reads only datasets the warm-up already holds")
	var got: Array = []
	var main_id := OS.get_main_thread_id()
	var ids := {}
	for c in combos:
		var out := [{}]
		var on := [-1]
		await _on_worker(func() -> void: out[0] = DmDepthsRun.generate(c[0], c[1]), on)
		got.append(out[0])
		ids[on[0]] = true
	var same := 0
	for i in combos.size():
		if got[i] == expect[i] and (got[i] as Dictionary).hash() == (expect[i] as Dictionary).hash():
			same += 1
	check(same == combos.size(), "a floor made on a worker thread is the floor the main thread makes (%d of %d)" % [same, combos.size()])
	check(not ids.has(main_id) and not ids.has(-1), "the generator ran off the main thread (threads %s, main %d)" % [str(ids.keys()), main_id])
	check(DmDb._cache.keys() == keys0, "the workers did not touch DmDb's cache")
	# the controller's own path: the same task through DmDepths._generate's pieces needs a game; tests/depths.gd runs it and checks DmThreadGuard


# ---- D: the Gear Atlas' verdicts -----------------------------------------------------------------------------------------------------------

func _tables() -> Array:
	return [DmDb._cache.size(), DmAtlasGear._by_id.size(), DmAtlasGear._by_set.size(), DmGearStats._ref_cache.size(), DmGearStats._priority.size(), DmSetBonuses._pieces_by_id.size(),
		DmSetBonuses._pieces_by_set.size(), DmAffixTotals._by_id.size(), DmAbilities._unlock_memo.size(), DmCharacterBuild._by_index.size()]


func _d_atlas_worker() -> void:
	var ids: Array = DmPaData.atlas().get("items", {}).keys()
	var gear: Array = ids.filter(func(id: Variant) -> bool: return DmAtlasGear.atlas_slot(String(id)) != null)
	check(ids.size() > 100 and gear.size() > 50, "the catalogue has %d items, %d of them gear" % [ids.size(), gear.size()])
	var worn_rows: Array = []
	for i in mini(4, gear.size()):
		var row: Dictionary = DmAtlasGear.atlas_slot(String(gear[i * 7 % gear.size()]), 100 + i)
		row["equipped"] = 1
		worn_rows.append(row)
	var ctx1 := DmAtlasGear.reference_context("gravecaller")
	var ctx2 := DmAtlasGear.reference_context("gravecaller")   # the same hero with four pieces worn: a context the first main-thread pass did not see
	ctx2["slots"] = worn_rows
	var owned1 := {}
	var owned2 := {}
	for r: Dictionary in worn_rows:
		owned2[r["item_id"]] = {"n": 1, "worn": true}
	# the game's order: one pass on the main thread first (it fills the lazily built tables), then the worker
	var main1 := DmAtlasGear.panel_inputs(ctx1.duplicate(true), ids, owned1)
	var before := _tables()
	var got1 := [{}]
	var got2 := [{}]
	var on1 := [-1]
	var on2 := [-1]
	var snap1 := ctx1.duplicate(true)
	var snap2 := ctx2.duplicate(true)
	await _on_worker(func() -> void: got1[0] = DmAtlasGear.panel_inputs(snap1, ids, owned1), on1)
	await _on_worker(func() -> void: got2[0] = DmAtlasGear.panel_inputs(snap2, ids, owned2), on2)
	var after := _tables()
	print("INFO threads: tables read by the verdicts (DmDb cache, atlas by id / by set, gear ref cache, priorities, set pieces by id / by set, affix totals, unlock memo, builds): %s" % str(after))
	check(before == after, "the tables the verdicts read are not written by the worker: %s -> %s" % [str(before), str(after)])
	check(got1[0] == main1 and (got1[0] as Dictionary).hash() == main1.hash(), "the verdicts a worker makes are the main thread's (%d verdicts, %d outlooks)" % [main1["verdicts"].size(), main1["outlooks"].size()])
	var main2 := DmAtlasGear.panel_inputs(ctx2.duplicate(true), ids, owned2)
	check(got2[0] == main2, "...also for a hero wearing four pieces (%d verdicts)" % main2["verdicts"].size())
	check(main1["verdicts"].size() > 20 and main1["outlooks"].size() > 5, "the verdicts are not empty (%d, %d)" % [main1["verdicts"].size(), main1["outlooks"].size()])
	check(on1[0] != OS.get_main_thread_id() and on2[0] != OS.get_main_thread_id() and on1[0] != -1, "the verdicts were made off the main thread")
	check(_tables() == after, "...and the main thread's second pass wrote no table either")


# ---- E: the guard and the warm-up ----------------------------------------------------------------------------------------------------------

func _e_guard_and_warm() -> void:
	var v0 := DmThreadGuard.violations
	var c0 := DmThreadGuard.checks
	check(DmThreadGuard.assert_main("the test") and DmThreadGuard.on_main(), "the main thread passes the guard")
	check(DmThreadGuard.checks == c0 + 1 and DmThreadGuard.violations == v0, "...and is counted")
	var seen := [true]
	await _on_worker(func() -> void: seen[0] = DmThreadGuard.on_main(), [-1])
	check(not seen[0], "a pool thread is not the main thread for the guard")
	check(DmDbWarm.done and DmDbWarm.datasets == DmDb.all_files().size(), "the warm-up holds all %d datasets" % DmDb.all_files().size())
	var n := DmDb._cache.size()
	DmDb.reset()
	check(DmDb._cache.is_empty(), "a reset empties DmDb's cache")
	DmDbWarm.all()
	check(DmDb._cache.size() == n, "all() warms it again after a reset (%d entries, was %d)" % [DmDb._cache.size(), n])
	check(DmThreadGuard.violations == 0, "no apply path has run off the main thread so far")
