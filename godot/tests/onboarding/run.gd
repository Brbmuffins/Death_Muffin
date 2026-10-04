extends SceneTree
## Covenant counsel tests (headless):  godot --headless --path godot --script res://tests/onboarding/run.gd
## Fixtures come from the real TS (tools/godot/fixtures-onboarding.ts): render, cadence decisions, scripted event sequences run through the
## real Onboarding class, and the web call-site list the event table must cover.

const FIX := "res://tests/onboarding/fixtures/"
const T0 := 50000.0

var _fail := 0
var _pass := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		if _fail <= 60:
			printerr("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func _load(name: String) -> Variant:
	var f := FileAccess.open(FIX + name, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func _eq(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _eq(a[k], b[k]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _eq(a[i], b[i]):
				return false
		return true
	return a == b


func _run() -> void:
	var sequences: Variant = _load("sequences.json")
	if sequences == null or not FileAccess.file_exists("res://data/onboarding/tips.json"):
		printerr("fixtures missing: run tools/godot/gen-fixtures.sh")
		quit(1)
		return
	_test_data()
	_test_render()
	_test_cadence()
	_test_sequences(sequences)
	_test_store()
	_test_events()
	_test_callsites()
	_test_tick_calls()
	await _test_view()
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------

func _test_data() -> void:
	var d := DmCounselData.data()
	var order: Array = d["order"]
	_check(order.size() == 120, "120 tips exported (%d)" % order.size())
	for id in order:
		_check(DmCounselData.title(id) != "" and DmCounselData.body(id).length() > 20, "tip has title+body: " + id)
	# every anchored tip resolves to a DmHud anchor key
	for id in d["anchors"]:
		_check(DmCounselData.hud_anchor_key(id) != "", "anchor selector mapped to a HUD key: %s -> %s" % [id, DmCounselData.anchor_selector(id)])
	_check(DmCounselData.hud_anchor_key("welcome") == "", "no anchor -> empty key")
	_check(DmCounselData.hud_anchor_key("bag_full") == "relic" and DmCounselData.hud_anchor_key("skill_up") == "gather" and DmCounselData.hud_anchor_key("brew") == "belt", "alias anchors")
	# kinds from the web lists
	_check(DmCounselData.kind_of("hurt") == "urgent" and DmCounselData.kind_of("move") == "danger" and DmCounselData.kind_of("vault") == "asked" and DmCounselData.kind_of("welcome") == "calm" and DmCounselData.kind_of("zzz") == "calm", "kinds")
	_check(DmCounselData.priority_of("welcome") == 100 and DmCounselData.priority_of("zzz") == 50, "priority")
	_check(DmCounselData.group_of("relic") == "gear" and DmCounselData.group_of("welcome") == "", "groups")


func _test_render() -> void:
	var keys: Dictionary = _load("keys.json")
	var key_for := func(a: String) -> String: return String(keys.get(a, ""))
	var cases: Array = _load("render.json")
	for c in cases:
		var kf: Callable = key_for if c["keys"] else Callable()
		if c.has("id"):
			var id: String = c["id"]
			_check(DmCounselData.render_text(DmCounselData.title(id), kf, c["auto"]) == c["title"], "render title %s" % id)
			var got := DmCounselData.render_text(DmCounselData.body(id), kf, c["auto"])
			_check(got == c["body"], "render body %s keys=%s auto=%s" % [id, c["keys"], c["auto"]])
		else:
			var got2 := DmCounselData.render_text(c["text"], kf, c["auto"])
			_check(got2 == c["out"], "render text %s -> %s" % [c["text"].left(24), got2.left(40)])


func _entry_of(t: Dictionary) -> Dictionary:
	return {"id": t["id"], "kind": t["kind"], "priority": t["priority"], "queued_at": t["queuedAt"], "seq": int(t["seq"])}


func _test_cadence() -> void:
	var f: Dictionary = _load("cadence.json")
	for c in f["classify"]:
		var id: String = c["id"]
		_check(DmCounselData.kind_of(id) == c["kind"] and DmCounselData.priority_of(id) == int(c["priority"]), "classify " + id)
		var g: Variant = c["group"]
		_check(DmCounselData.group_of(id) == ("" if g == null else String(g)), "group " + id)
	var me: Array = f["make_entry"]
	_check(_eq(DmCounselCadence.make_entry("welcome", 500, 3), _entry_of(me[0])), "make_entry welcome")
	_check(_eq(DmCounselCadence.make_entry("hurt", 500, 4, true), _entry_of(me[1])), "make_entry bump")
	_check(_eq(DmCounselCadence.make_entry("move", 1500, 5), _entry_of(me[2])), "make_entry move")
	_check(_eq(DmCounselCadence.make_entry("totally_unknown", 7, 6), _entry_of(me[3])), "make_entry unknown")
	for s in f["show_ms"]:
		_check(DmCounselCadence.show_ms(s["kind"], int(s["words"])) == int(s["ms"]), "show_ms %s %d" % [s["kind"], int(s["words"])])
	var n := 0
	for c in f["cases"]:
		n += 1
		var st: Dictionary = c["state"]
		var state := {"now": st["now"], "last_closed_at": -INF if st["lastClosedAt"] == null else st["lastClosedAt"], "group_shown_at": st["groupShownAt"], "busy": st["busy"]}
		var queue: Array = []
		for t in c["queue"]:
			queue.append(_entry_of(t))
		var card := {"id": c["card"]["id"], "kind": c["card"]["kind"], "shown_at": c["card"]["shownAt"]}
		var waiting: Dictionary = {}
		if c["waiting_seq"] != null:
			for t in queue:
				if t["seq"] == int(c["waiting_seq"]):
					waiting = t
		for i in queue.size():
			_check(DmCounselCadence.can_show(queue[i], state) == c["can_show"][i], "can_show case %d/%d" % [n, i])
			_check(_eq(DmCounselCadence.max_age(queue[i]), c["max_age"][i]), "max_age case %d/%d" % [n, i])
		var picked := DmCounselCadence.pick_next(queue, state)
		_check((-1 if picked.is_empty() else int(picked["seq"])) == (-1 if c["pick"] == null else int(c["pick"])), "pick_next case %d" % n)
		var pr: Array = []
		for t in DmCounselCadence.prune(queue, state["now"]):
			pr.append(int(t["seq"]))
		var want: Array = []
		for q in c["prune"]:
			want.append(int(q))
		_check(pr == want, "prune case %d: %s vs %s" % [n, pr, want])
		_check(DmCounselCadence.should_preempt(card, waiting, state) == c["preempt"], "should_preempt case %d" % n)
		_check(DmCounselCadence.should_yield(card, state) == c["yield"], "should_yield case %d" % n)


func _test_sequences(seqs: Array) -> void:
	var total_events := 0
	var shows := 0
	for q in seqs:
		var name: String = q["name"]
		var store := DmCounselStore.new()
		if q["initial_seen"] != null:
			store.set_item("dm_tips_v1_7", JSON.stringify(q["initial_seen"]))
		var counsel := DmCounsel.new(7, store, T0)
		counsel.record = true
		if q["keys"]:
			var keys: Dictionary = _load("keys.json")
			counsel.key_for = func(a: String) -> String: return String(keys.get(a, ""))
		var busy := {}
		var stale_ids := {}
		counsel.stale = func(id: String) -> bool: return stale_ids.has(id)
		var ops: Array = q["ops"]
		var order: Array = []
		for i in ops.size():
			order.append(i)
		order = DmStableSort.sorted(order, func(a: int, b: int) -> bool: return float(ops[a]["t"]) < float(ops[b]["t"]))
		var snap_every: int = int(q["snap_every"])
		var snaps: Array = q["snaps"]
		var si := 0
		var k := 0
		for oi in order:
			var o: Dictionary = ops[oi]
			counsel.advance_to(T0 + float(o["t"]))
			match String(o["op"]):
				"show": counsel.show(String(o["id"]), float(o.get("delay", 0)), o.get("opts", null))
				"busy":
					for kk in o["set"]:
						busy[kk] = o["set"][kk]
					counsel.set_busy(busy)
				"click": counsel.dismiss()
				"hover":
					if counsel.is_card_up():
						if o["on"]:
							counsel.pause_card()
						else:
							counsel.resume_card()
				"skip": counsel.set_tips_enabled(false)
				"tips": counsel.set_tips_enabled(bool(o["value"]))
				"reset": counsel.reset()
				"stale":
					stale_ids.clear()
					for id in o["ids"]:
						stale_ids[id] = true
			k += 1
			if snap_every <= 1 or k % snap_every == 0:
				_compare_snap(counsel, snaps[si], name, "op %d" % k)
				si += 1
		counsel.advance_to(T0 + float(q["end"]))
		_compare_snap(counsel, snaps[si], name, "end")
		counsel.dispose()
		# the show/hide/glow log
		var want_log: Array = q["log"]
		var got_log: Array = []
		for e in counsel.record_log_rel(T0):
			got_log.append(e)
		var ok := got_log.size() == want_log.size()
		var bad := ""
		if ok:
			for i in got_log.size():
				if not _eq(got_log[i], want_log[i]):
					ok = false
					bad = "entry %d: %s vs %s" % [i, got_log[i], want_log[i]]
					break
		else:
			bad = "size %d vs %d" % [got_log.size(), want_log.size()]
		_check(ok, "sequence %s log %s" % [name, bad])
		total_events += want_log.size()
		for e in want_log:
			if e[1] == "show":
				shows += 1
	print("  sequences: %d scripts, %d logged events, %d cards shown (all matched the TS: %s)" % [seqs.size(), total_events, shows, "yes" if _fail == 0 else "no"])


func _compare_snap(counsel: DmCounsel, snap: Dictionary, name: String, where: String) -> void:
	var seen_got: Array = counsel.seen.keys()
	_check(_eq(seen_got, snap["seen"]), "%s %s seen %s vs %s" % [name, where, seen_got, snap["seen"]])
	var qg: Array = []
	for t in counsel.queue:
		qg.append([t["id"], t["kind"], t["priority"], float(t["queued_at"]) - T0, t["seq"]])
	_check(_eq(qg, snap["queue"]), "%s %s queue %s vs %s" % [name, where, qg, snap["queue"]])
	var sh: Variant = null
	if not counsel.shown.is_empty():
		sh = [counsel.shown["id"], counsel.shown["kind"], float(counsel.shown["shown_at"]) - T0]
	_check(_eq(sh, snap["shown"]), "%s %s shown %s vs %s" % [name, where, sh, snap["shown"]])
	_check(_eq(counsel.last_closed_at - T0, snap["last_closed"]), "%s %s last_closed %s vs %s" % [name, where, counsel.last_closed_at - T0, snap["last_closed"]])
	var gg: Array = []
	for g in counsel.group_shown_at:
		gg.append([g, float(counsel.group_shown_at[g]) - T0])
	gg.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_check(_eq(gg, snap["groups"]), "%s %s groups" % [name, where])
	var pg: Array = counsel.pending.keys()
	pg.sort()
	_check(_eq(pg, snap["pending"]), "%s %s pending" % [name, where])


func _test_store() -> void:
	var store := DmCounselStore.new()
	var a := DmCounsel.new(3, store, 0.0)
	a.show("welcome")
	a.advance_to(4000.0)
	_check(a.has_seen("welcome") and a.has_seen("acre"), "welcome counts the acre card as seen")
	var b := DmCounsel.new(3, store, 0.0)
	_check(b.has_seen("welcome") and b.has_seen("acre"), "seen tips persist per character")
	var c := DmCounsel.new(4, store, 0.0)
	_check(not c.has_seen("welcome"), "another character starts fresh")
	b.show("welcome")
	b.advance_to(4000.0)
	_check(not b.is_card_up(), "a seen tip never shows again")
	b.reset()
	_check(not b.has_seen("welcome") and store.get_item("dm_tips_v1_3") == "[]", "reset forgets and persists")
	# on-disk store
	var path := "user://dm_counsel_test.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var s1 := DmCounselStore.new(path)
	s1.set_item("dm_tips_v1_9", "[\"move\",\"nope\"]")
	var s2 := DmCounselStore.new(path)
	var d := DmCounsel.new(9, s2, 0.0)
	_check(d.has_seen("move") and not d.has_seen("nope"), "file store round trip drops unknown ids")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Show tips again: reset + the five calm cards, the optional two gated by what is revealed
	var e := DmCounsel.new(5, DmCounselStore.new(), 0.0)
	e.seen["welcome"] = true
	e.show_tips_again({"atlas_revealed": true, "spells_revealed": false})
	var ids: Array = []
	for t in e.queue:
		ids.append(t["id"])
	# one of them is already on its way to the card; the rest wait
	e.advance_to(3000.0)
	ids = [e.shown_id()]
	for t in e.queue:
		ids.append(t["id"])
	_check(ids == ["minimap", "belt", "atlas", "codex"], "show tips again queue %s" % [ids])
	_check(not e.has_seen("welcome"), "show tips again forgets seen")
	# Don't show tips
	var f := DmCounsel.new(6, DmCounselStore.new(), 0.0)
	var disabled := [false]
	f.tips_disabled.connect(func() -> void: disabled[0] = true)
	f.show("welcome")
	f.advance_to(3000.0)
	f.skip()
	_check(disabled[0] and not f.is_card_up() and f.queue.is_empty(), "skip hides and empties")
	f.show("move")
	_check(f.queue.is_empty(), "no tips while off")
	f.set_tips_enabled(true)
	f.show("move")
	_check(f.queue.size() == 1 or f.is_card_up(), "tips back on")


func _test_events() -> void:
	var tb := DmCounselEvents.table()
	_check(tb.size() >= 45, "events table size %d" % tb.size())
	var r := DmCounselEvents.calls("rite_key_set", {"ability": "grave_frost"})
	_check(r.size() == 1 and r[0]["tip"] == "rite_frost" and r[0]["delay"] == 0.0 and r[0]["opts"] == null, "rite tip lookup")
	_check(DmCounselEvents.calls("rite_key_set", {"ability": "bone_needle"}).is_empty(), "rite without counsel")
	var w := DmCounselEvents.calls("world_entered", {"family": "knight", "level": 12, "grimoire_unlocked": true})
	var wt: Array = []
	for c in w:
		wt.append([c["tip"], c["delay"]])
	_check(wt == [["welcome", 900.0], ["knight_rage", 2600.0], ["signature", 4000.0], ["grimoire", 4500.0]], "world_entered %s" % [wt])
	var sp := DmCounselEvents.calls("enemy_spawned", {"def": "golem", "elite": true})
	var st: Array = []
	for c in sp:
		st.append(c["tip"])
	_check(st == ["golem", "elite", "move"], "enemy_spawned %s" % [st])
	_check(DmCounselEvents.calls("enemy_spawned", {"def": "golem", "area_safe": true}).is_empty(), "no fight counsel in a sanctuary")
	_check(DmCounselEvents.calls("hurt_check", {"hp": 40.0, "max_hp": 100.0}).size() == 1 and DmCounselEvents.calls("hurt_check", {"hp": 60.0, "max_hp": 100.0}).is_empty(), "hurt under half")
	var gl := DmCounselEvents.calls("grimoire_opened", {"family": "necromancer", "owns_rune": false})
	_check(gl.size() == 2 and gl[0]["opts"] == {"kind": "asked"} and gl[1]["delay"] == 2500.0, "grimoire opened -> runeHunt")
	_check(DmCounselEvents.calls("bag_changed", {"slots_used": 39, "bag_size": 48}).size() == 1, "bag_filling at 80% of 48 (39)")
	_check(DmCounselEvents.calls("bag_changed", {"slots_used": 38, "bag_size": 48}).is_empty(), "not yet at 38")
	_check(DmCounselEvents.calls("tool_belted")[0]["opts"] == true, "toolBelt bump")
	# notify end to end
	var c := DmCounsel.new(1, DmCounselStore.new(), 0.0)
	c.notify("souls_charged")
	c.advance_to(3000.0)
	_check(c.shown_id() == "souls", "notify -> card")


func _test_callsites() -> void:
	var sites: Array = _load("callsites.json")
	var tb := DmCounselEvents.table()
	# every spec the table can produce (dynamic ones expanded)
	var produced: Dictionary = {}   # "tip|delay|kind|bump" -> src list
	var specs_by_src: Dictionary = {}
	var rite_tips: Dictionary = DmCounselData.data()["rite_tips"]
	var first_sight: Dictionary = DmCounselData.data()["first_sight_tips"]
	for ev in tb:
		for c in tb[ev]:
			var tips: Array = []
			if c.has("tip"):
				tips = [c["tip"]]
			elif ev.begins_with("rite_"):
				tips = rite_tips.values()
			else:
				tips = first_sight.values()
			for t in tips:
				var key := "%s|%d|%s|%s" % [t, int(c["delay"]), c["kind"], c["bump"]]
				produced[key] = true
			for sr in String(c["src"]).split(","):
				specs_by_src[sr] = specs_by_src.get(sr, 0) + 1
	var tick_ctx := {"wave_affordable": true, "thralls_mine": 1, "corpses_near": 5, "pack_on_corpse": true, "family": "necromancer", "level": 5, "total_kills": 500, "has_tool": true, "has_belt_item": true,
		"shards": 99, "boss_near": ["gravedigger", "abbess", "congregation", "saint", "regent", "mire"], "has_seal": true, "area": "chapterhouse", "cheapest_unlock": 1.0, "boss_kills": 1, "ascension": 1, "ashes": 1, "gate_near": true}
	for c in DmCounselEvents.tick_calls(tick_ctx):
		produced["%s|%d|%s|%s" % [c["tip"], int(c["delay"]), c["kind"], c["bump"]]] = true
		specs_by_src[c["src"]] = specs_by_src.get(c["src"], 0) + 1
	var covered := 0
	var seen_src: Dictionary = {}
	for s in sites:
		seen_src["%s:%d" % [s["file"], int(s["line"])]] = true
		if s["dynamic"]:
			# `show(tip)` (rites), `show(firstSight, 600)`, the Depths adapter (pass-through) and `boss_${id}` (a template, expanded below)
			if s["tip"] == "id":
				covered += 1
				continue
			var tips2: Array = rite_tips.values() if s["tip"] == "tip" else (first_sight.values() if s["tip"] == "firstSight" else [])
			if s["tip"].begins_with("boss_"):
				tips2 = ["boss_gravedigger", "boss_abbess", "boss_congregation", "boss_saint", "boss_regent", "boss_mire"]
			var all_ok := not tips2.is_empty()
			for t in tips2:
				all_ok = all_ok and produced.has("%s|%d|%s|%s" % [t, int(s["delay"]), "" if s["kind"] == null else s["kind"], bool(s["bump"])])
			_check(all_ok, "dynamic call site covered: %s:%d (%s)" % [s["file"], int(s["line"]), s["tip"]])
			covered += 1
			continue
		var key := "%s|%d|%s|%s" % [s["tip"], int(s["delay"]), "" if s["kind"] == null else s["kind"], bool(s["bump"])]
		_check(produced.has(key), "web call site has an event: %s:%d %s" % [s["file"], int(s["line"]), key])
		_check(specs_by_src.has("%s:%d" % [s["file"], int(s["line"])]), "event table cites the web line %s:%d" % [s["file"], int(s["line"])])
		covered += 1
	# and nothing in the table is invented: each spec cites a real web call site (3 lines come from the ones above)
	for src in specs_by_src:
		_check(seen_src.has(src), "event table cites a real web call site: " + src)
	print("  call sites: %d web calls covered by %d events" % [covered, tb.size()])


func _test_tick_calls() -> void:
	var base := {"family": "necromancer", "level": 1, "total_kills": 0, "shards": 0, "area": "graves", "cheapest_unlock": INF}
	_check(DmCounselEvents.tick_calls(base).is_empty(), "idle tick shows nothing")
	var t := DmCounselEvents.tick_calls({"family": "necromancer", "level": 2, "thralls_mine": 2, "corpses_near": 2, "total_kills": 41, "area": "graves", "gate_near": true, "cheapest_unlock": INF})
	var ids: Array = []
	for c in t:
		ids.append(c["tip"])
	_check(ids == ["thrall", "litany", "codex", "gate"], "tick: %s" % [ids])
	var boss := DmCounselEvents.tick_calls({"family": "knight", "boss_near": ["saint"], "has_seal": true, "area": "cloister", "cheapest_unlock": INF})
	_check(boss.size() == 2 and boss[0]["tip"] == "boss_saint" and boss[1]["tip"] == "boss_seal", "tick: boss counsel + seal")
	var altar := DmCounselEvents.tick_calls({"family": "knight", "area": "chapterhouse", "shards": 8, "cheapest_unlock": 3.0, "total_kills": 450, "ascension": 1, "ashes": 4, "cheapest_unlock_ok": true})
	var ids2: Array = []
	for c in altar:
		ids2.append(c["tip"])
	_check(ids2 == ["codex", "prelate", "altar_unlocks", "vows", "boons"], "tick: altar %s" % [ids2])


func _test_view() -> void:
	get_root().size = Vector2i(1280, 800)
	await _frames(2)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(root)
	var hud := DmHud.new()
	root.add_child(hud)
	hud.apply(DmHudMock.calm())
	var counsel := DmCounsel.new(1, DmCounselStore.new(), 0.0)
	var view := DmCounselView.new()
	view.setup(counsel, hud, DmCounselStore.new())
	root.add_child(view)
	await _frames(3)
	counsel.show("minimap", 0, {"kind": "calm"})
	counsel.tick(3.5)
	await _frames(3)
	_check(view.card() != null and counsel.is_card_up(), "view draws the card")
	_check(view.card().position.is_equal_approx(hud.tip_default_position()), "card sits at the HUD default position %s vs %s" % [view.card().position, hud.tip_default_position()])
	_check(view.glow_rect() == hud.tip_anchor_rect("minimap") and view.glow_rect().size.x > 10.0, "glow follows the minimap anchor")
	counsel.dismiss()
	await _frames(2)
	_check(view.glow_rect() == Rect2(), "glow out when the card goes")
	counsel.tick(1.0)
	counsel.show("welcome")
	counsel.tick(30.0)
	_check(counsel.shown_id() == "" or counsel.shown_id() == "welcome", "welcome flows")
	root.queue_free()
	await _frames(2)
