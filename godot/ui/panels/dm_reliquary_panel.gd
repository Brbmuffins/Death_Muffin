class_name DmReliquaryPanel
extends DmWindow
## The Reliquary (src/ui/InventoryPanel.ts): stats line, paper doll (3x4 grid) + tool belt + set summary, 8x6 bag grid,
## footer (slot count, Legion, Sort, Sell all junk with in-place confirm), detail strip (item text left, action column right).
## Layout numbers from ui.css `.cw-reliquary` / gear-stats.css. Pure UI: feed it data, listen to signals.
##
## Data in:  set_inventory(bag: Array[Dictionary] (index = bag slot, {} = empty), worn: Dictionary (equip slot id -> item),
##           belt: Dictionary (hatchet|pickaxe|rod|spade -> item)); set_stats_line(chips: Array[Dictionary{label,value,plus}]).
## Signals:  selected(item), equip_toggled(item), lock_toggled(item), sell_requested(item, qty), sort_requested,
##           junk_sell_confirmed, legion_pressed, sheet_pressed, salvage_requested(item).

signal selected(item: Dictionary)
signal equip_toggled(item: Dictionary)
signal lock_toggled(item: Dictionary)
signal sell_requested(item: Dictionary, qty: int)
signal sort_requested
signal junk_sell_confirmed
signal legion_pressed
signal sheet_pressed
signal salvage_requested(item: Dictionary)
## Wiring additions (game-ui): the web's other detail buttons and gestures. `extra_actions` = Callable(item) -> Array of {id, label, primary?, disabled?, hint?};
## action_requested(id, item) fires when one is pressed. slot_right_clicked(item) is the cell's context click (tool belt / brew belt).
signal action_requested(id: String, item: Dictionary)
signal slot_right_clicked(item: Dictionary)

const BAG_SIZE := 48
const COLS := 8
## Height of the selected-item strip; fixed so the window does not change size when the selection does.
const DETAIL_H := 236
# paper-doll order (3 columns); "" = spacer, "sheet" = the Sheet · J button
const DOLL := ["ring", "head", "trinket", "main_hand", "chest", "off_hand", "hands", "legs", "", "", "feet", "sheet"]
const EQUIP := {
	"head": ["Head", "⛨"], "chest": ["Chest", "⛊"], "legs": ["Legs", "‖"], "feet": ["Feet", "◭"], "hands": ["Hands", "✋"],
	"main_hand": ["Main hand", "⚔"], "off_hand": ["Off hand", "◐"], "ring": ["Ring", "◎"], "trinket": ["Trinket", "✦"],
}
const BELT := [["hatchet", "Hatchet"], ["pickaxe", "Pickaxe"], ["rod", "Rod"], ["spade", "Spade"]]

var has_sell := true
var has_legion := true
var has_sheet := true
var at_grinder := false
var legion_flag := false   # a spare piece would arm the thralls better (green ▲ on the button)
var junk_count := 0        # computed by the integrator (rules track); the panel only shows + confirms
var junk_gold := 0
var extra_actions: Callable = Callable()
var drag_brews := false            # bag cells holding a brew can be dragged onto the HUD belt (web: draggable + BELT_DRAG_TYPE)
var footer_extra: Control = null   # shown before the slot count (the one-time tool-belt offer)
var set_summary: Array = []        # [{name, accent: Color, pips: [bool x5], on: [String], next: String}] (the .cw-setsum block)
var _setsum: VBoxContainer

var bag: Array = []
var worn: Dictionary = {}
var belt: Dictionary = {}
var sel_item: Dictionary = {}
var confirm_junk := false
var confirm_sell_all := ""

var _stats_row: HFlowContainer
var _doll: GridContainer
var _belt_row: HBoxContainer
var _grid: GridContainer
var _tools: HFlowContainer
var _detail_panel: PanelContainer
var _detail: HBoxContainer
var _detail_scroll: ScrollContainer
var _error: Label
var _slots: Array[DmItemSlot] = []
var _doll_slots: Dictionary = {}
var _belt_slots: Dictionary = {}
var _built := false


