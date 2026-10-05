class_name DmLegionView
extends VBoxContainer
## The Legion (Y, or the Reliquary button; src/ui/LegionPanel.ts): the two kit slots the thralls wear, what each gives in plain words, the legion's total,
## Reinforce (the gold sink), and spare gear ranked by green up / red down arrows against the piece it would replace.
## Pure display. gameplay/legionKit.ts (kitPieces / pieceLines / bonusLines / kitCandidates) produces the strings; the caller passes them in.
##
## Data in:  set_data({
##     kit: {weapon: piece|null, armor: piece|null}   piece = {slot_index, name, rarity, icon?, ilvl?, lines:[String], unused:[String]}
##     bonus_lines: [String]            (legion total, bonusLines(legionOf(slots, tier)))
##     thrall: {hp, damage} | null      (a freshly raised thrall)
##     spares: [{slot_index, name, rarity, icon?, kit: "weapon"|"armor", verdict: "up"|"down"|"same", text}]   best first
##     tier: int, cost: int (-1 at the top), gold: int })
## Signals (DmApi mapping):
##   take_off_requested(kit_id)   -> DmApi.kit_move(character_id, 120 + KIT_IDS.index(kit_id), 0)   (slot_index 120 weapon / 121 armor)
##   give_requested(slot_index)   -> DmApi.kit_move(character_id, slot_index, 1)
##   reinforce_requested          -> local gold spend (Progression.buyLegion) + the necro save; no dedicated endpoint
## set_error(msg) shows the server's refusal verbatim.

signal take_off_requested(kit_id: String)
signal give_requested(slot_index: int)
signal reinforce_requested

const SPARES_SHOWN := 4
const KIT_LABEL := {"weapon": "Weapon", "armor": "Armour"}

var data: Dictionary = {}
var error := ""
var busy := false


func _init() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_data(d: Dictionary) -> void:
	data = d
	render()


func set_error(msg: String) -> void:
	error = msg
	render()


var _built_sig := 0
var _built := false


func render() -> void:
	var sig := [data, error, busy].hash()
	if _built and sig == _built_sig and get_child_count() > 0:
		return
	_built_sig = sig
	_built = true
	DmPa.clear(self)
	if error != "":
		var e := DmPa.card(DmUi.BLOOD_500, Color(DmUi.BLOOD_500, 0.28), Vector2(10, 6))
		DmPa.card_body(e).add_child(DmPa.text(error, 14, DmUi.TEXT))
		e.set_meta("role", "error")
		add_child(e)
	var kit: Dictionary = data.get("kit", {})
	var slots := DmPa.grid(2, 10, 10)
	for id in ["weapon", "armor"]:
		slots.add_child(_slot_card(id, kit.get(id)))
	add_child(slots)
	var mid := DmPa.grid(2, 10, 10)
	mid.add_child(_total())
	mid.add_child(_reinforce())
	add_child(mid)
	add_child(_spares())


func _h3(t: String, small: String = "") -> Control:
	var h := DmPa.hbox(6)
	h.add_child(DmPa.text(DmUi.upper(t), 13, DmUi.BONE_300, "display", false))
	if small != "":
		var s := DmPa.text(small, 12, DmUi.TEXT_MUTED, "numeric", false)
		s.size_flags_vertical = Control.SIZE_SHRINK_END
		h.add_child(s)
	return h


func _icon(piece: Dictionary, px: int, kit_glyph: String) -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", DmUi.box(Color(0, 0, 0, 0.35), Color(DmUi.BONE_300, 0.12), 1, 0))
	wrap.custom_minimum_size = Vector2(px, px)
	wrap.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var ic := DmPa.icon(String(piece.get("icon", "")), px - 2, String(piece.get("name", kit_glyph)), kit_glyph)
	ic.border = Color(0, 0, 0, 0)
	wrap.add_child(ic)
	return wrap


