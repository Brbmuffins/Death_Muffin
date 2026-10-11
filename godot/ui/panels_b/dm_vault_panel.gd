class_name DmVaultPanel
extends DmPanelB
## The Ossuary Vault (archive/legacy-web:src/ui/VaultPanel.ts): a 120-slot stash shared by every character on the account, beside the 48-slot Reliquary.
## Click an item to move its whole stack across; Shift+click (or Shift held on a drop) asks how many; drag a stack onto any bag or Vault cell to put it
## exactly there (rearranging within a side too: empty = move, same item = merge, else swap; vault.cjs /api/vault/move); worn-gear cells take Vault items into the bag. Tabs of 40 slots (DmVault.VAULT_SLOTS / VAULT_TAB_SIZE). Locked bag items are shown but
## never moved by the bulk buttons. Pure UI: the server reply is the truth, feed it back through set_state().
##
## Data in:  set_state(state)  state = GET /api/vault reply {bag:[rows], vault:[rows]}  (rows: {slot_index, item_id, name, rarity, item_type,
##           quantity, equipped 0/1, sell_value, inst?})   set_locks(locks) (DmItemLocks)   set_busy(bool)   set_note(text)   set_error(text)
##           potion_pick = DmGameUi.belt_pick(): which flask / brew Q / Z / X drink, for the look-only potion belt under the gear doll.
##           Until set_state() runs the vault shows "Opening the Vault…" and every action button is disabled.
## Signals:  deposit_requested(bag_slot)              -> DmApi.vault_deposit(character_id, bag_slot)
##           move_requested(from_side, from_slot, to_side, to_slot, qty) -> DmApi.vault_move (a drop on an exact cell; qty -1 = whole stack)
##           withdraw_requested(vault_slot)           -> DmApi.vault_withdraw(character_id, vault_slot)
##           deposit_part_requested(bag_slot, qty)    -> DmApi.vault_deposit(character_id, bag_slot, qty)   (Shift+click amount prompt)
##           withdraw_part_requested(vault_slot, qty) -> DmApi.vault_withdraw(character_id, vault_slot, qty)
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
signal deposit_part_requested(bag_slot: int, quantity: int)
## A drop on an exact cell (any bag or Vault cell, the same side rearranges) -> DmApi.vault_move; quantity -1 = the whole stack.
signal move_requested(from_side: String, from_slot: int, to_side: String, to_slot: int, quantity: int)
signal withdraw_part_requested(vault_slot: int, quantity: int)

const DRAG_TYPE := "vault_move"
const COLS := 8
const SLOT_PX := 44.0
const GRID_W := COLS * SLOT_PX + (COLS - 1) * 4.0
const GRID_H := 6 * SLOT_PX + 5 * 4.0        # the 48-slot bag grid: 6 rows
const BELT_PX := 39.0                         # a tool / potion belt cell, as in the Reliquary
const PREFIX_PX := 4 * BELT_PX + 3 * 5.0     # the gear column: as wide as the four tool cells
const VAULT_GRID_H := 5 * SLOT_PX + 4 * 4.0   # a Vault tab is 40 slots: 5 rows
const TAB_H := GRID_H - VAULT_GRID_H - 6.0    # tabs + grid together are exactly as tall as the bag grid
const SORT_ROW_PX := 34.0
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
var belt_slots: Dictionary = {}         # tool kind -> DmItemSlot (tool belt, look only)
var potion_slots: Dictionary = {}       # heal|elixir|tonic -> DmItemSlot (potion belt, look only)
var potion_pick: Dictionary = {}        # the player's chosen flask / brew per potion slot (DmGameUi.belt_pick()); set before set_state
var deposit_materials_button: Button
var take_materials_button: Button
var deposit_all_button: Button
var take_all_button: Button
var sort_button: Button
## Shift+click (or Shift held on a drop) asks how many: {from: "bag"|"vault", row}. Empty = no prompt.
var pending: Dictionary = {}
var pending_qty := 1
var shift_probe := Callable()           # () -> bool; tests swap it, default Input.is_key_pressed(KEY_SHIFT)
var qty_spin: SpinBox
var qty_move_button: Button
var _qty_typed := false   ## the amount box holds text the player typed that its value has not taken yet
## Drawn counts and state for tests: {bag_count, bag_total, vault_count, vault_total, tab_labels, locked_hint, loading}.
var shown: Dictionary = {}


func _init() -> void:
	super._init()
	title = "Ossuary Vault"
	panel_width = 1060


