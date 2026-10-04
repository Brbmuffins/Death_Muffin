extends Control
## Screenshot harness (mock backend only, never the live server):
##   godot --path godot res://front/front_shoot.tscn -- --page=login|register|select|standalone --out=/path.png [--w=1280 --h=800]

func _ready() -> void:
	var a := {}
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--") and s.contains("="):
			var kv := s.substr(2).split("=", true, 1)
			a[kv[0]] = kv[1]
	if a.has("w"):
		get_window().size = Vector2i(int(a["w"]), int(a.get("h", "800")))
	var page: String = a.get("page", "login")
	var mock := DmMockBackend.new("")
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var flow := DmFrontFlow.new(api, page == "standalone", true)
	flow.persist_token = false
	add_child(flow)
	flow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if page == "select":
		var r := await api.register("shot", "", "pw1234")
		api.set_token(r.data["token"])
	await flow.start()
	if page == "register" or page == "standalone_register":
		(flow.current as DmLoginScreen).toggle_mode()
	if a.has("out"):
		for i in 14:
			await get_tree().process_frame
		await get_tree().create_timer(0.6).timeout
		var img := get_viewport().get_texture().get_image()
		img.save_png(a["out"])
		print("saved ", a["out"], " ", img.get_size())
		get_tree().quit()
