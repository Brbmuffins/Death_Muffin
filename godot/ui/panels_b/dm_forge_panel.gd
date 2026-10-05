class_name DmForgePanel
extends DmTabbedWindow
## The Ossuary Workbench and the Sexton's Acre stations (src/ui/ForgePanel.ts): a profession's recipes with ingredient counts, a quantity picker and
## Craft. Recipes are the server's GET /api/recipes rows (the same dictionary shape DmRecipes.for_skill returns also works). Every number that
## decides what is craftable comes from DmRecipes (has_skill_and_materials, max_craftable, clamp_craft_qty).
##
## Build:    setup(station, has_reforge)  once, BEFORE add_child: station "" = the Workbench (every rite + Reforge when has_reforge),
##           "kiln" | "sawpit" | "fire" | "cauldron" = that station locked to its rites.
## Data in:  set_recipes(tab, rows)   rows = DmApi.get_recipes(prof) reply (tab "tools" = the "mining" rows; the panel keeps only smith_* for it and drops them elsewhere)
##           set_professions(rows)    [{profession_id, skill_level, skill_xp}]     set_bag(slots)  bag rows (item_id, quantity, slot_index, equipped)
##           set_only_craftable(on)   set_busy(on, recipe_id, status)   set_error(text)   set_bonus_claimed(bool) (cauldron's brew of the day)
##           reforge (Workbench only): `reforge` is a DmReforgeView (set_pieces/set_gold/set_counts on it).
## Signals:  recipes_requested(profession)       -> DmApi.get_recipes(profession) + DmApi.get_professions(character_id), on opening and on every tab change
##           craft_requested(recipe_id, qty)     -> qty x DmApi.craft(character_id, recipe_id) inside the inventory-exclusive guard, stop at the first error
##                                                 (shown verbatim: set_error), then DmApi.get_inventory + DmApi.get_professions
##           only_craftable_changed(on)          -> DmAccountPrefs.save_one(api, PREF_ONLY_CRAFTABLE, on) (+ the local copy)
##           quote_requested / reforge_requested -> forwarded from `reforge` (see DmReforgeView)

signal recipes_requested(profession: String)
signal craft_requested(recipe_id: String, qty: int)
signal only_craftable_changed(on: bool)
signal quote_requested
signal reforge_requested(slot_index: int, affix_index: int, expect_cost: int)

const PROFESSIONS := ["mining", "tools", "fishing", "woodcutting", "gravedigging", "alchemy"]
const LABEL := {"mining": "Smelting", "tools": "Tools", "fishing": "Cooking", "woodcutting": "Coffin-wood", "gravedigging": "Bonework", "alchemy": "Alchemy", "reforge": "Reforge"}
const STATIONS := {
	"kiln": {"title": "Bone Kiln", "tabs": ["mining", "tools", "gravedigging"], "blurb": "Smelt ore into ingots, forge gathering tools, and grind bones into bone meal."},
	"sawpit": {"title": "Sawpit", "tabs": ["woodcutting"], "blurb": "Saw logs into planks, staves and bows."},
	"cauldron": {"title": "The Great Cauldron", "tabs": ["alchemy"], "blurb": "Brew herbs and reagents into flasks, tonics and elixirs. Today's pick brews one extra the first time you make it here."},
	"fire": {"title": "Cooking Fire", "tabs": ["fishing"], "blurb": "Cook fish into meals, and render fillets into tinctures and flasks."},
}

var station := ""
var tabs_ids: Array[String] = []
var recipes: Dictionary = {}       # tab -> Array of recipe rows (after the tools filter)
var professions: Array = []
var bag: Array = []
var only_craftable := false
var busy := false
var busy_recipe := ""
var status := ""
var qty: Dictionary = {}           # recipe id -> picked quantity (session only)
var bonus_claimed := false
var day_key_override := ""         # test hook: the UTC day for the brew of the day
var reforge: DmReforgeView
var errors: Dictionary = {}        # tab -> text
var _lists: Dictionary = {}        # tab -> VBox of recipe rows
var _hints: Dictionary = {}        # tab -> wing hint holder
var _checks: Dictionary = {}       # tab -> CheckBox
var _errs: Dictionary = {}         # tab -> Label
## Drawn rows of the active tab: {id, name, req, skill_ok, ingredients: [{text, ok}], max, qty, craft_text, craft_enabled, step_enabled, botd}.
var rows: Array[Dictionary] = []
var hint_text := ""
var empty_text := ""
var craft_buttons: Dictionary = {}
var qty_inputs: Dictionary = {}
var max_buttons: Dictionary = {}


func _init() -> void:
	super._init()
	panel_width = 720


