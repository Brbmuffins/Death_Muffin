class_name DmReforgeView
extends DmPanelB
## The Workbench's Reforge tab (src/ui/ReforgeView.ts): pick a rolled piece (bag or worn), pick one of its affixes, see the price, confirm.
## Only that affix's VALUE is drawn again; the server prices and rolls, this view previews the price with the same rules (DmGoldSink, DmAffixRules).
##
## Data in:  set_pieces(slots)  bag rows {slot_index, item_id, name, rarity, base_rarity?, inst:{id, ilvl, affixes:[{id, v}]}}   (filtered here)
##           set_counts({instance_id: rerolls})  from the quote   set_gold(int)   set_busy(bool)   show_result(reply, was_text)   set_error(text)
## Signals:  quote_requested                                  -> DmApi.reforge_quote(character_id)  (when the tab is shown; feed set_counts)
##           reforge_requested(slot_index, affix_index, expect_cost) -> DmApi.reforge_affix(character_id, slot_index, affix_index, expect_cost) through
##                                                                the gold-spend guard (Progression.spendOnServer) and the inventory-exclusive guard;
##                                                                reply {bag, rerolls, from, to, cost} -> set_pieces(reply.bag), show_result(reply, was_text)

signal quote_requested
signal reforge_requested(slot_index: int, affix_index: int, expect_cost: int)

var pieces_src: Array = []
var counts: Dictionary = {}
var gold := 0
var busy := false
var picked_instance := -1
var confirm := -1
var result_text := ""
## Drawn state: {pieces: [{name, ilvl, worn, reforged, on}], affixes: [{text, range, button, enabled}], confirm_text, gold_text}.
var shown: Dictionary = {}
var pick_buttons: Dictionary = {}
var ask_buttons: Array[Button] = []
var go_button: Button
var cancel_button: Button


func _init() -> void:
	super._init()
	title = "Reforge"
	panel_width = 720


func _inputs() -> Variant:
	return [pieces_src, counts, gold, busy, picked_instance, confirm, result_text, error_text]


func set_pieces(slots: Array) -> void:
	pieces_src = slots
	rebuild()


func set_counts(c: Dictionary) -> void:
	counts = c
	rebuild()


func set_gold(g: int) -> void:
	gold = g
	rebuild()


func set_busy(v: bool) -> void:
	busy = v
	rebuild()


func pieces() -> Array:
	var out: Array = []
	for s: Dictionary in pieces_src:
		if s.get("inst") != null and s["inst"]["affixes"].size() > 0 and int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 200:
			out.append(s)
	# Worn pieces first, then by item level.
	return DmStableSort.sorted(out, func(a: Dictionary, b: Dictionary) -> bool:
		var wa := int(int(a["slot_index"]) >= 100)
		var wb := int(int(b["slot_index"]) >= 100)
		if wa != wb:
			return wa > wb
		if int(a["inst"]["ilvl"]) != int(b["inst"]["ilvl"]):
			return int(a["inst"]["ilvl"]) > int(b["inst"]["ilvl"])
		return int(a["slot_index"]) < int(b["slot_index"]))


func cost_of(s: Dictionary) -> int:
	return DmGoldSink.reforge_cost(float(s["inst"]["ilvl"]), String(s.get("base_rarity", s["rarity"])), s["inst"]["affixes"].size(), counts.get(int(s["inst"]["id"]), 0))


func picked(list: Array) -> Dictionary:
	for s: Dictionary in list:
		if int(s["inst"]["id"]) == picked_instance:
			return s
	return {}


func show_result(reply: Dictionary, was_text: String, affix_id: String) -> void:
	var to_text := DmAffixRules.affix_text({"id": affix_id, "v": reply["to"]})
	var verdict := "higher" if reply["to"] > reply["from"] else ("lower" if reply["to"] < reply["from"] else "the same")
	result_text = "%s became %s %s · %s gold" % [was_text, to_text, verdict, DmPb.num(reply["cost"])]
	confirm = -1
	rebuild()


func _build() -> void:
	pick_buttons.clear()
	ask_buttons.clear()
	go_button = null
	cancel_button = null
	var list := pieces()
	var sel := picked(list)
	shown = {"pieces": [], "affixes": [], "confirm_text": "", "gold_text": "Your gold %s" % DmPb.num(gold)}
	add_child(DmPb.rich("Pick a piece, then one of its affixes. <b>Reforge</b> draws that affix's number again (the affix itself stays) for gold. Each reforge of the same piece costs about 25% more. It can come out lower, and a roll already at the top of its range cannot be reforged.", 13, DmUi.TEXT_FAINT))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(cols)
	var left := DmPb.vbox(5)
	left.size_flags_stretch_ratio = 5.0
	var right := DmPb.vbox(6)
	right.size_flags_stretch_ratio = 6.0
	if list.is_empty():
		left.add_child(DmPb.hint("You carry no gear with affixes. Rolled drops (magic, rare and better) have them; common pieces do not."))
		cols.add_child(left)
	else:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size = Vector2(0, minf(list.size() * 50.0, 300.0))
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_stretch_ratio = 5.0
		scroll.add_child(left)
		cols.add_child(scroll)
		for s: Dictionary in list:
			_pick_row(left, s, s == sel)
	cols.add_child(right)
	if sel.is_empty():
		right.add_child(DmPb.hint("Choose a piece on the left."))
	else:
		_detail(right, sel)
	add_child(DmPb.rich("Your gold <b>%s</b>" % DmPb.num(gold), 13, DmUi.TEXT_MUTED))
	if result_text != "":
		var rc := DmPb.card(self, DmUi.BORDER, Color(0, 0, 0, 0), Vector2(10, 8))
		rc.add_child(DmPb.text(result_text, 13, DmUi.OK, "body", true))
	_error_row()


