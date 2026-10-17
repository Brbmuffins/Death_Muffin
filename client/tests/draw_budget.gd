extends SceneTree
## The 3D draw-call budget (ROADMAP "Now: the rebuild", client/README.md "The draw budget"): the draw calls of the Graves' Full Party fight, counted from data (`DmDrawModel`) in a scene a
## headless run can build (`DmDrawScene`: the Graves' area scene, the game's camera, the Ultra preset's moon, 72 enemies and four necromancers' thralls on the combat core). A draw call
## is what the budget counts and a headless run draws nothing, so the test counts what Forward+ would issue: an object per instance the camera sees (or a moon cascade, for a caster), a
## draw per surface, identical meshes instanced into one draw, and a MultiMesh costing its draws whether or not it holds an instance. It proves:
##   - the crowd costs what is in view and not what is registered: a MultiMesh group is shown while it holds instances and hidden when it does not, so the Full Party's draws are the
##     used groups' (a few dozen) and not those of every baked model's groups (the 8913127 test build drew 396 for the crowd, 280 before the roster grew, 41 now);
##   - the model sees that regression: with every group shown the crowd counts several times its draws;
##   - the world and the whole stay inside their budgets (BUDGET_*), so a change that adds draw calls (a prop merged so that it no longer instances, a group left shown) fails here and not
##     on Helix's PC.
## INFO lines print the rows by group. Bakes the Graves' roster (and three models the party does not use) into a scratch folder first (about a minute).
## Run: godot --headless --path client --script res://tests/draw_budget.gd   (--fixed-fps 60 before --path is faster)

const OUT := "user://draw_budget_test"
const BAKE := ["grave_robber", "bone_hound", "barrow_ghoul", "choir_wraith", "skeleton_thrall", "skeleton_thrall+warrior", "skeleton_thrall+shieldbearer", "skeleton_thrall+archer",
	"skeleton_thrall+bonemage", "skull_rat", "tithe_bat", "shroud_moth"]   ## the party uses the first nine (the legions' own bodies fall back to the skeleton); the last three are the idle roster
## The model's draw calls for the Graves' Full Party at the benchmark's camera, both passes, a little over what the model counts (client/README.md "The draw budget" has the figures).
const BUDGET_CROWD := 30
const BUDGET_WORLD := 85
const BUDGET_TOTAL := 110

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
		printerr("FAIL draw_budget: " + what)


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	DmSimData.ensure()
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	await the_budget()
	_remove_dir(OUT)
	check(errlog.errors.is_empty(), "zero script errors or engine errors in the log (%d: %s)" % [errlog.errors.size(), "; ".join(errlog.errors.slice(0, 3))])
	print("INFO draw_budget: %d checks" % checks)
	if fails > 0:
		printerr("FAIL draw_budget: %d of %d checks failed" % [fails, checks])
		quit(1)
		return
	print("PASS draw_budget")
	quit(0)


func the_budget() -> void:
	var stage := DmDrawScene.build(root)
	var host := DmDrawScene.add_crowd(stage, OUT)
	var frames := Engine.get_physics_frames() + 120   # two seconds of the party standing and fighting: the rise is over, the levels of detail have settled
	while Engine.get_physics_frames() < frames:
		await physics_frame
	await process_frame
	var recs := DmDrawModel.records(stage, stage)
	var facts := DmDrawModel.facts(stage, stage.camera)
	var res := DmDrawModel.count(recs, facts)
	check(res.cascades == 2, "the Ultra preset's moon has two cascades (%d)" % res.cascades)
	var crowd := parts(res, "crowd")
	var world := parts(res, "world")
	var rest := parts(res, "other")
	var total := DmDrawModel.draws(res.total)
	print("INFO draw calls the model counts for the Graves' Full Party (%d recorded instances): crowd %d (main %d, shadow %d), world %d (main %d, shadow %d), the rest %d; %d in all" % [
		recs.size(), DmDrawModel.draws(crowd), crowd.main_draws, crowd.shadow_draws, DmDrawModel.draws(world), world.main_draws, world.shadow_draws, DmDrawModel.draws(rest), total])
	for g: String in res.groups:
		var c: Dictionary = res.groups[g]
		print("INFO   %-34s %3d instances: main %3d objects %3d draws, shadow %3d objects %3d draws" % [g, c.instances, c.main_objs, c.main_draws, c.shadow_objs, c.shadow_draws])
	# the crowd: shown groups are the groups that hold instances
	var groups: Array = recs.filter(func(r: Dictionary) -> bool: return String(r["grp"]).begins_with("crowd"))
	var shown := groups.filter(func(r: Dictionary) -> bool: return bool(r["vis"]))
	var holding := groups.filter(func(r: Dictionary) -> bool: return int(r["n"]) > 0)
	var holding_hidden := holding.filter(func(r: Dictionary) -> bool: return not bool(r["vis"]))
	var shown_empty := shown.filter(func(r: Dictionary) -> bool: return int(r["n"]) == 0)
	check(host.view.model_slots().size() >= 12, "the crowd has %d models: the party's and the idle roster's" % host.view.model_slots().size())
	check(groups.size() > 3 * holding.size() and holding.size() > 0, "%d groups exist and %d hold instances: most of them are idle" % [groups.size(), holding.size()])
	check(holding_hidden.is_empty() and shown_empty.size() <= 2, "a group is shown while it holds instances; %d shown empty (emptied in the last half second), %d holding and hidden" % [shown_empty.size(), holding_hidden.size()])
	check(crowd.main_draws == shown.size(), "the crowd's main pass draws one surface for each shown group (%d draws, %d groups)" % [crowd.main_draws, shown.size()])
	check(DmDrawModel.draws(crowd) <= BUDGET_CROWD, "the crowd stays inside %d draw calls (%d)" % [BUDGET_CROWD, DmDrawModel.draws(crowd)])
	# the regression this test exists for: every group shown
	var legacy: Array = []
	for r: Dictionary in recs:
		var copy := r.duplicate()
		if String(r["grp"]).begins_with("crowd"):
			copy["vis"] = true
		legacy.append(copy)
	var lres := DmDrawModel.count(legacy, facts)
	var lcrowd := parts(lres, "crowd")
	print("INFO with every one of the %d groups shown the crowd would cost %d draw calls (%d shown: %d)" % [groups.size(), DmDrawModel.draws(lcrowd), shown.size(), DmDrawModel.draws(crowd)])
	check(DmDrawModel.draws(lcrowd) > 4 * DmDrawModel.draws(crowd), "the model sees a crowd with every group shown: %d draws against %d" % [DmDrawModel.draws(lcrowd), DmDrawModel.draws(crowd)])
	check(DmDrawModel.draws(lres.total) > BUDGET_TOTAL, "and the total budget would not hold it (%d of %d)" % [DmDrawModel.draws(lres.total), BUDGET_TOTAL])
	# the world and the whole
	check(DmDrawModel.draws(world) <= BUDGET_WORLD, "the Graves' world stays inside %d draw calls (%d)" % [BUDGET_WORLD, DmDrawModel.draws(world)])
	check(total <= BUDGET_TOTAL, "and the whole inside %d (%d)" % [BUDGET_TOTAL, total])
	stage.queue_free()
	await process_frame


## The counts of the groups whose name starts with `prefix`, added up.
func parts(res: Dictionary, prefix: String) -> Dictionary:
	var out := {"main_objs": 0, "main_draws": 0, "shadow_objs": 0, "shadow_draws": 0}
	for g: String in res.groups:
		if g.begins_with(prefix):
			for k: String in out:
				out[k] += int(res.groups[g][k])
	return out


func _remove_dir(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)
