class_name DmSettingsPanel
extends DmWindow
## Settings (src/ui/MiscPanels.ts SettingsPanel): every section and control of the web panel, as a native Godot window.
## Pure UI: it holds a `values` Dictionary (seeded with the web defaults) and emits `changed(key, value)` / `action(name)`;
## the integrator wires those to the settings store, party, class change, bug report, leave-the-world.
##
## value keys: difficulty, auto_combat, auto_gather, loot_common..loot_legendary ("ground"|"auto"|"gold"), graphics, fps,
##   auto_res, vol_master, vol_combat, vol_amb, vol_music, vol_ui, reduce_motion, damage_numbers, hide_helm, no_tips,
##   guidance, guide_ping, dev_access, party_in (the join-code field).
## Options: `can_auto_combat`, `has_dev`, `has_bug_report`, `has_reset_tips`, `has_change_class`, `has_party`, `party_code` ("" = solo),
##   `has_keybinds`, `binds` {action: key}, `kit_primary`, `kit_corpse`, `kit_legion`.

signal changed(key: String, value: Variant)
signal action(name: String)          # leave, bug_report, reset_tips, change_class, party_make, party_join, party_leave
signal bind_requested(action_id: String)

const DIFFICULTIES := [
	["easy", "Easy", "The dead hit softer and fall faster. Less gold and experience."],
	["medium", "Medium", "The intended balance."],
	["hard", "Hard", "Tougher, deadlier dead and more elites. More gold and experience."],
]
const LOOT_TIERS := [["common", "Common"], ["uncommon", "Uncommon"], ["rare", "Rare"], ["epic", "Epic"], ["legendary", "Legendary"]]
const LOOT_ACTIONS := [["ground", "On the ground"], ["auto", "Auto-loot"], ["gold", "Sell for gold"]]
const LOADOUT_ACTIONS := [["loadout_next", "Next loadout"], ["loadout_1", "Loadout 1"], ["loadout_2", "Loadout 2"], ["loadout_3", "Loadout 3"], ["loadout_4", "Loadout 4"], ["loadout_5", "Loadout 5"], ["loadout_6", "Loadout 6"]]

var values: Dictionary = {
	"difficulty": "medium", "auto_combat": false, "auto_gather": false,
	"loot_common": "ground", "loot_uncommon": "ground", "loot_rare": "ground", "loot_epic": "ground", "loot_legendary": "ground",
	"graphics": "high", "fps": 0, "auto_res": true, "ui_scale": 1.0,
	"vol_master": 0.7, "vol_combat": 0.8, "vol_amb": 0.6, "vol_music": 0.5, "vol_ui": 0.8,
	"reduce_motion": false, "damage_numbers": true, "hide_helm": false, "no_tips": false, "guidance": true, "guide_ping": true,
	"dev_access": true, "party_in": "",
}
var can_auto_combat := true
var has_dev := true
var has_bug_report := true
var has_reset_tips := true
var has_change_class := true
var has_party := true
var party_code := ""
var has_keybinds := true
var binds: Dictionary = {"loadout_next": "", "loadout_1": "F1", "loadout_2": "F2", "loadout_3": "", "loadout_4": "", "loadout_5": "", "loadout_6": ""}
var kit_primary := "Bone Needle"
var kit_corpse := "Corpse Explosion"
var kit_legion := true
var bind_note: Label
var _diff_note: Label
var _auto_cb: CheckBox
var _bind_btns: Dictionary = {}


func _init() -> void:
	super._init()
	title = "Settings"
	panel_width = 540


var _built_sig := 0
var _party_le: LineEdit


## Everything build() draws from (the join-code field is not part of it: it starts empty on every open).
func _sig() -> int:
	var v := values.duplicate()
	v.erase("party_in")
	return [v, can_auto_combat, has_dev, has_bug_report, has_reset_tips, has_change_class, has_party, party_code, has_keybinds, binds, kit_primary, kit_corpse, kit_legion].hash()


