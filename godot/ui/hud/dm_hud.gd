class_name DmHud
extends Control
## The in-world HUD (archive/legacy-web:src/ui/HUD.ts + ui.css `.hud*`). One full-screen, mouse-transparent Control that owns every readout.
## State flows in through ONE Dictionary: `hud.apply(vm)` (schema in ui/hud/README.md). One-shot things (toasts, banners, floating
## numbers, hit flash, chat lines) are method calls. Player intent flows out as signals; nothing here touches world/ or net/.

signal cast(slot: int)                   ## 0 = LMB primary, 1..N = hotbar slot
signal swap_slot(index: int)             ## the key cap under a rite (opens the Grimoire there)
signal buy_damage
signal buy_wave
signal dial_wave(delta: int)
signal open_panel(panel: String)         ## inventory forge professions map grimoire atlas codex settings
signal open_grimoire(select: Variant)
signal chat_sent(text: String)
signal toggle_auto_combat
signal dismiss_next
signal report_bug
signal belt_clicked(slot: String)
signal navigate(x: float, z: float)
signal cue_used(id: String)
signal brew_dropped(slot: String, item_id: String)   ## a brew dragged from the Reliquary onto a belt chip

const MENU_ROW := [
	["inventory", "bag", "Bag", "Reliquary (I)", ""],
	["forge", "anvil", "Craft", "Workbench (C)", ""],
	["professions", "skills", "Acre", "Acre ledger: Skills, Garden, Laborers, Contracts (P)", "menu.skills"],
	["map", "waymap", "Map", "Waystones (M)", ""],
	["grimoire", "grimoire", "Spells", "Grimoire and Legion (L)", "menu.spells"],
	["atlas", "atlas", "Atlas", "Gear Atlas (.)", "menu.atlas"],
	["codex", "book", "Codex", "Codex (K)", ""],
	["party", "person", "Party", "Party: host a session, join friends (F)", ""],
	["settings", "gear", "Settings", "Settings (Esc)", ""],
]
const SLOT_KEYS := ["1", "2", "3", "4", "RMB", "R"]
const CHAIN_TIER := ["bone", "e6d3a0", "f0b25a", "f08a3a", "ee5a2a", "ff3a3a"]
const AFFIX_COLOR := {"bellTolled": "d9a441", "hungering": "b3b84a", "shrouded": "96a0b5", "vengeful": "e0703a"}
const RESERVED_TOP := 14.0

# --- state mirrors (tests read these) ---
var vm: Dictionary = {}
var toasts: VBoxContainer
var _reveal: Dictionary = {}
var _new: Dictionary = {}
var _slots: Array[DmHudSlot] = []
var _slot_sig := ""
var _brew_chips: Dictionary = {}
var _tip_nodes: Dictionary = {}

# nodes
var vignette: DmHudParts.Vignette
var party_box: VBoxContainer
var omen: PanelContainer
var omen_host: Control
var omen_img: TextureRect
var omen_name: Label
var ward: PanelContainer
var ward_n: Label
var brews_box: VBoxContainer
var brew_row: HBoxContainer
var chain: PanelContainer
var chain_n: Label
var chain_lbl: Label
var chain_bar: DmHudBar
var target_box: VBoxContainer
var target_name_row: HBoxContainer
var target_bar: DmHudBar
var target_stat: HBoxContainer
var target_blurb: Label
var boss: PanelContainer
var boss_name: Label
var boss_phase: Label
var boss_bar: DmHudBar
var boss_num: Label
var map_col: VBoxContainer
var minimap: DmHudMinimap
var area_lbl: Label
var prog_lbl: RichTextLabel
var depth_box: PanelContainer
var depth_n: Label
var depth_k: Label
var depth_bar: DmHudBar
var depth_cue: Label
var next_box: PanelContainer
var next_txt: Label
var menu_flow: HFlowContainer
var menu_btns: Dictionary = {}
var auto_btn: Button
var banner_host: Control
var prompt: PanelContainer
var node_tip_box: PanelContainer
var node_tip_rt: RichTextLabel
var prompt_rt: RichTextLabel
var hint: Label
var chat_log: VBoxContainer
var chat_in: LineEdit
var bug_btn: Button
var level_badge: DmHudParts.LevelBadge
var dev_chip: PanelContainer
var xp_bar: DmHudBar
var xp_txt: Label
var hp_orb: DmHudOrb
var hp_txt: Label
var hp_sub: Label
var ess_orb: DmHudOrb
var ess_txt: Label
var ess_sub: Label
var souls_box: PanelContainer
var souls_bar: DmHudBar
var souls_n: Label
var souls_skull: TextureRect
var slots_row: HBoxContainer
## The spell card's data for a slot: Callable(index: int) -> Dictionary ({} = none; index -1 = the LMB primary, 0.. = the hotbar). Set by the
## game UI (it knows the rites, runes and discipline); see DmHudTips. Without it slots keep Godot's plain tooltip.
var spell_card: Callable = Callable()
var _tip_slot := -2
var _tip_key := ""
var primary_slot: DmHudSlot
var grim_btn: Button
var grim_pip: PanelContainer
var thrall_pips: DmHudParts.Diamonds
var altar: HBoxContainer
var up_plate: Control
var up_panel: PanelContainer
var dmg_pct: Label
var dmg_bar: DmHudBar
var dmg_gems: DmHudParts.Diamonds
var dmg_buy: Button
var dmg_cost: Label
var wave_pct: Label
var wave_bar: DmHudBar
var wave_gems: DmHudParts.Diamonds
var wave_buy: Button
var wave_cost: Label
var dial_box: HFlowContainer
var dial_minus: Button
var dial_plus: Button
var dial_tier: Label
var dial_ms: Label
var gold_lbl: Label
var thrall_chip: HBoxContainer
var thrall_num: Label
var shard_chip: HBoxContainer
var shard_lbl: Label
var save_lbl: Label
var death: Control
var death_sub: Label
var float_layer: Control
var _glows: Dictionary = {}   # reveal id -> [NewGlow...]
var _pips: Dictionary = {}    # reveal id -> [pip...]
var _banner: DmBanner
var _loot_toasts: Dictionary = {}
var xp_box: HBoxContainer
var chat_col: VBoxContainer


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = DmUi.theme()
	_build()


# ======================================================================== build

func _build() -> void:
	vignette = DmHudParts.Vignette.new()
	add_child(vignette)
	_build_party_and_edge_readouts()
	_build_target_boss()
	_build_map_column()
	_build_toasts_banner_prompts()
	_build_chat()
	_build_xp()
	_build_altar()
	_build_right()
	_build_death()
	float_layer = Control.new()
	float_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	float_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(float_layer)
	_build_safe_frame()


## Ultrawide: every HUD element is edge-anchored, so on a 21:9 window the party list, map and cards sit a long way from the centre.
## They live in a frame no wider than MAX_ASPECT x the height, centred; the vignette, death veil and floating numbers stay full-screen.
const MAX_ASPECT := 2.0
var safe: Control


func _build_safe_frame() -> void:
	safe = Control.new()
	safe.name = "SafeFrame"
	safe.set_anchors_preset(Control.PRESET_FULL_RECT)
	safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(safe)
	move_child(safe, vignette.get_index() + 1)
	for c in get_children():
		if c == vignette or c == safe or c == death or c == float_layer:
			continue
		remove_child(c)
		safe.add_child(c)


## Settings -> HUD size. The whole safe frame is scaled from its top-left corner and given 1/scale of the room as its layout size, so the
## edge-anchored groups stay in their corners and the hit areas follow (a Control's scale also scales its input transform). The floating
## numbers, vignette and death veil are outside the frame and keep their screen size.
const HUD_SCALE_MIN := 0.75
const HUD_SCALE_MAX := 1.3
## The narrowest logical frame width at which the side columns still clear the orb row: the upgrade panel is 298+ wide whatever its clamp says,
## the orbs reach 413 px either side of the centre, plus the 18 px gutter and a gap (measured; tests/hud/run.gd checks the rects).
const MIN_FIT_WIDTH := 1500.0
var hud_scale := 1.0        ## what Settings asked for
var effective_scale := 1.0  ## what is applied: hud_scale, held back on a frame too narrow to fit it


func set_hud_scale(v: float) -> void:
	v = clampf(v, HUD_SCALE_MIN, HUD_SCALE_MAX)
	if is_equal_approx(v, hud_scale):
		return
	hud_scale = v
	_notification(NOTIFICATION_RESIZED)


## hud_scale, but never more than the frame can hold: above 100 % it is capped at frame width / MIN_FIT_WIDTH (never below 100 %).
static func fit_scale(want: float, frame_w: float) -> float:
	if want <= 1.0:
		return want
	return minf(want, maxf(1.0, frame_w / MIN_FIT_WIDTH))


func _fit_safe_frame() -> void:
	if safe == null:
		return
	var m := maxf(0.0, (size.x - size.y * MAX_ASPECT) * 0.5)
	effective_scale = fit_scale(hud_scale, size.x - 2.0 * m)
	safe.set_anchors_preset(Control.PRESET_TOP_LEFT)
	safe.pivot_offset = Vector2.ZERO
	safe.scale = Vector2(effective_scale, effective_scale)
	safe.position = Vector2(m, 0.0)
	safe.size = Vector2(size.x - 2.0 * m, size.y) / effective_scale


func _txt(text: String, size: int, color: Color, font: String = "body", spacing: float = 0.0, shadow: bool = true) -> Label:
	return DmHudKit.lbl(text, size, color, font, shadow, spacing)


func _pip_on(host: Control, id: String) -> void:
	var pip := DmUi.new_pip("NEW")
	pip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	pip.offset_right = 7
	pip.offset_top = -7
	pip.visible = false
	host.add_child(pip)
	if not _pips.has(id):
		_pips[id] = []
	_pips[id].append(pip)


func _glow_on(host: Control, id: String) -> void:
	var g := DmHudParts.NewGlow.new()
	host.add_child(g)
	if not _glows.has(id):
		_glows[id] = []
	_glows[id].append(g)


