extends SceneTree
## Rendered check of DmNecroBackdrop (needs a display; use backdrop_shot.sh). Runs ~8 s of simulated frames so mist and embers fill in.
##   args: --out=<png>  --mouse=x,y (-1..1)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var out := "res://../shots/world_fx/backdrop.png"
	var mouse := Vector2.ZERO
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--mouse="):
			var p := a.substr(8).split(",")
			mouse = Vector2(float(p[0]), float(p[1]))
	var layer := DmNecroBackdrop.make_layer()
	root.add_child(layer)
	await process_frame
	await process_frame
	var b: DmNecroBackdrop = layer.get_meta("backdrop")
	b.set_process(false)
	b.mouse = mouse
	for i in 500:
		b.tick(1.0 / 60.0)
		if i % 50 == 0:
			await process_frame
	await process_frame
	await process_frame
	var img := root.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	img.save_png(out)
	print("[backdrop] saved ", out, " mist=", b.mist.active, " embers=", b.embers.active)
	quit()
