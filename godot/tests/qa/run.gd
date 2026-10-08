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
	ok(DmQaUiShots.parse('{"shots":[{"hover":"head"}]}')["ok"] == false, "bad hover string rejected")
	ok(DmQaUiShots.parse('{"shots":[{"name":"x"}]}')["bag"] == "demo", "demo bag is the default")
	# every window id the plan accepts must be one DmGameUi.toggle_panel knows
	var known: Array = DmGameUi.PANEL_KEYS.values() + ["settings", "salvage", "shelf", "ascension", "class"]
	for k in DmQaUiShots.WINDOWS:
		ok(DmQaUiShots.WINDOWS[k] in known, "window %s maps to a real panel id" % k)
	# the demo bag only names items the content knows, and fits the bag
	ok(DmQaUiShots.DEMO_BAG.size() <= DmReliquaryPanel.BAG_SIZE, "demo bag fits")
	for e in DmQaUiShots.DEMO_BAG:
		ok(not DmLootData.item(e[0]).is_empty(), "demo item %s exists" % e[0])
	print("qa shot plan tests: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