func _build_party_and_edge_readouts() -> void:
	party_box = VBoxContainer.new()
	party_box.add_theme_constant_override("separation", 6)
	party_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(party_box)
	DmHudKit.place(party_box, 0, 0, 18, 14)
	# omen chip (left 242, top 20)
	omen = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.55), DmUi.SPELL_300, Vector4(3, 0, 0, 0), Vector4(4, 4, 10, 4))
	var oh := HBoxContainer.new()
	oh.add_theme_constant_override("separation", 8)
	oh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	omen.add_child(oh)
	omen_img = TextureRect.new()
	omen_img.custom_minimum_size = Vector2(30, 30)
	omen_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	omen_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	omen_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	oh.add_child(omen_img)
	omen_name = _txt("", 12, DmUi.BONE_100, "display", 2.0)
	omen_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	oh.add_child(omen_name)
	omen.mouse_filter = Control.MOUSE_FILTER_PASS
	omen.mouse_default_cursor_shape = Control.CURSOR_HELP   # `cursor: help` (the blurb is its title)
	omen_host = DmHudParts.OverlayHost.new(omen)
	omen_host.visible = false
	add_child(omen_host)
	DmHudKit.place(omen_host, 0, 0, 242, 20)
	_glow_on(omen_host, "hud.omen")
	_pip_on(omen_host, "hud.omen")
	_tip_nodes["omen"] = omen_host
	# bone ward (left 22, top 60%)
	ward = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.55), DmUi.BONE_300, Vector4(3, 0, 0, 0), Vector4(12, 4, 12, 4))
	var wh := HBoxContainer.new()
	wh.add_theme_constant_override("separation", 10)
	wh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ward.add_child(wh)
	wh.add_child(_txt("BONE WARD", 12, DmUi.BONE_100, "display", 2.0))
	ward_n = _txt("", 20, Color("efe6d0"), "numeric")
	wh.add_child(ward_n)
	ward.visible = false
	add_child(ward)
	DmHudKit.place(ward, 0, 0.6, 22, 0)
	# kill chain (left 22, top 48%)
	chain = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.55), DmUi.BONE_300, Vector4(3, 0, 0, 0), Vector4(12, 6, 12, 8))
	chain.custom_minimum_size.x = 150
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 0)
	cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chain.add_child(cv)
	chain_n = _txt("×0", 34, DmUi.BONE_300, "numeric")
	cv.add_child(chain_n)
	chain_lbl = _txt("", 12, DmUi.BONE_100, "display", 2.0)
	cv.add_child(chain_lbl)
	chain_bar = DmHudBar.new(4.0)
	chain_bar.setup(DmUi.BONE_300, DmUi.BONE_300, Color(0.0275, 0.0235, 0.0392, 0.9), Color(0, 0, 0, 0))
	var cbw := MarginContainer.new()
	cbw.add_theme_constant_override("margin_top", 6)
	cbw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cbw.add_child(chain_bar)
	cv.add_child(cbw)
	chain.visible = false
	add_child(chain)
	DmHudKit.place(chain, 0, 0.48, 22, 0)
	_tip_nodes["chain"] = chain
	# belt (left 22, top 66%)
	brews_box = VBoxContainer.new()
	brews_box.add_theme_constant_override("separation", 3)
	brews_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.55), DmUi.BORDER_STRONG, Vector4(2, 0, 0, 0), Vector4(6, 1, 8, 1))
	head.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	head.add_child(_txt("BELT", 10, DmUi.BONE_300, "display", 2.0))
	brews_box.add_child(head)
	brew_row = HBoxContainer.new()
	brew_row.add_theme_constant_override("separation", 6)
	brew_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	brews_box.add_child(brew_row)
	brews_box.visible = false
	add_child(brews_box)
	DmHudKit.place(brews_box, 0, 0.66, 22, 0)
	_tip_nodes["belt"] = brews_box


func _build_target_boss() -> void:
	# target plate: centred, top 14, min(440, 50vw)
	target_box = VBoxContainer.new()
	target_box.add_theme_constant_override("separation", 0)
	target_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_box.custom_minimum_size.x = 440
	target_name_row = HBoxContainer.new()
	target_name_row.alignment = BoxContainer.ALIGNMENT_CENTER
	target_name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_box.add_child(target_name_row)
	var tw := MarginContainer.new()
	tw.add_theme_constant_override("margin_top", 4)
	tw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_bar = DmHudBar.new(10.0)
	target_bar.setup(Color("4a1f3a"), Color("8a3a6c"), Color(0.0275, 0.0235, 0.0392, 0.9), DmUi.BORDER_STRONG)
	tw.add_child(target_bar)
	target_box.add_child(tw)
	var sw := MarginContainer.new()
	sw.add_theme_constant_override("margin_top", 5)
	sw.custom_minimum_size.y = 26 + 5
	sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_stat = HBoxContainer.new()
	target_stat.alignment = BoxContainer.ALIGNMENT_CENTER
	target_stat.add_theme_constant_override("separation", 6)
	target_stat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sw.add_child(target_stat)
	target_box.add_child(sw)
	target_blurb = _txt("", 12, DmUi.TEXT_MUTED, "body_italic", 0.0, false)
	target_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	target_box.add_child(target_blurb)
	target_box.visible = false
	add_child(target_box)
	DmHudKit.place(target_box, 0.5, 0, 0, RESERVED_TOP, Control.GROW_DIRECTION_BOTH)
	# boss plate: cw-plate, min(620, 60vw)
	boss = PanelContainer.new()
	boss.theme_type_variation = "DmPlate"
	boss.add_theme_stylebox_override("panel", DmHudKit.style(DmUi.PANEL, DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(16, 10, 16, 12), 3))
	boss.custom_minimum_size.x = 620
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 0)
	bv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boss.add_child(bv)
	boss_name = _txt("", 22, DmUi.BONE_100, "display_bold", 4.0, false)
	boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(boss_name)
	boss_phase = _txt("", 12, DmUi.SPELL_300, "body", 2.0, false)
	boss_phase.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(boss_phase)
	bv.add_child(DmUi.spacer(6))
	boss_bar = DmHudBar.new(14.0)
	boss_bar.setup(Color("3b1d5e"), Color("c6a4ff"), Color("07060a"), DmUi.BORDER_STRONG, Color(0.608, 0.361, 1.0, 0.55))
	boss_bar.mid = Color("7c3aed")
	boss_bar.marks = [0.6, 0.3]
	boss_bar.overshoot = 4.0
	bv.add_child(boss_bar)
	boss_num = _txt("", 12, DmUi.TEXT_MUTED, "numeric", 0.0, false)
	boss_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bnw := MarginContainer.new()
	bnw.add_theme_constant_override("margin_top", 4)
	bnw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bnw.add_child(boss_num)
	bv.add_child(bnw)
	boss.add_child(DmCorners.new())
	boss.visible = false
	boss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(boss)
	DmHudKit.place(boss, 0.5, 0, 0, RESERVED_TOP, Control.GROW_DIRECTION_BOTH)


func _build_map_column() -> void:
	map_col = VBoxContainer.new()
	map_col.add_theme_constant_override("separation", 8)
	map_col.custom_minimum_size.x = 200
	map_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(map_col)
	DmHudKit.place(map_col, 1, 0, -18, 14, Control.GROW_DIRECTION_BEGIN)
	minimap = DmHudMinimap.new()
	minimap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	minimap.navigate.connect(func(x: float, z: float) -> void: navigate.emit(x, z))
	map_col.add_child(minimap)
	_tip_nodes["minimap"] = minimap
	area_lbl = _txt("", 16, DmUi.BONE_100, "display_bold", 2.0)
	area_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	area_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	area_lbl.custom_minimum_size.x = 200
	map_col.add_child(area_lbl)
	prog_lbl = RichTextLabel.new()
	prog_lbl.bbcode_enabled = true
	prog_lbl.fit_content = true
	prog_lbl.scroll_active = false
	prog_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prog_lbl.custom_minimum_size.x = 200
	prog_lbl.add_theme_font_override("normal_font", DmUi.font("body"))
	prog_lbl.add_theme_font_size_override("normal_font_size", 12)
	prog_lbl.add_theme_color_override("default_color", DmUi.TEXT_MUTED)
	map_col.add_child(prog_lbl)
	# depth readout
	depth_box = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.5), DmUi.BORDER_STRONG, Vector4(0, 0, 0, 2), Vector4(8, 4, 8, 5))
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 0)
	dv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	depth_box.add_child(dv)
	var dr := HBoxContainer.new()
	dr.alignment = BoxContainer.ALIGNMENT_CENTER
	dr.add_theme_constant_override("separation", 10)
	dr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dv.add_child(dr)
	dr.add_child(_txt("DEPTH", 12, DmUi.BONE_100, "display", 2.0))
	depth_n = _txt("", 16, DmUi.BONE_300, "numeric")
	dr.add_child(depth_n)
	depth_k = _txt("", 12, DmUi.BONE_300, "numeric")
	dr.add_child(depth_k)
	depth_bar = DmHudBar.new(3.0)
	depth_bar.setup(DmUi.BONE_300, DmUi.BONE_300, Color(0.0275, 0.0235, 0.0392, 0.9), Color(0, 0, 0, 0))
	var dbw := MarginContainer.new()
	dbw.add_theme_constant_override("margin_top", 4)
	dbw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dbw.add_child(depth_bar)
	dv.add_child(dbw)
	depth_cue = _txt("", 11, DmUi.TEXT_MUTED, "body", 0.0)
	depth_cue.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	depth_cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	depth_cue.custom_minimum_size.x = 184
	dv.add_child(depth_cue)
	depth_box.visible = false
	map_col.add_child(depth_box)
	# "Next" suggestion
	next_box = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.7), DmUi.BORDER, Vector4(2, 1, 1, 1), Vector4(10, 5, 4, 5))
	next_box.add_theme_stylebox_override("panel", _next_style())
	next_box.custom_minimum_size.x = 200
	var nh := HBoxContainer.new()
	nh.add_theme_constant_override("separation", 6)
	nh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	next_box.add_child(nh)
	var nv := VBoxContainer.new()
	nv.add_theme_constant_override("separation", 0)
	nv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nh.add_child(nv)
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.add_child(_txt("NEXT", 10, Color("e8c15a"), "body", 2.0, false))
	next_txt = _txt("", 13, DmUi.BONE_100, "body", 0.0, false)
	next_txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	next_txt.custom_minimum_size.x = 150
	next_txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.add_child(next_txt)
	var nx := Button.new()
	nx.text = "×"
	nx.flat = true
	nx.focus_mode = Control.FOCUS_NONE
	nx.tooltip_text = "Hide this suggestion (turn the line off in Settings)"
	nx.add_theme_font_size_override("font_size", 17)
	nx.add_theme_color_override("font_color", DmUi.TEXT_MUTED)
	nx.add_theme_color_override("font_hover_color", DmUi.BONE_100)
	nx.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	nx.pressed.connect(func() -> void: dismiss_next.emit())
	nh.add_child(nx)
	next_box.visible = false
	map_col.add_child(next_box)
	# menu row
	menu_flow = HFlowContainer.new()
	menu_flow.alignment = FlowContainer.ALIGNMENT_CENTER
	menu_flow.add_theme_constant_override("h_separation", 3)
	menu_flow.add_theme_constant_override("v_separation", 3)
	menu_flow.custom_minimum_size.x = 200
	menu_flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_col.add_child(menu_flow)
	for row in MENU_ROW:
		var b := _menu_button(String(row[0]), String(row[1]), String(row[2]), String(row[3]), String(row[4]))
		menu_flow.add_child(b)
		menu_btns[row[0]] = b
	auto_btn = Button.new()
	auto_btn.theme_type_variation = "DmButtonSmall"
	auto_btn.custom_minimum_size = Vector2(200, 26)
	auto_btn.focus_mode = Control.FOCUS_NONE
	auto_btn.add_theme_font_size_override("font_size", 11)
	auto_btn.pressed.connect(func() -> void: toggle_auto_combat.emit())
	auto_btn.visible = false
	menu_flow.add_child(auto_btn)
	_tip_nodes["atlas"] = menu_btns["atlas"]
	_tip_nodes["codex"] = menu_btns["codex"]
	_tip_nodes["relic"] = menu_btns["inventory"]
	_tip_nodes["gather"] = menu_btns["professions"]