func _init() -> void:
	super._init()
	title = "Reliquary"
	aka = "Bag · I"
	panel_width = 780
	top_gap = 12
	max_height_margin = 140
	pad_y = 16


func _ready() -> void:
	super._ready()
	if not _built:
		_build_ui()


func _build_ui() -> void:
	_built = true
	body.add_theme_constant_override("separation", 8)
	# .cw-stats-line
	_stats_row = HFlowContainer.new()
	_stats_row.add_theme_constant_override("h_separation", 10)
	_stats_row.add_theme_constant_override("v_separation", 0)
	body.add_child(_stats_row)

	# .cw-inv-body
	var inv := HBoxContainer.new()
	inv.alignment = BoxContainer.ALIGNMENT_CENTER   # .cw-reliquary .cw-inv-body { justify-content: center }
	inv.add_theme_constant_override("separation", 18)
	body.add_child(inv)

	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 182
	col.add_theme_constant_override("separation", 6)
	inv.add_child(col)
	_doll = GridContainer.new()
	_doll.columns = 3
	_doll.add_theme_constant_override("h_separation", 7)
	_doll.add_theme_constant_override("v_separation", 7)
	col.add_child(_doll)
	for i in DOLL.size():
		var id: String = DOLL[i]
		if id == "":
			_doll.add_child(DmUi.spacer(56, 56))
		elif id == "sheet":
			var b := Button.new()
			b.custom_minimum_size = Vector2(56, 56)
			b.theme_type_variation = "DmButtonSmall"
			b.text = DmUi.upper("Sheet · J")
			b.add_theme_font_size_override("font_size", 10)
			b.add_theme_constant_override("h_separation", 0)
			b.visible = has_sheet
			b.pressed.connect(func() -> void: sheet_pressed.emit())
			b.focus_mode = Control.FOCUS_NONE
			_doll.add_child(b)
		else:
			var s := DmItemSlot.new()
			s.kind = DmItemSlot.Kind.EQUIP
			s.custom_minimum_size = Vector2(56, 56)
			s.empty_glyph = EQUIP[id][1]
			s.empty_label = EQUIP[id][0]
			s.pressed.connect(_on_slot_pressed)
			s.double_clicked.connect(func(sl: DmItemSlot) -> void: equip_toggled.emit(sl.data))
			_doll.add_child(s)
			_doll_slots[id] = s
	_setsum = VBoxContainer.new()
	_setsum.add_theme_constant_override("separation", 4)
	_setsum.visible = false
	col.add_child(_setsum)
	# .cw-toolbelt: 4 small slots with a top border
	var tb := VBoxContainer.new()
	tb.add_theme_constant_override("separation", 6)
	tb.add_child(DmUi.hrule())
	_belt_row = HBoxContainer.new()
	_belt_row.add_theme_constant_override("separation", 5)
	for b in BELT:
		var s2 := DmItemSlot.new()
		s2.kind = DmItemSlot.Kind.BELT
		s2.empty_label = b[1]
		s2.custom_minimum_size = Vector2(39, 39)
		s2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s2.pressed.connect(_on_slot_pressed)
		s2.double_clicked.connect(func(sl: DmItemSlot) -> void: equip_toggled.emit(sl.data))
		s2.right_clicked.connect(func(sl: DmItemSlot) -> void: slot_right_clicked.emit(sl.data))
		_belt_row.add_child(s2)
		_belt_slots[b[0]] = s2
	tb.add_child(_belt_row)
	col.add_child(tb)

	_grid = GridContainer.new()
	_grid.columns = COLS
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	_grid.custom_minimum_size.x = 392
	inv.add_child(_grid)
	for i in BAG_SIZE:
		var s3 := DmItemSlot.new()
		s3.index = i
		s3.custom_minimum_size = Vector2(45.5, 45.5)
		s3.pressed.connect(_on_slot_pressed)
		s3.double_clicked.connect(func(sl: DmItemSlot) -> void: equip_toggled.emit(sl.data))
		s3.right_clicked.connect(func(sl: DmItemSlot) -> void: slot_right_clicked.emit(sl.data))
		_grid.add_child(s3)
		_slots.append(s3)

	_tools = HFlowContainer.new()
	_tools.add_theme_constant_override("h_separation", 8)
	body.add_child(_tools)

	_detail_panel = PanelContainer.new()
	_detail_panel.theme_type_variation = "DmInset"
	var ds := DmUi.theme().get_stylebox("panel", "DmInset").duplicate() as StyleBoxFlat
	ds.content_margin_left = 12
	ds.content_margin_right = 12
	ds.content_margin_top = 8
	ds.content_margin_bottom = 8
	_detail_panel.add_theme_stylebox_override("panel", ds)
	# A fixed-height detail strip: the card and its buttons scroll inside it, so selecting items never resizes the window
	# (and never pushes bag slots out of view).
	_detail_panel.custom_minimum_size.y = DETAIL_H
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_scroll.custom_minimum_size.y = DETAIL_H - 16
	_detail_panel.add_child(_detail_scroll)
	_detail = HBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 14)
	_detail_scroll.add_child(_detail)
	body.add_child(_detail_panel)
	_error = DmUi.label("", "DmError")   # hidden while empty ([data-error]:empty)
	_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error.visible = false
	body.add_child(_error)
	refresh()


