class_name DmCrashWatch
extends RefCounted
## Automatic crash reports (owner 2026-10-15; DECISIONS B29). A release build writes a lock file when it starts and removes it when it
## shuts down normally (main.gd _exit_tree: window close, quit, benchmark end; or `DmMain.end_process` just before a Windows release build ends
## its own process, DECISIONS B60). A lock still there at the next start means the last run
## ended without shutting down: a crash, a freeze that was killed, or the PC going down. That run's log tail is kept in a pending file
## until a signed-in game can send it as a bug report (category "bug", context `crash: true`), which opens an #in-game-reports thread like
## any player report. Dev builds never write the lock, so editor and test runs make no reports. The combat core also
## writes a crash note while crashing (native/README.md "Crash notes": each stack frame's module and offset, which Godot's own log prints as
## "???"); the report carries it first in the log and as `coreCrash`.

const LOCK := "user://session.lock"
const PENDING := "user://crash_pending.json"
const LOG_CHARS := 11000
const CORE_NOTE := "user://core_crash_note.txt"

## At startup. Returns true when the previous run crashed (its report is now pending). Writes this run's lock.
static func begin(version: String, lock_path: String = LOCK, pending_path: String = PENDING, log_dir: String = "user://logs", note_path: String = CORE_NOTE) -> bool:
	if not DmBuild.is_release(version):
		return false
	var crashed := false
	var note := ""   # read and removed at every start: a note with no lock left behind is stale
	if FileAccess.file_exists(note_path):
		note = FileAccess.get_file_as_string(note_path).strip_edges()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(note_path))
	if FileAccess.file_exists(lock_path):
		var prev: Variant = JSON.parse_string(FileAccess.get_file_as_string(lock_path))
		var p: Dictionary = prev if prev is Dictionary else {}
		var log_text := DmBugReportView.game_log_tail(LOG_CHARS, log_dir, true)
		var f := FileAccess.open(pending_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"version": String(p.get("version", "unknown")), "started": int(p.get("started", 0)), "log": log_text, "core_note": note}))
			f.close()
		crashed = true
	var l := FileAccess.open(lock_path, FileAccess.WRITE)
	if l != null:
		l.store_string(JSON.stringify({"version": version, "started": int(Time.get_unix_time_from_system())}))
		l.close()
	return crashed


## At a normal shutdown.
static func end(lock_path: String = LOCK) -> void:
	if FileAccess.file_exists(lock_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lock_path))


## The pending crash as a bug report payload, or {} when there is none.
static func pending_report(character_id: int, pending_path: String = PENDING) -> Dictionary:
	if not FileAccess.file_exists(pending_path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(pending_path))
	if not (d is Dictionary):
		clear(pending_path)
		return {}
	var p: Dictionary = d
	var when := Time.get_datetime_string_from_unix_time(int(p.get("started", 0)), true) + " UTC" if int(p.get("started", 0)) > 0 else "unknown"
	var log_text := String(p.get("log", ""))
	var note := String(p.get("core_note", ""))
	var vp := DisplayServer.window_get_size()
	var rep := {"category": "bug", "characterId": character_id,
		"message": "Automatic crash report: the game closed without shutting down (build %s, started %s). Sent by the game, not typed by the player.%s" % [
			String(p.get("version", "unknown")), when, " The combat core noted where it crashed (coreCrash)." if note != "" else ""],
		"context": {"crash": true, "release": String(p.get("version", "unknown")), "gpu": RenderingServer.get_video_adapter_name(),
			"viewport": "%dx%d@1" % [vp.x, vp.y], "userAgent": "DeathMuffin Godot %s" % Engine.get_version_info()["string"],
			"errors": DmBugReportView.log_errors(log_text), "log": (note + "\n\n" + log_text) if note != "" else log_text}}
	if note != "":
		rep["context"]["coreCrash"] = note
	return rep


static func clear(pending_path: String = PENDING) -> void:
	if FileAccess.file_exists(pending_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(pending_path))