func _next_style() -> StyleBoxFlat:
	var sb := DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.7), DmUi.BORDER, Vector4(2, 1, 1, 1), Vector4(10, 5, 4, 5))
	sb.border_color = DmUi.BORDER
	sb.border_blend = false
	return sb


func _menu_button(id: String, icon_name: String, label: String, tip: String, gate: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(46, 34)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.add_theme_stylebox_override("normal", DmHudKit.style(DmUi.INSET, DmUi.BORDER))
	b.add_theme_stylebox_override("hover", DmHudKit.style(DmUi.INSET, DmUi.BORDER_ACTIVE))
	b.add_theme_stylebox_override("pressed", DmHudKit.style(DmUi.INSET, DmUi.BORDER_ACTIVE))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 1)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)
	var ic := TextureRect.new()
	ic.texture = DmHudKit.icon(icon_name)
	ic.custom_minimum_size = Vector2(17, 17)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(ic)
	var l := _txt(label, 10, DmUi.BONE_300, "body", 0.0, false)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	b.pressed.connect(func() -> void:
		if gate != "" and _new.get(gate, false):
			cue_used.emit(gate)
		open_panel.emit(id))
	if gate != "":
		_pip_on(b, gate)
		_glow_on(b, gate)
		b.set_meta("gate", gate)
	return b


func _build_toasts_banner_prompts() -> void:
	toasts = VBoxContainer.new()
	toasts.add_theme_constant_override("separation", 6)
	toasts.alignment = BoxContainer.ALIGNMENT_BEGIN
	toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toasts)
	DmHudKit.place(toasts, 0.5, 0, 0, 64, Control.GROW_DIRECTION_BOTH)
	banner_host = Control.new()
	banner_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_host.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner_host.offset_top = 210
	banner_host.offset_bottom = 330
	add_child(banner_host)
	prompt = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.88), DmUi.BORDER_STRONG, Vector4(1, 1, 1, 1), Vector4(14, 7, 14, 7))
	prompt_rt = RichTextLabel.new()
	prompt_rt.bbcode_enabled = true
	prompt_rt.fit_content = true
	prompt_rt.scroll_active = false
	prompt_rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	prompt_rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt_rt.add_theme_font_override("normal_font", DmUi.font("body"))
	prompt_rt.add_theme_font_size_override("normal_font_size", 15)
	prompt_rt.add_theme_color_override("default_color", DmUi.BONE_100)
	prompt.add_child(prompt_rt)
	prompt.visible = false
	add_child(prompt)
	DmHudKit.place(prompt, 0.5, 1, 0, -220, Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BEGIN)
	# `.hud-nodetip`: the hover card of a gathering node / laborer (HUD.nodeTip): max 260 wide, padding 8 12, 13 px, never takes the mouse
	node_tip_box = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.92), DmUi.BORDER_STRONG, Vector4(1, 1, 1, 1), Vector4(12, 8, 12, 8))
	node_tip_rt = RichTextLabel.new()
	node_tip_rt.bbcode_enabled = true
	node_tip_rt.fit_content = true
	node_tip_rt.scroll_active = false
	node_tip_rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node_tip_rt.custom_minimum_size.x = 236
	node_tip_rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node_tip_rt.add_theme_font_override("normal_font", DmUi.font("body"))
	node_tip_rt.add_theme_font_override("bold_font", DmUi.font("body_bold"))
	node_tip_rt.add_theme_font_size_override("normal_font_size", 13)
	node_tip_rt.add_theme_font_size_override("bold_font_size", 14)
	node_tip_rt.add_theme_color_override("default_color", Color("e6dccb"))   # bone-200
	node_tip_box.add_child(node_tip_rt)
	node_tip_box.visible = false
	node_tip_box.z_index = 30
	add_child(node_tip_box)
	hint = _txt("", 13, DmUi.TEXT_FAINT, "body")
	add_child(hint)
	DmHudKit.place(hint, 0.5, 1, 0, -196, Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BEGIN)


func _build_chat() -> void:
	var col := VBoxContainer.new()
	chat_col = col
	col.add_theme_constant_override("separation", 5)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.custom_minimum_size.x = 320
	add_child(col)
	DmHudKit.place(col, 0, 1, 18, -84, Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_BEGIN)
	bug_btn = Button.new()
	bug_btn.text = "⚑ Report a bug"
	bug_btn.focus_mode = Control.FOCUS_NONE
	bug_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bug_btn.tooltip_text = "Something wrong? Tell us. Your area, level and game version are attached for you."
	bug_btn.add_theme_font_override("font", DmUi.font("body_bold"))
	bug_btn.add_theme_font_size_override("font_size", 11)
	bug_btn.add_theme_color_override("font_color", DmUi.BONE_300)
	bug_btn.add_theme_color_override("font_hover_color", DmUi.BONE_100)
	bug_btn.add_theme_stylebox_override("normal", DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.5), DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(9, 2, 9, 2), 3))
	bug_btn.add_theme_stylebox_override("hover", DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.5), DmUi.BORDER_STRONG, Vector4(1, 1, 1, 1), Vector4(9, 2, 9, 2), 3))
	bug_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	bug_btn.modulate.a = 0.7
	bug_btn.pressed.connect(func() -> void: report_bug.emit())
	col.add_child(bug_btn)
	chat_log = VBoxContainer.new()
	chat_log.add_theme_constant_override("separation", 2)
	chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(chat_log)
	chat_in = LineEdit.new()
	chat_in.placeholder_text = "Enter to speak"
	chat_in.max_length = 240
	chat_in.add_theme_font_size_override("font_size", 13)
	chat_in.add_theme_stylebox_override("normal", DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.75), DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(10, 7, 10, 7)))
	chat_in.add_theme_stylebox_override("focus", DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.75), DmUi.FOCUS, Vector4(1, 1, 1, 1), Vector4(10, 7, 10, 7)))
	chat_in.modulate.a = 0.55
	chat_in.focus_entered.connect(func() -> void: chat_in.modulate.a = 1.0)
	chat_in.focus_exited.connect(func() -> void: chat_in.modulate.a = 0.55)
	chat_in.text_submitted.connect(func(t: String) -> void:
		t = t.strip_edges()
		if t != "":
			chat_sent.emit(t)
		chat_in.text = ""
		chat_in.release_focus())
	col.add_child(chat_in)


func _build_xp() -> void:
	var xp := HBoxContainer.new()
	xp.add_theme_constant_override("separation", 10)
	xp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	xp.custom_minimum_size.x = 360
	xp_box = xp
	add_child(xp)
	DmHudKit.place(xp, 0, 1, 18, -24, Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_BEGIN)
	var lvw := CenterContainer.new()
	lvw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	level_badge = DmHudParts.LevelBadge.new()
	lvw.add_child(level_badge)
	xp.add_child(lvw)
	dev_chip = DmHudKit.panel(DmUi.GOLD, Color(0, 0, 0, 0), Vector4(0, 0, 0, 0), Vector4(5, 1, 5, 1), 3)
	dev_chip.add_child(_txt("DEV", 10, Color("1a1206"), "numeric", 0.0, false))
	dev_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dev_chip.tooltip_text = "Dev access: every rite, area and gathering tier is open. Nothing is saved. Toggle it in Settings."
	dev_chip.visible = false
	xp.add_child(dev_chip)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	xp.add_child(col)
	xp_bar = DmHudBar.new(6.0)
	xp_bar.setup(Color("7d6b4f"), DmUi.BONE_300, DmUi.INSET, DmUi.BORDER, Color(0.8471, 0.8118, 0.7412, 0.35))
	col.add_child(xp_bar)
	var tr := HBoxContainer.new()
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(tr)
	var e := _txt("Experience", 12, DmUi.TEXT_MUTED, "numeric", 0.0, false)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tr.add_child(e)
	xp_txt = _txt("", 12, DmUi.TEXT_MUTED, "numeric", 0.0, false)
	tr.add_child(xp_txt)