# --- data ---------------------------------------------------------------------------------------------------
func set_stats_line(chips: Array) -> void:
	if not _built:
		_build_ui()
	for c in _stats_row.get_children():
		c.queue_free()
	for chip in chips:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 4)
		var l := DmUi.label(String(chip.get("label", "")), "DmNumeric")
		l.add_theme_color_override("font_color", DmUi.BONE_300)
		h.add_child(l)
		var v := DmUi.label(str(chip.get("value", "")), "DmNumeric")
		h.add_child(v)
		if chip.get("plus", 0) != 0:
			var p := DmUi.label("+%s" % str(chip["plus"]), "DmNumeric")
			p.add_theme_color_override("font_color", DmUi.OK)
			h.add_child(p)
		_stats_row.add_child(h)


func set_inventory(bag_: Array, worn_: Dictionary, belt_: Dictionary) -> void:
	bag = bag_
	worn = worn_
	belt = belt_
	if not _built:
		_build_ui()
	if not sel_item.is_empty():
		# Follow the fresh card (a drunk flask or a partial sale changes quantity and row), or drop the selection if the item is gone.
		sel_item = _find(sel_item)
	refresh()


func _find(it: Dictionary) -> Dictionary:
	for b in bag:
		if not b.is_empty() and b.get("id", -1) == it.get("id", -2):
			return b
	for k in worn:
		if worn[k].get("id", -1) == it.get("id", -2):
			return worn[k]
	for k in belt:
		if belt[k].get("id", -1) == it.get("id", -2):
			return belt[k]
	return {}


func refresh() -> void:
	if not _built:
		return
	for i in BAG_SIZE:
		var d: Dictionary = bag[i] if i < bag.size() else {}
		_slots[i].set_item(d)
		_slots[i].drag_data = {"type": DmHudBrewChip.DRAG_TYPE, "item_id": d.get("item_id", "")} if drag_brews and d.get("is_brew", false) else null
		_slots[i].selected = not d.is_empty() and d.get("id", -1) == sel_item.get("id", -2)
	for id in _doll_slots:
		var s: DmItemSlot = _doll_slots[id]
		var d2: Dictionary = worn.get(id, {})
		if not d2.is_empty():
			d2["equipped"] = true
		s.set_item(d2)
		s.selected = not d2.is_empty() and d2.get("id", -1) == sel_item.get("id", -2)
	for k in _belt_slots:
		var s2: DmItemSlot = _belt_slots[k]
		var d3: Dictionary = belt.get(k, {})
		s2.set_item(d3)
		s2.selected = not d3.is_empty() and d3.get("id", -1) == sel_item.get("id", -2)
	_render_setsum()
	_render_tools()
	_render_detail()