## build(), unless the content on screen was built from exactly this state (opening Settings rebuilt ~430 nodes every time: ~50 ms).
func build_if_changed() -> void:
	if _built_sig != 0 and _sig() == _built_sig and body.get_child_count() > 0 and not _stale:
		if _party_le != null and is_instance_valid(_party_le):
			_party_le.text = ""
		return
	build()


## Something else replaced the body (the bug report form): the next build_if_changed() draws Settings again.
func mark_stale() -> void:
	_stale = true


var _stale := false


## Build (or rebuild) the content from the current `values`/options. Call once after setting options, before open().
func build() -> void:
	_built_sig = _sig()
	_stale = false
	_party_le = null
	for c in body.get_children():
		c.queue_free()
	_bind_btns.clear()
	var top := PanelContainer.new()
	top.theme_type_variation = "DmInsetTight"
	var tm := DmUi.theme().get_stylebox("panel", "DmInsetTight")
	var tb := tm.duplicate() as StyleBoxFlat
	tb.content_margin_left = 16
	tb.content_margin_right = 16
	tb.content_margin_top = 10
	tb.content_margin_bottom = 10
	top.add_theme_stylebox_override("panel", tb)
	var th := HBoxContainer.new()
	top.add_child(th)
	var tl := DmUi.label("Done for now?", "DmMuted")
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	th.add_child(tl)
	th.add_child(_button("Leave the world", "leave"))
	body.add_child(top)

	# --- Play ---------------------------------------------------------------------------------
	var s1 := _section("Play")
	var diff := OptionButton.new()
	for d in DIFFICULTIES:
		diff.add_item(d[1])
	diff.select(_idx(DIFFICULTIES, values["difficulty"]))
	diff.item_selected.connect(func(i: int) -> void:
		_put("difficulty", DIFFICULTIES[i][0])
		_refresh_diff())
	_row(s1, "Difficulty", diff)
	_diff_note = DmUi.label("", "DmNote", true)
	_note_margin(s1, _diff_note)
	if can_auto_combat:
		_auto_cb = _check(s1, "Auto combat (Easy only, G)", "auto_combat")
	_check(s1, "Auto gathering", "auto_gather")
	s1.add_child(_margin(DmUi.label(DmUi.upper("Loot"), "DmSub"), 10, 4))
	for t in LOOT_TIERS:
		var ob := OptionButton.new()
		var acts: Array = LOOT_ACTIONS if t[0] != "legendary" else LOOT_ACTIONS.slice(0, 2)
		for a in acts:
			ob.add_item(a[1])
		ob.select(maxi(0, _idx(acts, values["loot_" + t[0]])))
		var key: String = "loot_" + t[0]
		ob.item_selected.connect(func(i: int) -> void: _put(key, acts[i][0]))
		_row(s1, "%s gear" % t[1], ob)
	_note(s1, "On the ground: walk over it. Auto-loot: straight into your bag as it drops (if the bag is full it lands instead). Sell for gold: you get its sell value and it never drops. Set pieces, legendaries, necromancer affixes and upgrades for you are never sold.")
	if can_auto_combat:
		_note(s1, "On Easy, Auto engages enemies in your current area, uses equipped rites and may cast your signature when a fight calls for it. Click or use WASD to take control; hold 1–5 to repeat a rite.")
	_refresh_diff()

	# --- Display and sound -------------------------------------------------------------------------
	var s2 := _section("Display and sound")
	_option(s2, "Graphics", "graphics", DmGraphicsPreset.options())
	_option(s2, "Frame rate", "fps", [[0, "Max — your screen's refresh rate"], [60, "60 — smooth"], [30, "30 — battery saver"]])
	_option(s2, "Interface size", "ui_scale", [[0.8, "80%"], [0.9, "90%"], [1.0, "100%"], [1.1, "110%"], [1.25, "125%"]])
	_check(s2, "Auto resolution", "auto_res")
	_note(s2, "Auto resolution only steps in after several seconds of sustained slow frames, and never below 85% on Medium and up. Turn it off to keep a constant sharp picture.")
	_slider(s2, "Volume", "vol_master")
	_slider(s2, "Combat", "vol_combat")
	_slider(s2, "Ambience", "vol_amb")
	_slider(s2, "Music", "vol_music")
	_slider(s2, "Interface", "vol_ui")
	_check(s2, "Reduce motion (no camera shake)", "reduce_motion")
	_check(s2, "Damage numbers", "damage_numbers")
	_check(s2, "Hide helms", "hide_helm")
	_check(s2, "Don't show tips", "no_tips")
	_check(s2, "Show the “Next” suggestion under the minimap", "guidance")
	_check(s2, "Point to it on the minimap", "guide_ping")

	# --- Character and help ------------------------------------------------------------------------
	var s3 := _section("Character and help")
	if has_dev:
		_check(s3, "Dev access (preview as a normal player when off)", "dev_access")
	if has_bug_report:
		_row(s3, "Found a bug or something odd?", _button("Report a bug", "bug_report", true))
	if has_reset_tips:
		_row(s3, "New to the Covenant?", _button("Show tips again", "reset_tips", true))
	if has_change_class:
		_row(s3, "Class", _button("Change class", "change_class", true))

	# --- Play together -------------------------------------------------------------------------------
	if has_party:
		var s4 := _section("Play together")
		if party_code != "":
			var code := DmUi.label(party_code, "DmNumeric")
			code.add_theme_font_size_override("font_size", 15)
			_row(s4, "Your party code", code)
			_note(s4, "Friends enter this code under Play together (or type /party %s) to join you. You choose who plays with you: being online at the same time never makes a party." % party_code)
			_row(s4, "Done playing together?", _button("Leave party (play solo)", "party_leave", true))
		else:
			_note(s4, "You are playing solo. Make a party and share its code, or enter a friend's code. In a party you share one world and its enemies; the Catacomb Depths stay a solo descent (you step out, then rejoin).")
			_row(s4, "Start a party", _button("Make a party", "party_make", true))
			var jr := HBoxContainer.new()
			jr.add_theme_constant_override("separation", 6)
			var le := LineEdit.new()
			le.placeholder_text = "code"
			le.max_length = 12
			le.custom_minimum_size.x = 110
			le.text_changed.connect(func(t: String) -> void: _put("party_in", t))
			_party_le = le
			jr.add_child(le)
			jr.add_child(_button("Join", "party_join", true))
			_row(s4, "Join a friend", jr)

	# --- Controls --------------------------------------------------------------------------------------
	var s5 := _section("Controls")
	if has_keybinds:
		var hh := HBoxContainer.new()
		hh.add_theme_constant_override("separation", 8)
		hh.add_child(DmUi.label(DmUi.upper("Loadout hotkeys"), "DmSub"))
		var sm := DmUi.label("unbound until you pick a key", "DmFaint")
		sm.add_theme_font_size_override("font_size", 11)
		sm.size_flags_vertical = Control.SIZE_SHRINK_END
		hh.add_child(sm)
		s5.add_child(_margin(hh, 4, 6))
		var g := GridContainer.new()
		g.columns = 2
		g.add_theme_constant_override("h_separation", 16)
		g.add_theme_constant_override("v_separation", 8)
		for a in LOADOUT_ACTIONS:
			var l := DmUi.label(a[1], "DmMuted")
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			g.add_child(l)
			var b := Button.new()
			b.theme_type_variation = "DmButtonSmall"
			b.focus_mode = Control.FOCUS_NONE
			b.custom_minimum_size.x = 110
			var aid: String = a[0]
			b.pressed.connect(func() -> void: bind_requested.emit(aid))
			g.add_child(b)
			_bind_btns[aid] = b
			_refresh_bind(aid)
		s5.add_child(g)
		bind_note = DmUi.label("Click an action, then press a key. Esc clears it. Keys the game already uses are refused.", "DmNote", true)
		bind_note.add_theme_font_size_override("font_size", 13)
		bind_note.add_theme_color_override("font_color", DmUi.TEXT_MUTED)
		s5.add_child(_margin(bind_note, 8, 2))
	s5.add_child(_margin(_keys_grid(), 10, 0))
	for sec in body.get_children():
		var v := (sec as Node).get_child(0) if sec is PanelContainer else null
		if v == null or v.get_child_count() == 0:
			continue
		var last := v.get_child(v.get_child_count() - 1)
		if last is VBoxContainer and last.get_child_count() == 2 and last.get_child(1) is ColorRect:
			(last.get_child(1) as Control).visible = false