func _orb_wrap(orb: DmHudOrb) -> Array:
	var w := VBoxContainer.new()
	w.add_theme_constant_override("separation", 4)
	w.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var oc := Control.new()
	oc.custom_minimum_size = Vector2(130, 130)  # 118 + the 6 px rings each side
	oc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	orb.position = Vector2(6, 6)
	oc.add_child(orb)
	w.add_child(oc)
	var t := _txt("", 14, DmUi.BONE_100, "numeric")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(t)
	var s := _txt("", 11, DmUi.TEXT_FAINT, "numeric_medium", 1.0, false)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(s)
	return [w, t, s]


func _build_altar() -> void:
	altar = HBoxContainer.new()
	altar.add_theme_constant_override("separation", 10)
	altar.alignment = BoxContainer.ALIGNMENT_CENTER
	altar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(altar)
	DmHudKit.place(altar, 0.5, 1, 0, -14, Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BEGIN)
	hp_orb = DmHudOrb.new()
	var hw := _orb_wrap(hp_orb)
	hp_txt = hw[1]
	hp_sub = hw[2]
	hp_sub.text = "HEALTH"
	var hwrap: VBoxContainer = hw[0]
	hwrap.size_flags_vertical = Control.SIZE_SHRINK_END
	altar.add_child(hwrap)
	var mid := VBoxContainer.new()
	mid.add_theme_constant_override("separation", 0)
	mid.size_flags_vertical = Control.SIZE_SHRINK_END
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	altar.add_child(mid)
	# soul harvest meter: 62% wide, centred, margin-bottom 6
	souls_box = DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.78), DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(8, 2, 8, 2))
	souls_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 8)
	sh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	souls_box.add_child(sh)
	souls_skull = TextureRect.new()
	souls_skull.texture = DmHudKit.icon("skull")
	souls_skull.custom_minimum_size = Vector2(18, 18)
	souls_skull.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	souls_skull.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	souls_skull.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	souls_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sh.add_child(souls_skull)
	souls_bar = DmHudBar.new(5.0)
	souls_bar.setup(Color("1f8f86"), Color("6fe3c8"), DmUi.INSET, DmUi.BORDER, Color(0.435, 0.89, 0.784, 0.55))
	souls_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sh.add_child(souls_bar)
	souls_n = _txt("", 12, DmUi.TEXT_MUTED, "numeric", 0.0, false)
	souls_n.custom_minimum_size.x = 48
	souls_n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sh.add_child(souls_n)
	souls_box.tooltip_text = "Soul Harvest — kills by you or your thralls fill the skull. When full, your next Marrow Spear, Miasma or Black Litany is free and 50% larger."
	souls_box.mouse_filter = Control.MOUSE_FILTER_PASS
	mid.add_child(souls_box)
	mid.add_child(DmUi.spacer(6))
	# slots wrap
	var wrap := DmHudKit.panel(Color(0.058, 0.04, 0.075, 0.95), DmUi.BORDER_STRONG, Vector4(1, 1, 1, 1), Vector4(14, 10, 14, 8), 2)
	var wsb: StyleBoxFlat = wrap.get_theme_stylebox("panel")
	wsb.shadow_color = Color(0, 0, 0, 0.6)
	wsb.shadow_size = 20
	wsb.shadow_offset = Vector2(0, 8)
	mid.add_child(wrap)
	wrap.resized.connect(func() -> void: souls_box.custom_minimum_size.x = wrap.size.x * 0.62)
	slots_row = HBoxContainer.new()
	slots_row.add_theme_constant_override("separation", 0)
	slots_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(slots_row)
	primary_slot = DmHudSlot.new()
	slots_row.add_child(primary_slot)
	slots_row.add_child(DmUi.spacer(0, 12))
	grim_btn = Button.new()
	grim_btn.focus_mode = Control.FOCUS_NONE
	grim_btn.custom_minimum_size = Vector2(104, 50)
	grim_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grim_btn.add_theme_stylebox_override("normal", DmHudKit.style(Color(0.039, 0.035, 0.055, 0.85), DmUi.BORDER_STRONG, Vector4(1, 1, 1, 1), Vector4(10, 6, 10, 6)))
	grim_btn.add_theme_stylebox_override("hover", DmHudKit.style(Color(0.039, 0.035, 0.055, 0.85), DmUi.BORDER_ACTIVE, Vector4(1, 1, 1, 1), Vector4(10, 6, 10, 6)))
	grim_btn.add_theme_stylebox_override("pressed", DmHudKit.style(Color(0.039, 0.035, 0.055, 0.85), DmUi.BORDER_ACTIVE, Vector4(1, 1, 1, 1), Vector4(10, 6, 10, 6)))
	grim_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	grim_btn.tooltip_text = "Open the Spellbook (L)"
	var gv := VBoxContainer.new()
	gv.add_theme_constant_override("separation", 2)
	gv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grim_btn.add_child(gv)
	var gi := TextureRect.new()
	gi.texture = DmHudKit.icon("grimoire")
	gi.custom_minimum_size = Vector2(22, 22)
	gi.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gi.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	gi.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	gi.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gv.add_child(gi)
	var gl := _txt("SPELLBOOK · L", 11, DmUi.BONE_100, "body_bold", 1.0, false)
	gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gv.add_child(gl)
	grim_btn.pressed.connect(func() -> void: open_grimoire.emit(null))
	var gvw := MarginContainer.new()
	gvw.add_theme_constant_override("margin_left", 10)
	gvw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gvw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gvw.add_child(grim_btn)
	slots_row.add_child(gvw)
	grim_btn.set_meta("host", gvw)
	grim_pip = DmUi.new_pip("NEW")
	grim_pip.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	grim_pip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grim_pip.offset_right = 8
	grim_pip.offset_top = -8
	grim_pip.visible = false
	grim_btn.add_child(grim_pip)
	_glow_on(grim_btn, "hud.spells")
	_tip_nodes["grimoire"] = grim_btn
	# thrall pips
	thrall_pips = DmHudParts.Diamonds.new()
	thrall_pips.side = 12.0
	thrall_pips.gap = 6.0
	var tc := CenterContainer.new()
	tc.custom_minimum_size.y = 14 + 6
	tc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tc.add_child(thrall_pips)
	mid.add_child(DmUi.spacer(6))
	mid.add_child(tc)
	var ew := _orb_wrap(ess_orb_make())
	ess_txt = ew[1]
	ess_sub = ew[2]
	var ewrap: VBoxContainer = ew[0]
	ewrap.size_flags_vertical = Control.SIZE_SHRINK_END
	altar.add_child(ewrap)


func ess_orb_make() -> DmHudOrb:
	ess_orb = DmHudOrb.new()
	ess_orb.use_resource_palette()
	return ess_orb


func _buy_button(label: String) -> Array:
	var b := Button.new()
	b.custom_minimum_size = Vector2(70, 40)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", DmHudKit.style(DmUi.INSET, DmUi.BORDER_STRONG))
	b.add_theme_stylebox_override("hover", DmHudKit.style(DmUi.INSET, DmUi.BORDER_ACTIVE))
	b.add_theme_stylebox_override("pressed", DmHudKit.style(DmUi.INSET, DmUi.BORDER_ACTIVE))
	b.add_theme_stylebox_override("disabled", DmHudKit.style(DmUi.INSET, DmUi.BORDER_STRONG))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 1)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)
	var a := _txt(label, 12, DmUi.BONE_100, "numeric", 0.0, false)
	a.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(a)
	var c := _txt("", 13, Color("e2c98f"), "numeric", 0.0, false)
	c.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(c)
	return [b, c]


func _up_row(icon_name: String, lbl_text: String, buy_label: String, bar_color_a: Color) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ibox := DmHudKit.panel(DmUi.INSET, DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(0, 0, 0, 0))
	ibox.custom_minimum_size = Vector2(34, 34)
	ibox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var ic := TextureRect.new()
	ic.texture = DmHudKit.icon(icon_name)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.custom_minimum_size = Vector2(22, 22)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ibox.add_child(ic)
	row.add_child(ibox)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 8)
	r1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(r1)
	var pct := _txt("", 15, DmUi.BONE_100, "numeric", 0.0, false)
	pct.custom_minimum_size.x = 44
	r1.add_child(pct)
	r1.add_child(_txt(lbl_text, 14, DmUi.TEXT_MUTED, "body", 0.0, false))
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 8)
	r2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(r2)
	var bar := DmHudBar.new(5.0)
	bar.setup(DmUi.VEIL_500, DmUi.SPELL_300, DmUi.INSET, DmUi.BORDER, Color(0.608, 0.361, 1.0, 0.6))
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r2.add_child(bar)
	var gems := DmHudParts.Diamonds.new()
	gems.side = 8.0
	gems.gap = 4.0
	gems.fill_on = DmUi.SPELL_300
	gems.edge_on = DmUi.SPELL_300
	gems.edge_off = DmUi.SPELL_300
	gems.glow_on = Color(DmUi.SPELL_400, 0.6)
	gems.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r2.add_child(gems)
	var buy := _buy_button(buy_label)
	row.add_child(buy[0])
	return [row, pct, bar, gems, buy[0], buy[1]]


