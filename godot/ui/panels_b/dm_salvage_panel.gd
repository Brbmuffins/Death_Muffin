class_name DmSalvagePanel
extends DmPanelB
## The Bone Grinder (src/ui/SalvagePanel.ts): tick gear you no longer want and grind it into ingots or planks plus alchemy reagents.
## Locked items are shown but never selectable and never taken by "Salvage all below rare". Yields/XP come from DmSalvage.preview (rules/gathering).
##
## Data in:  set_bag(slots)  bag rows {slot_index, item_id, name, rarity, base_rarity?, item_type, equipped (0/1), quantity, inst?:{ilvl, affixes:[..]}}
##           set_locks(locks)  anything with is_locked(slot) (DmItemLocks)       set_skill({level, xp, next})   (Salvaging)
##           keep: Callable(slot)->bool  pieces "Salvage all below rare" spares because they would upgrade you (keepsForYou)
##           set_result(reply)  SalvageReply {salvaged, gained:[{item_id, quantity}], xp, level, leveledUp}   set_busy(bool)   set_error(text)
## Signals:  salvage_requested(slots: Array[int]) -> DmApi.salvage_gear(character_id, slots) under the inventory-exclusive guard; adopt reply.bag via
##           set_bag(), then set_result(reply). Both buttons emit it (selected slots / the "below rare" list).

signal salvage_requested(slots: Array)

var bag: Array = []
var locks: Object = null
var skill: Dictionary = {"level": 1, "xp": 0, "next": 50}
var keep: Callable = Callable()
var chosen: Dictionary = {}          # slot_index -> true
var result: Dictionary = {}
var busy := false
## Drawn rows: [{slot, name, rarity, locked, on, checkbox_enabled, yield_line}] plus footer state.
var rows: Array[Dictionary] = []
var footer: Dictionary = {}
var checks: Dictionary = {}
var go_button: Button
var below_button: Button


func _init() -> void:
	super._init()
	title = "Bone Grinder"
	panel_width = 720


func set_bag(slots: Array) -> void:
	bag = slots
	rebuild()


func set_locks(l: Object) -> void:
	locks = l
	rebuild()


func set_skill(s: Dictionary) -> void:
	skill = s
	rebuild()


func set_result(r: Dictionary) -> void:
	result = r
	chosen.clear()
	rebuild()


func set_busy(v: bool) -> void:
	busy = v
	rebuild()


func is_locked(slot: Dictionary) -> bool:
	return locks != null and locks.is_locked(slot)


## Gear in the bag that can be ground (worn pieces never appear), by rarity then slot.
func gear() -> Array:
	var out: Array = []
	for s: Dictionary in bag:
		if int(s.get("equipped", 0)) == 0 and int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 100 and DmSalvage.is_salvageable(String(s["item_type"])):
			out.append(s)
	var rank := func(r: String) -> int: return DmSalvage.RARITIES.find(r)
	return DmStableSort.sorted(out, func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = rank.call(a["rarity"])
		var rb: int = rank.call(b["rarity"])
		if ra != rb:
			return ra < rb
		return int(a["slot_index"]) < int(b["slot_index"]))


static func item_of(s: Dictionary) -> Dictionary:
	var it := {"id": s["item_id"], "item_type": s["item_type"], "rarity": s.get("base_rarity", s["rarity"])}
	if s.get("inst") != null:
		it["ilvl"] = s["inst"]["ilvl"]
		it["affixes"] = s["inst"]["affixes"].size()
	return it


static func _reagent_text(r: Dictionary) -> String:
	var q: Array = r["qty"]
	var t := DmPb.item_name(String(r["id"]))
	if q[0] != q[1]:
		t += " ×%d-%d" % [q[0], q[1]]
	if float(r["chance"]) < 1.0:
		t += " (%d%%)" % DmMath.js_round(float(r["chance"]) * 100.0)
	return t


## "2-3 Silver Ingot or Steel Ingot (+1 12%) · Grave Dust ×1-2, ..." for one piece.
static func preview_line(s: Dictionary) -> String:
	var p := DmSalvage.preview(item_of(s))
	var reagents := ", ".join(p["reagents"].map(_reagent_text))
	if p["materials"].is_empty():
		return "one rune%s · %s" % [" (of %d)" % int(s["quantity"]) if int(s["quantity"]) > 1 else "", reagents]
	var mats := " or ".join(p["materials"].map(func(id: String) -> String: return DmPb.item_name(id)))
	var mq: Array = p["materialQty"]
	var qty := str(mq[0]) if mq[0] == mq[1] else "%d-%d" % [mq[0], mq[1]]
	var extra := " (+1 %d%%)" % DmMath.js_round(float(p["extraChance"]) * 100.0) if float(p["extraChance"]) > 0.0 else ""
	return "%s %s%s · %s" % [qty, mats, extra, reagents]


func below_rare() -> Array:
	return DmItemLocks.salvage_below_rare(bag, locks if locks != null else _NoLocks.new(), keep)


class _NoLocks:
	func is_locked(_s: Dictionary) -> bool:
		return false


