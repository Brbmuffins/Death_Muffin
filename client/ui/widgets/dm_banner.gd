class_name DmBanner
extends VBoxContainer
## `.hud-banner`: the big, brief area / level banner. Title (Cormorant 700 44px, .16em, uppercase), a violet rule, italic subtitle.
## Fades in over 0.6 s (drifting 8 px down), holds, fades out. Centre it horizontally at ~24% of the screen height.

@export var hold_s: float = 3.0
var _t: Label
var _s: Label


static func make(title: String, subtitle: String = "", hold: float = 3.0) -> DmBanner:
	var b := DmBanner.new()
	b.hold_s = hold
	b._build(title, subtitle)
	return b


func _build(title: String, subtitle: String) -> void:
	theme = DmUi.theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 0)
	_t = DmUi.label(DmUi.upper(title), "DmBannerTitle")
	_t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_t)
	var rule := _Rule.new()
	rule.custom_minimum_size = Vector2(260, 18)
	rule.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(rule)
	_s = DmUi.label(subtitle, "DmBannerSub")
	_s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_s)
	_s.visible = subtitle != ""
	modulate.a = 0.0


func play() -> void:
	var y := position.y
	position.y = y - 8.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "modulate:a", 1.0, 0.6)
	tw.tween_property(self, "position:y", y, 0.6)
	var tw2 := create_tween()
	tw2.tween_interval(0.6 + hold_s)
	tw2.tween_property(self, "modulate:a", 0.0, 0.6)
	tw2.tween_callback(queue_free)


class _Rule extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		# linear-gradient(90deg, transparent, spell-300, transparent), 1px
		var n := 40
		for i in n:
			var x0 := size.x * i / n
			var x1 := size.x * (i + 1) / n
			var k := 1.0 - absf((i + 0.5) / n * 2.0 - 1.0)
			draw_rect(Rect2(x0, size.y * 0.5, x1 - x0 + 0.5, 1), Color(DmUi.SPELL_300, k))
