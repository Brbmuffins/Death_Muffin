extends SceneTree
## Golden-fixture runner for godot/rules/dialogue (guidance.ts selectors + memory, content/dialogue.ts lines, DmCovenantDialogue).
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/dialogue/run.gd
## Fixtures: tools/godot/fixtures-dialogue.ts (npx vite-node tools/godot/fixtures-dialogue.ts, or tools/godot/gen-fixtures.sh) -> tests/dialogue/fixtures/*.json

const DIR := "res://tests/dialogue/fixtures/"
var passed := 0
var failed := 0
var per_check: Dictionary = {}
var _shown := 0


func _initialize() -> void:
	if not FileAccess.file_exists(DIR + "talk.json"):
		print("fixtures missing (committed under tests/<suite>/fixtures)")
		quit(1)
		return
	_guidance()
	_talk()
	_advice()
	_misc()
	_source_and_hud()
	print("--- dialogue: %d passed, %d failed ---" % [passed, failed])
	for k in per_check:
		print("  %-24s %s" % [k, per_check[k]])
	quit(0 if failed == 0 else 1)


func _load(name: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR + name + ".json"))
	return parsed["cases"]


func eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		var x := float(a)
		var y := float(b)
		return absf(x - y) <= 1e-9 or absf(x - y) <= 1e-12 * maxf(absf(x), absf(y))
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not eq(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not eq(a[k], b[k]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func diff(a: Variant, b: Variant, path: String = "") -> String:
	if (a is int or a is float) and (b is int or b is float):
		return "" if eq(a, b) else "%s: got %s want %s" % [path, a, b]
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: array size got %d want %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a is Dictionary and b is Dictionary:
		for k in b:
			if not a.has(k):
				return "%s.%s: missing in got" % [path, k]
			var d := diff(a[k], b[k], "%s.%s" % [path, k])
			if d != "":
				return d
		for k in a:
			if not b.has(k):
				return "%s.%s: unexpected in got" % [path, k]
		return ""
	return "" if (typeof(a) == typeof(b) and a == b) else "%s: got %s (%s) want %s (%s)" % [path, a, type_string(typeof(a)), b, type_string(typeof(b))]


func check(name: String, got: Variant, want: Variant, label: String = "") -> void:
	var ok := eq(got, want)
	if not per_check.has(name):
		per_check[name] = [0, 0]
	if ok:
		passed += 1
		per_check[name][0] += 1
	else:
		failed += 1
		per_check[name][1] += 1
		if _shown < 25:
			_shown += 1
			printerr("FAIL %s %s %s" % [name, label, diff(got, want)])


func ok(name: String, cond: bool, label: String = "") -> void:
	check(name, cond, true, label)





func _guidance() -> void:
	var i := 0
	for c: Dictionary in _load("guidance"):
		var s: Dictionary = c["in"]["s"]
		var d: String = "" if c["in"]["dismissed"] == null else String(c["in"]["dismissed"])
		var o: Dictionary = c["out"]
		var lab := "case %d" % i
		i += 1
		check("suggestions", DmGuidance.suggestions(s), o["suggestions"], lab)
		check("next_suggestion", DmGuidance.next_suggestion(s, d), o["next"], lab)
		check("pending_seals", DmGuidance.pending_seals(s), o["seals"], lab)
		check("bosses_waiting", DmGuidance.bosses_waiting(s), o["waiting"], lab)
		var fn := {}
		var news := {}
		for n in DmGuidance.NPC_IDS:
			fn[n] = DmGuidance.suggestion_for(n, s)
			news[n] = DmGuidance.news_for(n, s)
		check("suggestion_for", fn, o["forNpc"], lab)
		check("news_for", news, o["news"], lab)


func _talk() -> void:
	var i := 0
	for c: Dictionary in _load("talk"):
		var mem := DmGuidanceMemory.new()
		var steps: Array = c["in"]["steps"]
		for k in steps.size():
			var st: Dictionary = steps[k]
			var s: Dictionary = st["s"]
			var npc: String = st["npc"]
			var o: Dictionary = c["out"][k]
			var lab := "case %d step %d (%s)" % [i, k, npc]
			var unheard := mem.unheard(npc, s)
			check("unheard", unheard, o["unheard"], lab)
			check("met", mem.met(npc), o["met"], lab)
			var overhead := {}
			for n in DmGuidance.NPC_IDS:
				overhead[n] = mem.has_something_new(n, s)
			check("has_something_new", overhead, o["newOverhead"], lab)
			check("greeting", DmDialogueLines.greeting_lines(npc, s, unheard, mem.met(npc)), o["greet"], lab)
			mem.told(npc, s)
			var topics := {}
			var before: Array = []
			for t: Dictionary in DmDialogueLines.topics(npc):
				topics[t["id"]] = DmDialogueLines.topic_lines(npc, t["id"], s)
				before.append(mem.heard_topic(npc, t["id"]))
			check("topic lines", topics, o["topics"], lab)
			check("heard_topic before", before, o["heardBefore"], lab)
			check("advice", DmDialogueLines.advice_lines(npc, s), o["advice"], lab)
			check("farewell", DmDialogueLines.farewell(npc, s), o["farewell"], lab)
			mem.hear_topic(npc, st["hear"])
			var after: Array = []
			for t: Dictionary in DmDialogueLines.topics(npc):
				after.append(mem.heard_topic(npc, t["id"]))
			check("heard_topic after", after, o["heardAfter"], lab)
			var f1 := mem.first_sight(npc)
			var f2 := mem.first_sight(npc)
			check("first_sight", [f1, f2, mem.met(npc)], [o["first"], o["first2"], o["metAfter"]], lab)
			check("memory dict", mem.to_dict(), o["mem"], lab)
		i += 1


func _advice() -> void:
	var i := 0
	for c: Dictionary in _load("advice"):
		var s: Dictionary = c["in"]
		var got := {}
		for n in DmGuidance.NPC_IDS:
			got[n] = {"advice": DmDialogueLines.advice_lines(n, s), "farewell": DmDialogueLines.farewell(n, s)}
		check("advice (spread)", got, c["out"], "case %d" % i)
		i += 1


func _misc() -> void:
	for c: Dictionary in _load("summaries"):
		check("summaries", {"labor": DmGuidance.summarize_labor(c["in"]["labor"]), "contracts": DmGuidance.summarize_contracts(c["in"]["contracts"])}, c["out"])
	for c: Dictionary in _load("trophies"):
		check("trophies", DmGuidance.parse_trophies(c["in"]), c["out"], str(c["in"]))
	check("trophy key", DmGuidance.boss_trophy_key(7), "dm_boss_trophies_v1:7")
	# memory persistence round trip
	var path := "user://dm_test_guidance.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var m := DmGuidanceMemory.new(path)
	var s := DmGuidance.base_state({"canAscend": true, "ashesOnAscend": 1234})
	m.told("prior", s)
	m.hear_topic("prior", "seals")
	var m2 := DmGuidanceMemory.new(path)
	ok("memory persists", m2.met("prior") and m2.heard_topic("prior", "seals") and m2.to_dict() == m.to_dict())
	m2.from_dict({"met": ["prior", "nobody", 3], "heard": ["x", 4], "seen": ["sexton", "zzz"]})
	check("from_dict filters", m2.to_dict(), {"v": 1, "met": ["prior"], "heard": ["x"], "seen": ["sexton"]})
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _source_and_hud() -> void:
	var state := {"v": DmGuidance.base_state({"totalKills": 3, "area": "chapterhouse"})}
	var src := DmCovenantDialogue.new(func() -> Dictionary: return state["v"])
	ok("source is a DmDialogueSource", src is DmDialogueSource)
	var g1 := src.greeting_lines("prior")
	ok("first meeting welcomes", String(g1[0]).begins_with("Welcome to the Chapterhouse"))
	src.told("prior")
	ok("met after told", src.met("prior"))
	ok("second greeting differs", src.greeting_lines("prior") != g1)
	ok("topic fresh then heard", not src.heard_topic("prior", "seals"))
	src.topic_lines("prior", "seals")
	src.hear_topic("prior", "seals")
	ok("topic heard", src.heard_topic("prior", "seals"))
	ok("farewell nonempty", src.farewell("sexton") != "")
	ok("advice first steps", String(src.advice_lines("prior")[0]).begins_with("North, through the door"))
	ok("no provider works", DmCovenantDialogue.new().advice_lines("prior").size() > 0)
	# panel integration: the real DmDialoguePanel opens with this source
	var panel := DmDialoguePanel.new()
	panel.source = DmCovenantDialogue.new(func() -> Dictionary: return state["v"])
	get_root().add_child(panel)
	panel.open_npc("sexton")
	ok("panel shows sexton welcome", String(panel.lines[0]).begins_with("Mind the graves"))
	panel.go("advice")
	ok("panel advice lines", panel.lines.size() > 0)
	panel.go("topic", "gather")
	ok("panel topic marks heard", panel.source.heard_topic("sexton", "gather"))
	panel.close()
	panel.queue_free()
	# HUD next driver
	var hud := DmGuidanceHud.new()
	var s0 := DmGuidance.base_state({"area": "chapterhouse", "totalKills": 2})
	var sug: Variant = hud.update(s0)
	ok("next shown", sug != null and hud.text() != "")
	var first_id: String = sug["id"]
	hud.dismiss()
	ok("dismissed hides", hud.update(s0) == null or hud.update(s0)["id"] != first_id)
	ok("setting off hides", hud.update(s0, false) == null)
	ok("depths hides", hud.update(DmGuidance.base_state({"area": "depths"})) == null)
	var s1 := DmGuidance.base_state({"area": "graves", "totalKills": 50, "canAscend": true, "ashesOnAscend": 9})
	hud.update(s1)
	ok("new top resets dismissal", hud.dismissed == "" and hud.current != null)
