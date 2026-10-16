class_name DmLaborPanel
extends DmPanelB
## Grave Laborers (archive/legacy-web:src/ui/LaborPanel.ts): the raised dead work a gathering post for you on the server's clock, up to eight hours between collections.
##
## Data in:  set_view(view)  view = GET /api/labor reply {now (server ms), capMs, totalLevel, levelsPerSlot, slots:[{slot, unlocked, nodeType|null,
##           nodeName|null, skill, item, startedAt}]}.   set_levels({skill_id: level}) = the player's gathering levels (rules numbers use them).
##           add_loot(slot, report)  report = GatherReport {items:[{itemId,name,qty,rarity}], totalItems, gold, skills:[{name,xp,fromLevel,toLevel}],
##           milestones:[], records:[]} ("Brought home", newest first, at most 12).   set_busy(bool).
## Signals:  assign_requested(slot, node_type) -> DmApi.assign_labor(character_id, slot, node_type)   (after the assign blocker check passes)
##           recall_requested(slot)            -> DmApi.assign_labor(character_id, slot, "")  (clears the post)
##           collect_requested(slot)           -> DmApi.collect_labor(character_id, slot) inside the inventory-exclusive guard, then DmApi.get_inventory
##           Feed each reply to set_view(); build the report from `collected` and call add_loot().

signal assign_requested(slot: int, node_type: String)
signal recall_requested(slot: int)
signal collect_requested(slot: int)
signal loot_cleared

const MAX_LOOT := 12

var view: Dictionary = {}
var levels: Dictionary = {}
var busy := false
var picks: Dictionary = {}           # slot -> chosen post id
var loot: Array[Dictionary] = []     # [{slot, report}]
var now_override_ms := -1
var skew_ms := 0
## What is drawn per laborer: {slot, status (Locked|Idle|Working), text, pct, send_enabled, collect_enabled, recall_enabled}.
var slots_info: Array[Dictionary] = []
var send_buttons: Dictionary = {}
var collect_buttons: Dictionary = {}
var recall_buttons: Dictionary = {}
var post_pickers: Dictionary = {}
var clear_button: Button
var _tick: Timer


func _init() -> void:
	super._init()
	title = "Grave Laborers"
	panel_width = 680


func _ready() -> void:
	_tick = Timer.new()
	_tick.wait_time = 1.0
	_tick.timeout.connect(func() -> void:
		if is_visible_in_tree() and not DmPb.pointer_busy(self):
			rebuild())
	add_child(_tick)
	_tick.start()
	rebuild()


func set_view(v: Dictionary) -> void:
	view = v
	skew_ms = int(v.get("now", 0)) - int(Time.get_unix_time_from_system() * 1000.0)
	head_note = "Gathering levels <b>%d</b>" % int(v["totalLevel"])
	rebuild()


func set_levels(l: Dictionary) -> void:
	levels = l
	rebuild()


func set_busy(v: bool) -> void:
	busy = v
	rebuild()


func add_loot(slot: int, report: Dictionary) -> void:
	loot.push_front({"slot": slot, "report": report})
	while loot.size() > MAX_LOOT:
		loot.pop_back()
	rebuild()


func clear_loot() -> void:
	loot.clear()
	loot_cleared.emit()
	rebuild()


func _now() -> int:
	return now_override_ms if now_override_ms >= 0 else int(Time.get_unix_time_from_system() * 1000.0) + skew_ms


func _build() -> void:
	slots_info.clear()
	send_buttons.clear()
	collect_buttons.clear()
	recall_buttons.clear()
	post_pickers.clear()
	clear_button = null
	_head_note_row()
	add_child(DmPb.hint("Send the dead to work a post and they keep at it, slowly, for up to eight hours, even while you are away. They gather a fraction of what you would and earn a quarter of the XP. Collect when you like.", 12))
	if view.is_empty():
		add_child(DmPb.hint(error_text if error_text != "" else "Calling the dead…"))
		return
	var list := DmPb.vbox(8)
	add_child(list)
	var now := _now()
	for s: Dictionary in view.get("slots", []):
		_slot_card(list, s, now)
	_loot_section()
	if error_text != "":
		_error_row()