func _render_setsum() -> void:
	if _setsum == null:
		return
	for c in _setsum.get_children():
		c.queue_free()
	_setsum.visible = not set_summary.is_empty()
	for st in set_summary:
		var accent: Color = st.get("accent", DmUi.GOLD)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 1)
		var hd := HBoxContainer.new()
		var nm := DmUi.label(String(st.get("name", "")), "DmNumeric")
		nm.add_theme_color_override("font_color", accent)
		hd.add_child(nm)
		var pips := String(" ").join((st.get("pips", []) as Array).map(func(on: bool) -> String: return "●" if on else "○"))
		var pl := DmUi.label(pips, "DmNumeric")
		pl.add_theme_color_override("font_color", accent)
		hd.add_child(pl)
		box.add_child(hd)
		for l in st.get("on", []):
			var ol := DmUi.label(String(l), "DmHint", true)
			ol.add_theme_font_size_override("font_size", 11)
			ol.add_theme_color_override("font_color", DmUi.BONE_100)
			box.add_child(ol)
		var nx := DmUi.label(String(st.get("next", "")), "DmHint", true)
		nx.add_theme_font_size_override("font_size", 11)
		box.add_child(nx)
		_setsum.add_child(box)


func _on_slot_pressed(sl: DmItemSlot) -> void:
	if sel_item.get("id", -1) == sl.data.get("id", -2):
		sel_item = {}
	else:
		sel_item = sl.data
	confirm_sell_all = ""
	refresh()
	selected.emit(sel_item)


# --- footer ---------------------------------------------------------------------------------------------------
func _small(text: String, on_press: Callable, disabled: bool = false, primary: bool = false) -> Button:
	var b := Button.new()
	b.theme_type_variation = "DmButtonSmallPrimary" if primary else "DmButtonSmall"
	b.text = DmUi.upper(text)
	b.disabled = disabled
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	return b


func _render_tools() -> void:
	if footer_extra != null and footer_extra.get_parent() == _tools:
		_tools.remove_child(footer_extra)
	for c in _tools.get_children():
		c.queue_free()
	var used := 0
	for d in bag:
		if not d.is_empty():
			used += 1
	if footer_extra != null and not confirm_junk:
		if footer_extra.get_parent() != null:
			footer_extra.get_parent().remove_child(footer_extra)
		_tools.add_child(footer_extra)
	if confirm_junk and junk_count > 0:
		var rt := RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.fit_content = true
		rt.scroll_active = false
		rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rt.add_theme_font_size_override("normal_font_size", 13)
		rt.add_theme_font_size_override("bold_font_size", 13)
		rt.add_theme_color_override("default_color", DmUi.BONE_100)
		rt.text = "Sell [b][color=#%s]%d[/color][/b] junk item%s (common and uncommon gear; locked items and upgrades for you are kept) for [b][color=#%s]%s[/color][/b]?" % [DmUi.GOLD.to_html(false), junk_count, "" if junk_count == 1 else "s", DmUi.GOLD.to_html(false), DmUi.gold(junk_gold)]
		_tools.add_child(rt)
		_tools.add_child(_small("Sell them", func() -> void:
			confirm_junk = false
			junk_sell_confirmed.emit()
			_render_tools()))
		_tools.add_child(_small("Cancel", func() -> void:
			confirm_junk = false
			_render_tools()))
		return
	var cnt := DmUi.label("%d / %d slots" % [used, BAG_SIZE], "DmMuted")
	cnt.add_theme_font_size_override("font_size", 13)
	cnt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tools.add_child(cnt)
	_tools.add_child(_small("Sort", func() -> void: sort_requested.emit(), used <= 1))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools.add_child(gap)
	if has_legion:
		var lb := _small("Legion · Y" + ("  ▲" if legion_flag else ""), func() -> void: legion_pressed.emit())
		if legion_flag:
			# .cw-legion-btn.flag: green border + green arrow, text stays bone
			var st := DmUi.theme().get_stylebox("normal", "DmButtonSmall").duplicate() as StyleBoxFlat
			st.border_color = DmUi.UP
			lb.add_theme_stylebox_override("normal", st)
		_tools.add_child(lb)
	if has_sell:
		var label := "Sell all junk" + (" (%d · %s)" % [junk_count, DmUi.gold(junk_gold)] if junk_count else "")
		_tools.add_child(_small(label, func() -> void:
			confirm_junk = true
			_render_tools(), junk_count == 0))


