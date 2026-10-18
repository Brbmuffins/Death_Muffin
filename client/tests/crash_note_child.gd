extends SceneTree
## Not a suite: crash_note.gd runs this in a child process. It arms the combat core's crash note at the path given after `--`, then crashes inside
## the core on purpose (DmCore.crash_for_test), so the parent can read the note that was written while crashing.


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	DmCore.arm_crash_note(args[0], "20261018.000000-abcdef0")
	DmCore.crash_for_test()
	quit(0)   # never reached