func _pick_row(parent: Control, s: Dictionary, on: bool) -> void:
	var rarity := String(s["rarity"])
	var rc := DmUi.rarity_color(rarity)
	var n: int = counts.get(int(s["inst"]["id"]), 0)
	var worn := int(s["slot_index"]) >= 100
	var sub := "%s ilvl %d%s%s" % [DmUi.rarity_mark(rarity), int(s["inst"]["ilvl"]), " · worn" if worn else "", " · reforged %d×" % n if n > 0 else ""]
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(0, 46)
	btn.add_theme_stylebox_override("normal", DmUi.box(DmUi.INSET.lerp(DmUi.SPELL_400, 0.16) if on else DmUi.INSET, rc if on else Color(rc, 0.35), 1, 0, Vector2.ZERO))
	btn.add_theme_stylebox_override("hover", DmUi.box(DmUi.INSET.lerp(DmUi.SPELL_400, 0.12), DmUi.BORDER_ACTIVE, 1, 0, Vector2.ZERO))
	btn.add_theme_stylebox_override("pressed", DmUi.box(DmUi.INSET.lerp(DmUi.SPELL_400, 0.2), DmUi.BORDER_ACTIVE, 1, 0, Vector2.ZERO))
	btn.add_theme_stylebox_override("focus", DmUi.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0, Vector2.ZERO))
	var h := DmPb.hbox(10)
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 5
	h.offset_right = -5
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(DmPb.icon(rarity, 36.0, null, false, String(s.get("item_id", ""))))
	var col := DmPb.vbox(0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := DmPb.text(String(s["name"]), 14, rc, "body_bold")
	nm.clip_text = true
	col.add_child(nm)
	col.add_child(DmPb.text(DmUi.upper(sub), 11, DmUi.TEXT_FAINT))
	h.add_child(col)
	btn.add_child(h)
	var inst_id := int(s["inst"]["id"])
	btn.pressed.connect(func() -> void:
		picked_instance = inst_id
		confirm = -1
		result_text = ""
		rebuild.call_deferred())
	parent.add_child(btn)
	pick_buttons[inst_id] = btn
	shown["pieces"].append({"name": s["name"], "ilvl": int(s["inst"]["ilvl"]), "worn": worn, "reforged": n, "on": on})


func _detail(parent: Control, s: Dictionary) -> void:
	var inst: Dictionary = s["inst"]
	var cost := cost_of(s)
	var afford := gold >= cost
	parent.add_child(DmPb.text(String(s["name"]), 16, DmUi.rarity_color(String(s["rarity"])), "body_bold"))
	for i in inst["affixes"].size():
		var a: Dictionary = inst["affixes"][i]
		var rng: Variant = DmAffixRules.affix_range(String(a["id"]), float(inst["ilvl"]))
		var why := DmGoldSink.reforge_problem(inst, i, DmAffixRules.affix_range)
		var q := DmMath.js_round(DmAffixRules.affix_quality(a, float(inst["ilvl"])) * 100.0)
		var c := DmPb.card(parent, DmUi.SPELL_300 if confirm == i else DmUi.BORDER, Color(0, 0, 0, 0), Vector2(8, 6))
		var row := DmPb.hbox(8)
		c.add_child(row)
		var col := DmPb.vbox(1)
		row.add_child(col)
		col.add_child(DmPb.text(DmAffixRules.affix_text(a), 14, DmUi.SPELL_300 if DmAffixRules.affix_is_necro(a) else DmUi.BONE_100))
		var rg := "range %d–%d · %d%%" % [int(rng[0]), int(rng[1]), q] if rng != null else ""
		col.add_child(DmPb.text(rg, 12, DmUi.TEXT_FAINT))
		var label := "Reforge · %sg" % DmPb.num(cost)
		if why != "":
			label = "Maxed" if why.begins_with("That roll") else "No"
		var b := DmPb.button(label, false, why != "" or busy, why if why != "" else "Re-roll this affix's value for %s gold" % DmPb.num(cost))
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var idx: int = i
		b.pressed.connect(func() -> void:
			confirm = idx
			result_text = ""
			rebuild.call_deferred())
		row.add_child(b)
		ask_buttons.append(b)
		shown["affixes"].append({"text": DmAffixRules.affix_text(a), "range": rg, "button": label, "enabled": not b.disabled})
	if confirm >= 0 and confirm < inst["affixes"].size():
		var ct := "Re-roll %s for %s gold%s?" % [DmAffixRules.affix_text(inst["affixes"][confirm]), DmPb.num(cost), "" if afford else " (you have %s)" % DmPb.num(gold)]
		shown["confirm_text"] = ct
		var cc := DmPb.card(parent, DmUi.BORDER_ACTIVE, Color(0, 0, 0, 0), Vector2(8, 6))
		cc.add_child(DmPb.text(ct, 13, DmUi.BONE_100 if afford else DmUi.DANGER, "body", true))
		var br := DmPb.hbox(8)
		go_button = DmPb.button("Reforging…" if busy else "Reforge", true, not afford or busy)
		var slot_index := int(s["slot_index"])
		var ci := confirm
		go_button.pressed.connect(func() -> void:
			reforge_requested.emit(slot_index, ci, cost))
		br.add_child(go_button)
		cancel_button = DmPb.button("Cancel", false, busy)
		cancel_button.pressed.connect(func() -> void:
			confirm = -1
			rebuild.call_deferred())
		br.add_child(cancel_button)
		cc.add_child(br)
