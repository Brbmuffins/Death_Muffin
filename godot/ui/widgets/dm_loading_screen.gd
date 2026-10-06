class_name DmLoadingScreen
extends CanvasLayer
## The one loading screen, shared by every loading moment from login to the first playable frame (the world build, DmWarmup's tour,
## DmGameUi's panel pre-build): the web's key-art splash (hooded necromancer raising skeletons before the cathedral), cover-fit, a dark
## gradient at the bottom, the status line and a progress bar in the game's fonts. One TextureRect + one gradient: nothing measurable per frame.
## Usage: `var ls := DmLoadingScreen.acquire(host, "text")` (returns the live one when a caller up the chain already showed it; `ls.owned`
## is false then, and only the creator dismisses it); `ls.set_text()`, `ls.set_progress(0..1)`, `ls.dismiss()`.

const ART := "res://assets/ui_art/loading/keyart.webp"
const FADE_S := 0.35
const BG := Color(0.027, 0.024, 0.039, 1.0)   # #07060a, the web splash base

static var current: DmLoadingScreen = null

var owned := true
var _label: Label
var _bar: ColorRect
var _track: Control
var _dismissing := false


## The live screen when there is one, else a new one on `host` (the art is loaded synchronously, so the first frame it is in has it).
static func acquire(host: Node, text: String = "") -> DmLoadingScreen:
	if current != null and is_instance_valid(current) and not current._dismissing:
		current.owned = false
		if text != "":
			current.set_text(text)
		return current
	var ls := DmLoadingScreen.new()
	ls.layer = 90
	ls.name = "LoadingScreen"
	ls._build(text)
	host.add_child(ls)
	current = ls
	return ls


func _build(text: String) -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	var art := TextureRect.new()
	art.texture = load(ART) as Texture2D
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(art)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.48, 0.76, 1.0])
	g.colors = PackedColorArray([Color(BG, 0.0), Color(BG, 0.0), Color(BG, 0.62), Color(BG, 0.95)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 256
	var shade := TextureRect.new()
	shade.texture = gt
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(shade)
	var copy := VBoxContainer.new()
	copy.anchor_left = 0.06
	copy.anchor_right = 0.55
	copy.anchor_top = 1.0
	copy.anchor_bottom = 1.0
	copy.offset_left = 0.0
	copy.offset_right = 0.0
	copy.offset_bottom = -64.0
	copy.offset_top = -64.0
	copy.grow_vertical = Control.GROW_DIRECTION_BEGIN
	copy.alignment = BoxContainer.ALIGNMENT_END
	copy.add_theme_constant_override("separation", 10)
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(copy)
	var title := Label.new()
	title.text = "DEATH MUFFIN"
	title.add_theme_font_override("font", DmUi.font("display_bold"))
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", DmUi.BONE_100)
	title.add_theme_color_override("font_shadow_color", Color(0.61, 0.36, 1.0, 0.55))
	title.add_theme_constant_override("shadow_outline_size", 10)
	copy.add_child(title)
	_label = Label.new()
	_label.text = text
	_label.add_theme_font_override("font", DmUi.font("display_italic"))
	_label.add_theme_font_size_override("font_size", 24)
	_label.add_theme_color_override("font_color", Color(0.85, 0.81, 0.74, 0.85))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_y", 1)
	copy.add_child(_label)
	_track = ColorRect.new()
	(_track as ColorRect).color = Color(0.17, 0.13, 0.24, 0.9)
	_track.custom_minimum_size = Vector2(340, 3)
	_track.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	copy.add_child(_track)
	_bar = ColorRect.new()
	_bar.color = Color(0.78, 0.64, 1.0)
	_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bar.anchor_right = 0.04
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track.add_child(_bar)


func set_text(t: String) -> void:
	if _label != null:
		_label.text = t


## 0..1 (never goes backwards visually below the 4% stub).
func set_progress(f: float) -> void:
	if _bar != null:
		_bar.anchor_right = clampf(f, 0.04, 1.0)


## Fade into the game (`fade` false = gone now, for tests that count frames).
func dismiss(fade: bool = true) -> void:
	if _dismissing:
		return
	_dismissing = true
	if current == self:
		current = null
	if not fade or not is_inside_tree():
		queue_free()
		return
	var root_ctl: Control = get_child(0)
	root_ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tw := create_tween()
	tw.tween_property(root_ctl, "modulate:a", 0.0, FADE_S)
	tw.tween_callback(queue_free)
