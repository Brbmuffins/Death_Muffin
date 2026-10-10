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
## Threading options (opt-in, default off, same file): `physics/3d/run_on_separate_thread` (physics thread) and
## `rendering/driver/threads/thread_model`=2 (separate render thread, written only while the requested renderer is Mobile; Compatibility/OpenGL is
## not offered it). They count as experimental graphics like Mobile: the guard covers all three (any of them running arms it), a crash in the
## first GUARD_OK_S puts ALL back to defaults, and `-- --safe-graphics` (or `--renderer=compat`) resets all of them. No non-default key = no file.

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
const SAFE_FLAG := "--safe-graphics"
const KEY_PHYSICS := "physics/3d/run_on_separate_thread"
const KEY_RENDER := "rendering/driver/threads/thread_model"
const THREAD_MODEL_SEPARATE := 2   # RenderingServer thread model: 0 single-unsafe, 1 safe (the engine default), 2 separate (multi-threaded)


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
	return "%s / %s%s" % [(LABELS[a] if LABELS.has(a) else a).split(" (")[0], RenderingServer.get_current_rendering_driver_name(), threads_text()]


## ", physics thread, render thread" for the options running, "" when none (F3 overlay, bug report).
static func threads_text() -> String:
	return (", physics thread" if physics_thread_active() else "") + (", render thread" if render_thread_active() else "")


## Requested Mobile but the engine is running something else (no Vulkan on this PC).
static func fell_back(path: String = CFG_PATH) -> bool:
	return requested(path) == MOBILE and active() != MOBILE


## Persist the renderer for the next launch. Compatibility drops the render-thread key (Mobile-only); the file is removed when nothing
## non-default is left, so a default install never carries an override. The physics-thread choice is kept.
static func set_requested(id: String, path: String = CFG_PATH) -> bool:
	_remove(REVERTED_PATH)
	return _write(path, id, physics_thread_requested(path), render_thread_requested(path) and id == MOBILE)


## Threading choices the NEXT launch will ask for (what the file says; off when there is no usable file).
static func physics_thread_requested(path: String = CFG_PATH) -> bool:
	return _cfg_value(path, "physics", "3d/run_on_separate_thread", false) == true


static func render_thread_requested(path: String = CFG_PATH) -> bool:
	return int(_cfg_value(path, "rendering", "driver/threads/thread_model", 1)) == THREAD_MODEL_SEPARATE and requested(path) == MOBILE


static func set_physics_thread(on: bool, path: String = CFG_PATH) -> bool:
	_remove(REVERTED_PATH)
	return _write(path, requested(path), on, render_thread_requested(path))


static func set_render_thread(on: bool, path: String = CFG_PATH) -> bool:
	_remove(REVERTED_PATH)
	var r := requested(path)
	return _write(path, r, physics_thread_requested(path), on and r == MOBILE)


## What this process actually runs (the engine applied the override at startup).
static func physics_thread_active() -> bool:
	return ProjectSettings.get_setting(KEY_PHYSICS, false) == true


static func render_thread_active() -> bool:
	return int(ProjectSettings.get_setting(KEY_RENDER, 1)) == THREAD_MODEL_SEPARATE


## Anything experimental running: Mobile or a threading option. This is what arms the crash guard.
static func experimental_active() -> bool:
	return is_mobile() or physics_thread_active() or render_thread_active()


## Everything back to the shipped defaults (Compatibility, no threads, no file, no guard).
static func reset_all(path: String = CFG_PATH) -> bool:
	_remove(REVERTED_PATH)
	return _write(path, COMPAT, false, false)


static func _cfg_value(path: String, section: String, key: String, default: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		return default
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return default
	return cf.get_value(section, key, default)


static func _write(path: String, renderer: String, physics: bool, render: bool) -> bool:
	if renderer != MOBILE and not physics and not render:
		_remove(GUARD_PATH)
		if FileAccess.file_exists(path):
			return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
		return true
	var cf := ConfigFile.new()
	if renderer == MOBILE:
		cf.set_value("rendering", "renderer/rendering_method", METHODS[MOBILE])
		if render:
			cf.set_value("rendering", "driver/threads/thread_model", THREAD_MODEL_SEPARATE)
	if physics:
		cf.set_value("physics", "3d/run_on_separate_thread", true)
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


## The user args without any `--renderer=` / `--safe-graphics` flag (what a relaunch passes, so the flag is applied once).
static func strip_flag(user_args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for a in user_args:
		if not a.begins_with(FLAG) and a != SAFE_FLAG:
			out.append(a)
	return out


## Launch-time hook (DmMain._ready): applies `--renderer=` and `--safe-graphics`. Compatibility (either flag) also resets the threading options.
## Returns true when the process is relaunching and the caller should stop starting up.
static func apply_flag(tree: SceneTree, user_args: PackedStringArray) -> bool:
	var choice := flag_choice(user_args)
	if SAFE_FLAG in user_args:
		choice = COMPAT
	if choice == "":
		return false
	if choice == COMPAT:
		reset_all()
	else:
		set_requested(choice)
	if active() == choice and (choice == MOBILE or not experimental_active()):
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


## True when a previous experimental run did not survive its first GUARD_OK_S seconds and everything was put back to defaults.
static func was_reverted() -> bool:
	return FileAccess.file_exists(REVERTED_PATH)


## Guard decision for a launch: true when a previous experimental run (Mobile or a threading option) left its guard (it died before
## GUARD_OK_S): ALL of them go back to defaults and the "reverted" note is left for Settings. Otherwise an experimental run arms the guard.
static func guard_check(experimental: bool, guard: String = GUARD_PATH, path: String = CFG_PATH) -> bool:
	if not experimental:
		return false
	if FileAccess.file_exists(guard):
		reset_all(path)
		_remove(guard)
		var f := FileAccess.open(REVERTED_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string("1")
		return true
	var g := FileAccess.open(guard, FileAccess.WRITE)
	if g != null:
		g.store_string("1")
	return false


## Launch-time hook after apply_flag (DmMain._ready). Returns true when the process is relaunching on the defaults. On an experimental run it
## arms the guard; the caller clears it with guard_ok() after GUARD_OK_S seconds or on a clean quit.
static func guard_start(tree: SceneTree, user_args: PackedStringArray) -> bool:
	if not guard_check(experimental_active()):
		return false
	relaunch(tree, strip_flag(user_args))
	return true


static func guard_ok(guard: String = GUARD_PATH) -> void:
	_remove(guard)
