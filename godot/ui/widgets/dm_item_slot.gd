class_name DmItemSlot
extends Control
## One bag / paper-doll / tool-belt cell (`.cw-slot`). Pure data in, pure drawing: no networking, no game rules.
##
## `set_item(d)` takes a Dictionary (all keys optional except item_id/name when filled):
##   item_id, name, rarity ("common".."legendary"), quantity:int, equipped:bool, locked:bool, is_new:bool,
##   icon:Texture2D (null -> glyph), glyph:String, verdict:"up"|"down"|""  or {kind, text} (the corner arrow),
##   plus whatever DmItemCard reads (type_label, ilvl, stats, lore, sell_value ...) for the hover tooltip.
## Empty slots show `empty_glyph` + `empty_label` (paper doll / belt).

signal pressed(slot: DmItemSlot)
signal double_clicked(slot: DmItemSlot)
signal right_clicked(slot: DmItemSlot)

enum Kind { BAG, EQUIP, BELT }

@export var kind: Kind = Kind.BAG
@export var empty_glyph: String = ""
@export var empty_label: String = ""

var data: Dictionary = {}
var index: int = -1
var selected := false:
	set(v):
		selected = v
		queue_redraw()
var _hover := false


func _init() -> void:
	custom_minimum_size = Vector2(48, 48)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	theme = DmUi.theme()


func _ready() -> void:
	mouse_entered.connect(func() -> void:
		_hover = true
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hover = false
		queue_redraw())


func set_item(d: Dictionary) -> void:
	data = d
	tooltip_text = String(d.get("name", "")) if not d.is_empty() else ""
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not d.is_empty() else Control.CURSOR_ARROW
	queue_redraw()


func is_filled() -> bool:
	return not data.is_empty()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if not is_filled():
				return
			if event.double_click:
				double_clicked.emit(self)
			else:
				pressed.emit(self)
		elif event.button_index == MOUSE_BUTTON_RIGHT and is_filled():
			right_clicked.emit(self)


func _make_custom_tooltip(_for_text: String) -> Object:
	if not is_filled():
		return null
	return DmItemTooltip.make(data)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var filled := is_filled()
	var rc := DmUi.rarity_color(String(data.get("rarity", "common")))
	var equipped: bool = data.get("equipped", false)
	var locked: bool = data.get("locked", false)
	var dim := 1.0
	if not filled:
		dim = 0.75 if kind == Kind.BELT else (0.6 if kind == Kind.EQUIP else 1.0)
	draw_rect(r, Color(DmUi.INSET, 1.0))
	if filled:
		# inset 12px glow in the rarity colour (box-shadow: inset 0 0 12px -4px)
		for i in 5:
			var a := 0.20 * (1.0 - i / 5.0)
			draw_rect(r.grow(-float(i) * 1.4), Color(rc, a), false, 1.6)
		var bw := 2.0 if equipped else 1.0
		var bc := Color(rc, 1.0 if _hover else 0.6)
		draw_rect(r.grow(-bw * 0.5), bc, false, bw)
		if locked:
			draw_rect(r.grow(-1.5), Color(DmUi.GOLD, 0.55), false, 1.0)
		var ic: Texture2D = data.get("icon", null)
		var inner := r.grow(-1.0)
		if ic != null:
			draw_texture_rect(ic, inner, false)
		else:
			var g: String = data.get("glyph", "◆")
			var f := DmUi.font("body")
			var fs := 20
			var gs := f.get_string_size(g, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			draw_string(f, Vector2((size.x - gs.x) * 0.5, size.y * 0.5 + fs * 0.32), g, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, rc)
	else:
		draw_rect(r.grow(-0.5), Color(DmUi.SLOT_BORDER.r, DmUi.SLOT_BORDER.g, DmUi.SLOT_BORDER.b, 0.10), false, 1.0)
		if empty_glyph != "":
			var f2 := DmUi.font("body")
			var fs2 := 18
			var gs2 := f2.get_string_size(empty_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2)
			draw_string(f2, Vector2((size.x - gs2.x) * 0.5, size.y * 0.5 + fs2 * 0.18), empty_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, Color(DmUi.TEXT_FAINT, dim))
		if empty_label != "":
			var fl := DmUi.font("body")
			var fsl := 9 if kind == Kind.BELT else 10
			var lab := empty_label.to_upper()
			draw_string(fl, Vector2(0, size.y - 3.0), lab, HORIZONTAL_ALIGNMENT_CENTER, size.x, fsl, Color(DmUi.TEXT_FAINT, dim))
	if filled:
		var nf := DmUi.font("numeric")
		var q: int = int(data.get("quantity", 1))
		if q > 1:
			var qs := str(q)
			var qw := nf.get_string_size(qs, HORIZONTAL_ALIGNMENT_RIGHT, -1, 12).x
			draw_string(nf, Vector2(size.x - 3.0 - qw + 1, size.y - 3.0 + 1), qs, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0, 0, 0, 0.9))
			draw_string(nf, Vector2(size.x - 3.0 - qw, size.y - 3.0), qs, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DmUi.BONE_100)
		if equipped:
			draw_string(nf, Vector2(4.0, 12.0), "E", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DmUi.SPELL_300)
		elif locked:
			_draw_lock(Vector2(3, 3))
		_draw_mark(String(data.get("rarity", "common")), Vector2(size.x - 3.0, 4.0), rc)
		var vv: Variant = data.get("verdict", "")
		var verdict: String = String(vv.get("kind", "")) if vv is Dictionary else String(vv)
		if verdict == "up":
			_draw_tri(Vector2(5.0, size.y - 5.0), true, DmUi.UP)
		elif verdict == "down":
			_draw_tri(Vector2(5.0, size.y - 5.0), false, DmUi.DOWN)
		if data.get("is_new", false):
			_draw_new_pip()
	if selected:
		draw_rect(r.grow(-1.0), DmUi.SPELL_300, false, 2.0)


