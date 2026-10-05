extends SceneTree
## Time each UI window's open, headless: the synchronous toggle_panel call plus the frame after it (layout, deferred fits).
##   1st   first open of the session (after ui.warm(), which pre-builds the panels behind the loading cover)
##   again reopen with nothing changed (the common case: it must cost almost nothing)
##   chg   reopen after the bag changed (a few items looted; only the rows that show them may rebuild)
## godot --headless --path godot --script res://tests/perf/panel_perf.gd [-- --nowarm] [--runs=3] [--budget]
## --budget: exit 1 when a median breaks a budget (generous: the VPS is shared, medians over --runs).

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
	if not "--nowarm" in OS.get_cmdline_user_args():
		await ui.warm()
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
	# A frame of the running game costs ~7 ms here even with nothing open: report what a panel adds on top of it.
	var idle: Array = []
	for i in 30:
		var ti := Time.get_ticks_usec()
		await process_frame
		if i >= 10:
			idle.append((Time.get_ticks_usec() - ti) / 1000.0)
	base_ms = _median(idle)
	print("idle frame %.1f ms (subtracted from every number below)" % base_ms)
	var runs := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--runs="):
			runs = maxi(1, int(a.substr(7)))
	var res := {}   # panel -> {"1st": [], "again": [], "chg": []}
	for p in PANELS:
		res[p] = {"1st": [], "again": [], "chg": [], "again_sync": []}
	for run_ in runs:
		for p in PANELS:
			(res[p]["1st"] as Array).append(await _open_ms(ui, p))
			ui.close_panels()
			await process_frame
		for p in PANELS:
			(res[p]["again"] as Array).append(await _open_ms(ui, p))
			(res[p].get("again_sync") as Array).append(last_sync_ms)
			ui.close_panels()
			await process_frame
		_loot(game)
		# A player loots, then opens a panel some seconds later: the Atlas verdicts are recomputed on a worker once the bag goes quiet.
		var t_wait := Time.get_ticks_msec()
		while not ui.pa.atlas_idle() or Time.get_ticks_msec() - t_wait < 1200:
			await process_frame
			if Time.get_ticks_msec() - t_wait > 15000:
				break
		for p in PANELS:
			(res[p]["chg"] as Array).append(await _open_ms(ui, p))
			ui.close_panels()
			await process_frame
	var bad := 0
	for p in PANELS:
		var m1 := _median(res[p]["1st"])
		var m2 := _median(res[p]["again"])
		var m3 := _median(res[p]["chg"])
		if "--raw" in OS.get_cmdline_user_args():
			print("RAW %s 1st=%s again=%s chg=%s" % [p, str(res[p]["1st"]), str(res[p]["again"]), str(res[p]["chg"])])
		print("PANEL %-12s 1st=%6.1f  again=%6.1f (sync %5.1f)  chg=%6.1f ms" % [p, m1, m2, _median(res[p]["again_sync"]), m3])
		if "--budget" in OS.get_cmdline_user_args():
			if m2 > BUDGET_AGAIN_MS or m1 > BUDGET_FIRST_MS or m3 > BUDGET_CHANGED_MS:
				bad += 1
				printerr("PANEL BUDGET %s: 1st %.1f (<%.0f) again %.1f (<%.0f) chg %.1f (<%.0f)" % [p, m1, BUDGET_FIRST_MS, m2, BUDGET_AGAIN_MS, m3, BUDGET_CHANGED_MS])
	quit(1 if bad > 0 else 0)


## Budgets in ms on the busy shared VPS (a 60 Hz frame is 16.7 ms; this VPS runs ~3x slower than a desktop; the unfixed code measured 50-600 over an idle frame).
const BUDGET_FIRST_MS := 60.0
const BUDGET_AGAIN_MS := 45.0
const BUDGET_CHANGED_MS := 130.0


var last_sync_ms := 0.0
var base_ms := 0.0

func _open_ms(ui: DmGameUi, p: String) -> float:
	var t := Time.get_ticks_usec()
	ui.toggle_panel(p)
	var sync_ms := (Time.get_ticks_usec() - t) / 1000.0
	await process_frame
	last_sync_ms = sync_ms
	return maxf(0.0, (Time.get_ticks_usec() - t) / 1000.0 - base_ms)


func _median(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return float(b[b.size() / 2])


## A few drops into the bag: some materials (recipe ingredients) and a piece of gear.
func _loot(game: DmGame) -> void:
	var n := 0
	var gear := false
	for id in DmContent.items():
		var m: Dictionary = DmContent.items()[id]
		if String(m.get("type", "")) == "material" and n < 6:
			game.inventory.add({"item_id": id, "quantity": 3})
			n += 1
		elif not gear and String(m.get("type", "")) in ["weapon", "chest_armor"]:
			game.inventory.add({"item_id": id, "quantity": 1})
			gear = true