## Build the tab set (call once, before the window enters the tree).
func setup(station_id: String = "", has_reforge: bool = false) -> void:
	station = station_id
	var st: Dictionary = STATIONS.get(station_id, {})
	tabs_ids.clear()
	var list: Array = st["tabs"] if not st.is_empty() else PROFESSIONS.duplicate()
	if st.is_empty() and has_reforge:
		list.append("reforge")
	for t in list:
		tabs_ids.append(String(t))
	title = String(st["title"]) if not st.is_empty() else "Ossuary Workbench"
	aka = "" if not st.is_empty() else "Craft · C"
	set_title(title, aka)
	if not st.is_empty():
		var bl := DmPb.hint(String(st["blurb"]))
		var m := DmPb.margin(bl, DmWindow.PAD_X, 10, DmWindow.PAD_X, 0)
		strip_slot.add_child(m)
		strip_slot.move_child(m, 0)
	for t in tabs_ids:
		if t == "reforge":
			reforge = DmReforgeView.new()
			reforge.quote_requested.connect(func() -> void: quote_requested.emit())
			reforge.reforge_requested.connect(func(a: int, b: int, c: int) -> void: reforge_requested.emit(a, b, c))
			add_tab(t, LABEL[t], reforge)
		else:
			var col := DmPb.vbox(8)
			var top := HBoxContainer.new()
			top.alignment = BoxContainer.ALIGNMENT_END
			var cb := CheckBox.new()
			cb.text = "Only show craftable"
			cb.tooltip_text = "Hide every recipe you lack the skill or materials for. Applies to every crafting page."
			cb.focus_mode = Control.FOCUS_NONE
			cb.add_theme_font_size_override("font_size", 14)
			cb.toggled.connect(_on_only_toggled)
			top.add_child(cb)
			col.add_child(top)
			var hint_holder := DmPb.vbox(0)
			col.add_child(hint_holder)
			var list_box := DmPb.vbox(8)
			col.add_child(list_box)
			var err := DmUi.label("", "DmError", true)
			err.visible = false
			col.add_child(err)
			_checks[t] = cb
			_hints[t] = hint_holder
			_lists[t] = list_box
			_errs[t] = err
			add_tab(t, LABEL[t], col)
	if tabs_ids.size() <= 1 and _strip != null:
		_strip.get_parent().visible = false
	tab_changed.connect(_on_tab)
	_render()


## The kit's tab group only un-presses the old tab on a click; a programmatic select must do it too.
func select_tab(id: String) -> void:
	super.select_tab(id)
	for k: String in _tabs:
		(_tabs[k]["btn"] as Button).set_pressed_no_signal(k == id)


## Opening asks the game for recipes, bag, professions... and each answer used to redraw every row (5 full rebuilds, ~0.5 s):
## redraws requested while opening collapse into one.
var _hold := 0
var _dirty := false

func open() -> void:
	_hold += 1
	super.open()
	_request_current()
	_hold -= 1
	if _hold == 0 and _dirty:
		_render()


func current_profession() -> String:
	return "mining" if active == "tools" else active


func _request_current() -> void:
	if active == "reforge":
		quote_requested.emit()
	elif active != "":
		recipes_requested.emit(current_profession())


func _on_tab(id: String) -> void:
	if visible:
		_request_current()
	_render()


func _on_only_toggled(on: bool) -> void:
	set_only_craftable(on, true)


func set_only_craftable(on: bool, from_ui: bool = false) -> void:
	only_craftable = on
	for t: String in _checks:
		(_checks[t] as CheckBox).set_pressed_no_signal(on)
	if from_ui:
		only_craftable_changed.emit(on)
	_render()


static func is_tool(id: String) -> bool:
	return id.begins_with("smith_")


func set_recipes(tab: String, rows_in: Array) -> void:
	recipes[tab] = rows_in.filter(func(r: Dictionary) -> bool: return (tab == "tools") == is_tool(String(r["id"])))
	_render()


func set_professions(rows_in: Array) -> void:
	professions = rows_in
	_render()


func set_bag(slots: Array) -> void:
	bag = slots
	_render()


func set_busy(on: bool, recipe_id: String = "", status_text: String = "") -> void:
	busy = on
	busy_recipe = recipe_id if on else ""
	status = status_text
	_render()


func set_bonus_claimed(v: bool) -> void:
	bonus_claimed = v
	_render()


func set_error(msg: String) -> void:
	errors[active] = msg
	_render()


# --- rules -------------------------------------------------------------------------------------------------------
static func prof_of(r: Dictionary) -> String:
	return String(r.get("profession_id", r.get("skill", "")))


