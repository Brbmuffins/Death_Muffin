class_name DmFloatingNumber
extends Label
## `.cw-num` floating combat text. `DmFloatingNumber.spawn(parent, screen_pos, "123", "crit")` pops, drifts up ~46 px and fades
## (lifetimes and sizes from FloatingText.ts / ui.css). The caller projects world -> screen; this only styles + animates.
## kinds: hit crit dot thrall hurt gold shard xp info big skill heal ward

const STYLE := {
	"hit": {"size": 17, "color": Color("f0e9dc"), "life": 0.85},
	"crit": {"size": 23, "color": Color("e7d6ff"), "life": 1.1},
	"dot": {"size": 14, "color": Color("b9a3e8"), "life": 0.85},
	"thrall": {"size": 13, "color": Color("d8cfbd"), "life": 0.85},
	"hurt": {"size": 18, "color": Color("e58aa8"), "life": 0.85},
	"gold": {"size": 15, "color": Color("e2c98f"), "life": 0.85},
	"shard": {"size": 16, "color": Color("c6a4ff"), "life": 0.85},
	"xp": {"size": 13, "color": Color("d8cfbd"), "life": 0.85},
	"skill": {"size": 15, "color": Color("f0e9dc"), "life": 0.85, "font": "body_bold"},
	"info": {"size": 15, "color": Color("f0e9dc"), "life": 1.6, "font": "body"},
	"big": {"size": 30, "color": Color("e7d6ff"), "life": 1.6},
	"heal": {"size": 19, "color": Color("8df0b0"), "life": 1.6, "glow": Color(0.31, 0.9, 0.55, 0.55)},
	"ward": {"size": 16, "color": Color("a9d0ff"), "life": 1.6, "glow": Color(0.43, 0.67, 1.0, 0.5)},
}


static func apply_style(n: Label, kind: String, color: Color = Color(0, 0, 0, 0)) -> void:
	var st: Dictionary = STYLE.get(kind, STYLE["hit"])
	n.theme = DmUi.theme()
	n.theme_type_variation = "DmCombatNum"
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	n.add_theme_font_size_override("font_size", int(st["size"]))
	n.add_theme_color_override("font_color", color if color.a > 0.0 else st["color"])
	n.add_theme_font_override("font", DmUi.font(String(st.get("font", "numeric"))))
	n.add_theme_constant_override("outline_size", 3)
	n.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))


static func spawn(parent: Node, pos: Vector2, text: String, kind: String = "hit", color: Color = Color(0, 0, 0, 0)) -> DmFloatingNumber:
	var n := DmFloatingNumber.new()
	var st: Dictionary = STYLE.get(kind, STYLE["hit"])
	n.text = text
	apply_style(n, kind, color)
	parent.add_child(n)
	n.reset_size()
	n.pivot_offset = n.size * 0.5
	n.position = pos - n.size * 0.5
	var life: float = st["life"]
	n.scale = Vector2.ONE * 0.7
	var tw := n.create_tween().set_parallel(true)
	tw.tween_property(n, "scale", Vector2.ONE * 1.2, life * 0.12)
	tw.tween_property(n, "position:y", pos.y - n.size.y * 0.5 - 46.0, life)
	var tw2 := n.create_tween()
	tw2.tween_property(n, "scale", Vector2.ONE, life * 0.4).set_delay(life * 0.12)
	var tw3 := n.create_tween()
	tw3.tween_interval(life * 0.65)
	tw3.tween_property(n, "modulate:a", 0.0, life * 0.35)
	tw3.tween_callback(n.queue_free)
	return n
