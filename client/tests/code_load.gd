extends SceneTree
## Proof for the code sync (DECISIONS B43, client/code.list): every script, scene, resource and shader copied from godot/ (client/code.lock.json)
## loads in this project, and no copy mentions a per-creature class or path (those are replaced by the combat core and the crowd view; the files
## that do are seams, left out in code.list). Run: godot --headless --path client --script res://tests/code_load.gd
## Prints the counts and, as INFO, how many copied-scene dependencies are found by uid (assets imported here get new uids unless the seeded
## .import carries the original's, see tools/rebuild/sync-assets.mjs). Exit 1 on any failure.

const LOCK := "res://code.lock.json"

## Class names of the per-creature systems code.list leaves out: enemies/ (DmEnemy, its states and kinds), next/thralls, next/corpses, next/status,
## next/affixes, next/enemy_fx, game/dm_entity_views.gd and the per-creature records of sim/. A copy must not name one, even in a string.
const CREATURE_CLASSES := [
	"DmAffixSet", "DmCorpseField", "DmEnemy", "DmEnemyBurrower", "DmEnemyCaster", "DmEnemyCenser", "DmEnemyClstAcolyte", "DmEnemyClstCaster",
	"DmEnemyClstSeraph", "DmEnemyClstTemplar", "DmEnemyDeacon", "DmEnemyFlanker", "DmEnemyFx", "DmEnemyFxHost", "DmEnemyGargoyle", "DmEnemyHazard",
	"DmEnemyNiche", "DmEnemyPfCaster", "DmEnemyPfFlanker", "DmEnemyPfHazard", "DmEnemyPfMelee", "DmEnemyState", "DmEnemyStateMachine",
	"DmEnemyTestArena", "DmEnemyWraith", "DmEntityViews", "DmHostileZone", "DmPfUtil", "DmSimCorpse", "DmSimEnemy", "DmSimThrall", "DmSimZone",
	"DmStateAttack", "DmStateBurrow", "DmStateCathDive", "DmStateCathDiveChase", "DmStateCathSupport", "DmStateChase", "DmStateClstKite",
	"DmStateDead", "DmStateDig", "DmStateEmerge", "DmStateErupt", "DmStateFlankChase", "DmStateFlee", "DmStateHurt", "DmStateIdle", "DmStateKite",
	"DmStatePfHookChase", "DmStatePfLureKite", "DmStateReturn", "DmStateRising", "DmStatusSet", "DmTargetDummy", "DmThrall", "DmThrallHost",
]
## Their places: a copied scene or script that names one of these paths needs a creature system that is not here.
const CREATURE_PATHS := [
	"res://enemies/", "res://next/thralls/", "res://next/corpses/", "res://next/status/", "res://next/affixes/", "res://next/enemy_fx/",
	"res://game/dm_entity_views.gd", "res://sim/sim_enemy.gd", "res://sim/sim_thrall.gd", "res://sim/sim_corpse.gd", "res://sim/sim_zone.gd",
]

var failures: Array[String] = []
var counts := {"gd": 0, "tscn": 0, "tres": 0, "gdshader": 0, "json": 0, "other": 0}
var uid_found := 0
var uid_lost := 0


func _init() -> void:
	var lock = JSON.parse_string(FileAccess.get_file_as_string(LOCK))
	if typeof(lock) != TYPE_DICTIONARY:
		_fail("cannot read %s (run node tools/rebuild/sync-code.mjs)" % LOCK)
		_finish()
		return
	var files: Array[String] = []
	for rel in (lock.get("copied", {}) as Dictionary).keys():
		files.append(rel)
	for rel in (lock.get("ported", {}) as Dictionary).keys():
		files.append(rel)
	files.sort()
	var pattern := _creature_regex()
	var classes := _global_classes()
	for rel in files:
		var path := "res://" + rel
		if not FileAccess.file_exists(path):
			_fail("%s: listed in code.lock.json but missing" % rel)
			continue
		var text := FileAccess.get_file_as_string(path)
		var ext: String = rel.get_extension()
		if ext == "uid":
			continue
		_check_creature_free(rel, text, ext, pattern)
		match ext:
			"gd":
				counts["gd"] += 1
				_check_script(rel, path, text, classes)
			"tscn", "tres":
				counts[ext] += 1
				_check_resource(rel, path)
			"gdshader":
				counts["gdshader"] += 1
				var sh = ResourceLoader.load(path)
				if not (sh is Shader):
					_fail("%s: does not load as a Shader" % rel)
			"json":
				counts["json"] += 1
				if JSON.parse_string(text) == null:
					_fail("%s: not valid JSON" % rel)
			_:
				counts["other"] += 1
	_finish()