func _build_right() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	DmHudKit.place(col, 1, 1, -18, -18, Control.GROW_DIRECTION_BEGIN, Control.GROW_DIRECTION_BEGIN)
	up_panel = PanelContainer.new()
	up_panel.theme_type_variation = "DmPlate"
	up_panel.add_theme_stylebox_override("panel", DmHudKit.style(DmUi.PANEL, DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(14, 12, 14, 12), 3))
	up_panel.custom_minimum_size.x = 300
	up_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	up_plate = DmHudParts.OverlayHost.new(up_panel)
	up_plate.size_flags_horizontal = Control.SIZE_SHRINK_END
	var uv := VBoxContainer.new()
	uv.add_theme_constant_override("separation", 12)
	uv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	up_panel.add_child(uv)
	var d := _up_row("crown", "Damage", "Empower", DmUi.VEIL_500)
	uv.add_child(d[0])
	dmg_pct = d[1]
	dmg_bar = d[2]
	dmg_gems = d[3]
	dmg_buy = d[4]
	dmg_cost = d[5]
	dmg_buy.pressed.connect(func() -> void: buy_damage.emit())
	var w := _up_row("skull", "Wave Speed", "Quicken", DmUi.VEIL_500)
	var wv := VBoxContainer.new()
	wv.add_theme_constant_override("separation", 6)
	wv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wv.add_child(w[0])
	wave_pct = w[1]
	wave_bar = w[2]
	wave_gems = w[3]
	wave_buy = w[4]
	wave_cost = w[5]
	wave_buy.pressed.connect(func() -> void: buy_wave.emit())
	dial_box = HFlowContainer.new()
	dial_box.add_theme_constant_override("h_separation", 6)
	dial_box.add_theme_constant_override("v_separation", 6)
	dial_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial_box.add_child(_txt("Active", 12, DmUi.TEXT_MUTED, "body", 0.0, false))
	dial_minus = _dial_button("−")
	dial_minus.pressed.connect(func() -> void: dial_wave.emit(-1))
	dial_box.add_child(dial_minus)
	dial_tier = _txt("", 12, DmUi.BONE_100, "numeric", 0.0, false)
	dial_tier.custom_minimum_size.x = 64
	dial_tier.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dial_box.add_child(dial_tier)
	dial_plus = _dial_button("+")
	dial_plus.pressed.connect(func() -> void: dial_wave.emit(1))
	dial_box.add_child(dial_plus)
	dial_ms = _txt("", 12, DmUi.TEXT_MUTED, "body", 0.0, false)
	dial_ms.custom_minimum_size.x = 270
	dial_ms.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dial_box.add_child(dial_ms)
	wv.add_child(dial_box)
	uv.add_child(wv)
	up_panel.add_child(DmCorners.new())
	_glow_on(up_plate, "hud.upgrades")
	_pip_on(up_plate, "hud.upgrades")
	_tip_nodes["wave"] = up_plate
	col.add_child(up_plate)
	# currency
	var cur := HBoxContainer.new()
	cur.add_theme_constant_override("separation", 18)
	cur.size_flags_horizontal = Control.SIZE_SHRINK_END
	cur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(cur)
	var g := HBoxContainer.new()
	g.add_theme_constant_override("separation", 6)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_child(_cur_icon(DmHudKit.tex(DmHudKit.ART + "ui/gold.webp"), 24))
	gold_lbl = _txt("0", 16, DmUi.BONE_100, "numeric")
	g.add_child(gold_lbl)
	cur.add_child(g)
	thrall_chip = HBoxContainer.new()
	thrall_chip.add_theme_constant_override("separation", 6)
	thrall_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thrall_chip.add_child(_cur_icon(DmHudKit.icon("skull"), 20))
	thrall_num = _txt("0/0", 16, DmUi.BONE_100, "numeric")
	thrall_chip.add_child(thrall_num)
	cur.add_child(thrall_chip)
	shard_chip = HBoxContainer.new()
	shard_chip.add_theme_constant_override("separation", 6)
	shard_chip.mouse_filter = Control.MOUSE_FILTER_PASS
	shard_chip.add_child(_cur_icon(DmHudKit.tex(DmHudKit.ART + "ui/soul_shard.webp"), 24))
	shard_lbl = _txt("0", 16, DmUi.BONE_100, "numeric")
	shard_chip.add_child(shard_lbl)
	cur.add_child(shard_chip)
	_tip_nodes["prelate"] = shard_chip
	save_lbl = _txt("", 12, DmUi.TEXT_FAINT, "body", 0.0, false)
	save_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	save_lbl.custom_minimum_size.y = 16
	col.add_child(save_lbl)


func _cur_icon(t: Texture2D, px: int) -> TextureRect:
	var r := TextureRect.new()
	r.texture = t
	r.custom_minimum_size = Vector2(px, px)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _dial_button(t: String) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(22, 22)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", DmUi.BONE_100)
	b.add_theme_color_override("font_disabled_color", Color(DmUi.BONE_100, 0.35))
	b.add_theme_stylebox_override("normal", DmHudKit.style(DmUi.INSET, DmUi.BORDER))
	b.add_theme_stylebox_override("hover", DmHudKit.style(DmUi.INSET, DmUi.BORDER_ACTIVE))
	b.add_theme_stylebox_override("pressed", DmHudKit.style(DmUi.INSET, DmUi.BORDER_ACTIVE))
	b.add_theme_stylebox_override("disabled", DmHudKit.style(DmUi.INSET, DmUi.BORDER))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


func _build_death() -> void:
	death = _Wash.new()
	death.set_anchors_preset(Control.PRESET_FULL_RECT)
	death.mouse_filter = Control.MOUSE_FILTER_IGNORE
	death.modulate.a = 0.0
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.grow_horizontal = Control.GROW_DIRECTION_BOTH
	v.grow_vertical = Control.GROW_DIRECTION_BOTH
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	death.add_child(v)
	var t := _txt("YOU HAVE FALLEN", 56, DmUi.BONE_100, "display_bold", 11.0, false)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	death_sub = _txt("", 20, DmUi.TEXT_MUTED, "display_italic", 0.0, false)
	death_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(death_sub)
	add_child(death)


class _Wash extends Control:
	func _draw() -> void:
		# radial-gradient(circle, rgba(20,4,14,.4), rgba(7,6,10,.88))
		var c := size * 0.5
		var rmax := c.length()
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0275, 0.0235, 0.0392, 0.88))
		var n := 48
		for i in n:
			var t := 1.0 - float(i) / n
			var col := Color(0.078, 0.016, 0.055, 0.4).lerp(Color(0.0275, 0.0235, 0.0392, 0.88), 1.0 - t)
			draw_circle(c, rmax * t, col)


# ======================================================================== layout (viewport-relative widths)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and target_box != null:
		_sec_hash.clear()   # width-dependent readouts (the hint's ellipsis) re-apply
		_fit_safe_frame()
		var w := safe.size.x if safe != null and safe.size.x > 0.0 else size.x
		target_box.custom_minimum_size.x = minf(440.0, w * 0.5)
		boss.custom_minimum_size.x = minf(620.0, w * 0.6)
		# The altar (orbs + bar) is 960 wide, centred, with a 18 px gutter on each side: the side columns take what is left of that.
		xp_box.custom_minimum_size.x = clampf(w * 0.5 - 516.0, 150.0, 360.0)
		chat_col.custom_minimum_size.x = clampf(w * 0.5 - 506.0, 170.0, 320.0)
		up_panel.custom_minimum_size.x = clampf(w * 0.5 - 500.0, 230.0, 300.0)
		hint.custom_minimum_size.x = 0.0
		# toasts sit lower while a target / boss plate is up
		_update_toast_top()


func _frame_w() -> float:
	return safe.size.x if safe != null and safe.size.x > 0.0 else size.x


func _update_toast_top() -> void:
	var low := boss.visible or target_box.visible
	toasts.offset_top = 112.0 if low else 64.0
	toasts.offset_bottom = toasts.offset_top
	var kids := toasts.get_children()
	for i in kids.size():
		(kids[i] as Control).visible = (not low) or (kids.size() - i) <= 2


# ======================================================================== apply

## The view-model keys each apply section reads. A section whose inputs hash the same as at its last apply is skipped: assigning a Label's
## text or a RichTextLabel's markup, a theme override or a container child re-lays and redraws the control even when the value did not change.
const SECTIONS := {
	"flags": ["reveal", "new", "grimoire_new", "dev"],
	"vitals": ["hp", "max_hp", "barrier", "essence", "max_essence", "resource_label", "resource_color", "beat_pulse", "level", "xp", "xp_next"],
	"souls": ["souls", "souls_max", "thralls", "thrall_cap", "raises_thralls", "thrall_hurt"],
	"economy": ["gold", "shards", "save"],
	"upgrades": ["gold", "damage", "wave"],
	"left": ["ward", "chain", "brews", "omen", "party"],
	"target": ["boss", "target"],
	"column": ["area_name", "area_progress", "depth", "next", "auto_combat"],
	"misc": ["prompt", "hint", "death"],
}
var _sec_hash := {}   ## section -> hash of its inputs at the last apply

## True when section `sec`'s inputs differ from the last apply (and remembers them).
func _changed(sec: String, v: Dictionary) -> bool:
	var vals: Array = []
	for k in SECTIONS[sec]:
		vals.append(v.get(k))
	var h := vals.hash()
	if _sec_hash.get(sec, 0) == h:
		return false
	_sec_hash[sec] = h
	return true


func apply(v: Dictionary) -> void:
	vm = v
	if _changed("flags", v):
		_apply_flags(v)
	if _changed("vitals", v):
		_apply_vitals(v)
	_apply_slots(v)
	_refresh_spell_tip()
	if _changed("souls", v):
		_apply_souls_thralls(v)
	if _changed("economy", v):
		_apply_economy(v)
	if _changed("upgrades", v):
		_apply_upgrades(v)
	if _changed("left", v):
		_apply_left_readouts(v)
	if _changed("target", v):
		_apply_target_boss(v)
	_apply_map_column(v, _changed("column", v))
	if _changed("misc", v):
		_apply_misc(v)
	else:
		area_lbl.tooltip_text = ""
	_update_toast_top()


func _apply_flags(v: Dictionary) -> void:
	_reveal = v.get("reveal", {})
	_new = v.get("new", {})
	# progressive elements: absent = revealed (the integrator only lists what is still held back)
	up_plate.visible = bool(_reveal.get("hud.upgrades", true))
	dial_box.visible = bool(_reveal.get("hud.dial", true))
	shard_chip.visible = bool(_reveal.get("hud.shards", true))
	grim_btn.get_meta("host").visible = bool(_reveal.get("hud.spells", true))
	for id in _glows:
		for g in _glows[id]:
			(g as DmHudParts.NewGlow).active = bool(_new.get(id, false))
	for id in _pips:
		for p in _pips[id]:
			(p as Control).visible = bool(_new.get(id, false))
	for id in menu_btns:
		var b: Button = menu_btns[id]
		if b.has_meta("gate"):
			b.visible = bool(_reveal.get(b.get_meta("gate"), true))
	grim_pip.visible = bool(v.get("grimoire_new", false))
	dev_chip.visible = bool(v.get("dev", false))