# --- detail strip ----------------------------------------------------------------------------------------------------
func _render_detail() -> void:
	for c in _detail.get_children():
		c.queue_free()
	if sel_item.is_empty():
		var h := DmUi.label("Select a relic. Double-click to equip, drink or eat.", "DmHint", true)
		h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_detail.add_child(h)
		return
	var it := sel_item
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card := DmItemCard.new()
	card.inline_head = true
	card.set_item(it, true, false)
	info.add_child(card)
	_detail.add_child(info)
	var acts := VBoxContainer.new()
	acts.custom_minimum_size.x = 148
	acts.add_theme_constant_override("separation", 5)
	_detail.add_child(acts)
	var equipped: bool = it.get("equipped", false)
	var locked: bool = it.get("locked", false)
	if it.get("equippable", true):
		acts.add_child(_full(_small("Unequip" if equipped else "Equip", func() -> void: equip_toggled.emit(it))))
	if extra_actions.is_valid():
		for a in extra_actions.call(it):
			var aid: String = a["id"]
			var ab := _small(String(a["label"]), func() -> void: action_requested.emit(aid, it), bool(a.get("disabled", false)), bool(a.get("primary", false)))
			ab.tooltip_text = String(a.get("hint", ""))
			acts.add_child(_full(ab))
	if not equipped:
		var lk := _small(("Unlock" if locked else "Lock"), func() -> void: lock_toggled.emit(it))
		if locked:
			lk.add_theme_color_override("font_color", DmUi.GOLD)
		var sv := _small("Salvage", func() -> void: salvage_requested.emit(it), not at_grinder)
		acts.add_child(_pair(lk, sv))
		if not at_grinder:
			var hint := DmUi.label("Needs the Bone Grinder (Acre)", "DmHint", true)
			hint.add_theme_font_size_override("font_size", 11)
			hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			acts.add_child(hint)
		if has_sell and int(it.get("sell_value", 0)) > 0:
			var q: int = int(it.get("quantity", 1))
			acts.add_child(_pair(_small("Sell (%dg)" % int(it["sell_value"]), func() -> void: sell_requested.emit(it, 1), locked), null))
			if q > 1:
				if confirm_sell_all == str(it.get("id")) and not locked:
					var cl := DmUi.label("Sell all %d %s for %s?" % [q, it.get("name", ""), DmUi.gold(int(it["sell_value"]) * q)], "DmHint", true)
					cl.add_theme_color_override("font_color", DmUi.BONE_100)
					acts.add_child(cl)
					acts.add_child(_pair(_small("Sell them", func() -> void:
						confirm_sell_all = ""
						sell_requested.emit(it, q), false, true), _small("Cancel", func() -> void:
						confirm_sell_all = ""
						_render_detail())))
				else:
					acts.add_child(_full(_small("Sell all (%d · %s)" % [q, DmUi.gold(int(it["sell_value"]) * q)], func() -> void:
						confirm_sell_all = str(it.get("id"))
						_render_detail(), locked)))


func _full(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_FILL
	return c


func _pair(a: Control, b: Control) -> Control:
	# two half-width buttons on one row (`.cw-detail-actions` is a 2-column grid)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 5)
	a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(a)
	var sp: Control = b if b != null else Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	return h


func set_error(text: String) -> void:
	if _error != null:
		_error.text = text
		_error.visible = text != ""