func skill_of(profession: String) -> int:
	for p: Dictionary in professions:
		if p["profession_id"] == profession:
			return int(p["skill_level"])
	return 1   # no row yet = level 1, as the server's craft check treats it


func count_of(item_id: String) -> int:
	var n := 0
	for s: Dictionary in bag:
		if s.get("item_id") == item_id:
			n += int(s.get("quantity", 0))
	return n


static func stack_of(item_id: String) -> int:
	var m := DmGatherData.item_meta(item_id)
	return int(m.get("stack", 1 << 60)) if m.get("type") == "material" else 1


func can_craft(r: Dictionary) -> bool:
	return DmRecipes.has_skill_and_materials(_norm(r), skill_of(prof_of(r)), count_of)


## Most this recipe can be made right now (materials and bag room).
func max_for(r: Dictionary) -> int:
	return DmRecipes.max_craftable(_norm(r), bag, DmBag.BAG_SIZE, stack_of)


func effective_qty(r: Dictionary, max_n: int) -> int:
	return maxi(1, mini(int(qty.get(r["id"], 1)), max_n if max_n > 0 else 1))


func _norm(r: Dictionary) -> Dictionary:
	if r.has("skill"):
		return r
	var d := r.duplicate()
	d["skill"] = prof_of(r)
	return d


## content/wing.ts brewOfTheDay: FNV-1a over the UTC day, picking from the first eight reagent brews.
static func brew_of_the_day(day: String) -> Dictionary:
	var h := 2166136261
	for i in day.length():
		h = ((h ^ day.unicode_at(i)) * 16777619) & 0xFFFFFFFF
	var list: Array = DmDb.content_export("reagents", "REAGENT_BREW_LIST")
	var entry: Array = list[h % mini(8, list.size())]
	return {"recipeId": entry[1]["recipe"]["id"], "brewId": entry[0], "name": entry[1]["name"]}


func today() -> String:
	return day_key_override if day_key_override != "" else Time.get_date_string_from_system(true)


# --- drawing -----------------------------------------------------------------------------------------------------
func _render() -> void:
	if _hold > 0:
		_dirty = true
		return
	_dirty = false
	if not _lists.has(active):
		rows.clear()
		return
	rows.clear()
	craft_buttons.clear()
	qty_inputs.clear()
	max_buttons.clear()
	var box := _lists[active] as VBoxContainer
	DmPb.clear(box)
	var holder := _hints[active] as VBoxContainer
	DmPb.clear(holder)
	hint_text = ""
	empty_text = ""
	var day := brew_of_the_day(today())
	if station == "cauldron":
		hint_text = "Brew of the day: %s %s" % [day["name"], "(bonus claimed today)" if bonus_claimed else "(one extra on your first brew today)"]
	elif station == "" and active == "alchemy":
		hint_text = "Brewing is easier in the Alchemist's Wing, east of the Chapterhouse: the Great Cauldron and the Reagent Shelf are there."
	if hint_text != "":
		holder.add_child(DmPb.hint(hint_text))
	var err := _errs[active] as Label
	err.text = String(errors.get(active, ""))
	err.visible = err.text != ""
	var list: Array = recipes.get(active, [])
	if list.is_empty():
		empty_text = "No recipes known for this rite." if recipes.has(active) else "Loading recipes…"
		box.add_child(DmPb.hint(empty_text))
		return
	var shown_list: Array = list.filter(func(r: Dictionary) -> bool: return can_craft(r)) if only_craftable else list
	if shown_list.is_empty():
		empty_text = "Nothing here is craftable right now. Untick \"Only show craftable\" to see every recipe."
		box.add_child(DmPb.hint(empty_text))
		return
	for r: Dictionary in shown_list:
		_recipe_row(box, r, day)