func _keys_grid() -> Control:
	var rows: Array = []
	if has_keybinds:
		rows.append(["Loadout keys", "Next loadout and Loadout 1-6: unbound until you assign them above (necromancers). They apply a saved Grimoire loadout"])
	rows.append_array([
		["WASD", "Walk freely; holding a direction takes over from click-to-move"],
		["Click", "Move · attack target (%s) · use" % kit_primary],
		["Minimap", "Click a walkable spot to travel there"],
		["Hover / focus", "Spell icon: cost, targeting, effects and combat counsel"],
		["Shift+Click", "Cast %s without moving" % kit_primary],
		["1–5 (hold)", "Cast your equipped rites at the cursor"],
		["L", "Grimoire (with the Legion beside it for necromancers) · click the swap arrows below a hotbar spell (they appear once you learn a second rite) to choose any unlocked class rite"],
		["RMB · 5", "Cast your fifth equipped rite (starts as %s)" % kit_corpse],
		["R · 6", "Signature rite (unlocks at level 10)"],
		["Q", "Drink a healing flask"],
		["Z · X", "Drink the elixir · tonic on your belt (right-click a brew in the Reliquary to belt it)"],
		["T", "Return to the Chapterhouse"],
		["Click a node", "Gather: chop a tree, mine a seam, fish a pool, dig a grave (it keeps working until the node is spent)"],
		["I C M", "Reliquary · Workbench · Waystones"],
		["P", "Acre ledger: Skills, then tabs for Garden, Laborers and Contracts (the Acre button appears once you start gathering)"],
		["U H O", "The Acre ledger's Garden · Laborers · Contracts tabs (old keys, they open the right tab)"],
		["J N", "Character window: your stats and where each number comes from, and a Capes & Pets tab (N opens it)"],
	])
	if kit_legion:
		rows.append(["Y", "Legion tab beside the Grimoire: spare weapon and armour for your thralls, and Reinforce (necromancers)"])
	rows.append_array([
		[".", "Gear Atlas: where every piece drops and how often, how to craft it, and what suits your discipline"],
		["F3", "Performance overlay: frame rate, where frame time goes, and a log of recent stutters (also ?fps in the address bar)"],
		["K", "Codex"],
		["E", "Talk to the Prior, the Sexton or the Apothecary when you stand close (or click them)"],
		["V", "Ossuary Vault: a shared stash (in the Chapterhouse or the Acre)"],
	])
	if can_auto_combat:
		rows.append(["G", "Toggle auto combat on Easy · engage nearby enemies"])
	rows.append_array([
		["Counsel header", "Drag to move · arrow keys while focused · remembers its position"],
		["Settings", "Change class · keeps your character and progress"],
		["Wheel", "Zoom"],
		["Enter", "Chat"],
		["Altar", "Click the Altar in the Chapterhouse to Ascend and buy Boons"],
	])
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 9)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for r in rows:
		var kc := DmUi.kbd(r[0])
		kc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		g.add_child(kc)
		var d := DmUi.label(r[1], "DmMuted", true)
		d.add_theme_font_size_override("font_size", 14)
		g.add_child(d)
	return g


