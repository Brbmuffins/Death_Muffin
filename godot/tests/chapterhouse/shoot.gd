extends SceneTree
## Rendered screenshots of the hub (under the renderer lock + xvfb): the Prior with the talk prompt, then the dialogue.
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/chapterhouse/shoot.gd -- --out=/some/dir

func _initialize() -> void:
	_run.call_deferred()


func _out() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			return a.substr(6)
	return "/tmp"


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("sh%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"persist": false, "waves": false})
	var b := g.local_body()
	b.teleport(Vector3(-2.0, 0, 18.0))
	g.camera.snap(b.position)
	await _frames(90)
	root.get_viewport().get_texture().get_image().save_png(_out() + "/chapterhouse-prompt.png")
	g.chapterhouse.talk_key()
	await _frames(30)
	root.get_viewport().get_texture().get_image().save_png(_out() + "/chapterhouse-dialogue.png")
	quit()
