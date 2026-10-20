class_name DmCoreData
extends RefCounted
## Feeds the combat core from the game's data so no number is retyped in C++ or in a test: the enemy defs and tuning, the status rules, the
## legion tuning (Rally, Hag's hex, the plague burst, the Legion burst, the Colossus, damage scale) and the GDScript constants of
## DmSimConsts and the old game's DmCorpseField and DmThrall, read from the files that define them. `godot_dir` is the folder that holds them (`res://` in the game).

const CONST_FILES: Array[String] = ["sim/sim_consts.gd", "next/corpses/dm_corpse_field.gd", "next/thralls/dm_thrall.gd"]


## A data file parsed. A file of the game's own data folder (`DmDb.ROOT`) comes through the one registry (`DmDb.raw`, a copy the caller may change), so a QA run's `--tune=` (main/qa_tune.gd) reaches the core too;
## any other path (a test's folder, the crowd's looks) is read from disk as it is.
static func json(path: String) -> Dictionary:
	if path.begins_with(DmDb.ROOT) and path.ends_with(".json"):
		var v: Variant = DmDb.raw(path.trim_prefix(DmDb.ROOT).trim_suffix(".json"))
		if v is Dictionary:
			return (v as Dictionary).duplicate(true)
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


## The numeric `const NAME := 1.5` / `const NAME: float = 1.5` lines of the given GDScript files, by name (later files win). A file that is not there
## is skipped (this project has no `next/corpses` or `next/thralls`: the core replaced them), and the core keeps the values compiled in, which are
## the old game's (client/tests/core_thralls.gd checks them).
static func consts(godot_dir: String, files: Array = CONST_FILES) -> Dictionary:
	var re := RegEx.new()
	re.compile("^const\\s+([A-Z][A-Z0-9_]*)\\s*(?::\\s*\\w+\\s*=|:=|=)\\s*(-?\\d+(?:\\.\\d+)?(?:e[+-]?\\d+)?)\\s*(?:#.*)?$")
	var out := {}
	for rel: String in files:
		var f := FileAccess.open(godot_dir.path_join(rel), FileAccess.READ)
		if f == null:
			continue
		for line in f.get_as_text().split("\n"):
			var m := re.search(line.strip_edges(false, true))
			if m != null:
				out[m.get_string(1)] = float(m.get_string(2))
	return out


## Everything the enemy brain, statuses, thralls and corpses need, in the order the core wants it. `godot_dir`: the folder holding data/ (and, for the
## constants, sim/ next/corpses next/thralls): this project's `res://` in the game.
static func load_all(core: RefCounted, godot_dir: String) -> void:
	var content := func(name: String) -> Dictionary: return json(godot_dir.path_join("data/content/%s.json" % name))
	var enemies: Dictionary = content.call("enemies")
	for key: String in (enemies["ENEMIES"] as Dictionary).keys():
		if String((enemies["ENEMIES"][key] as Dictionary).get("behavior", "")) == "boss":   # a boss's def (DmBoss.ensure_def registers it at run time in the shared table, for the codex): bosses are
			(enemies["ENEMIES"] as Dictionary).erase(key)                                     # externals the core never runs, and a core built after one woke must hold the tables of one built before
	var abilities: Dictionary = content.call("abilities")
	var statuses: Dictionary = content.call("statuses")
	core.load_enemy_defs(enemies["ENEMIES"])
	core.load_tuning(enemies)
	core.load_status_defs(DmStatusRules.build(abilities, statuses, enemies))
	core.load_legion_tuning({
		"abilities": abilities, "fen": content.call("fen"), "statuses": statuses, "gameplay_legendary": content.call("gameplay_legendary"),
		"runes": content.call("runes"), "combat_enemies": json(godot_dir.path_join("data/combat/enemies.json")),
	})
	core.load_sim_consts(consts(godot_dir))
