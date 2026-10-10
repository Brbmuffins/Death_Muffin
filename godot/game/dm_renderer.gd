class_name DmRenderer
extends RefCounted
## Settings -> Graphics -> Renderer: Compatibility (OpenGL 3.3, the default for everyone) or Mobile (Vulkan, experimental). The renderer is chosen
## before any script runs, so the choice lives in a project-settings override file, not in dm_settings: project.godot names it
## (`application/config/project_settings_override="user://dm_renderer.cfg"`) and the engine reads it at startup before the renderer
## initialises. Compatibility = no file (deleting the file is the way back); Mobile = a file holding `rendering/renderer/rendering_method="mobile"`.
## If Vulkan is unavailable the engine falls back to OpenGL 3 on its own (`rendering/rendering_device/fallback_to_opengl3`, on), so the game
## still starts; `active()` then reports Compatibility while `requested()` still says Mobile.
## Recovery if Mobile looks wrong: Settings -> Graphics -> Renderer -> Compatibility and restart; or launch with `-- --renderer=compat` (this
## rewrites the file and relaunches without the flag); or delete the file (README.md "Renderer").
## Crash guard: the engine fallback only covers a Vulkan that fails to start. A Mobile run that dies later (driver crash while loading the
## world) leaves a guard file; the next launch sees it, puts the choice back to Compatibility, says so in Settings and relaunches. A Mobile run
## clears the guard after GUARD_OK_S of play or on a clean quit. A crash before the first script runs cannot be seen from inside the game: delete
## the override file by hand (README.md "Renderer").
## Branch on the renderer with `active()` / `is_mobile()`, never on the setting: the fallback means they can differ.

const CFG_PATH := "user://dm_renderer.cfg"
const COMPAT := "compat"
const MOBILE := "mobile"
const IDS: Array[String] = [COMPAT, MOBILE]
const LABELS := {
	COMPAT: "Compatibility (default)",
	MOBILE: "Mobile (Vulkan, experimental, restart required)",
}
## Engine rendering-method names (RenderingServer.get_current_rendering_method()) per id.
const METHODS := {COMPAT: "gl_compatibility", MOBILE: "mobile"}
const FLAG := "--renderer="
const GUARD_PATH := "user://dm_renderer.guard"
const REVERTED_PATH := "user://dm_renderer.reverted"
const GUARD_OK_S := 25.0


static func options() -> Array:
	var out := []
	for id in IDS:
		out.append([id, LABELS[id]])
	return out


## The renderer the NEXT launch will ask for (what the file says; Compatibility when there is no usable file).
static func requested(path: String = CFG_PATH) -> String:
	if not FileAccess.file_exists(path):
		return COMPAT
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return COMPAT
	var m := str(cf.get_value("rendering", "renderer/rendering_method", METHODS[COMPAT]))
	return MOBILE if m == METHODS[MOBILE] else COMPAT


## The renderer this process actually runs: "compat", "mobile", or the raw engine name for anything else (forward_plus from a hand-made override).
static func active() -> String:
	var m := RenderingServer.get_current_rendering_method()
	for id in IDS:
		if METHODS[id] == m:
			return id
	return m


static func is_mobile() -> bool:
	return RenderingServer.get_current_rendering_method() == METHODS[MOBILE]


## "Mobile / vulkan", "Compatibility / opengl3" (F3 overlay, bug report).
static func describe() -> String:
	var a := active()
	return "%s / %s" % [(LABELS[a] if LABELS.has(a) else a).split(" (")[0], RenderingServer.get_current_rendering_driver_name()]


## Requested Mobile but the engine is running something else (no Vulkan on this PC).
static func fell_back(path: String = CFG_PATH) -> bool:
	return requested(path) == MOBILE and active() != MOBILE


## Persist the choice for the next launch. Compatibility removes the file, so a default install never carries an override.
static func set_requested(id: String, path: String = CFG_PATH) -> bool:
	_remove(REVERTED_PATH)
	if id != MOBILE:
		_remove(GUARD_PATH)
		if FileAccess.file_exists(path):
			return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
		return true
	var cf := ConfigFile.new()
	cf.set_value("rendering", "renderer/rendering_method", METHODS[MOBILE])
	return cf.save(path) == OK


## `--renderer=compat|mobile` among the user args ("" = none or unknown value).
static func flag_choice(user_args: PackedStringArray) -> String:
	for a in user_args:
		if a.begins_with(FLAG):
			var v := a.substr(FLAG.length()).to_lower()
			if v in ["compat", "compatibility", "gl_compatibility", "opengl"]:
				return COMPAT
			if v == MOBILE:
				return MOBILE
	return ""


## The user args without any `--renderer=` flag (what a relaunch passes, so the flag is applied once).
static func strip_flag(user_args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for a in user_args:
		if not a.begins_with(FLAG):
			out.append(a)
	return out


## Launch-time hook (DmMain._ready): applies `--renderer=`. Returns true when the process is relaunching and the caller should stop starting up.
static func apply_flag(tree: SceneTree, user_args: PackedStringArray) -> bool:
	var choice := flag_choice(user_args)
	if choice == "":
		return false
	set_requested(choice)
	if active() == choice:
		return false   # already running it: nothing to relaunch
	relaunch(tree, strip_flag(user_args))
	return true


## Quit and start again with the same engine args (the renderer is only read at startup).
static func relaunch(tree: SceneTree, user_args: PackedStringArray = strip_flag(OS.get_cmdline_user_args())) -> void:
	var args := PackedStringArray(OS.get_cmdline_args())
	if not user_args.is_empty():
		args.append("--")
		args.append_array(user_args)
	OS.set_restart_on_exit(true, args)
	tree.root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)   # DmMain saves, then quits


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## True when a previous Mobile run did not survive its first GUARD_OK_S seconds and the choice was put back to Compatibility.
static func was_reverted() -> bool:
	return FileAccess.file_exists(REVERTED_PATH)


## Guard decision for a launch: true when a previous Mobile run left its guard (it died before GUARD_OK_S): the choice goes back to
## Compatibility and the "reverted" note is left for Settings. Otherwise a Mobile run arms the guard.
static func guard_check(mobile: bool, guard: String = GUARD_PATH, path: String = CFG_PATH) -> bool:
	if not mobile:
		return false
	if FileAccess.file_exists(guard):
		set_requested(COMPAT, path)
		_remove(guard)
		var f := FileAccess.open(REVERTED_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string("1")
		return true
	var g := FileAccess.open(guard, FileAccess.WRITE)
	if g != null:
		g.store_string("1")
	return false


## Launch-time hook after apply_flag (DmMain._ready). Returns true when the process is relaunching into Compatibility. On a Mobile run it
## arms the guard; the caller clears it with guard_ok() after GUARD_OK_S seconds or on a clean quit.
static func guard_start(tree: SceneTree, user_args: PackedStringArray) -> bool:
	if not guard_check(is_mobile()):
		return false
	relaunch(tree, strip_flag(user_args))
	return true


static func guard_ok(guard: String = GUARD_PATH) -> void:
	_remove(guard)