func _slot_card(parent: Control, s: Dictionary, now: int) -> void:
	var slot := int(s["slot"])
	var working: bool = s.get("nodeType") != null
	var status := "Locked" if not s["unlocked"] else ("Working" if working and s.get("nodeName") != null else "Idle")
	var info := {"slot": slot, "status": status, "text": "", "pct": 0, "send_enabled": false, "collect_enabled": false, "recall_enabled": false}
	var ready := false
	if s["unlocked"] and working:
		var def0 := DmGatherData.node(String(s["nodeType"]))
		var el0 := maxi(0, mini(now - int(s["startedAt"]), int(view["capMs"])))
		ready = DmLabor.estimate(def0, int(levels.get(def0["skill"], 1)), float(el0))["actions"] >= 1
	var card := DmPb.card(parent, DmUi.OK if ready else DmUi.BORDER, Color(0, 0, 0, 0), Vector2(10, 8))
	(card.get_meta("panel") as Control).custom_minimum_size = Vector2(0, 78)
	if not s["unlocked"]:
		(card.get_meta("panel") as Control).modulate.a = 0.55
	var hd := DmPb.hbox(8)
	hd.add_child(DmPb.grow(DmPb.text("Laborer %d" % (slot + 1), 13, DmUi.BONE_100, "body_bold")))
	hd.add_child(DmPb.text(DmUi.upper(status), 10, DmUi.TEXT_FAINT))
	card.add_child(hd)
	if not s["unlocked"]:
		var need := slot * int(view["levelsPerSlot"])
		info["text"] = "Raised when your gathering levels total %d (now %d)." % [need, int(view["totalLevel"])]
		card.add_child(DmPb.hint(info["text"], 12, DmUi.TEXT_MUTED))
	elif not working:
		var posts := DmLabor.posts_for(levels)
		var cur: String = String(picks.get(slot, ""))
		var valid := false
		for p: Dictionary in posts:
			if p["id"] == cur:
				valid = true
		if not valid:
			cur = String(posts[0]["id"]) if posts.size() > 0 else ""
		picks[slot] = cur
		var row := DmPb.hbox(8)
		var ob := OptionButton.new()
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ob.clip_text = true
		var sel := -1
		for sk: String in DmGathering.SKILL_IDS:
			var group: Array = posts.filter(func(p: Dictionary) -> bool: return p["skill"] == sk)
			if group.is_empty():
				continue
			ob.add_separator(DmPb.skill_name(sk))
			for p: Dictionary in group:
				ob.add_item("%s (Lv %d)" % [p["name"], int(p["level"])])
				var idx := ob.item_count - 1
				ob.set_item_metadata(idx, p["id"])
				if p["id"] == cur:
					sel = idx
		if sel >= 0:
			ob.select(sel)
		ob.item_selected.connect(func(i: int) -> void:
			picks[slot] = String(ob.get_item_metadata(i))
			rebuild.call_deferred())
		row.add_child(ob)
		post_pickers[slot] = ob
		var send := DmPb.button("Send to work", false, busy or cur == "")
		send.pressed.connect(func() -> void:
			var blocked := DmLabor.assign_blocker(cur, levels)
			if blocked != "":
				set_error(blocked)
			else:
				assign_requested.emit(slot, cur))
		row.add_child(send)
		send_buttons[slot] = send
		card.add_child(row)
		info["send_enabled"] = not send.disabled
		var def := DmGatherData.node(cur)
		if not def.is_empty():
			var per := DmLabor.estimate(def, int(levels.get(def["skill"], 1)), 3600000.0)
			info["text"] = "About %s %s an hour, up to %d hours." % [DmPb.num(per["items"]), DmPb.item_name(String(def["item"])), DmLabor.CAP_MS / 3600000]
			card.add_child(DmPb.hint(info["text"], 12, DmUi.TEXT_MUTED))
	else:
		var def := DmGatherData.node(String(s["nodeType"]))
		var cap := int(view["capMs"])
		var elapsed := maxi(0, mini(now - int(s["startedAt"]), cap))
		var est := DmLabor.estimate(def, int(levels.get(def["skill"], 1)), float(elapsed))
		var pct := DmMath.js_round(float(elapsed) / float(cap) * 100.0)
		var row := DmPb.hbox(8)
		var col := DmPb.vbox(3)
		col.custom_minimum_size.x = 120
		var bar := DmPbBar.new(5.0)
		bar.fill = DmUi.OK
		bar.pct = float(pct)
		col.add_child(bar)
		var node_name: String = String(s["nodeName"]) if s.get("nodeName") != null else String(def["name"])
		info["text"] = "%s · %s%s · about %s %s, %s xp" % [node_name, DmPb.duration_text(elapsed / 1000), " (full)" if elapsed >= cap else "", DmPb.num(est["items"]), DmPb.item_name(String(def["item"])), DmPb.num(est["xp"])]
		col.add_child(DmPb.hint(info["text"], 12, DmUi.TEXT_MUTED))
		row.add_child(col)
		var collect := DmPb.button("Collect", false, not (est["actions"] >= 1) or busy)
		collect.pressed.connect(func() -> void: collect_requested.emit(slot))
		row.add_child(collect)
		var recall := DmPb.button("Recall", false, busy, "Bring them home")
		recall.pressed.connect(func() -> void: recall_requested.emit(slot))
		row.add_child(recall)
		collect_buttons[slot] = collect
		recall_buttons[slot] = recall
		card.add_child(row)
		info["pct"] = pct
		info["collect_enabled"] = not collect.disabled
		info["recall_enabled"] = not recall.disabled
	slots_info.append(info)


func _loot_section() -> void:
	if loot.is_empty():
		return
	var head := DmPb.hbox(8)
	head.add_child(DmPb.grow(DmPb.section_title("Brought home")))
	clear_button = DmPb.button("Clear")
	clear_button.pressed.connect(clear_loot)
	head.add_child(clear_button)
	add_child(head)
	for entry: Dictionary in loot:
		var r: Dictionary = entry["report"]
		var sk: Dictionary = r["skills"][0] if r.get("skills", []).size() > 0 else {}
		var xp := ""
		if not sk.is_empty():
			xp = " · +%s %s xp" % [DmPb.num(sk["xp"]), sk["name"]]
			if int(sk["toLevel"]) > int(sk["fromLevel"]):
				xp += " (Lv %d → %d)" % [int(sk["fromLevel"]), int(sk["toLevel"])]
		var gold := " · +%sg" % DmPb.num(r["gold"]) if int(r.get("gold", 0)) > 0 else ""
		var g := DmPb.group(self, "Laborer %d · %s finds%s%s" % [int(entry["slot"]) + 1, DmPb.num(r["totalItems"]), xp, gold], false)
		for w: String in r.get("milestones", []) + r.get("records", []):
			g.add_child(DmPb.text("★ " + w, 13, DmUi.BONE_100))
		DmPb.item_rows(g, r.get("items", []))
