class_name DmHudKit
extends RefCounted
## Small builders shared by the HUD widgets (labels with the web's text-shadow, panels, number formats). Pure helpers.
## The HUD draws from ONE texture and ONE z layer per kind of drawing, so it costs a handful of draw
## calls (client/ui/hud/PERFORMANCE.md). Panels are 9-patches of the atlas (DmHudAtlas.nine), icons are regions of it, rectangles are its white block, and
## text sits on a z layer per (font, size) above the chrome and the vector art.

const ART := "res://ui/hud/art/"
const SHADOW := Color(0, 0, 0, 1)

## The z layers of a HUD piece, bottom to top. Items with the same z draw in tree order, and consecutive draws of one kind that share a texture are ONE draw
## call (a 9-patch, a rectangle or icon, a mesh and a run of text are four kinds), so every kind of drawing gets a layer of its own: all the panels are one
## batch, all the rectangles and icons another, each widget's vector art one draw, each (font, size) of text one batch. Pieces that overlap the others (toasts,
## the banner, the prompt) add Z_OVERLAY to every layer; the floating numbers use Z_FLOATS.
const Z_PANEL := 0      ## 9-patch panels (the default: a PanelContainer or Button with a style from `style` draws here)
const Z_CHROME := 1     ## rectangles and icons: the atlas (`rect`, `outline`, `gradient_rect`, a TextureRect)
const Z_ART := 2        ## vector art: orbs, cooldown sweeps, pips, the minimap (one triangle mesh each)
const Z_EDGE := 3       ## rectangles that lie over the art (a slot's border over its cooldown sweep, glows)
const Z_TEXT := 4       ## the first text layer; every (font, size) takes the next
const Z_OVERLAY := 100
const Z_FLOATS := 200

static var _tex: Dictionary = {}
static var _text_z: Dictionary = {}

## The draw-call model's hook (tests/hud_cost.gd): while `recording`, every drawing helper says which kind of command it adds to which item, so the model can count how
## consecutive commands batch. Off in the game: one static bool read per helper call.
static var recording := false
static var log: Dictionary = {}   ## canvas item instance id -> Array[String] of command keys, in order
static var _uid := 0


## Notes a command of kind `key` on `canvas` (see HudCost): "quad:<texture>" batches with the next of the same key, "poly:<n>" and "line" kinds do as they are.
static func rec(canvas: Object, key: String) -> void:
	if recording:
		var id := canvas.get_instance_id()
		if not log.has(id):
			log[id] = []
		(log[id] as Array).append(key)


static func rec_unique(canvas: Object, kind: String) -> void:
	if recording:
		_uid += 1
		rec(canvas, "%s:%d" % [kind, _uid])


## Theme overrides only when the value differs: every add_theme_*_override fires a theme change that re-lays the control's
## container, and the HUD applies its view-model every frame (that was most of a ~3 ms hud.apply).
static func set_color(c: Control, name: StringName, col: Color) -> void:
	if c.has_theme_color_override(name) and c.get_theme_color(name) == col:
		return
	c.add_theme_color_override(name, col)


static func set_const(c: Control, name: StringName, v: int) -> void:
	if c.has_theme_constant_override(name) and c.get_theme_constant(name) == v:
		return
	c.add_theme_constant_override(name, v)


static func set_font_size(c: Control, name: StringName, v: int) -> void:
	if c.has_theme_font_size_override(name) and c.get_theme_font_size(name) == v:
		return
	c.add_theme_font_size_override(name, v)
	layer_text(c)


## The HUD's textures, from the atlas: `side` is the longest edge they are kept at (portraits are 480x640 files shown 34 px wide, ability art 256 px shown 62: twice the
## size they are shown at is plenty, at any scale up to 4K).
static func tex(path: String, side: int = 0) -> Texture2D:
	if path == "":
		return null
	if _tex.has(path):
		return _tex[path]
	if side <= 0:
		side = 64 if path.contains("/status/") else 128
	var t: Texture2D = DmHudAtlas.icon(path, side)
	_tex[path] = t
	return t


## Chrome glyph (archive/legacy-web:src/ui/icons.ts) as a texture: skull crown bag anvil gear waymap skills grimoire atlas book ...
static func icon(name: String) -> Texture2D:
	return tex(ART + "icons/" + name + ".svg", 48)