func _recipe_row(box: VBoxContainer, r: Dictionary, day: Dictionary) -> void:
	var id := String(r["id"])
	var skill := skill_of(prof_of(r))
	var skill_ok := skill >= int(r["skill_level_required"])
	var max_n := max_for(r) if skill_ok else 0
	var n := effective_qty(r, max_n)
	var off := max_n < 1 or busy
	var card := DmPb.card(box, DmUi.BORDER, Color(0, 0, 0, 0), Vector2(15, 12))
	var row := DmPb.hbox(18)
	card.add_child(row)
	var info := DmPb.vbox(7)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	var top := HFlowContainer.new()   # .cw-recipe .row: flex-wrap, name left, requirement after it
	top.add_theme_constant_override("h_separation", 12)
	top.add_theme_constant_override("v_separation", 2)
	var nm := DmPb.text(String(r["name"]), 17, DmUi.BONE_100, "body_bold")
	top.add_child(nm)
	var botd: bool = station == "cauldron" and id == day["recipeId"]
	if botd:
		top.add_child(DmPb.text("brew of the day", 12, DmUi.GOLD, "body_italic"))
	var req := "%s %d" % [prof_of(r).capitalize(), int(r["skill_level_required"])]
	top.add_child(DmPb.text(req, 12, DmUi.OK if skill_ok else DmUi.DANGER))
	info.add_child(top)
	var ings := HFlowContainer.new()
	ings.add_theme_constant_override("h_separation", 12)
	ings.add_theme_constant_override("v_separation", 4)
	var ing_info: Array = []
	for ing: Dictionary in r["ingredients"]:
		var have := count_of(String(ing["item_id"]))
		var ok := have >= int(ing["quantity"])
		var nmi := String(ing.get("name", DmPb.item_name(String(ing["item_id"]))))
		var l := HBoxContainer.new()
		l.add_theme_constant_override("separation", 4)
		l.add_child(DmPb.text("%d× %s" % [int(ing["quantity"]), nmi], 14, DmUi.OK if ok else DmUi.DANGER))
		l.add_child(DmPb.text("(%d)" % have, 14, Color(DmUi.OK if ok else DmUi.DANGER, 0.6)))
		ings.add_child(l)
		ing_info.append({"text": "%d× %s (%d)" % [int(ing["quantity"]), nmi, have], "ok": ok})
	info.add_child(ings)

	var ctl := HFlowContainer.new()
	ctl.add_theme_constant_override("h_separation", 6)
	ctl.add_theme_constant_override("v_separation", 6)
	ctl.custom_minimum_size.x = 430
	ctl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var step := HBoxContainer.new()
	step.add_theme_constant_override("separation", 4)
	var dec := DmPb.button("−", false, off)
	dec.custom_minimum_size = Vector2(40, 40)
	var inp := LineEdit.new()
	inp.custom_minimum_size = Vector2(56, 40)
	inp.alignment = HORIZONTAL_ALIGNMENT_CENTER
	inp.text = str(qty.get(id, 1))
	inp.editable = not off
	inp.add_theme_font_override("font", DmUi.font("numeric"))
	var inc := DmPb.button("+", false, off)
	inc.custom_minimum_size = Vector2(40, 40)
	step.add_child(dec)
	step.add_child(inp)
	step.add_child(inc)
	ctl.add_child(step)
	var x5 := DmPb.button("×5", false, off)
	x5.custom_minimum_size = Vector2(40, 40)
	ctl.add_child(x5)
	var mx := DmPb.button("Max (%d)" % max_n if max_n > 0 else "Max", false, off)
	mx.custom_minimum_size = Vector2(40, 40)
	ctl.add_child(mx)
	var craft_text := status if busy and busy_recipe == id else "Craft ×%d" % n
	var go := DmPb.button(craft_text, true, not (max_n >= 1 and not busy))
	go.custom_minimum_size = Vector2(110, 40)
	ctl.add_child(go)
	row.add_child(ctl)
	craft_buttons[id] = go
	qty_inputs[id] = inp
	max_buttons[id] = mx

	var set_qty := func(v: int) -> void:
		qty[id] = DmRecipes.clamp_craft_qty(v, max_for(r) if max_for(r) > 0 else 1)
		_render.call_deferred()
	dec.pressed.connect(func() -> void: set_qty.call(effective_qty(r, max_for(r)) - 1))
	inc.pressed.connect(func() -> void: set_qty.call(effective_qty(r, max_for(r)) + 1))
	x5.pressed.connect(func() -> void: set_qty.call(5))
	mx.pressed.connect(func() -> void: set_qty.call(max_for(r)))
	# Typing keeps focus (no rebuild) and only refreshes the craft label; clamp on commit.
	inp.text_changed.connect(func(t: String) -> void:
		qty[id] = DmRecipes.clamp_craft_qty(t, max_for(r) if max_for(r) > 0 else 1)
		if not busy:
			go.text = DmUi.upper("Craft ×%d" % effective_qty(r, max_for(r))))
	var commit := func(_t: Variant = null) -> void:
		var v := effective_qty(r, max_for(r))
		qty[id] = v
		inp.text = str(v)
		if not busy:
			go.text = DmUi.upper("Craft ×%d" % v)
	inp.text_submitted.connect(commit)
	inp.focus_exited.connect(commit)
	go.pressed.connect(func() -> void:
		craft_requested.emit(id, effective_qty(r, max_for(r))))
	rows.append({"id": id, "name": r["name"], "req": req, "skill_ok": skill_ok, "ingredients": ing_info, "max": max_n, "qty": qty.get(id, 1), "craft_text": craft_text,
		"craft_enabled": not go.disabled, "step_enabled": not off, "botd": botd})