func _slot_card(id: String, piece: Variant) -> Control:
	var glyph := "⚔" if id == "weapon" else "⛊"
	var rarity := String(piece.get("rarity", "common")) if piece is Dictionary else "common"
	var col := DmUi.rarity_color(rarity)
	var c := DmPa.card(Color(col, 0.55) if piece is Dictionary else DmUi.BORDER, DmUi.INSET, Vector2(10, 10))
	c.custom_minimum_size.y = 104 if piece is Dictionary else 80
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.set_meta("kit", id)
	c.set_meta("empty", not (piece is Dictionary))
	var h := DmPa.hbox(10)
	DmPa.card_body(c).add_child(h)
	if not (piece is Dictionary):
		var ph := PanelContainer.new()
		ph.custom_minimum_size = Vector2(56, 56)
		ph.add_theme_stylebox_override("panel", DmUi.box(Color(0, 0, 0, 0.35), Color(DmUi.BONE_300, 0.12), 1, 0))
		var g := DmPa.text(glyph, 22, DmUi.TEXT_FAINT, "display_bold", false)
		g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		g.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		ph.add_child(g)
		h.add_child(ph)
		var info := DmPa.vbox(2)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_child(DmPa.text(DmUi.upper(KIT_LABEL[id]), 11, DmUi.TEXT_FAINT, "body", false))
		var hint := "a sword, staff, wand or off-hand" if id == "weapon" else "a helm, chest, legs, boots or gloves"
		info.add_child(DmPa.text("Empty. Give it %s from your bag." % hint, 13, DmUi.TEXT_MUTED))
		h.add_child(info)
		return c
	h.add_child(_icon(piece, 56, glyph))
	var info := DmPa.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(DmPa.text(DmUi.upper(KIT_LABEL[id]), 11, DmUi.TEXT_FAINT, "body", false))
	var nm := DmUi.rarity_mark(rarity) + " " + String(piece["name"])
	var rt := DmPa.rich_bb("", 15, col)
	rt.text = "[color=#%s][b]%s[/b][/color]%s" % [col.to_html(false), nm.replace("[", "[lb]"), (" [color=#%s]ilvl %d[/color]" % [DmUi.TEXT_MUTED.to_html(false), int(piece["ilvl"])]) if piece.has("ilvl") else ""]
	info.add_child(rt)
	var lines: Array = piece.get("lines", [])
	if lines.is_empty():
		info.add_child(DmPa.text("Gives your thralls nothing.", 13, DmUi.TEXT_FAINT))
	for l in lines:
		info.add_child(DmPa.text(String(l), 13, DmUi.OK))
	var unused: Array = piece.get("unused", [])
	if not unused.is_empty():
		var u := DmPa.text("Not used by thralls: " + ", ".join(PackedStringArray(unused)), 13, DmUi.TEXT_FAINT)
		u.tooltip_text = "These affixes help you, not your thralls"
		info.add_child(u)
	var b := DmPa.button("Take off", "small", busy, "take", id)
	b.tooltip_text = "Take the %s off the legion" % KIT_LABEL[id]
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed.connect(func() -> void: take_off_requested.emit(id))
	info.add_child(b)
	h.add_child(info)
	return c


func _total() -> Control:
	var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(12, 8))
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.set_meta("role", "total")
	var b := DmPa.card_body(c)
	b.add_theme_constant_override("separation", 2)
	b.add_child(_h3("Your legion now"))
	var lines: Array = data.get("bonus_lines", [])
	if lines.is_empty():
		b.add_child(DmPa.text("Spare gear becomes thrall damage, health and attack speed. Give the legion a piece.", 13, DmUi.TEXT_FAINT))
	for l in lines:
		b.add_child(DmPa.text(String(l), 14, DmUi.OK))
	var t: Variant = data.get("thrall")
	if t is Dictionary:
		b.add_child(DmPa.rich("A thrall raised now: <b>%d</b> health, hits for <b>%s</b>. Reinforcing also strengthens the thralls already standing, once; swapping a kit piece reaches the next ones you raise." % [int(roundf(float(t["hp"]))), "%.1f" % float(t["damage"])], 13, DmUi.TEXT_FAINT))
	return c


