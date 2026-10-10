class_name DmHudBrewChip
extends Control
## `.brew-chip`: a 54x58 belt slot: key cap top-left, big glyph, label, sub line (count / seconds left / "+ add" / "none") and a
## bottom timer bar. States: on (active effect), empty (dashed + faint), cd (dimmed while its cooldown runs).

signal clicked(slot: String)
signal dropped(slot: String, item_id: String)   ## a brew dragged from the Reliquary (BELT_DRAG_TYPE)

const DRAG_TYPE := "dm_belt_item"

const W := 54.0
const H := 58.0

var slot: String = ""
var key_text: String = ""
var label: String = ""
var glyph: String = ""
var color: Color = Color.WHITE
var active: bool = false
var left: float = 0.0
var frac: float = 0.0
var count: int = 0
var empty: bool = false
var tip: String = ""

var _kbd: Label
var _glyph: Label
var _lbl: Label
var _sub: Label


func _init() -> void:
	custom_minimum_size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_kbd = DmHudKit.lbl("", 11, DmUi.BONE_100, "numeric", false)
	_kbd.position = Vector2(3, 2)
	_kbd.custom_minimum_size = Vector2(14, 14)
	_kbd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_kbd)
	_glyph = DmHudKit.lbl("", 24, Color.WHITE, "body")
	_glyph.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_glyph.offset_top = 8
	_glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_glyph)
	_lbl = DmHudKit.lbl("", 9, DmUi.BONE_100, "display", true)
	_lbl.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_lbl.offset_top = 33
	_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl.clip_text = true
	_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_lbl)
	_sub = DmHudKit.lbl("", 12, Color("efe6d0"), "numeric")
	_sub.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_sub.offset_top = 41
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_sub)


## b: {slot,key,label,glyph,color,active,left,frac,count,empty,tip}
func apply(b: Dictionary) -> void:
	slot = String(b.get("slot", ""))
	key_text = String(b.get("key", ""))
	label = String(b.get("label", ""))
	glyph = String(b.get("glyph", ""))
	color = DmHudKit.color_of(b.get("color", 0xffffff))
	active = bool(b.get("active", false))
	left = float(b.get("left", 0.0))
	frac = float(b.get("frac", 0.0))
	count = int(b.get("count", 0))
	empty = bool(b.get("empty", false))
	tip = String(b.get("tip", ""))
	tooltip_text = tip
	_kbd.text = key_text
	_glyph.text = glyph
	DmHudKit.set_color(_glyph, "font_color", color)
	DmHudKit.set_color(_glyph, "font_shadow_color", Color(color, 0.0 if empty else 0.7))
	DmHudKit.set_const(_glyph, "shadow_outline_size", 0 if empty else 6)
	_lbl.text = DmUi.upper(label)
	_sub.text = sub_text(slot, empty, active, left, count)
	modulate.a = 0.72 if empty else (0.6 if (frac > 0.0 and not active) else 1.0)
	queue_redraw()


## `.sub`: empty -> "none" (heal) / "+ add"; active -> "12s"; else "x3" or "ready".
static func sub_text(slot_: String, empty_: bool, active_: bool, left_: float, count_: int) -> String:
	if empty_:
		return "none" if slot_ == "heal" else "+ add"
	if active_:
		return "%ds" % int(left_)
	return "×%d" % count_ if count_ > 0 else "ready"


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, Vector2(W, H))
	draw_rect(r, Color(0.0275, 0.0235, 0.0392, 0.66))
	var strong := DmUi.BORDER_STRONG
	var bottom := strong
	if active:
		bottom = color
	elif not empty:
		bottom = strong.lerp(color, 0.6)
	if empty:
		_dashed(r, strong)
	else:
		draw_rect(r, strong, false, 1.0)
	draw_rect(Rect2(0, H - 3, W, 3), bottom)
	# timer bar
	draw_rect(Rect2(0, H - 3, W, 3), Color(1, 1, 1, 0.08))
	draw_rect(Rect2(0, H - 3, W * clampf(frac, 0.0, 1.0), 3), color)
	# key cap
	draw_rect(Rect2(3, 2, maxf(14.0, _kbd.size.x), 14), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(3, 2, maxf(14.0, _kbd.size.x), 14), strong, false, 1.0)


func _dashed(r: Rect2, col: Color) -> void:
	var step := 4.0
	var x := 0.0
	while x < r.size.x:
		draw_line(Vector2(x, 0.5), Vector2(minf(x + 2.0, r.size.x), 0.5), col, 1.0)
		draw_line(Vector2(x, r.size.y - 0.5), Vector2(minf(x + 2.0, r.size.x), r.size.y - 0.5), col, 1.0)
		x += step
	var y := 0.0
	while y < r.size.y:
		draw_line(Vector2(0.5, y), Vector2(0.5, minf(y + 2.0, r.size.y)), col, 1.0)
		draw_line(Vector2(r.size.x - 0.5, y), Vector2(r.size.x - 0.5, minf(y + 2.0, r.size.y)), col, 1.0)
		y += step


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(slot)
		accept_event()


## The belt slot an item goes in ("heal" for a healing flask, "elixir" / "tonic" for a brew, "" for anything else).
static func belt_slot_of(item_id: String) -> String:
	if DmContent.healing_flasks().has(item_id):
		return "heal"
	return String(DmContent.brew(item_id).get("slot", ""))


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.get("type", "") == DRAG_TYPE and belt_slot_of(String(data.get("item_id", ""))) == slot


func _drop_data(_at: Vector2, data: Variant) -> void:
	dropped.emit(slot, String(data["item_id"]))
