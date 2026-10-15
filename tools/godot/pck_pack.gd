extends SceneTree
## Write a .pck from extracted files (assets-pack.sh): godot --headless --script pck_pack.gd -- <files dir> <list.txt> <out.pck>

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		printerr("usage: -- <files dir> <list.txt> <out.pck>")
		quit(2)
		return
	var p := PCKPacker.new()
	if p.pck_start(a[2]) != OK:
		printerr("cannot write %s" % a[2])
		quit(1)
		return
	for rel in FileAccess.get_file_as_string(a[1]).split("\n", false):
		if p.add_file("res://" + rel, a[0].path_join(rel)) != OK:
			printerr("cannot add %s" % rel)
			quit(1)
			return
	quit(0 if p.flush() == OK else 1)
