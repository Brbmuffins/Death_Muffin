extends SceneTree
## Rendered screenshot of the shared loading screen: godot --rendering-driver opengl3 --resolution WxH --script res://tests/perf/loading_shot.gd -- --out=/path.png
func _initialize() -> void:
	var out := "/tmp/loading.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var ls := DmLoadingScreen.acquire(root, "Waking the dead...  The Graves  (3 / 9)")
	ls.set_progress(0.5)
	await process_frame
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(out)
	print("SHOT ", out, " ", root.get_texture().get_size())
	quit()