## A Label in the HUD's look: size px, colour, font kind (DmUi.font), optional `text-shadow: 0 1px 3px #000`.
static func lbl(text: String, size: int = 14, color: Color = DmUi.BONE_100, font: String = "body", shadow: bool = true, spacing: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", DmUi.font(font))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if shadow:
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("shadow_offset_x", 0)
		l.add_theme_constant_override("shadow_offset_y", 1)
	if spacing != 0.0:
		l.add_theme_font_override("font", spaced(font, spacing))
	layer_text(l)
	return l


## Puts a text control (Label, RichTextLabel, Button, LineEdit) on the z layer of its (font, size), above the chrome and the art. The layer is the control's
## own z_index, relative to the piece it is in. A control whose font or size changes later is put on its layer again (set_font_size does).
static func layer_text(c: Control) -> void:
	var font: Font
	var size: int
	if c is RichTextLabel:
		font = c.get_theme_font("normal_font")
		size = c.get_theme_font_size("normal_font_size")
	else:
		font = c.get_theme_font("font")
		size = c.get_theme_font_size("font_size")
	c.z_index = text_z(font, size)


## The z layer of a (font, size): the first one asked takes Z_TEXT, the next Z_TEXT + 1, ... A letter-spaced variation shares its base font's glyph cache, so it shares the layer.
static func text_z(font: Font, size: int) -> int:
	var base: Font = font
	if font is FontVariation and (font as FontVariation).base_font != null:
		base = (font as FontVariation).base_font
	var key := "%d|%d" % [base.get_instance_id() if base != null else 0, size]
	var z: int = _text_z.get(key, -1)
	if z < 0:
		z = mini(Z_TEXT + _text_z.size(), Z_OVERLAY - 1)
		_text_z[key] = z
	return z


## Puts every control of a subtree on its layer: text on its (font, size) layer, a TextureRect on the chrome layer. The HUD calls it on what it builds and on
## the chips and rows it makes later (status chips, party members, toasts), so no control is missed.
static func layer_tree(n: Node) -> void:
	if n is TextureRect:
		(n as TextureRect).z_index = Z_CHROME
	elif n is Label or n is RichTextLabel or n is LineEdit or (n is Button and (n as Button).text != ""):
		layer_text(n as Control)
	for c in n.get_children():
		layer_tree(c)


## Letter-spaced font (CSS letter-spacing in px; Godot spacing is whole pixels on the glyph advance).
## One FontVariation per (font, spacing), shared by every label that uses it (they were one per label, each its own font resource).
static var _spaced: Dictionary = {}

static func spaced(base: String, px: float) -> Font:
	var key := "%s|%d" % [base, int(round(px))]
	var cached: Font = _spaced.get(key)
	if cached != null:
		return cached
	var fv := FontVariation.new()
	fv.base_font = DmUi.font(base)
	fv.spacing_glyph = int(round(px))
	_spaced[key] = fv
	return fv


static func panel(bg: Color, border: Color = Color(0, 0, 0, 0), widths: Vector4 = Vector4(1, 1, 1, 1), pad: Vector4 = Vector4(0, 0, 0, 0), radius: int = 0) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", plate(bg, border, widths, pad, radius))
	return p


## widths = (left, top, right, bottom); pad = (left, top, right, bottom). A 9-patch of the HUD atlas that looks like the StyleBoxFlat of these arguments
## (`style`): the same fill, border ring and rounded corners, the same content margins, but drawn from the shared texture so it batches with every other panel.
static func plate(bg: Color, border: Color = Color(0, 0, 0, 0), widths: Vector4 = Vector4(1, 1, 1, 1), pad: Vector4 = Vector4(0, 0, 0, 0), radius: int = 0) -> StyleBoxTexture:
	var n := DmHudAtlas.nine(bg, border, int(widths.x), int(widths.y), int(widths.z), int(widths.w), radius)
	var sb := StyleBoxTexture.new()
	sb.texture = DmHudAtlas.panel_texture
	sb.region_rect = Rect2(n["region"])
	var m := float(n["margin"])
	sb.texture_margin_left = m
	sb.texture_margin_top = m
	sb.texture_margin_right = m
	sb.texture_margin_bottom = m
	sb.content_margin_left = pad.x
	sb.content_margin_top = pad.y
	sb.content_margin_right = pad.z
	sb.content_margin_bottom = pad.w
	return sb


## The StyleBoxFlat itself (the panels still ask for one), for the few panels that need what a 9-patch cannot be (the hotbar's soft shadow).
static func style(bg: Color, border: Color = Color(0, 0, 0, 0), widths: Vector4 = Vector4(1, 1, 1, 1), pad: Vector4 = Vector4(0, 0, 0, 0), radius: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left = int(widths.x)
	sb.border_width_top = int(widths.y)
	sb.border_width_right = int(widths.z)
	sb.border_width_bottom = int(widths.w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad.x
	sb.content_margin_top = pad.y
	sb.content_margin_right = pad.z
	sb.content_margin_bottom = pad.w
	return sb


## A filled rectangle of any colour from the atlas's white block: it batches with the panels and icons, which `draw_rect` (a different texture) would not.
static func rect(canvas: CanvasItem, r: Rect2, col: Color) -> void:
	if r.size.x <= 0.0 or r.size.y <= 0.0 or col.a <= 0.0:
		return
	var white := DmHudAtlas.white()   # (makes the atlas the first time)
	canvas.draw_texture_rect_region(DmHudAtlas.texture, r, white, col, false, false)
	if recording:
		rec(canvas, "quad:%d" % DmHudAtlas.texture.get_rid().get_id())


## The outline of a rectangle, `w` px thick, drawn INSIDE it as four filled rectangles (draw_rect(..., false) is a polyline: one draw call, more when anti-aliased).
static func outline(canvas: CanvasItem, r: Rect2, col: Color, w: float = 1.0) -> void:
	rect(canvas, Rect2(r.position.x, r.position.y, r.size.x, w), col)
	rect(canvas, Rect2(r.position.x, r.end.y - w, r.size.x, w), col)
	rect(canvas, Rect2(r.position.x, r.position.y + w, w, r.size.y - 2.0 * w), col)
	rect(canvas, Rect2(r.end.x - w, r.position.y + w, w, r.size.y - 2.0 * w), col)


## A filled rectangle with a left-to-right gradient from `a` to `b` (a bar's fill).
static func gradient_rect(canvas: CanvasItem, r: Rect2, a: Color, b: Color) -> void:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var strip := DmHudAtlas.gradient(a, b)
	canvas.draw_texture_rect_region(DmHudAtlas.texture, r, strip, Color.WHITE, false, false)
	if recording:
		rec(canvas, "quad:%d" % DmHudAtlas.texture.get_rid().get_id())


## A static mesh (art that never changes) as one command.
static func mesh(canvas: CanvasItem, m: Mesh, xf: Transform2D = Transform2D()) -> void:
	canvas.draw_mesh(m, null, xf)
	rec_unique(canvas, "poly")


## A MultiMesh (every instance) as one command.
static func multimesh(canvas: CanvasItem, mm: MultiMesh) -> void:
	canvas.draw_multimesh(mm, null)
	rec_unique(canvas, "poly")


## Line segments (pairs of points) of one width and colour: batched lines, one draw call for consecutive calls.
static func lines(canvas: CanvasItem, pts: PackedVector2Array, col: Color, w: float = 1.0) -> void:
	canvas.draw_multiline(pts, col, w)
	rec(canvas, "line")


## Absolute placement: anchors (ax, ay) with the control's own edge placed `ox, oy` from them. gh/gv: which way it grows.
static func place(c: Control, ax: float, ay: float, ox: float, oy: float, gh: int = Control.GROW_DIRECTION_END, gv: int = Control.GROW_DIRECTION_END) -> void:
	c.anchor_left = ax
	c.anchor_right = ax
	c.anchor_top = ay
	c.anchor_bottom = ay
	c.grow_horizontal = gh
	c.grow_vertical = gv
	c.offset_left = ox
	c.offset_right = ox
	c.offset_top = oy
	c.offset_bottom = oy


## 1234567 -> "1,234,567" (JS toLocaleString, en-US integers). The same few numbers come up every refresh (health, XP, gold): their text is kept.
static var _commas := {}

static func commas(n: float) -> String:
	var v := int(n)
	var kept: Variant = _commas.get(v)
	if kept != null:
		return kept
	var s := str(absi(v))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	out = ("-" if v < 0 else "") + out
	if _commas.size() >= 512:
		_commas.clear()
	_commas[v] = out
	return out


static func html(c: Color) -> String:
	return "#" + c.to_html(false)


## "#rrggbb" string, Color, or 0xRRGGBB int -> Color
static func color_of(v: Variant, fallback: Color = Color.WHITE) -> Color:
	if v is Color:
		return v
	if v is String and v != "":
		return Color(v)
	if v is int:
		return Color.hex((int(v) << 8) | 0xFF)
	return fallback


static func mix(a: Color, b: Color, t: float) -> Color:
	return a.lerp(b, t)
