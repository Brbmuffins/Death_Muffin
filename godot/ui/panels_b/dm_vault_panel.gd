class_name DmVaultPanel
extends DmPanelB
## The Ossuary Vault (archive/legacy-web:src/ui/VaultPanel.ts): a 120-slot stash shared by every character on the account, beside the 48-slot Reliquary.
## Click an item to move its whole stack across. Tabs of 40 slots (DmVault.VAULT_SLOTS / VAULT_TAB_SIZE). Locked bag items are shown but
## never moved by the bulk buttons. Pure UI: the server reply is the truth, feed it back through set_state().
##
## Data in:  set_state(state)  state = GET /api/vault reply {bag:[rows], vault:[rows]}  (rows: {slot_index, item_id, name, rarity, item_type,
##           quantity, equipped 0/1, sell_value, inst?})   set_locks(locks) (DmItemLocks)   set_busy(bool)   set_note(text)   set_error(text)
##           Until set_state() runs the vault shows "Opening the Vault…" and every action button is disabled.
## Signals:  deposit_requested(bag_slot)              -> DmApi.vault_deposit(character_id, bag_slot)
##           withdraw_requested(vault_slot)           -> DmApi.vault_withdraw(character_id, vault_slot)
##           deposit_all_requested(kind, except_slots)-> DmApi.vault_deposit_all(character_id, kind "materials"|"all", except_slots)
##           take_all_requested(kind, vault_slots)    -> DmApi.vault_withdraw once per listed slot, in order; stop at the first stack that does not
##                                                       fit and report "Took what fit. <reason>" (the web's withdrawAll loop)
##           sort_requested                           -> DmApi.vault_sort(character_id)
##           Every one runs inside the inventory-exclusive guard and adopts reply.bag.

signal deposit_requested(bag_slot: int)
signal withdraw_requested(vault_slot: int)
signal deposit_all_requested(kind: String, except_slots: Array)
signal take_all_requested(kind: String, vault_slots: Array)
signal sort_requested

const COLS := 8
const SLOT_PX := 44.0
const TYPE_LABEL := {
	"weapon": "weapon", "offhand": "off hand", "armor_head": "head armor", "armor_chest": "chest armor", "armor_legs": "legs armor",
	"armor_feet": "feet armor", "armor_hands": "hand armor", "ring": "ring", "trinket": "trinket", "rune": "rune",
	"consumable": "consumable", "material": "material",
}

var state: Dictionary = {}
var locks: Object = null
var busy := false
var note := ""
var tab := 0
var tab_buttons: Array[Button] = []
var bag_slots: Dictionary = {}          # bag slot_index -> DmItemSlot
var vault_slots: Dictionary = {}        # vault slot_index -> DmItemSlot
var doll_slots: Dictionary = {}         # equip slot id -> DmItemSlot (worn gear, look only)
var deposit_materials_button: Button
var take_materials_button: Button
var deposit_all_button: Button
var take_all_button: Button
var sort_button: Button
## Drawn counts and state for tests: {bag_count, bag_total, vault_count, vault_total, tab_labels, locked_hint, loading}.
var shown: Dictionary = {}


func _init() -> void:
	super._init()
	title = "Ossuary Vault"
	panel_width = 1060


func set_state(s: Dictionary) -> void:
	state = s
	rebuild()


func set_locks(l: Object) -> void:
	locks = l
	rebuild()


func set_busy(v: bool) -> void:
	busy = v
	rebuild()


func set_note(t: String) -> void:
	note = t
	error_text = ""
	rebuild()


func select_tab(t: int) -> void:
	tab = clampi(t, 0, tab_count() - 1)
	rebuild()


static func tab_count() -> int:
	return ceili(float(DmVault.VAULT_SLOTS) / float(DmVault.VAULT_TAB_SIZE))


func bag_rows() -> Array:
	var out: Array = []
	for s: Dictionary in state.get("bag", []):
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < DmBag.BAG_SIZE:
			out.append(s)
	return out


func is_locked(s: Dictionary) -> bool:
	return locks != null and locks.is_locked(s)


func locked_slots() -> Array:
	return locks.slots_of(bag_rows()) if locks != null else []


## The tab's vault stacks a "Take" button moves: everything, or materials / consumables / runes only.
func take_slots(kind: String) -> Array:
	var lo := tab * DmVault.VAULT_TAB_SIZE
	var out: Array = []
	for s: Dictionary in state.get("vault", []):
		var i := int(s["slot_index"])
		if i >= lo and i < lo + DmVault.VAULT_TAB_SIZE and (kind == "all" or ["material", "consumable", "rune"].has(s["item_type"])):
			out.append(i)
	return out


