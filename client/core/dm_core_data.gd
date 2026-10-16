class_name DmCoreData
extends RefCounted
## Feeds the combat core from today's data so no number is retyped in C++ or in a test: the enemy defs and tuning, the status rules, the
## legion tuning (Rally, Hag's hex, the plague burst, the Legion burst, the Colossus, damage scale) and the GDScript constants of
## DmSimConsts, DmCorpseField and DmThrall, read from the files that define them. `godot_dir` is the folder of the live game (`godot/`);
## on launch day the same files move into `client/` and only the folder changes.

const CONST_FILES: Array[String] = ["sim/sim_consts.gd", "next/corpses/dm_corpse_field.gd", "next/thralls/dm_thrall.gd"]


static func json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


## The numeric `const NAME := 1.5` / `const NAME: float = 1.5` lines of the given GDScript files, by name (later files win). A file that is not there
## is skipped (this project has no `next/corpses` or `next/thralls`: the core replaced them), and the core keeps the values compiled in, which are
## today's (client/tests/core_thralls.gd asserts it against the live files).
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
## constants, sim/ next/corpses next/thralls): this project's `res://` in the game, the live game's folder in the core tests.
static func load_all(core: RefCounted, godot_dir: String) -> void:
	var content := func(name: String) -> Dictionary: return json(godot_dir.path_join("data/content/%s.json" % name))
	var enemies: Dictionary = content.call("enemies")
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
