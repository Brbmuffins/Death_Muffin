class_name DmCosmeticsView
extends VBoxContainer
## Capes & Pets (N; archive/legacy-web:src/ui/CosmeticsPanel.ts): mastery capes (level 99 in a skill, or total level for the mantles) and adopted companions.
##
## Data in:  set_view(view: Dictionary)  = the server's CosmeticsView {totalLevel, selected:{cape, pet}, capes:[{id,name,lore,color,trim,unlocked,have,need}],
##           pets:[{id,name,lore,skill,charm,adopted, rarity?}]};  set_charm_counts({charm_item_id: count}) (bag counts for the Adopt button).
##           set_error(msg) / set_loading().
## Signals (each maps to a DmApi call; the reply becomes the new view):
##   cape_toggled(id)  -> DmApi.select_cosmetics(character_id, {cape: id or null})   (id is "" to take it off)
##   pet_toggled(id)   -> DmApi.select_cosmetics(character_id, {pet: id or null})
##   adopt_requested(id) -> DmApi.adopt_pet(character_id, id)   (spends a charm: run under the inventory's exclusive action, then re-read the bag)

signal cape_toggled(id: String)
signal pet_toggled(id: String)
signal adopt_requested(id: String)

var view: Dictionary = {}
var charms: Dictionary = {}
var error := ""
var busy := false


func _init() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	render()


func set_view(v: Dictionary) -> void:
	view = v
	render()


func set_charm_counts(c: Dictionary) -> void:
	charms = c
	render()


func set_error(msg: String) -> void:
	error = msg
	render()


func set_busy(b: bool) -> void:
	busy = b
	render()


func total_level_text() -> String:
	return "Total level %s" % DmPa.commas(view.get("totalLevel", 0)) if not view.is_empty() else ""


func render() -> void:
	DmPa.clear(self)
	if view.is_empty():
		add_child(DmPa.text(error if error != "" else "The Sexton is opening the chest…", 14, DmUi.TEXT_FAINT))
		return
	var top := DmPa.hbox(8)
	top.add_child(DmPa.text(total_level_text(), 13, DmUi.TEXT_MUTED, "body", false))
	add_child(top)
	add_child(DmPa.text("Capes are earned: level 99 in a skill, or a total level for the mantles. Pets are rare finds while you work; adopt a charm and the companion is yours for good. Other players see what you wear.", 13, DmUi.TEXT_FAINT))
	add_child(_h("Capes"))
	var sel_v: Variant = view.get("selected")
	var sel: Dictionary = sel_v if sel_v is Dictionary else {}
	# The server sends null for "nothing worn".
	var cape_sel := "" if sel.get("cape") == null else String(sel.get("cape"))
	var pet_sel := "" if sel.get("pet") == null else String(sel.get("pet"))
	for c in view.get("capes", []):
		add_child(_cape_row(c, cape_sel == String(c["id"])))
	add_child(_h("Companions"))
	for p in view.get("pets", []):
		add_child(_pet_row(p, pet_sel == String(p["id"])))
	if error != "":
		add_child(DmPa.text(error, 14, DmUi.DANGER))


func _h(t: String) -> Control:
	return DmPa.margin(DmPa.text(DmUi.upper(t), 15, DmUi.BONE_300, "display_bold", false), 0, 8, 0, 0)


static func hex(n: Variant) -> Color:
	var v := int(n)
	return Color.from_rgba8((v >> 16) & 255, (v >> 8) & 255, v & 255)


func _row_card(worn: bool, open: bool, border: Color) -> PanelContainer:
	var c := DmPa.card(DmUi.BORDER_ACTIVE if worn else DmUi.BORDER, DmUi.INSET, Vector2(12, 10))
	c.modulate = Color(1, 1, 1, 1.0 if open else 0.78)
	return c


func _cape_row(c: Dictionary, worn: bool) -> Control:
	var unlocked := bool(c.get("unlocked", false))
	var card := _row_card(worn, unlocked, DmUi.BORDER)
	card.set_meta("cape", String(c["id"]))
	card.set_meta("worn", worn)
	card.set_meta("unlocked", unlocked)
	var h := DmPa.hbox(12)
	DmPa.card_body(card).add_child(h)
	var sw := DmPaSwatch.new()
	sw.body_color = hex(c.get("color", 0))
	sw.trim_color = hex(c.get("trim", 0))
	h.add_child(sw)
	var txt := DmPa.vbox(3)
	txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	txt.add_child(DmPa.text(String(c["name"]), 15, DmUi.BONE_100, "body_bold", false))
	txt.add_child(DmPa.text(String(c.get("lore", "")), 13, DmUi.TEXT_MUTED))
	if not unlocked:
		var need := maxf(1.0, float(c.get("need", 1)))
		var have := float(c.get("have", 0))
		var pb := ProgressBar.new()
		pb.min_value = 0
		pb.max_value = 100
		pb.value = minf(100.0, roundf(have / need * 100.0))
		pb.show_percentage = false
		pb.custom_minimum_size = Vector2(0, 6)
		txt.add_child(pb)
		txt.add_child(DmPa.text("%s / %s" % [DmPa.commas(have), DmPa.commas(need)], 13, DmUi.TEXT_MUTED, "body", false))
	h.add_child(txt)
	var label := "Take off" if worn else ("Wear" if unlocked else "Locked")
	var b := DmPa.button(label, "small", (not unlocked) or busy, "cape", String(c["id"]))
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(func() -> void: cape_toggled.emit("" if worn else String(c["id"])))
	h.add_child(b)
	return card


func _pet_row(p: Dictionary, called: bool) -> Control:
	var adopted := bool(p.get("adopted", false))
	var have: int = int(charms.get(String(p.get("charm", "")), 0))
	var rarity := String(p.get("rarity", "rare"))
	var card := _row_card(called, adopted, DmUi.rarity_color(rarity))
	card.set_meta("pet", String(p["id"]))
	card.set_meta("called", called)
	card.set_meta("adopted", adopted)
	var h := DmPa.hbox(12)
	DmPa.card_body(card).add_child(h)
	var sw := DmPaSwatch.new()
	sw.pet_glyph = "✦" if adopted else "?"
	sw.body_color = DmUi.rarity_color(rarity)
	h.add_child(sw)
	var txt := DmPa.vbox(3)
	txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	txt.add_child(DmPa.text(String(p["name"]), 15, DmUi.BONE_100, "body_bold", false))
	txt.add_child(DmPa.text(String(p.get("lore", "")), 13, DmUi.TEXT_MUTED))
	if not adopted:
		var charm_name := String(DmContent.item(String(p.get("charm", ""))).get("name", ""))
		txt.add_child(DmPa.text("A rare find while working %s. %s." % [p.get("skill_name", String(p.get("skill", "")).capitalize()), charm_name], 13, DmUi.TEXT_MUTED))
	h.add_child(txt)
	var b: Button
	if adopted:
		b = DmPa.button("Send away" if called else "Call", "small", busy, "pet", String(p["id"]))
		b.pressed.connect(func() -> void: pet_toggled.emit("" if called else String(p["id"])))
	elif have > 0:
		b = DmPa.button("Adopt (charm ×%d)" % have, "small", busy, "adopt", String(p["id"]))
		b.pressed.connect(func() -> void: adopt_requested.emit(String(p["id"])))
	else:
		b = DmPa.button("Not found", "small", true, "notfound", String(p["id"]))
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(b)
	return card
