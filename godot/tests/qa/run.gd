extends SceneTree
## QA UI shot plan parsing (main/qa_ui_shots.gd). Headless:  godot --headless --path godot --script res://tests/qa/run.gd

var pass_count := 0
var fail_count := 0

func ok(cond: bool, label: String) -> void:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
		print("FAIL: ", label)

func _init() -> void:
	var p := DmQaUiShots.parse('{"shots":[{"name":"Bag + Tip!","open":["bag"],"hover":3,"wait_ms":99999,"clip":"window"},{"open":"character","area":"chapterhouse"},{"open":["Reliquary","vault"],"hover":"worn:head"}]}')
	ok(p["ok"], "valid plan parses")
	var shots: Array = p["shots"]
	ok(shots.size() == 3, "three shots")
	ok(shots[0]["name"] == "bag-tip-", "name is slugged: %s" % shots[0]["name"])
	ok(shots[0]["open"] == ["inventory"], "bag -> inventory")
	ok(shots[0]["hover"] == 3 and shots[0]["clip"] == "window", "hover slot and clip kept")
	ok(shots[0]["wait_ms"] == DmQaUiShots.MAX_WAIT_MS, "wait_ms is capped")
	ok(shots[1]["name"] == "shot-2" and shots[1]["open"] == ["sheet"] and shots[1]["area"] == "chapterhouse", "string open, default name, area")
	ok(shots[2]["open"] == ["inventory", "vault"] and shots[2]["hover"] == "worn:head", "case-insensitive ids, worn hover")
	ok(DmQaUiShots.parse('{"shots":[{},{},{},{},{},{}]}')["shots"].size() == DmQaUiShots.MAX_SHOTS, "at most 4 shots")
	ok(DmQaUiShots.parse("not json")["ok"] == false, "garbage rejected")
	ok(DmQaUiShots.parse('{"shots":[]}')["ok"] == false, "empty plan rejected")
	ok(DmQaUiShots.parse('{"shots":[{"open":["nope"]}]}')["ok"] == false, "unknown window rejected")
	ok(DmQaUiShots.parse('{"shots":[{"hover":48}]}')["ok"] == false, "slot out of range rejected")
	ok(DmQaUiShots.parse('{"shots":[{"hover":"item:staff_moon"}]}')["shots"][0]["hover"] == "item:staff_moon", "item hover accepted")
	ok(DmQaUiShots.parse('{"give":["staff_oak",""],"shots":[{}]}')["give"] == ["staff_oak"], "give list parsed")
	ok(DmQaUiShots.parse('{"shots":[{"hover":"head"}]}')["ok"] == false, "bad hover string rejected")
	var hp := DmQaUiShots.parse('{"equip":["a","","b"],"discipline":"hero_Rotweaver","shots":[{"view":"hero","turn":180,"anim":"cast"},{"view":"game"},{"view":"hero"},{}]}')
	ok(hp["ok"] and hp["equip"] == ["a", "b"] and hp["class_index"] == 4, "equip list and discipline parsed")
	ok(hp["shots"][0]["view"] == "hero" and hp["shots"][0]["turn"] == 180.0 and hp["shots"][0]["anim"] == "cast", "hero view, turn and anim parsed")
	ok(hp["shots"][1]["view"] == "game" and hp["shots"][2]["turn"] == DmQaUiShots.DEFAULT_TURN and hp["shots"][3]["view"] == "" and hp["shots"][3]["anim"] == "", "view defaults")
	ok(DmQaUiShots.parse('{"equip":["1","2","3","4","5","6","7","8","9","10","11","12","13"],"shots":[{}]}')["equip"].size() == DmQaUiShots.MAX_EQUIP, "equip capped")
	ok(DmQaUiShots.parse('{"discipline":11,"shots":[{}]}')["class_index"] == 11 and DmQaUiShots.parse('{"shots":[{}]}')["class_index"] == 0, "numeric discipline, none by default")
	ok(DmQaUiShots.parse('{"discipline":"grave_warden","shots":[{}]}')["ok"] == false, "non-playable discipline rejected")
	ok(DmQaUiShots.parse('{"shots":[{"view":"top"}]}')["ok"] == false and DmQaUiShots.parse('{"shots":[{"anim":"dance"}]}')["ok"] == false, "bad view / anim rejected")
	var sh := FileAccess.get_file_as_string("res://../server/death-muffin/discord-agent/shot-godot.sh")
	for nm in DmQaUiShots.DISCIPLINES:
		ok(sh.contains('"%s": %d' % [nm, DmQaUiShots.DISCIPLINES[nm]]), "shot-godot.sh maps %s to its class index" % nm)
	var by_index: Dictionary = DmCombatData.disciplines()["by_index"]
	for nm in DmQaUiShots.DISCIPLINES:
		ok(DmCharacterBuild.is_playable(float(DmQaUiShots.DISCIPLINES[nm])) and String(by_index[str(DmQaUiShots.DISCIPLINES[nm])]) == nm, "%s is a playable discipline at its class index" % nm)
	ok(DmQaUiShots.parse('{"shots":[{"name":"x"}]}')["bag"] == "demo", "demo bag is the default")
	# every window id the plan accepts must be one DmGameUi.toggle_panel knows
	var known: Array = DmGameUi.PANEL_KEYS.values() + ["settings", "salvage", "shelf", "ascension", "class"]
	for k in DmQaUiShots.WINDOWS:
		ok(DmQaUiShots.WINDOWS[k] in known, "window %s maps to a real panel id" % k)
	# the demo bag only names items the content knows, and fits the bag
	ok(DmQaUiShots.DEMO_BAG.size() <= DmReliquaryPanel.BAG_SIZE, "demo bag fits")
	for e in DmQaUiShots.DEMO_BAG:
		ok(not DmLootData.item(e[0]).is_empty(), "demo item %s exists" % e[0])
	# the screenshot QA's launch lines enter the rebuild directly: --world-demo is an alias of the dev quick start (class 2)
	ok(DmMain.quick_start_class(PackedStringArray(["--world-demo", "--qa"])) == 2, "--world-demo = quick start as class 2")
	ok(DmMain.quick_start_class(PackedStringArray(["--dev-offline", "--class=4"])) == 4, "--class=N picks the class")
	ok(DmMain.quick_start_class(PackedStringArray(["--dev-offline"])) == -1, "no quick start without --class / --world-demo")
	ok(DmMain.mode_for(PackedStringArray(["--world-demo"])) == "dev_offline", "--world-demo is dev-offline, never the live server")
	print("qa shot plan tests: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
