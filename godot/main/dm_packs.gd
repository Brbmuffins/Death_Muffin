extends Node
## The first autoload (project.godot): loads DeathMuffin.assets.pck, the art, models and audio under res://assets, before anything else
## loads a resource. The game ships as two packs (publish-godot-client.sh): DeathMuffin.pck (code, data, UI) changes every release, the
## assets pack only when res://assets changes, so the launcher reuses it (same SHA-256) and most updates download ~15 MB instead of ~280.
## An editor or test run has res://assets on disk and no pack: nothing to do. `-- --assets-pack=<path>` points at a pack elsewhere (tests).

const FILE := "DeathMuffin.assets.pck"

func _init() -> void:
	var path := OS.get_executable_path().get_base_dir().path_join(FILE)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--assets-pack="):
			path = a.trim_prefix("--assets-pack=")
	if not FileAccess.file_exists(path):
		if not DirAccess.dir_exists_absolute("res://assets"):   # an exported build without its assets pack: say so instead of a broken world
			push_error("%s is missing next to the game." % FILE)
			OS.alert("Death Muffin could not find its art and sound files (%s).\nOpen the launcher and let it repair the install." % FILE, "Death Muffin")
		return
	# replace_files false: the assets pack never overrides a file the main pack has (it carries none, publish strips them).
	if not ProjectSettings.load_resource_pack(path, false):
		push_error("Could not load %s: reinstall the game from the launcher." % path)
		OS.alert("Death Muffin could not load its art and sound files (%s).\nOpen the launcher and let it repair the install." % FILE, "Death Muffin")