# --- row builders ------------------------------------------------------------------------------------------------
func _section(title_text: String) -> VBoxContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "DmInset"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	p.add_child(v)
	var h := DmUi.label(DmUi.upper(title_text), "DmH3")
	v.add_child(_margin(h, 0, 6))
	body.add_child(p)
	body.add_theme_constant_override("separation", 18)
	return v


func _margin(c: Control, top: int, bottom: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", top)
	m.add_theme_constant_override("margin_bottom", bottom)
	m.add_child(c)
	return m


func _row(parent: VBoxContainer, text: String, ctrl: Control) -> void:
	# label.row: flex, space-between, padding 12px 0, 1px bottom rule (not on the last row of a section)
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 0)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 12)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 18)
	var l := DmUi.label(text, "DmRow", true)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_SHRINK_END
	ctrl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ctrl)
	m.add_child(h)
	wrap.add_child(m)
	wrap.add_child(DmUi.hrule())
	parent.add_child(wrap)


func _check(parent: VBoxContainer, text: String, key: String) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = values.get(key, false)
	cb.toggled.connect(func(on: bool) -> void:
		_put(key, on))
	cb.focus_mode = Control.FOCUS_NONE
	_row(parent, text, cb)
	return cb


func _option(parent: VBoxContainer, text: String, key: String, opts: Array) -> void:
	var ob := OptionButton.new()
	ob.fit_to_longest_item = true
	for o in opts:
		ob.add_item(o[1])
	ob.select(maxi(0, _idx(opts, values[key])))
	ob.item_selected.connect(func(i: int) -> void: _put(key, opts[i][0]))
	_row(parent, text, ob)