func set_state(s: Dictionary) -> void:
	state = s
	pending = {}
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
	add_child(DmPb.hint("One stash for every character on this account. Click an item to move its whole stack across, Shift+click to choose how many, or drag it between the Vault and your bag or worn gear. Locked items stay in your bag when you use the buttons below.", 12, DmUi.TEXT_MUTED))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 20)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(cols)

	var left := DmPb.vbox(6)
	cols.add_child(left)
	left.add_child(_section_head("Reliquary", "%d / %d" % [bag.size(), DmBag.BAG_SIZE]))
	var sort_outer := DmPb.hbox(12)   # Sort is centered above the bag grid, not above the gear column beside it
	sort_outer.custom_minimum_size.y = SORT_ROW_PX
	sort_outer.add_child(DmUi.spacer(0, PREFIX_PX))
	var sort_row := DmPb.hbox(8)
	sort_row.custom_minimum_size.x = GRID_W
	sort_row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	sort_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sort_outer.add_child(sort_row)
	left.add_child(sort_outer)
	var bag_row := HBoxContainer.new()
	bag_row.add_theme_constant_override("separation", 12)
	left.add_child(bag_row)
	bag_row.add_child(_gear_column())
	var bg := _grid()
	bag_row.add_child(bg)
	for i in DmBag.BAG_SIZE:
		var row: Dictionary = {}
		for s: Dictionary in bag:
			if int(s["slot_index"]) == i:
				row = s
		var cell := _cell(row, is_locked(row) if not row.is_empty() else false)
		if not row.is_empty():
			cell.press_on_release = true   # click moves on release; press-and-drag drags
			cell.pressed.connect(_on_bag_pressed.bind(row))
			if int(row.get("equipped", 0)) == 0:
				cell.drag_data = {"type": DRAG_TYPE, "from": "bag", "row": row}
		cell.accepts = _accepts_any   # any bag cell takes a stack from the bag (rearrange) or the Vault, into exactly that slot
		cell.dropped.connect(_on_dropped_at.bind("bag", i))
		bg.add_child(cell)
		bag_slots[i] = cell

	var right := DmPb.vbox(6)
	cols.add_child(right)
	right.add_child(_section_head("Vault", "%d / %d" % [vault.size(), DmVault.VAULT_SLOTS]))
	right.add_child(DmUi.spacer(SORT_ROW_PX))   # level with the Sort row on the bag side, so the tabs start where the bag grid starts
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
		b.custom_minimum_size = Vector2(0, TAB_H)
		b.pressed.connect(func() -> void: select_tab(t))
		tabs.add_child(b)
		tab_buttons.append(b)
	right.add_child(tabs)
	if not loaded:
		var wait := DmPb.hint("Opening the Vault…")
		wait.custom_minimum_size.y = VAULT_GRID_H
		right.add_child(wait)
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
				cell.press_on_release = true   # click moves on release; press-and-drag drags
				cell.pressed.connect(_on_vault_pressed.bind(row))
				cell.drag_data = {"type": DRAG_TYPE, "from": "vault", "row": row}
			cell.accepts = _accepts_any   # any Vault cell takes a stack from the bag or the Vault (rearrange), into exactly that slot
			cell.dropped.connect(_on_dropped_at.bind("vault", idx))
			vg.add_child(cell)
			vault_slots[idx] = cell

	if not pending.is_empty():
		add_child(_qty_row())

	var off := busy or not loaded
	var dep_row := DmPb.hbox(8)
	deposit_materials_button = DmPb.button("Deposit materials", false, off, "Stores every unlocked material and consumable in the Vault")
	deposit_materials_button.pressed.connect(func() -> void: deposit_all_requested.emit("materials", locked_slots()))
	deposit_all_button = DmPb.button("Deposit all", false, off, "Stores everything unlocked and not worn")
	deposit_all_button.pressed.connect(func() -> void: deposit_all_requested.emit("all", locked_slots()))
	dep_row.add_child(deposit_materials_button)
	dep_row.add_child(deposit_all_button)
	var dep_outer := DmPb.hbox(12)   # the Deposit row is centered under the bag grid, not under the gear doll beside it
	dep_outer.add_child(DmUi.spacer(0, PREFIX_PX))
	dep_row.custom_minimum_size.x = GRID_W
	dep_row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	dep_row.alignment = BoxContainer.ALIGNMENT_CENTER
	dep_outer.add_child(dep_row)
	left.add_child(dep_outer)
	var take_row := DmPb.hbox(8)
	take_row.custom_minimum_size.x = GRID_W
	take_row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	take_row.alignment = BoxContainer.ALIGNMENT_CENTER
	take_materials_button = DmPb.button("Take materials", false, off, "Takes every material and consumable from the open Vault tab into your bag, as far as it fits")
	take_materials_button.pressed.connect(_take.bind("materials"))
	take_all_button = DmPb.button("Take all", false, off, "Takes everything from the open Vault tab into your bag, as far as it fits")
	take_all_button.pressed.connect(_take.bind("all"))
	take_row.add_child(take_materials_button)
	take_row.add_child(take_all_button)
	right.add_child(take_row)
	sort_button = DmPb.button("Sort", false, off, "Sorts the Vault and your bag: merges stacks, then orders by type, rarity and name")
	sort_button.pressed.connect(func() -> void: sort_requested.emit())
	sort_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sort_row.add_child(sort_button)
	var lh := DmPb.text(shown["locked_hint"], 12, DmUi.TEXT_FAINT)
	lh.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(lh)
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


