extends SceneTree
## The combat core's crash note (native/README.md "Crash notes") and the crash report that carries it (DmCrashWatch). Headless:
##   godot --headless --path client --script res://tests/crash_note.gd
## Checks: the note's format; a real crash inside the core (a child process: tests/crash_note_child.gd) writes the note with the core's module
## and offsets and still ends as a crash; the next start puts the note first in the report's log and in `coreCrash`; a note with no crash
## (no lock left) is dropped as stale. The Windows half (an unhandled-exception filter) is checked on a Windows PC: client/README.md "Crash notes".

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL crash_note: " + what)


func _init() -> void:
	# the format, from fixed frames
	var sample: String = DmCore.crash_note_sample()
	var lines := sample.strip_edges().split("\n")
	check(lines.size() == 6, "a sample note has a header, the build, what happened and three frames (%d lines)" % lines.size())
	check(lines[0] == "DMCORE CRASH NOTE" and lines[1] == "build 20261018.000000-abcdef0" and lines[2] == "what access violation (0xc0000005)", "header lines: %s" % str(lines.slice(0, 3)))
	check(lines[3] == "#0 libdmcore.windows.template_release.x86_64.dll+0x1a2b3" and lines[4] == "#1 DeathMuffin.exe+0x45" and lines[5] == "#2 ?+0x7", "frame lines: %s" % str(lines.slice(3)))

	# a real crash inside the core, in a child process
	var dir := OS.get_user_data_dir().path_join("crash_note_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var note_path := dir.path_join("note.txt")
	if FileAccess.file_exists(note_path):
		DirAccess.remove_absolute(note_path)
	var out := []
	var code := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/crash_note_child.gd", "--", note_path], out, true)
	check(code != 0, "the child crashed (exit code %d)" % code)
	check(FileAccess.file_exists(note_path), "the crash wrote the note")
	var note := FileAccess.get_file_as_string(note_path) if FileAccess.file_exists(note_path) else ""
	check(note.begins_with("DMCORE CRASH NOTE\nbuild 20261018.000000-abcdef0\nwhat SIGSEGV\n"), "the note names the build and the signal: %s" % note.substr(0, 120))
	check(note.contains("libdmcore.linux.template_debug.x86_64.so+0x"), "a frame is in the core's library, with its offset")
	var text := "\n".join(out)
	check(text.contains("Program crashed with signal") or text.contains("CrashHandlerException") or text.contains("handle_crash"), "Godot's own crash handler still ran after the note (the signal was handed on)")

	# the next start: the crash report carries the note
	var lk := dir.path_join("session.lock"); var pd := dir.path_join("pending.json"); var ld := "user://no_such_logs"
	var rel := "20261018.000000-abcdef0"
	DmCrashWatch.end(lk); DmCrashWatch.clear(pd)
	check(not DmCrashWatch.begin(rel, lk, pd, ld, note_path), "a first start is no crash")
	check(not FileAccess.file_exists(note_path), "a note with no crash left behind is dropped as stale")
	var f := FileAccess.open(note_path, FileAccess.WRITE)
	f.store_string(note)
	f.close()
	check(DmCrashWatch.begin(rel, lk, pd, ld, note_path), "the lock left behind: the last run crashed")
	check(not FileAccess.file_exists(note_path), "the note is taken into the pending report")
	var rep := DmCrashWatch.pending_report(7, pd)
	check(String(rep["context"].get("coreCrash", "")).begins_with("DMCORE CRASH NOTE"), "the report carries the note as coreCrash")
	check(String(rep["context"]["log"]).begins_with("DMCORE CRASH NOTE"), "the note comes first in the report's log")
	check(String(rep["message"]).contains("The combat core noted where it crashed"), "the report's message says the core noted where")
	DmCrashWatch.clear(pd); DmCrashWatch.end(lk)
	for n in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)

	if fails == 0:
		print("PASS crash_note")
	quit(1 if fails else 0)