func _apply_vitals(v: Dictionary) -> void:
	var max_hp := maxf(float(v.get("max_hp", 1)), 1.0)
	var hp := float(v.get("hp", 0))
	var hp_frac := maxf(0.0, hp / max_hp)
	hp_orb.fill = hp_frac
	hp_orb.barrier = minf(0.9, float(v.get("barrier", 0)) / max_hp * 3.0)
	hp_txt.text = "%s / %s" % [DmHudKit.commas(ceil(hp)), DmHudKit.commas(max_hp)]
	vignette.low = hp_frac < 0.3 and hp > 0.0
	var max_e := maxf(float(v.get("max_essence", 1)), 1.0)
	var ess := float(v.get("essence", 0))
	ess_orb.fill = ess / max_e
	var res_label := String(v.get("resource_label", "Grave Essence"))
	ess_txt.text = "%d / %d" % [int(floor(ess)), int(max_e)]
	ess_sub.text = DmUi.upper(res_label)
	var rc := String(v.get("resource_color", ""))
	if rc == "":
		ess_orb.use_resource_palette()
	else:
		ess_orb.set_resource_color(Color(rc))
	ess_orb.beat_pulse = bool(v.get("beat_pulse", false))
	level_badge.text.text = str(int(v.get("level", 1)))
	var xp := float(v.get("xp", 0))
	var xn := maxf(float(v.get("xp_next", 1)), 1.0)
	xp_bar.value = minf(1.0, xp / xn)
	xp_txt.text = "%s / %s" % [DmHudKit.commas(xp), DmHudKit.commas(xn)]


func _apply_slots(v: Dictionary) -> void:
	_bind_primary_tip()
	var prim: Dictionary = v.get("primary", {})
	if prim.is_empty():
		primary_slot.visible = false
	else:
		primary_slot.visible = true
		var p := prim.duplicate()
		p["key"] = p.get("key", "LMB")
		primary_slot.apply(p)
		if not primary_slot.pressed.is_connected(_on_cast_primary):
			primary_slot.pressed.connect(_on_cast_primary)
		var key_lbl: Control = primary_slot.get_child(1).get_child(0)
		if not key_lbl.has_theme_color_override("font_color") or key_lbl.get_theme_color("font_color") != DmUi.GOLD:
			key_lbl.add_theme_color_override("font_color", DmUi.GOLD)
	var slots: Array = v.get("slots", [])
	var sig := ""
	for s in slots:
		sig += "%s|" % bool(s.get("alt", false))
	if sig != _slot_sig or _slots.size() != slots.size():
		_rebuild_slots(slots)
		_slot_sig = sig
	for i in slots.size():
		_slots[i].apply(slots[i])


func _on_cast_primary() -> void:
	cast.emit(0)


func _rebuild_slots(slots: Array) -> void:
	_slots.clear()
	# keep the primary slot, spacer and grimoire host; the hotbar goes between spacer and grim button host
	var anchor_idx := 2
	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 12)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.set_meta("slots_inner", true)
	for old in slots_row.get_children():
		if old.has_meta("slots_inner"):
			slots_row.remove_child(old)
			old.queue_free()
	slots_row.add_child(inner)
	slots_row.move_child(inner, anchor_idx)
	for i in slots.size():
		var s := DmHudSlot.new()
		var cell: Control = s
		if bool(slots[i].get("alt", false)):
			# `.hud-slot.alt`: 12 px padding and a 1 px rule on the left
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 0)
			h.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var rule := ColorRect.new()
			rule.color = DmUi.BORDER
			rule.custom_minimum_size.x = 1
			rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
			h.add_child(rule)
			h.add_child(DmUi.spacer(0, 12))
			h.add_child(s)
			cell = h
		inner.add_child(cell)
		_slots.append(s)
		var idx := i
		s.pressed.connect(func() -> void: cast.emit(idx + 1))
		s.swap_pressed.connect(func() -> void: swap_slot.emit(idx))


var _souls_full := -1
var _thr_hurt := 0
var _depth_open := -1

func _apply_souls_thralls(v: Dictionary) -> void:
	var souls := float(v.get("souls", 0))
	var smax := maxf(float(v.get("souls_max", 1)), 1.0)
	var full := souls >= smax
	souls_bar.value = minf(1.0, souls / smax)
	souls_n.text = "HARVEST" if full else "%d / %d" % [int(souls), int(smax)]
	# Restyle only when the state flips (a new StyleBox + theme change every 50 ms re-laid the left column).
	if int(full) != _souls_full:
		_souls_full = int(full)
		souls_n.add_theme_color_override("font_color", Color("9ff5e0") if full else DmUi.TEXT_MUTED)
		souls_box.add_theme_stylebox_override("panel", DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.78), Color(0.435, 0.89, 0.784, 0.6) if full else DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(8, 2, 8, 2)))
		souls_skull.modulate = Color("9ff5e0") if full else Color.WHITE
	var thr := int(v.get("thralls", 0))
	var cap := int(v.get("thrall_cap", 0))
	var on := bool(v.get("raises_thralls", false)) or thr > 0
	thrall_pips.get_parent().visible = on
	thrall_chip.visible = on
	var flags: Array = []
	var hurt := int(v.get("thrall_hurt", 0))   # living thralls under a third of their health: their pips are red
	for i in cap:
		flags.append((2 if i < hurt else true) if i < thr else false)
	thrall_pips.set_state(flags)
	thrall_num.text = "%d/%d" % [thr, cap]
	if int(hurt > 0) != _thr_hurt:   # restyle only on a flip (a theme change every 50 ms re-lays the column)
		_thr_hurt = int(hurt > 0)
		thrall_num.add_theme_color_override("font_color", Color("ff8a78") if hurt > 0 else DmUi.BONE_100)


func _apply_economy(v: Dictionary) -> void:
	gold_lbl.text = DmHudKit.commas(float(v.get("gold", 0)))
	shard_lbl.text = str(int(v.get("shards", 0)))
	var sv: Dictionary = v.get("save", {})
	save_lbl.text = String(sv.get("text", ""))
	DmHudKit.set_color(save_lbl, "font_color", DmUi.DANGER if bool(sv.get("warn", false)) else DmUi.TEXT_FAINT)


func _apply_upgrades(v: Dictionary) -> void:
	var gold := float(v.get("gold", 0))
	var d: Dictionary = v.get("damage", {})
	var dmax := float(DmUpgrades.max_tier("damage"))
	var dtier := float(d.get("tier", 0))
	dmg_pct.text = "+%d%%" % int(d.get("pct", 0))
	dmg_bar.value = dtier / dmax
	dmg_gems.set_state(DmUpgrades.milestones(dtier, dmax))
	var dcost: Variant = d.get("cost", null)
	var dmax_reached: bool = dcost == null
	dmg_cost.text = "Max" if dmax_reached else DmHudKit.commas(float(dcost)) + "g"
	dmg_buy.disabled = dmax_reached or gold < float(dcost)
	dmg_buy.modulate.a = 0.45 if dmg_buy.disabled else 1.0
	var w: Dictionary = v.get("wave", {})
	var wmax := float(DmUpgrades.max_tier("wave"))
	var owned := int(w.get("owned", 0))
	var active := int(w.get("active", 0))
	wave_pct.text = "+%d%%" % int(w.get("pct", 0))
	wave_bar.value = float(owned) / wmax
	wave_gems.set_state(DmUpgrades.milestones(owned, wmax))
	var wcost: Variant = w.get("cost", null)
	wave_cost.text = "Max" if wcost == null else DmHudKit.commas(float(wcost)) + "g"
	wave_buy.disabled = wcost == null or gold < float(wcost)
	wave_buy.modulate.a = 0.45 if wave_buy.disabled else 1.0
	dial_tier.text = "Tier %d / %d" % [active, owned]
	dial_minus.disabled = active <= 0
	dial_plus.disabled = active >= owned
	var ms := wave_milestone_text(active)
	dial_ms.text = ms[0]
	DmHudKit.set_color(dial_ms, "font_color", Color("d9a441") if ms[1] else DmUi.TEXT_MUTED)
	dial_ms.visible = ms[0] != ""


## The dial's line under the tier: top active milestone (+N more), or the next one to reach. Returns [text, active?].
static func wave_milestone_text(active_tier: int) -> Array:
	var all: Array = DmProgContent.upgrades()["waveMilestones"]
	var act: Array = []
	var nxt: Variant = null
	for m in all:
		if active_tier >= int(m["tier"]):
			act.append(m)
		elif nxt == null:
			nxt = m
	if act.size() > 0:
		var top: Dictionary = act[act.size() - 1]
		return [String(top["name"]) + (" +%d" % (act.size() - 1) if act.size() > 1 else ""), true]
	if nxt != null:
		return ["%s at tier %d" % [nxt["name"], int(nxt["tier"])], false]
	return ["", false]


var _chain_tier := -1