## The Reliquary's gear column: the paper doll, then the tool belt (hatchet, pickaxe, rod, spade) and the potion belt (Heal Q, Elixir Z, Tonic X).
## Look only, like the doll: the cells show what is worn and belted and do nothing when clicked.
func _gear_column() -> Control:
	var col := DmPb.vbox(6)
	col.custom_minimum_size.x = PREFIX_PX
	col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	col.add_child(_doll(DmGear.equipped_by_slot(state.get("bag", []))))
	col.add_child(DmUi.hrule())
	belt_slots.clear()
	potion_slots.clear()
	var tools := belt_rows()
	var tr := DmPb.hbox(5)
	for b: Array in DmReliquaryPanel.BELT:
		var c := _belt_cell(String(b[1]), tools.get(b[0], {}))
		tr.add_child(c)
		belt_slots[b[0]] = c
	col.add_child(tr)
	var brews := potion_rows()
	var pr := DmPb.hbox(5)
	for p: Array in DmReliquaryPanel.POTION_BELT:
		var c := _belt_cell("%s · %s" % [p[1], p[2]], brews.get(p[0], {}))
		pr.add_child(c)
		potion_slots[p[0]] = c
	col.add_child(pr)
	return col


func _belt_cell(label: String, row: Dictionary) -> DmItemSlot:
	var c := DmItemSlot.new()
	c.kind = DmItemSlot.Kind.BELT
	c.empty_label = label
	c.custom_minimum_size = Vector2(BELT_PX, BELT_PX)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.plain_tip = true
	if not row.is_empty():
		c.set_item(slot_data(row, false))
		c.tooltip_text = plain_title(row, false, "look")
	return c


## Tool-belt rows by kind (hatchet|pickaxe|rod|spade): the reply's bag rows that sit in the belt slots.
func belt_rows() -> Dictionary:
	var out := {}
	for s: Dictionary in state.get("bag", []):
		var kind := DmGathering.belt_slot_kind(int(s["slot_index"]))
		if kind != "" and int(s.get("quantity", 0)) > 0:
			out[kind] = s
	return out


func _bag_count(item_id: String) -> int:
	var n := 0
	for s: Dictionary in bag_rows():
		if s["item_id"] == item_id:
			n += int(s["quantity"])
	return n


## What Q / Z / X drink: the picked flask or brew while the bag holds it, else the best flask / first brew of that slot (the Reliquary's rule),
## as bag rows with the stack's total count.
func potion_rows() -> Dictionary:
	var out := {}
	for slot in DmPotionBelt.SLOT_IDS:
		var want := ""
		var chosen: Variant = potion_pick.get(slot)
		if chosen is String and _bag_count(chosen) > 0:
			want = chosen
		elif slot == "heal":
			want = DmPotionBelt.heal_pick(_bag_count)
		else:
			for id in DmContent.brews():
				if DmContent.brews()[id]["slot"] == slot and _bag_count(id) > 0:
					want = id
					break
		if want == "":
			continue
		for s: Dictionary in bag_rows():
			if s["item_id"] == want:
				var r := s.duplicate()
				r["quantity"] = _bag_count(want)
				out[slot] = r
				break
	return out


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
		c.accepts = _accepts.bind("vault")   # dropping a Vault item on worn gear takes it into the bag (no auto-equip)
		c.dropped.connect(_on_dropped)
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
	if kind == "look":
		t = t.trim_suffix("\n")
	elif int(row.get("equipped", 0)) != 0:
		t += "Equipped gear cannot be stored"
	else:
		t += ("Click to store it in the Vault" if kind == "bag" else "Click to take it into your bag") + ", Shift+click for part, or drag it"
	return t


func _on_bag_pressed(_cell_node: DmItemSlot, row: Dictionary) -> void:
	if busy or state.is_empty():
		return
	if int(row.get("equipped", 0)) != 0:
		set_error("Equipped gear cannot be stored. Unequip it first.")
		return
	_move("bag", row, _shift())


func _on_vault_pressed(_cell_node: DmItemSlot, row: Dictionary) -> void:
	if busy or state.is_empty():
		return
	_move("vault", row, _shift())