func _draw_lock(at: Vector2) -> void:
	# 12x14 padlock (LOCK_SVG): shackle arc + body
	var col := DmUi.GOLD
	var sh := Color(0, 0, 0, 0.8)
	for pass_i in 2:
		var o := Vector2(0.8, 0.8) if pass_i == 0 else Vector2.ZERO
		var c := sh if pass_i == 0 else col
		var cx := at.x + 5.5 + o.x
		draw_arc(Vector2(cx, at.y + 4.0 + o.y), 2.6, PI, TAU, 10, c, 1.4, true)
		draw_line(Vector2(cx - 2.6, at.y + 4.0 + o.y), Vector2(cx - 2.6, at.y + 6.0 + o.y), c, 1.4)
		draw_line(Vector2(cx + 2.6, at.y + 4.0 + o.y), Vector2(cx + 2.6, at.y + 6.0 + o.y), c, 1.4)
		draw_rect(Rect2(at.x + 1.0 + o.x, at.y + 5.8 + o.y, 9.0, 6.0), c)


func _draw_tri(base: Vector2, up: bool, col: Color) -> void:
	var pts: PackedVector2Array
	if up:
		pts = PackedVector2Array([base + Vector2(-4, 0), base + Vector2(4, 0), base + Vector2(0, -7)])
	else:
		pts = PackedVector2Array([base + Vector2(-4, -7), base + Vector2(4, -7), base + Vector2(0, 0)])
	var sh := PackedVector2Array()
	for p in pts:
		sh.append(p + Vector2(0.8, 0.8))
	draw_colored_polygon(sh, Color(0, 0, 0, 0.8))
	draw_colored_polygon(pts, col)


func _draw_mark(rarity: String, right_top: Vector2, col: Color) -> void:
	# ·  ◆  ◆◆  ◆◆◆  ★ drawn as shapes (colour-independent rarity cue, no font dependence)
	match rarity:
		"common":
			draw_circle(right_top + Vector2(-2.5, 2.5), 1.3, col)
		"legendary":
			var c := right_top + Vector2(-4.5, 4.0)
			var pts := PackedVector2Array()
			for i in 10:
				var rr := 4.2 if i % 2 == 0 else 1.8
				var a := -PI / 2.0 + i * PI / 5.0
				pts.append(c + Vector2(cos(a), sin(a)) * rr)
			draw_colored_polygon(pts, col)
		_:
			var n: int = {"uncommon": 1, "rare": 2, "epic": 3}.get(rarity, 0)
			for i in n:
				var c2 := right_top + Vector2(-3.0 - i * 5.0, 3.5)
				draw_colored_polygon(PackedVector2Array([c2 + Vector2(0, -3.2), c2 + Vector2(2.6, 0), c2 + Vector2(0, 3.2), c2 + Vector2(-2.6, 0)]), col)


func _draw_new_pip() -> void:
	var f := DmUi.font("numeric")
	var w := f.get_string_size("NEW", HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x + 8.0
	var pr := Rect2(size.x - w - 1.0, size.y - 13.0, w, 12.0)
	draw_rect(pr, DmUi.GOLD)
	draw_string(f, pr.position + Vector2(4.0, 9.0), "NEW", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color("1a1206"))
