extends SceneTree
## Rendered shot of a fully dressed hero (legendary set + sword + cape + pet), the rebuild vs the current client (NOT a pass/fail suite):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 timeout 400 xvfb-run -a -s "-screen 0 1280x800x24" \
##     godot --rendering-driver opengl3 --path godot --script res://tests/next_hero_look/render_probe.gd -- --mode=next|old --out=/dir
## Saves <out>/hero_<mode>.png: the hero cropped from the frame and scaled up, and prints the mean frame time of 120 rendered frames.

const BAG := ["sword_copper", "leg_legion_unburied_head", "leg_legion_unburied_chest", "leg_legion_unburied_hands", "leg_legion_unburied_legs", "leg_legion_unburied_feet", "charm_tithe_bat"]


func _initialize() -> void:
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _run() -> void:
	var mode := _arg("mode", "next")
	var out := _arg("out", "")
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("shot%d" % (Time.get_ticks_usec() % 100000), "s@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var cid := int(c.data["id"])
	var rows: Array = []
	for i in BAG.size():
		rows.append({"slot_index": i, "item_id": BAG[i], "quantity": 1, "equipped": 1 if i < 6 else 0})
	await api.save_inventory(cid, rows, 48)
	for k in mock.db["accounts"]:
		mock.db["accounts"][k]["professions"][0]["skill_level"] = 99
	await api.adopt_pet(cid, "pet_tithe_bat")
	await api.select_cosmetics(cid, {"cape": "cape_mining", "pet": "pet_tithe_bat"})
	var pos := Callable()
	if mode == "old":
		var g := DmGame.new()
		root.add_child(g)
		await g.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 5})
		pos = func() -> Vector3: return Vector3(g.player.x, 1.0, g.player.z)
		for i in 30:
			g.tick(1.0 / 30.0)
			await process_frame
	else:
		var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
		root.add_child(g)
		await g.start(c.data, api, {"persist": false, "waves": false, "audio": false})
		pos = func() -> Vector3: return g.local_body().position + Vector3(0, 1.0, 0)
	for i in 90:
		await process_frame
	var t0 := Time.get_ticks_usec()
	for i in 120:
		await process_frame
	print("%s: mean frame %.1f ms (llvmpipe)" % [mode, float(Time.get_ticks_usec() - t0) / 120.0 / 1000.0])
	var cam := root.get_viewport().get_camera_3d()
	var sp := cam.unproject_position(pos.call())
	var img := root.get_viewport().get_texture().get_image()
	var crop := Rect2i(int(sp.x) - 130, int(sp.y) - 110, 260, 220).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var part := img.get_region(crop)
	part.resize(crop.size.x * 3, crop.size.y * 3, Image.INTERPOLATE_BILINEAR)
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
		part.save_png("%s/hero_%s.png" % [out, mode])
		img.save_png("%s/full_%s.png" % [out, mode])
	quit()