## DmItemSlot data for a server row (real item art via DmUiArt, glyph when it is missing).
static func slot_data(s: Dictionary, locked: bool) -> Dictionary:
	var d := s.duplicate()
	d["equipped"] = int(s.get("equipped", 0)) != 0
	d["locked"] = locked
	d["glyph"] = "◆"
	var ic := DmUiArt.item(String(s.get("item_id", "")))   # the real item art; the glyph shows only when the file is missing
	if ic != null:
		d["icon"] = ic
	d["type_label"] = TYPE_LABEL.get(String(s.get("item_type", "")), String(s.get("item_type", "")))
	if s.get("inst") != null:
		d["ilvl"] = s["inst"]["ilvl"]
		d["affix_count"] = s["inst"]["affixes"].size()
	return d


func _build() -> void:
	tab_buttons.clear()
	bag_slots.clear()
	vault_slots.clear()
	var loaded := not state.is_empty()
	var bag := bag_rows()
	var vault: Array = state.get("vault", [])
	var tab_used := func(t: int) -> int:
		var n := 0
		for v: Dictionary in vault:
			if int(v["slot_index"]) >= t * DmVault.VAULT_TAB_SIZE and int(v["slot_index"]) < (t + 1) * DmVault.VAULT_TAB_SIZE:
				n += 1
		return n
	var locked := locked_slots()
	shown = {"bag_count": bag.size(), "bag_total": DmBag.BAG_SIZE, "vault_count": vault.size(), "vault_total": DmVault.VAULT_SLOTS, "tab_labels": [], "loading": not loaded,
		"locked_hint": ("%d locked item%s stay%s put" % [locked.size(), "" if locked.size() == 1 else "s", "s" if locked.size() == 1 else ""]) if locked.size() > 0 else "Lock items in the Reliquary (I) to keep them out of the bulk buttons"}
	add_child(DmPb.hint("One stash for every character on this account. Click an item to move its whole stack across. Locked items stay in your bag when you use the buttons below.", 12, DmUi.TEXT_MUTED))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 20)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(cols)

	var left := DmPb.vbox(6)
	cols.add_child(left)
	left.add_child(_section_head("Reliquary", "%d / %d" % [bag.size(), DmBag.BAG_SIZE]))
	var bag_row := HBoxContainer.new()
	bag_row.add_theme_constant_override("separation", 12)
	left.add_child(bag_row)
	bag_row.add_child(_doll(DmGear.equipped_by_slot(state.get("bag", []))))
	var bg := _grid()
	bag_row.add_child(bg)
	for i in DmBag.BAG_SIZE:
		var row: Dictionary = {}
		for s: Dictionary in bag:
			if int(s["slot_index"]) == i:
				row = s
		var cell := _cell(row, is_locked(row) if not row.is_empty() else false)
		if not row.is_empty():
			cell.pressed.connect(_on_bag_pressed.bind(row))
		bg.add_child(cell)
		bag_slots[i] = cell

	var right := DmPb.vbox(6)
	cols.add_child(right)
	right.add_child(_section_head("Vault", "%d / %d" % [vault.size(), DmVault.VAULT_SLOTS]))
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	tabs.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tabs.custom_minimum_size.x = COLS * SLOT_PX + (COLS - 1) * 4   # as wide as the vault grid below
	for t in tab_count():
		var lbl := "Tab %d  %d/%d" % [t + 1, tab_used.call(t), DmVault.VAULT_TAB_SIZE]
		(shown["tab_labels"] as Array).append(lbl)
		var b := DmPb.button(lbl, t == tab)
		b.toggle_mode = false
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 32)
		b.pressed.connect(func() -> void: select_tab(t))
		tabs.add_child(b)
		tab_buttons.append(b)
	right.add_child(tabs)
	if not loaded:
		right.add_child(DmPb.hint("Opening the Vault…"))
	else:
		var vg := _grid()
		right.add_child(vg)
		for i in DmVault.VAULT_TAB_SIZE:
			var idx := tab * DmVault.VAULT_TAB_SIZE + i
			var row: Dictionary = {}
			for v: Dictionary in vault:
				if int(v["slot_index"]) == idx:
					row = v
			var cell := _cell(row, false, "vault")
			if not row.is_empty():
				cell.pressed.connect(_on_vault_pressed.bind(row))
			vg.add_child(cell)
			vault_slots[idx] = cell

	var acts := HFlowContainer.new()
	acts.add_theme_constant_override("h_separation", 8)
	acts.add_theme_constant_override("v_separation", 6)
	add_child(acts)
	var off := busy or not loaded
	var c1 := DmPb.vbox(6)
	c1.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	deposit_materials_button = DmPb.button("Deposit materials", false, off, "Stores every unlocked material and consumable in the Vault")
	deposit_materials_button.pressed.connect(func() -> void: deposit_all_requested.emit("materials", locked_slots()))
	take_materials_button = DmPb.button("Take materials", false, off, "Takes every material and consumable from the open Vault tab into your bag, as far as it fits")
	take_materials_button.pressed.connect(_take.bind("materials"))
	c1.add_child(deposit_materials_button)
	c1.add_child(take_materials_button)
	var c2 := DmPb.vbox(6)
	c2.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	deposit_all_button = DmPb.button("Deposit all", false, off, "Stores everything unlocked and not worn")
	deposit_all_button.pressed.connect(func() -> void: deposit_all_requested.emit("all", locked_slots()))
	take_all_button = DmPb.button("Take all", false, off, "Takes everything from the open Vault tab into your bag, as far as it fits")
	take_all_button.pressed.connect(_take.bind("all"))
	c2.add_child(deposit_all_button)
	c2.add_child(take_all_button)
	acts.add_child(c1)
	acts.add_child(c2)
	sort_button = DmPb.button("Sort", false, off, "Merges stacks, then orders by type, rarity and name")
	sort_button.pressed.connect(func() -> void: sort_requested.emit())
	sort_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	acts.add_child(sort_button)
	acts.add_child(DmPb.text(shown["locked_hint"], 12, DmUi.TEXT_FAINT))
	var nl := DmPb.text(note, 12, DmUi.OK)
	nl.name = "Note"
	nl.custom_minimum_size.y = 18
	add_child(nl)
	_error_row()