func _apply_left_readouts(v: Dictionary) -> void:
	var w: Variant = v.get("ward")
	ward.visible = w != null and int((w as Dictionary).get("pct", 0)) > 0
	if ward.visible:
		ward_n.text = "−%d%%" % int(w["pct"])
		ward.tooltip_text = "Each active thrall shields you from %d%% of incoming damage (you have %d; the most it gives is 60%%)." % [int(round(float(w.get("per_thrall", 0.0)) * 100.0)), int(w.get("thralls", 0))]
	var c: Variant = v.get("chain")
	chain.visible = c != null
	if c != null:
		chain_n.text = "×%d" % int(c["count"])
		var bonus := float(c.get("bonus", 0.0))
		chain_lbl.text = DmUi.upper("%s · +%d%% XP & gold" % [c["name"], int(round(bonus * 100.0))]) if bonus > 0.0 else "CHAIN"
		var tier := clampi(int(c.get("tier", 0)), 0, 5)
		var col := DmUi.BONE_300 if tier == 0 else Color(String(CHAIN_TIER[tier]))
		# Restyle only when the tier changes: a theme override per frame re-laid the whole left column every frame (~1.6 ms).
		if tier != _chain_tier:
			_chain_tier = tier
			chain_n.add_theme_color_override("font_color", col)
			chain_bar.fill_a = col
			chain_bar.fill_b = col
			chain.add_theme_stylebox_override("panel", DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.55), col, Vector4(3, 0, 0, 0), Vector4(12, 6, 12, 8)))
		chain_bar.value = float(c.get("frac", 0.0))
	var brews: Array = v.get("brews", [])
	brews_box.visible = brews.size() > 0
	var seen := {}
	for b in brews:
		var slot := String(b.get("slot", ""))
		seen[slot] = true
		var chip: DmHudBrewChip = _brew_chips.get(slot)
		if chip == null:
			chip = DmHudBrewChip.new()
			chip.clicked.connect(func(s: String) -> void: belt_clicked.emit(s))
			chip.dropped.connect(func(s: String, id: String) -> void: brew_dropped.emit(s, id))
			brew_row.add_child(chip)
			_brew_chips[slot] = chip
		chip.apply(b)
	for slot in _brew_chips.keys():
		if not seen.has(slot):
			_brew_chips[slot].queue_free()
			_brew_chips.erase(slot)
	var om: Variant = v.get("omen")
	omen_host.visible = om != null and bool((om as Dictionary).get("visible", true))
	if om != null:
		omen_img.texture = DmHudKit.tex(String(om.get("icon", "")))
		omen_name.text = DmUi.upper(String(om.get("name", "")))
		omen.tooltip_text = String(om.get("blurb", ""))
	# party (up to MAX_PARTY_SIZE = 4)
	var party: Array = v.get("party", [])
	var psig := ""
	for m in party:
		psig += "%s%s%s%d|" % [m.get("id", ""), m.get("name", ""), m.get("discipline", ""), int(round(float(m.get("hp_frac", 1.0)) * 20.0))]
	if psig != str(party_box.get_meta("sig", "")):
		party_box.set_meta("sig", psig)
		for ch in party_box.get_children():
			ch.queue_free()
		for i in mini(party.size(), 4):
			party_box.add_child(_member(party[i]))


func _member(m: Dictionary) -> Control:
	var p := DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.82), DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(5, 5, 8, 5))
	p.custom_minimum_size.x = 210
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	var pb := DmHudKit.panel(Color(0, 0, 0, 0), DmUi.BORDER_STRONG, Vector4(1, 1, 1, 1), Vector4(0, 0, 0, 0))
	pb.custom_minimum_size = Vector2(34, 34)
	var img := TextureRect.new()
	img.texture = DmHudKit.tex(String(m.get("portrait", "")))
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pb.add_child(img)
	h.add_child(pb)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(v)
	var n := _txt(String(m.get("name", "")), 13, DmUi.BONE_100, "body_bold", 0.0, false)
	n.clip_text = true
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(n)
	v.add_child(_txt(DmUi.upper(String(m.get("discipline", ""))), 11, DmUi.TEXT_FAINT, "body", 1.0, false))
	var bw := MarginContainer.new()
	bw.add_theme_constant_override("margin_top", 3)
	bw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar := DmHudBar.new(4.0)
	bar.setup(Color("8a3a6c"), Color("8a3a6c"), DmUi.INSET, Color(0, 0, 0, 0))
	bar.value = float(m.get("hp_frac", 1.0))
	bw.add_child(bar)
	v.add_child(bw)
	return p


func _apply_target_boss(v: Dictionary) -> void:
	var b: Variant = v.get("boss")
	var t: Variant = v.get("target") if b == null else null
	boss.visible = b != null
	if b != null:
		boss_name.text = DmUi.upper(String(b["name"]))
		var phases: Array = b.get("phases", ["The bell is silent", "The procession begins", "The bell is breaking"])
		var ph := int(b.get("phase", 1))
		boss_phase.text = DmUi.upper(String(phases[ph - 1])) if ph >= 1 and ph <= phases.size() else ""
		var mh := maxf(float(b.get("max_hp", 1)), 1.0)
		var hp := float(b.get("hp", 0))
		boss_bar.value = maxf(0.0, hp / mh)
		boss_num.text = "%s / %s" % [DmHudKit.commas(maxf(0.0, ceil(hp))), DmHudKit.commas(ceil(mh))]
	target_box.visible = t != null
	if t != null:
		var sig := "%s|%s|%s" % [t["name"], t.get("elite", false), str(t.get("affixes", []))]
		if sig != str(target_name_row.get_meta("sig", "")):
			target_name_row.set_meta("sig", sig)
			for ch in target_name_row.get_children():
				ch.queue_free()
			target_name_row.add_child(_txt(DmUi.upper(String(t["name"])), 18, DmUi.BONE_100, "display_bold", 2.0))
			if bool(t.get("elite", false)):
				var e := _txt("◆ ELITE", 13, DmUi.SPELL_300, "display_bold", 2.0)
				var mw := MarginContainer.new()
				mw.add_theme_constant_override("margin_left", 6)
				mw.mouse_filter = Control.MOUSE_FILTER_IGNORE
				mw.add_child(e)
				target_name_row.add_child(mw)
			for a in t.get("affixes", []):
				var col := Color(String(AFFIX_COLOR.get(String(a.get("id", "")), "d8cfbd")))
				var chip := DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.7), col, Vector4(1, 1, 1, 1), Vector4(6, 0, 6, 0))
				chip.add_child(_txt(DmUi.upper(String(a.get("name", ""))), 13, col, "body", 2.0, false))
				var cw := MarginContainer.new()
				cw.add_theme_constant_override("margin_left", 8)
				cw.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cw.add_child(chip)
				target_name_row.add_child(cw)
			target_blurb.text = String(t.get("blurb", ""))
		target_bar.value = maxf(0.0, float(t.get("hp", 0)) / maxf(float(t.get("max_hp", 1)), 1.0))
		var ssig := str(t.get("statuses", []))
		if ssig != str(target_stat.get_meta("sig", "")):
			target_stat.set_meta("sig", ssig)
			for ch in target_stat.get_children():
				ch.queue_free()
			for s in t.get("statuses", []):
				var sp := DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.85), DmUi.BORDER, Vector4(1, 1, 1, 1), Vector4(1, 1, 6, 1))
				sp.tooltip_text = String(s.get("label", ""))
				sp.mouse_filter = Control.MOUSE_FILTER_PASS
				var sh := HBoxContainer.new()
				sh.add_theme_constant_override("separation", 3)
				sh.mouse_filter = Control.MOUSE_FILTER_IGNORE
				sp.add_child(sh)
				var ic := TextureRect.new()
				ic.texture = DmHudKit.tex(String(s.get("icon", "")))
				ic.custom_minimum_size = Vector2(22, 22)
				ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
				sh.add_child(ic)
				sh.add_child(_txt("%s ×%d" % [s.get("label", ""), int(s.get("n", 1))], 12, DmUi.BONE_100, "numeric", 0.0, false))
				target_stat.add_child(sp)


func _apply_map_column(v: Dictionary, changed: bool) -> void:
	var m: Variant = v.get("minimap")
	if m != null:
		minimap.apply(m)
	if not changed:
		return
	area_lbl.text = DmUi.upper(String(v.get("area_name", "")))
	prog_lbl.text = "[center]" + DmUi.markup(String(v.get("area_progress", "")), DmUi.SPELL_300).replace("[b][color=#%s]" % DmUi.BONE_100.to_html(false), "[color=#%s]" % DmUi.SPELL_300.to_html(false)).replace("[/color][/b]", "[/color]") + "[/center]"
	var d: Variant = v.get("depth")
	depth_box.visible = d != null
	if d != null:
		var open := bool(d.get("open", false))
		var col := Color("ffb347") if open else DmUi.BONE_300
		depth_n.text = str(int(d["depth"]))
		DmHudKit.set_color(depth_n, "font_color", col)
		depth_k.text = "STAIR OPEN" if open else "%d/%d" % [int(d["kills"]), int(d["need"])]
		DmHudKit.set_color(depth_k, "font_color", col)
		depth_bar.fill_a = col
		depth_bar.fill_b = col
		depth_bar.value = float(d["kills"]) / maxf(float(d["need"]), 1.0)
		var chest := bool(d.get("chest", false))
		depth_cue.text = ("The stair is open · a chest waits on this floor" if chest else "Follow the amber mark on the minimap") if open else ("A chest waits on this floor" if chest else "")
		depth_cue.visible = depth_cue.text != ""
		DmHudKit.set_color(depth_cue, "font_color", Color("ffcf85") if open else DmUi.TEXT_MUTED)
		if int(open) != _depth_open:
			_depth_open = int(open)
			depth_box.add_theme_stylebox_override("panel", DmHudKit.style(Color(0.0275, 0.0235, 0.0392, 0.5), col if open else DmUi.BORDER_STRONG, Vector4(0, 0, 0, 2), Vector4(8, 4, 8, 5)))
	var nx: Variant = v.get("next")
	next_box.visible = nx != null and String(nx) != ""
	next_txt.text = String(nx) if nx != null else ""
	var ac: Dictionary = v.get("auto_combat", {})
	auto_btn.visible = bool(ac.get("visible", false))
	var avail := bool(ac.get("available", false))
	auto_btn.disabled = not avail
	auto_btn.text = ("Auto: On · G" if bool(ac.get("on", false)) else "Auto: Off · G") if avail else "Auto: Easy only"
	auto_btn.tooltip_text = "Toggle auto combat (G)" if avail else "Available on Easy difficulty"


func _apply_misc(v: Dictionary) -> void:
	area_lbl.tooltip_text = ""
	var pr: Variant = v.get("prompt")
	prompt.visible = pr != null and String(pr) != ""
	if prompt.visible:
		prompt_rt.text = DmUi.markup(String(pr))
	hint.text = _ellipsize(String(v.get("hint", "")), 13, minf(640.0, _frame_w() - 700.0) if size.x > 0.0 else 640.0)
	var dv: Dictionary = v.get("death", {})
	var show := bool(dv.get("show", false))
	death_sub.text = String(dv.get("sub", ""))
	if show != bool(death.get_meta("shown", false)):
		death.set_meta("shown", show)
		create_tween().tween_property(death, "modulate:a", 1.0 if show else 0.0, 0.8)