func _finish() -> void:
	print("INFO code_load: %d scripts, %d scenes, %d resources, %d shaders, %d json, %d other copies" % [counts["gd"], counts["tscn"], counts["tres"], counts["gdshader"], counts["json"], counts["other"]])
	print("INFO code_load: dependencies found by uid %d, by text path only %d" % [uid_found, uid_lost])
	if failures.is_empty():
		print("PASS code_load")
		quit(0)
		return
	for f in failures:
		printerr("FAIL code_load: " + f)
	printerr("FAIL code_load: %d problem(s)" % failures.size())
	quit(1)


func _fail(msg: String) -> void:
	failures.append(msg)


## One regex over every creature class name (whole words) and path.
func _creature_regex() -> RegEx:
	var alts: Array[String] = []
	for c in CREATURE_CLASSES:
		alts.append("\\b" + c + "\\b")
	for p in CREATURE_PATHS:
		alts.append(_escape(p))
	var re := RegEx.new()
	re.compile("|".join(alts))
	return re


func _escape(s: String) -> String:
	return s.replace(".", "\\.")


## class_name -> script path for every global class of this project.
func _global_classes() -> Dictionary:
	var out := {}
	for d in ProjectSettings.get_global_class_list():
		out[str(d.get("class", ""))] = str(d.get("path", ""))
	return out


## A copy names no per-creature class or path. Comments are not code (a `##` line may say what a class used to be); strings are.
func _check_creature_free(rel: String, text: String, ext: String, re: RegEx) -> void:
	var body := _strip_comments(text) if ext == "gd" else text
	var m := re.search(body)
	if m != null:
		_fail("%s: names the per-creature '%s' (a seam: leave it out in client/code.list)" % [rel, m.get_string()])


## Source with every `# ...` comment cut off, string-aware (a '#' inside quotes stays).
func _strip_comments(text: String) -> String:
	var out := PackedStringArray()
	for line in text.split("\n"):
		var quote := ""
		var cut := -1
		var i := 0
		while i < line.length():
			var ch := line[i]
			if quote != "":
				if ch == "\\":
					i += 1
				elif ch == quote:
					quote = ""
			elif ch == "\"" or ch == "'":
				quote = ch
			elif ch == "#":
				cut = i
				break
			i += 1
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)


func _check_script(rel: String, path: String, text: String, classes: Dictionary) -> void:
	var s = ResourceLoader.load(path)
	if not (s is Script):
		_fail("%s: does not load as a script" % rel)
		return
	if not s.can_instantiate():
		_fail("%s: script has errors (cannot instantiate)" % rel)
	var re := RegEx.create_from_string("(?m)^class_name\\s+(\\w+)")
	var m := re.search(text)
	if m != null:
		var cn := m.get_string(1)
		if classes.get(cn, "") != path:
			_fail("%s: class %s is registered for '%s' (a class name collision)" % [rel, cn, classes.get(cn, "nothing")])


func _check_resource(rel: String, path: String) -> void:
	var r = ResourceLoader.load(path)
	if r == null:
		_fail("%s: does not load" % rel)
		return
	if r is PackedScene and not r.can_instantiate():
		_fail("%s: scene cannot be instantiated" % rel)
	for dep in ResourceLoader.get_dependencies(path):
		var p := ""
		var uid_text := ""
		for part in str(dep).split("::"):   # the path alone, or uid, type and path
			if part.begins_with("uid://"):
				uid_text = part
			elif part.begins_with("res://"):
				p = part
		if uid_text != "" and p == "":
			p = ResourceUID.get_id_path(ResourceUID.text_to_id(uid_text)) if ResourceUID.has_id(ResourceUID.text_to_id(uid_text)) else ""
		if p == "" or not ResourceLoader.exists(p):
			_fail("%s: dependency %s is missing" % [rel, str(dep)])
			continue
		if uid_text != "":
			var id := ResourceUID.text_to_id(uid_text)
			if ResourceUID.has_id(id) and ResourceUID.get_id_path(id) == p:
				uid_found += 1
			else:
				uid_lost += 1