func _build() -> void:
	rows.clear()
	checks.clear()
	var list_gear := gear()
	# Drop picks that are gone or have since been locked.
	for i: int in chosen.keys():
		var found := false
		for g: Dictionary in list_gear:
			if int(g["slot_index"]) == i and not is_locked(g):
				found = true
		if not found:
			chosen.erase(i)
	head_note = "Salvaging <b>%d</b>  %s / %s XP" % [int(skill["level"]), DmPb.num(skill["xp"]), DmPb.num(skill["next"])]
	_head_note_row()
	add_child(DmPb.rich("Feed it gear you will not wear. It gives back <b>ingots</b> (or <b>planks</b> from staffs, wands and grimoires) by rarity, plus <b>Grave Dust</b> and other alchemy reagents. Higher Salvaging adds a chance of an extra material (+0.5% a level); gear with a high item level or affixes adds more. A spare <b>Relic rune</b> is ground one at a time into reagents only.", 12))
	var picked: Array = list_gear.filter(func(g: Dictionary) -> bool: return chosen.has(int(g["slot_index"])))
	var below := below_rare()
	var xp := 0
	for g: Dictionary in picked:
		xp += int(DmSalvage.preview(item_of(g))["xp"])

	var list := DmPb.vbox(5)
	if list_gear.is_empty():
		add_child(DmPb.hint("You carry no gear to salvage. Worn gear never appears here."))
	else:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size = Vector2(0, minf(list_gear.size() * 49.0, 300.0))
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(list)
		add_child(scroll)
		for g: Dictionary in list_gear:
			_row(list, g)
	var foot := HFlowContainer.new()
	foot.add_theme_constant_override("h_separation", 8)
	foot.add_theme_constant_override("v_separation", 6)
	var ft := "%d chosen · about %d Salvaging XP" % [picked.size(), xp] if picked.size() > 0 else "Tick the gear to grind. Locked items cannot be chosen."
	var fl := DmPb.hint(ft)
	fl.custom_minimum_size.x = 200
	foot.add_child(fl)
	go_button = DmPb.button("Salvage selected", false, picked.is_empty() or busy)
	go_button.pressed.connect(func() -> void: salvage_requested.emit(chosen.keys()))
	foot.add_child(go_button)
	below_button = DmPb.button("Salvage all below rare%s" % (" (%d)" % below.size() if below.size() > 0 else ""), false, below.is_empty() or busy, "Every unlocked common and uncommon piece in your bag, except pieces that would upgrade you")
	below_button.pressed.connect(func() -> void: salvage_requested.emit(below.map(func(s: Dictionary) -> int: return int(s["slot_index"]))))
	foot.add_child(below_button)
	add_child(foot)
	footer = {"text": ft, "picked": picked.size(), "xp": xp, "go_enabled": not go_button.disabled, "below_count": below.size(), "below_enabled": not below_button.disabled, "result": ""}
	if not result.is_empty():
		var gained := ", ".join(result["gained"].map(func(g: Dictionary) -> String: return "%d× %s" % [int(g["quantity"]), DmPb.item_name(String(g["item_id"]))]))
		var n: int = result["salvaged"].size()
		var line := "Ground %d piece%s for %s · +%d Salvaging XP%s" % [n, "" if n == 1 else "s", gained, int(result["xp"]), " · Salvaging level %d" % int(result["level"]) if result.get("leveledUp", false) else ""]
		footer["result"] = line
		var rc := DmPb.card(self, DmUi.BORDER, Color(0, 0, 0, 0), Vector2(10, 8))
		rc.add_child(DmPb.text(line, 13, DmUi.OK, "body", true))
	_error_row()


func _row(parent: Control, g: Dictionary) -> void:
	var slot := int(g["slot_index"])
	var locked := is_locked(g)
	var on := chosen.has(slot)
	var rarity := String(g["rarity"])
	var rc := DmUi.rarity_color(rarity)
	var card := DmPb.card(parent, rc if on else DmUi.BORDER, Color(0, 0, 0, 0), Vector2(8, 5), DmUi.INSET.lerp(DmUi.SPELL_400, 0.16) if on else DmUi.INSET)
	if locked:
		(card.get_meta("panel") as Control).modulate.a = 0.55
	var row := DmPb.hbox(10)
	card.add_child(row)
	var cb := CheckBox.new()
	cb.button_pressed = on
	cb.disabled = locked or busy
	cb.focus_mode = Control.FOCUS_NONE
	cb.tooltip_text = "Salvage %s" % g["name"]
	cb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cb.toggled.connect(func(v: bool) -> void:
		if v:
			chosen[slot] = true
		else:
			chosen.erase(slot)
		rebuild.call_deferred())
	row.add_child(cb)
	checks[slot] = cb
	row.add_child(DmPb.icon(rarity, 36.0))
	var col := DmPb.vbox(1)
	row.add_child(col)
	var nm := DmPb.hbox(8)
	nm.add_child(DmPb.text(String(g["name"]), 14, rc, "body_bold"))
	var sub := "%s %s%s" % [DmUi.rarity_mark(rarity), rarity, " · ilvl %d" % int(g["inst"]["ilvl"]) if g.get("inst") != null else ""]
	nm.add_child(DmPb.text(DmUi.upper(sub), 11, DmUi.TEXT_FAINT))
	if locked:
		var lk := DmPbLock.new()
		lk.tooltip_text = "Locked"
		lk.mouse_filter = Control.MOUSE_FILTER_PASS
		nm.add_child(lk)
	col.add_child(nm)
	var yl := preview_line(g)
	var yll := DmPb.text(yl, 12, DmUi.TEXT_MUTED)
	yll.clip_text = true
	yll.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(yll)
	rows.append({"slot": slot, "name": g["name"], "rarity": rarity, "locked": locked, "on": on, "checkbox_enabled": not cb.disabled, "yield_line": yl})