func _shift() -> bool:
	return bool(shift_probe.call()) if shift_probe.is_valid() else Input.is_key_pressed(KEY_SHIFT)


## `from` is where the stack is now. Shift on a stack of 2 or more asks how many; otherwise the whole stack goes.
func _move(from: String, row: Dictionary, ask: bool) -> void:
	if ask and int(row.get("quantity", 1)) > 1:
		pending = {"from": from, "row": row}
		pending_qty = int(row["quantity"])
		rebuild()
		return
	if from == "bag":
		deposit_requested.emit(int(row["slot_index"]))
	else:
		withdraw_requested.emit(int(row["slot_index"]))


## A drag is welcome on the far side only (`from` = where the dragged stack must come from): Vault items onto the bag or worn gear, bag items onto the Vault.
func _accepts(_cell_node: DmItemSlot, payload: Variant, from: String) -> bool:
	return not busy and not state.is_empty() and payload is Dictionary and payload.get("type", "") == DRAG_TYPE and payload.get("from", "") == from


func _accepts_any(_cell_node: DmItemSlot, payload: Variant) -> bool:
	return not busy and not state.is_empty() and payload is Dictionary and payload.get("type", "") == DRAG_TYPE


## A stack dropped on an exact bag or Vault cell: moves there (empty), merges (same item) or swaps (anything else). Shift asks how many.
func _on_dropped_at(_cell_node: DmItemSlot, payload: Variant, to_side: String, to_slot: int) -> void:
	if busy or state.is_empty() or not (payload is Dictionary):
		return
	var from := String(payload["from"])
	var row: Dictionary = payload["row"]
	var from_slot := int(row["slot_index"])
	if from == to_side and from_slot == to_slot:
		return
	if _shift() and int(row.get("quantity", 1)) > 1:
		pending = {"from": from, "row": row, "to_side": to_side, "to_slot": to_slot}
		pending_qty = int(row["quantity"])
		rebuild()
		return
	move_requested.emit(from, from_slot, to_side, to_slot, -1)


func _on_dropped(_cell_node: DmItemSlot, payload: Variant) -> void:
	if busy or state.is_empty() or not (payload is Dictionary):
		return
	_move(String(payload["from"]), payload["row"], _shift())


func _qty_row() -> Control:
	var row: Dictionary = pending["row"]
	var h := DmPb.hbox(8)
	h.name = "QtyRow"
	h.add_child(DmPb.text("Move how many %s?" % row.get("name", "items"), 13, DmUi.TEXT))
	qty_spin = SpinBox.new()
	qty_spin.min_value = 1
	qty_spin.max_value = int(row["quantity"])
	qty_spin.value = clampi(pending_qty, 1, int(row["quantity"]))
	qty_spin.value_changed.connect(func(v: float) -> void: pending_qty = int(v))
	_qty_typed = false
	qty_spin.get_line_edit().text_changed.connect(func(_t: String) -> void: _qty_typed = true)   # typed by the player (not set by code)
	qty_spin.get_line_edit().text_submitted.connect(func(_t: String) -> void: confirm_pending())   # Enter moves the typed amount
	h.add_child(qty_spin)
	h.add_child(DmPb.text("of %d" % int(row["quantity"]), 12, DmUi.TEXT_FAINT, "numeric"))
	qty_move_button = DmPb.button("Move", true, busy)
	qty_move_button.pressed.connect(confirm_pending)
	h.add_child(qty_move_button)
	var cancel := DmPb.button("Cancel")
	cancel.pressed.connect(func() -> void:
		pending = {}
		rebuild())
	h.add_child(cancel)
	return h


func confirm_pending() -> void:
	if pending.is_empty() or busy:
		return
	# A typed amount only reaches the SpinBox's value on Enter or focus loss, and the Move button takes no focus: commit it first (2026-10-10:
	# typing 3 and clicking Move moved the whole stack).
	if qty_spin != null and _qty_typed:
		qty_spin.apply()
	var from := String(pending["from"])
	var slot := int(pending["row"]["slot_index"])
	var n := clampi(int(qty_spin.value) if qty_spin != null else pending_qty, 1, int(pending["row"]["quantity"]))
	var to: Dictionary = pending
	pending = {}
	if to.has("to_side"):   # a Shift-drop on an exact cell
		move_requested.emit(from, slot, String(to["to_side"]), int(to["to_slot"]), n)
		return
	if from == "bag":
		deposit_part_requested.emit(slot, n)
	else:
		withdraw_part_requested.emit(slot, n)


func _take(kind: String) -> void:
	var slots := take_slots(kind)
	if slots.is_empty():
		set_error("This tab holds no materials to take." if kind == "materials" else "This tab is empty.")
		return
	take_all_requested.emit(kind, slots)