func _reinforce() -> Control:
	var tier: int = int(data.get("tier", 0))
	var cost: int = int(data.get("cost", -1))
	var have: int = int(data.get("gold", 0))
	var maxt: int = int(DmCombatData.progression()["legion_upgrade"]["maxTier"])
	var now := DmLegion.reinforce_bonus(tier)
	var nxt := DmLegion.reinforce_bonus(tier + 1)
	var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(12, 8))
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_stretch_ratio = 1.25
	c.set_meta("role", "reinforce")
	var b := DmPa.card_body(c)
	b.add_theme_constant_override("separation", 4)
	b.add_child(_h3("Reinforce", "tier %d / %d" % [tier, maxt]))
	var pips := HBoxContainer.new()
	pips.add_theme_constant_override("separation", 4)
	for i in maxt:
		var p := ColorRect.new()
		p.color = DmUi.SPELL_400 if i < tier else Color(DmUi.BONE_300, 0.12)
		p.custom_minimum_size = Vector2(0, 6)
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pips.add_child(p)
	b.add_child(pips)
	if tier > 0:
		b.add_child(DmPa.rich("Bound: <b>+%s</b> health and damage, <b>+%s</b> attack speed." % [DmPa.pct(now["hp"]), DmPa.pct(now["speed"])], 14, DmUi.TEXT_MUTED))
	else:
		b.add_child(DmPa.text("Spend gold to bind the dead tighter.", 14, DmUi.TEXT_MUTED))
	if cost < 0:
		b.add_child(DmPa.text("Fully reinforced. The bindings reset when you Ascend.", 13, DmUi.TEXT_FAINT))
	else:
		var afford := have >= cost
		var btn := DmPa.button("Reinforce · %sg" % DmPa.commas(cost), "small", not afford, "reinforce")
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		btn.custom_minimum_size.x = 170
		btn.tooltip_text = ("Costs gold, rises with each tier (you hold %sg). Thralls already standing are strengthened at once" % DmPa.commas(have)) if afford else "You need %sg more gold" % DmPa.commas(cost - have)
		btn.pressed.connect(func() -> void: reinforce_requested.emit())
		b.add_child(btn)
		b.add_child(DmPa.text("Next: +%s health and damage, +%s attack speed" % [DmPa.pct(nxt["hp"]), DmPa.pct(nxt["speed"])], 13, DmUi.TEXT_FAINT))
	return c


func _spares() -> Control:
	var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(12, 8))
	c.set_meta("role", "spares")
	var b := DmPa.card_body(c)
	b.add_theme_constant_override("separation", 2)
	b.add_child(_h3("Spare gear in your bag"))
	var spares: Array = data.get("spares", [])
	if spares.is_empty():
		b.add_child(DmPa.text("No spare weapons or armour. Anything the Bone Grinder would eat can arm your legion instead.", 13, DmUi.TEXT_FAINT))
	for i in mini(spares.size(), SPARES_SHOWN):
		b.add_child(_spare_row(spares[i]))
	if spares.size() > SPARES_SHOWN:
		b.add_child(DmPa.text("%d more in your bag, ranked lower." % (spares.size() - SPARES_SHOWN), 13, DmUi.TEXT_FAINT))
	return c


func _spare_row(s: Dictionary) -> Control:
	var rarity := String(s.get("rarity", "common"))
	var col := DmUi.rarity_color(rarity)
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 0)
	wrap.add_child(DmUi.hrule(Color(DmUi.BONE_300, 0.08)))
	var h := DmPa.hbox(10)
	h.add_child(DmPa.margin(_icon(s, 38, "◆"), 0, 4, 0, 4))
	var t := DmPa.vbox(0)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.add_child(DmPa.text(String(s["name"]), 13, col, "body_bold", false))
	var verdict := String(s.get("verdict", "same"))
	var arrow: String = {"up": "▲", "down": "▼", "same": "="}[verdict]
	var vcol: Color = {"up": DmUi.UP, "down": DmUi.DOWN, "same": DmUi.TEXT_MUTED}[verdict]
	var vt := DmPa.text("%s %s" % [arrow, "no change" if verdict == "same" else String(s.get("text", ""))], 13, vcol, "numeric_medium", false)
	vt.set_meta("verdict", verdict)
	t.add_child(vt)
	h.add_child(t)
	var where := "Weapon" if String(s.get("kit", "weapon")) == "weapon" else "Armour"
	var g := DmPa.button("Give", "small", busy, "give", int(s["slot_index"]))
	g.tooltip_text = "Give %s to the legion's %s slot" % [s["name"], where]
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	g.pressed.connect(func() -> void: give_requested.emit(int(s["slot_index"])))
	h.add_child(g)
	wrap.add_child(h)
	return wrap