## `max-width + text-overflow: ellipsis` for a one-line label that must keep its natural width otherwise.
func _ellipsize(text: String, font_size: int, max_w: float) -> String:
	var f := DmUi.font("body")
	if max_w <= 0.0 or f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
		return text
	var t := text
	while t.length() > 1 and f.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > max_w:
		t = t.substr(0, t.length() - 1)
	return t + "…"


# ======================================================================== events

func toast(text: String, kind: String = "", on_click: Callable = Callable()) -> void:
	# the same line twice is one toast; three at most
	for old in toasts.get_children():
		if old.has_meta("text") and old.get_meta("text") == text and not old.has_meta("loot"):
			toasts.remove_child(old)
			old.queue_free()
	var hold := maxf(6000.0, 2000.0 + text.split(" ", false).size() * 400.0) / 1000.0
	var t := DmToast.make(text, "new_cue" if kind == "new" else kind, hold)
	t.set_meta("text", text)
	if on_click.is_valid():
		t.set_clickable(on_click)
	toasts.add_child(t)
	var plain := []
	for c in toasts.get_children():
		if not c.has_meta("loot"):
			plain.append(c)
	while plain.size() > 3:
		var o: Node = plain.pop_front()
		toasts.remove_child(o)
		o.queue_free()
	_update_toast_top()


## A pickup. The same item again while its toast is up becomes "Name ×3" and restarts its clock; minor loot lives 3.5 s.
func loot_toast(item_name: String, qty: int, rarity: String) -> void:
	var minor := rarity == "common" or rarity == "uncommon"
	var total := qty
	var live: Variant = _loot_toasts.get(item_name)
	if live != null and is_instance_valid(live) and live.is_inside_tree():
		total += int(live.get_meta("total"))
		toasts.remove_child(live)
		live.queue_free()
	var line := item_name if total <= 1 else "%s ×%d" % [item_name, total]
	var t := DmToast.make(line, "loot" if minor else "loot_major", 3.5 if minor else 8.0)
	t.set_meta("loot", true)
	t.set_meta("minor", minor)
	t.set_meta("total", total)
	toasts.add_child(t)
	_loot_toasts[item_name] = t
	# four at most with loot in the stack: the oldest minor pickup goes first, then the oldest of anything
	while toasts.get_child_count() > 4:
		var victim: Node = toasts.get_child(0)
		for c in toasts.get_children():
			if c.has_meta("minor") and c.get_meta("minor"):
				victim = c
				break
		toasts.remove_child(victim)
		victim.queue_free()
	_update_toast_top()


func banner(title: String, sub: String = "", ms: int = 3200) -> void:
	if _banner != null and is_instance_valid(_banner):
		_banner.get_parent().queue_free()
	# DmBanner's own play() tweens `position`, which fights a centring container: the HUD drives the fade itself (0.6 s in, hold, 0.6 s out).
	var row := CenterContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner_host.add_child(row)
	_banner = DmBanner.make(title, sub, 0.0)
	row.add_child(_banner)
	_banner.modulate.a = 1.0
	row.modulate.a = 0.0
	row.position.y = -8.0
	var tw := row.create_tween()
	tw.set_parallel(true)
	tw.tween_property(row, "modulate:a", 1.0, 0.6)
	tw.tween_property(row, "position:y", 0.0, 0.6)
	var tw2 := row.create_tween()
	tw2.tween_interval(maxf(0.0, ms / 1000.0 - 0.6))
	tw2.tween_property(row, "modulate:a", 0.0, 0.6)
	tw2.tween_callback(row.queue_free)


func banner_active() -> bool:
	return _banner != null and is_instance_valid(_banner)


func hit_flash() -> void:
	vignette.flash()


func slot_flash(n: int) -> void:
	if n == 0:
		primary_slot.flash()
	elif n >= 1 and n <= _slots.size():
		_slots[n - 1].flash()


func float_text(screen_pos: Vector2, text: String, kind: String = "hit", color: Color = Color(0, 0, 0, 0)) -> void:
	DmFloatingNumber.spawn(float_layer, screen_pos, text, kind, color)


func chat_line(text: String) -> void:
	var p := DmHudKit.panel(Color(0.0275, 0.0235, 0.0392, 0.62), Color(0, 0, 0, 0), Vector4(0, 0, 0, 0), Vector4(8, 3, 8, 3))
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var l := _txt(text, 13, DmUi.BONE_300, "body", 0.0, false)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = minf(l.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 2.0, 300.0)
	p.add_child(l)
	chat_log.add_child(p)
	while chat_log.get_child_count() > 8:
		var o := chat_log.get_child(0)
		chat_log.remove_child(o)
		o.queue_free()


func focus_chat() -> void:
	chat_in.grab_focus()


## Counsel-tip glow target (Onboarding.ts TIP_ANCHOR): the screen rect of the HUD part a tip is about, or an empty Rect2.
func tip_anchor_rect(tip_id: String) -> Rect2:
	var n: Control = _tip_nodes.get(tip_id)
	if n == null or not n.is_visible_in_tree():
		return Rect2()
	return n.get_global_rect()


## Default counsel-card position (Onboarding.ts DEFAULT_X/Y): top-left, under the party list when co-op fills the corner.
func tip_default_position() -> Vector2:
	var below := 0.0
	if party_box.get_child_count() > 0:
		below = party_box.get_global_rect().end.y + 8.0
	var s := effective_scale
	return Vector2(safe.position.x + 18.0 * s, maxf(70.0 * s, below)) if safe != null else Vector2(18.0, maxf(70.0, below))


# ======================================================================== spell card (HUD.showTooltip / refreshTooltip)

func _bind_primary_tip() -> void:
	pass   # the bar shows no spell cards: spell info lives in the Grimoire


func _primary_hover(on: bool) -> void:
	_spell_hover(-1, primary_slot, on)


func _spell_hover(idx: int, s: DmHudSlot, on: bool) -> void:
	if not spell_card.is_valid():
		return
	var tip := DmTip.of(self)
	if not on:
		tip.hide_for(s.button)
		return
	_tip_slot = idx
	_tip_key = ""
	_show_spell_tip(s.button, true)


func _slot_button(idx: int) -> Control:
	if idx == -1:
		return primary_slot.button
	return _slots[idx].button if idx >= 0 and idx < _slots.size() else null


func _show_spell_tip(btn: Control, fresh: bool) -> void:
	var d: Dictionary = spell_card.call(_tip_slot)
	var tip := DmTip.of(self)
	if d.is_empty():
		tip.hide_now()
		return
	var key := String(d.get("key", ""))
	if not fresh and key == _tip_key:
		return
	_tip_key = key
	var card := DmSpellCard.new()
	card.build(d, get_viewport_rect().size)
	if fresh or not tip.is_showing_for(btn):
		tip.show_anchor(btn, card)
	else:
		var old := tip.content as DmSpellCard
		var keep := old.scroll.scroll_vertical if old != null else 0
		tip.replace_content(card)
		card.scroll.set_deferred("scroll_vertical", keep)


## Live card: the cost / cooldown / status lines follow the slot while it is open (the web calls refreshTooltip from update()).
func _refresh_spell_tip() -> void:
	if _tip_slot == -2 or not spell_card.is_valid():
		return
	var btn := _slot_button(_tip_slot)
	var tip := DmTip.of(self)
	if btn == null or not tip.is_showing_for(btn):
		_tip_slot = -2
		return
	_show_spell_tip(btn, false)


# ======================================================================== node tip (HUD.nodeTip)

## The web's tiny node-tip HTML (`<b>`, `<div class="req ok|missing">`, `<span class="rich">`, `<div class="spent">`, `<div>`) as BBCode.
static func node_tip_bbcode(html: String) -> String:
	var src := html.replace("[", "[lb]")
	var re := RegEx.create_from_string('<div(?: class="([^"]*)")?>(.*?)</div>')
	var out := ""
	var pos := 0
	for m in re.search_all(src):
		out += src.substr(pos, m.get_start() - pos)
		var inner := m.get_string(2)
		match m.get_string(1):
			"req ok": out += "\n[color=#9fc27a]%s[/color]" % inner
			"req missing": out += "\n[color=#e58a8a]%s[/color]" % inner
			"spent": out += "\n[i][color=#8c8478]%s[/color][/i]" % inner
			_: out += "\n" + inner
		pos = m.get_end()
	out += src.substr(pos)
	out = out.replace("<b>", "[b][color=#%s]" % DmUi.BONE_100.to_html(false)).replace("</b>", "[/color][/b]")
	out = out.replace('<span class="rich">rich</span>', "[color=#e2c98f][font_size=11]RICH[/font_size][/color]")
	return out.replace("&amp;", "&").replace("&middot;", "·").strip_edges()


## `hud.nodeTip(html, x, y)`: null hides; otherwise the card sits at left = clamp(x + 18, 8, W - w - 8), top = clamp(y - h - 12, 8, H - h - 8).
## The game feeds it each frame from the node / laborer under the cursor (game core; the HUD only draws it).
func node_tip(html: Variant, x: float = 0.0, y: float = 0.0) -> void:
	if html == null or String(html) == "":
		node_tip_box.visible = false
		return
	var bb := node_tip_bbcode(String(html))
	if node_tip_rt.text != bb:
		node_tip_rt.text = bb
	node_tip_box.visible = true
	var s := effective_scale
	var sz := node_tip_box.get_combined_minimum_size()
	var vp := get_viewport_rect().size
	node_tip_box.size = sz
	# (x, y) is the pointer in screen space; the card lives in the scaled frame, so clamp its screen rect and convert back.
	var ssz := sz * s
	var screen := Vector2(maxf(8.0, minf(vp.x - ssz.x - 8.0, x + 18.0)), maxf(8.0, minf(vp.y - ssz.y - 8.0, y - ssz.y - 12.0)))
	node_tip_box.position = (screen - safe.global_position) / s
