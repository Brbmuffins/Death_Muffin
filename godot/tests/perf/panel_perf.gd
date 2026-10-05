extends SceneTree
## Time each UI window's open (toggle_panel is synchronous): first open vs second open, headless.
## godot --headless --path godot --script res://tests/perf/panel_perf.gd

const PANELS := ["inventory", "sheet", "legion", "forge", "professions", "contracts", "garden", "grimoire", "codex", "atlas", "map", "ascension", "settings"]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("pp%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 7, "warmup": false})
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	game.ui = ui
	for i in 10:
		await process_frame
	if "--split" in OS.get_cmdline_user_args():
		var pa = ui.pa
		var t0 := Time.get_ticks_usec()
		pa._atlas_data()
		var t1 := Time.get_ticks_usec()
		pa.atlas.open_atlas()
		var t2 := Time.get_ticks_usec()
		print("SPLIT atlas data=%.1fms open=%.1fms" % [(t1 - t0) / 1000.0, (t2 - t1) / 1000.0])
		ui.close_panels()
		t0 = Time.get_ticks_usec()
		pa.grim_win.grimoire.open_session(null)
		t1 = Time.get_ticks_usec()
		pa.refresh_grimoire()
		t2 = Time.get_ticks_usec()
		if pa.loadouts != null:
			pa.loadouts.load_rows()
		var t3 := Time.get_ticks_usec()
		pa.grim_win.select_tab("grimoire")
		pa.grim_win.open()
		var t4 := Time.get_ticks_usec()
		print("SPLIT grimoire session=%.1fms refresh=%.1fms loadouts=%.1fms win.open=%.1fms" % [(t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, (t4 - t3) / 1000.0])
		quit(0)
		return
	for round_ in 2:
		for p in PANELS:
			var t := Time.get_ticks_usec()
			ui.toggle_panel(p)
			var open_ms := (Time.get_ticks_usec() - t) / 1000.0
			t = Time.get_ticks_usec()
			await process_frame
			var frame_ms := (Time.get_ticks_usec() - t) / 1000.0
			print("PANEL round=%d %-12s open=%.1fms next-frame=%.1fms open?=%s" % [round_ + 1, p, open_ms, frame_ms, ui.is_open(p)])
			ui.close_panels()
			await process_frame
	quit(0)