func _slider(parent: VBoxContainer, text: String, key: String) -> void:
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = values[key]
	s.custom_minimum_size = Vector2(150, 20)
	s.focus_mode = Control.FOCUS_NONE
	s.value_changed.connect(func(v: float) -> void: _put(key, v))
	_row(parent, text, s)


func _button(text: String, act: String, small: bool = false) -> Button:
	var b := Button.new()
	b.text = DmUi.upper(text)
	b.theme_type_variation = "DmButtonSmall" if small else "Button"
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void: action.emit(act))
	return b


func _note(parent: VBoxContainer, text: String) -> void:
	var l := DmUi.label(text, "DmNote", true)
	l.add_theme_font_size_override("font_size", 14)
	_note_margin(parent, l)


func _note_margin(parent: VBoxContainer, l: Label) -> void:
	l.add_theme_font_size_override("font_size", 14)
	parent.add_child(_margin(l, 8, 2))


func _idx(arr: Array, v: Variant) -> int:
	for i in arr.size():
		if arr[i][0] == v or (typeof(v) == TYPE_FLOAT and typeof(arr[i][0]) in [TYPE_FLOAT, TYPE_INT] and is_equal_approx(float(arr[i][0]), v)):
			return i
	return 0


func _put(key: String, v: Variant) -> void:
	values[key] = v
	changed.emit(key, v)
	if key == "difficulty":
		_refresh_diff()


func _refresh_diff() -> void:
	if _diff_note == null:
		return
	var d: Array = DIFFICULTIES[_idx(DIFFICULTIES, values["difficulty"])]
	var extra := ""
	if can_auto_combat:
		extra = " Auto combat turns on with Easy." if values["difficulty"] == "easy" else " Auto combat turns off with Medium and Hard."
	_diff_note.text = "%s%s In co-op, the world keeper sets enemy difficulty." % [d[2], extra]
	if _auto_cb != null:
		_auto_cb.disabled = values["difficulty"] != "easy"


## Show a key (or "unbound") on a loadout hotkey button; call after the integrator changes `binds`.
func _refresh_bind(aid: String) -> void:
	var b: Button = _bind_btns.get(aid)
	if b == null:
		return
	var k: String = binds.get(aid, "")
	b.text = k.to_upper() if k != "" else "—"


func set_bind(aid: String, key: String) -> void:
	binds[aid] = key
	_refresh_bind(aid)