func _section_head(t: String, count: String) -> Control:
	var h := DmPb.hbox(8)
	h.add_child(DmPb.grow(DmPb.section_title(t)))
	h.add_child(DmPb.text(count, 12, DmUi.TEXT_FAINT, "numeric"))
	return h


func _grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = COLS
	g.add_theme_constant_override("h_separation", 4)
	g.add_theme_constant_override("v_separation", 4)
	return g


## The worn gear, laid out like the Reliquary's paper doll. Look only: worn gear cannot be stored, so the cells do nothing when clicked.
func _doll(worn: Dictionary) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 4)
	g.add_theme_constant_override("v_separation", 4)
	g.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	doll_slots.clear()
	for id: String in DmReliquaryPanel.DOLL:
		if not DmReliquaryPanel.EQUIP.has(id):
			g.add_child(DmUi.spacer(SLOT_PX, SLOT_PX))
			continue
		var c := DmItemSlot.new()
		c.kind = DmItemSlot.Kind.EQUIP
		c.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
		c.empty_glyph = DmReliquaryPanel.EQUIP[id][1]
		c.empty_label = DmReliquaryPanel.EQUIP[id][0]
		c.plain_tip = true
		if worn.has(id):
			c.set_item(slot_data(worn[id], false))
			c.tooltip_text = plain_title(worn[id], false, "bag")
		g.add_child(c)
		doll_slots[id] = c
	return g


func _cell(row: Dictionary, locked: bool, kind: String = "bag") -> DmItemSlot:
	var c := DmItemSlot.new()
	c.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
	c.plain_tip = true
	if not row.is_empty():
		c.set_item(slot_data(row, locked))
		c.tooltip_text = plain_title(row, locked, kind)
	return c


## VaultPanel.cell's `btn.title`: what the Reliquary card would say in plain text (kind, base stats, the roll, the price) and the move.
static func plain_title(row: Dictionary, locked: bool, kind: String) -> String:
	var q := int(row.get("quantity", 1))
	var t := "%s%s (%s %s)%s\n" % [row.get("name", ""), " ×%d" % q if q > 1 else "", row.get("rarity", ""), DmItemText.type_label(row), " · locked" if locked else ""]
	var sb: Variant = row.get("stat_bonus")
	if sb is Dictionary:
		var parts: Array = []
		for k in ["stat_str", "stat_agi", "stat_int", "stat_vit"]:
			if sb.get(k) != null and float(sb[k]) != 0.0:
				parts.append("+%s %s" % [DmJsFmt.num_str(float(sb[k])), DmGearStats.STAT_LABELS[k]])
		if not parts.is_empty():
			t += ", ".join(parts) + "\n"
	for l in DmAffixes.roll_title_lines(row):
		t += String(l) + "\n"
	if String(row.get("item_type", "")) == "rune":
		var r := DmContent.rune(String(row.get("item_id", "")))
		if not r.is_empty():
			t += "%s: %s\n" % [r["short"], r["lines"][0]]
	if int(row.get("sell_value", 0)) > 0:
		t += "Worth %sg%s\n" % [DmJsFmt.num_str(float(row["sell_value"])), " each" if q > 1 else ""]
	if int(row.get("equipped", 0)) != 0:
		t += "Equipped gear cannot be stored"
	else:
		t += "Click to store it in the Vault" if kind == "bag" else "Click to take it into your bag"
	return t


func _on_bag_pressed(_cell_node: DmItemSlot, row: Dictionary) -> void:
	if busy or state.is_empty():
		return
	if int(row.get("equipped", 0)) != 0:
		set_error("Equipped gear cannot be stored. Unequip it first.")
		return
	deposit_requested.emit(int(row["slot_index"]))


func _on_vault_pressed(_cell_node: DmItemSlot, row: Dictionary) -> void:
	if busy or state.is_empty():
		return
	withdraw_requested.emit(int(row["slot_index"]))


func _take(kind: String) -> void:
	var slots := take_slots(kind)
	if slots.is_empty():
		set_error("This tab holds no materials to take." if kind == "materials" else "This tab is empty.")
		return
	take_all_requested.emit(kind, slots)
