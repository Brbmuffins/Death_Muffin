class_name DmHudAtlas
extends RefCounted
## One runtime texture for everything flat or icon-like the HUD draws: the 9-patch panels and their borders, plain rectangles (a 2x2 white block), bar
## gradients, and every icon. The canvas renderer draws consecutive commands that share a texture as ONE draw call, so a HUD whose chrome all comes from this
## texture, and whose items sit on the same z layer (DmHudKit.Z_CHROME), costs a handful of draws instead of one per panel and per icon
## (client/README.md "The HUD's budget"; ROADMAP: the new HUD).
##
## Regions are packed on demand with a one pixel extruded border (linear filtering never reads the next region). The image uploads once per frame, before the
## frame is drawn, when something was added. Nothing is created per frame: a style, an icon or a gradient is packed the first time it is asked for.
##
##   DmHudAtlas.white()                       Rect2 of a white block: draw a rectangle of any colour with `draw_texture_rect_region(DmHudAtlas.texture, rect, white(), colour)`
##   DmHudAtlas.nine(bg, border, l, t, r, b, radius) -> {region: Rect2i, margin: int}   the picture of a StyleBoxFlat (fill, border ring, rounded corners)
##   DmHudAtlas.gradient(a, b) -> Rect2       a left-to-right two colour strip (a bar's fill)
##   DmHudAtlas.icon(path, side) -> Texture2D an AtlasTexture of the imported texture, scaled down to `side` px; dimmed(path, level, side) its greyed variants

const SIZE := 1024          ## the page of icons, rectangles and gradients
const PANEL_SIZE := 512     ## the page of 9-patches: a 9-patch is its own kind of draw (its own pipeline), so it never shares a batch with the rectangles and icons
const PAD := 1
const DIM_SOFT := 1         ## a rite that needs a corpse or a legion the hero lacks: sat 0.55, brightness 0.7
const DIM_HARD := 2         ## out of essence: sat 0.3, brightness 0.55
const DIM_LOCKED := 3       ## locked: sat 0, brightness 0.55


## One page: an image, its texture, a shelf packer and the regions on it.
class Page:
	extends RefCounted
	var size := 0
	var image: Image
	var texture: ImageTexture
	var regions: Dictionary = {}    ## key -> Rect2i
	var used := 0                   ## packed pixels, padding included
	var uploads := 1
	var dirty := false
	var _x := 0
	var _y := 0
	var _row := 0

	func _init(size_: int) -> void:
		size = size_
		image = Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
		texture = ImageTexture.create_from_image(image)

	func flush() -> void:
		if dirty:
			dirty = false
			texture.update(image)
			uploads += 1

	## Packs `img` under `key` (already packed: the existing region). The region is the picture itself; one pixel around it repeats its edge. An empty Rect2i when full.
	func add(key: String, img: Image) -> Rect2i:
		if regions.has(key):
			return regions[key]
		var w := img.get_width()
		var h := img.get_height()
		var cell_w := w + 2 * PAD
		var cell_h := h + 2 * PAD
		if _x + cell_w > size:
			_x = 0
			_y += _row
			_row = 0
		if _y + cell_h > size or cell_w > size:
			push_error("DmHudAtlas: page full, cannot pack %s (%dx%d)" % [key, w, h])
			return Rect2i()
		var r := Rect2i(_x + PAD, _y + PAD, w, h)
		image.blit_rect(img, Rect2i(0, 0, w, h), r.position)
		# repeat the edge pixels outward
		image.blit_rect(img, Rect2i(0, 0, w, 1), Vector2i(r.position.x, r.position.y - 1))
		image.blit_rect(img, Rect2i(0, h - 1, w, 1), Vector2i(r.position.x, r.end.y))
		image.blit_rect(img, Rect2i(0, 0, 1, h), Vector2i(r.position.x - 1, r.position.y))
		image.blit_rect(img, Rect2i(w - 1, 0, 1, h), Vector2i(r.end.x, r.position.y))
		image.set_pixel(r.position.x - 1, r.position.y - 1, img.get_pixel(0, 0))
		image.set_pixel(r.end.x, r.position.y - 1, img.get_pixel(w - 1, 0))
		image.set_pixel(r.position.x - 1, r.end.y, img.get_pixel(0, h - 1))
		image.set_pixel(r.end.x, r.end.y, img.get_pixel(w - 1, h - 1))
		_x += cell_w
		_row = maxi(_row, cell_h)
		used += cell_w * cell_h
		regions[key] = r
		dirty = true
		return r


static var _main: Page
static var _panels: Page
static var texture: ImageTexture        ## the icons' page: what a TextureRect, a rectangle or a gradient draws from
static var panel_texture: ImageTexture  ## the 9-patches' page
static var _nine: Dictionary = {}       ## key -> {region, margin}
static var _icons: Dictionary = {}      ## key -> Texture2D
static var _hooked := false
static var _white := Rect2i()


## Makes the pages (once). Safe to call from anywhere; the first call also hooks the upload before each drawn frame.
static func ensure() -> void:
	if _main != null:
		return
	_main = Page.new(SIZE)
	_panels = Page.new(PANEL_SIZE)
	texture = _main.texture
	panel_texture = _panels.texture
	if not _hooked:
		_hooked = true
		RenderingServer.frame_pre_draw.connect(flush)


## Uploads the pages that were added to since the last upload.
static func flush() -> void:
	if _main != null:
		_main.flush()
		_panels.flush()


## Pixels packed on both pages and uploads so far (tests, the F3 overlay).
static func used_pixels() -> int:
	return _main.used + _panels.used if _main != null else 0


static func uploads() -> int:
	return _main.uploads + _panels.uploads if _main != null else 0


## Drops everything (tests start from an empty atlas).
static func reset() -> void:
	_main = null
	_panels = null
	texture = null
	panel_texture = null
	_nine.clear()
	_icons.clear()
	_white = Rect2i()
	ensure()


## Packs `img` on the icons' page under `key`.
static func add(key: String, img: Image) -> Rect2i:
	ensure()
	return _main.add(key, img)


static func region(key: String) -> Rect2i:
	ensure()
	return _main.regions.get(key, Rect2i())


## A white block: a rectangle of any colour is this region drawn with that colour as the modulate.
static func white() -> Rect2:
	if _white.size == Vector2i.ZERO:
		var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_white = add("white", img)
	return Rect2(Vector2(_white.position) + Vector2.ONE, Vector2(2, 2))   # the middle, away from the edge


## The picture of `StyleBoxFlat(bg_color, border_color, border widths l/t/r/b, corner radius)` as the middle of a 9-patch: the margin `margin` pixels on every side,
## one pixel of centre. Border pixels carry the border colour on its own (a translucent border shows what is behind the panel, as StyleBoxFlat's does); the
## corners are anti-aliased by 16 samples per pixel. Pure CPU, cached by its arguments.
static func nine(bg: Color, border: Color, wl: int, wt: int, wr: int, wb: int, radius: int) -> Dictionary:
	var key := "n|%s|%s|%d,%d,%d,%d|%d" % [bg.to_html(true), border.to_html(true), wl, wt, wr, wb, radius]
	if _nine.has(key):
		return _nine[key]
	var m := maxi(1, maxi(maxi(maxi(wl, wt), maxi(wr, wb)), radius))
	var img := nine_image(bg, border, wl, wt, wr, wb, radius, m)
	ensure()
	var out := {"region": _panels.add(key, img), "margin": m}
	_nine[key] = out
	return out


## The pixels of `nine` (a function of its own for the tests).
static func nine_image(bg: Color, border: Color, wl: int, wt: int, wr: int, wb: int, radius: int, m: int) -> Image:
	var s := 2 * m + 1
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	var outer := Rect2(0, 0, s, s)
	var inner := Rect2(wl, wt, s - wl - wr, s - wt - wb)
	var r_in := maxi(0, radius - maxi(maxi(wl, wt), maxi(wr, wb)))
	var has_border := (wl + wt + wr + wb) > 0 and border.a > 0.0
	for py in s:
		for px in s:
			var n_border := 0
			var n_fill := 0
			for j in 4:
				for i in 4:
					var p := Vector2(px + (i + 0.5) / 4.0, py + (j + 0.5) / 4.0)
					if not _in_round(p, outer, radius):
						continue
					if _in_round(p, inner, r_in):
						n_fill += 1
					elif has_border:
						n_border += 1
					else:
						n_fill += 1   # no border: the fill reaches the rim
			var a_b := border.a * n_border / 16.0
			var a_f := bg.a * n_fill / 16.0
			var a := a_b + a_f
			if a <= 0.0:
				img.set_pixel(px, py, Color(bg.r, bg.g, bg.b, 0.0))   # colour of the nearer paint, so a linear filter never fringes
				continue
			var c := Color(border.r * a_b + bg.r * a_f, border.g * a_b + bg.g * a_f, border.b * a_b + bg.b * a_f) / a
			img.set_pixel(px, py, Color(c.r, c.g, c.b, a))
	return img


static func _in_round(p: Vector2, r: Rect2, radius: int) -> bool:
	if not r.has_point(p):
		return false
	if radius <= 0:
		return true
	var rr := float(radius)
	var cx := clampf(p.x, r.position.x + rr, r.end.x - rr)
	var cy := clampf(p.y, r.position.y + rr, r.end.y - rr)
	return (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) <= rr * rr


## A left-to-right strip from `a` to `b` (64 px wide): drawn stretched, it is the linear gradient of a bar's fill. The picture is its two end colours' mix per pixel.
static func gradient(a: Color, b: Color) -> Rect2:
	var key := "g|%s|%s" % [a.to_html(true), b.to_html(true)]
	var r := region(key)
	if r.size == Vector2i.ZERO:
		var img := Image.create_empty(64, 2, false, Image.FORMAT_RGBA8)
		for x in 64:
			var c := a.lerp(b, (x + 0.5) / 64.0)
			img.set_pixel(x, 0, c)
			img.set_pixel(x, 1, c)
		r = add(key, img)
	return Rect2(r)


## An AtlasTexture of the imported texture at `path`, scaled down so its longer side is at most `side` px (smaller ones stay as they are). The original texture
## when the image cannot be read (a headless run has no pixels) or the atlas is full; null when the path does not exist.
static func icon(path: String, side: int = 128) -> Texture2D:
	var key := "i|%s|%d" % [path, side]
	if _icons.has(key):
		return _icons[key]
	var out: Texture2D = null
	if ResourceLoader.exists(path):
		var t := load(path) as Texture2D
		out = t
		var img := _readable(t, side)
		if img != null:
			var r := add(key, img)
			if r.size != Vector2i.ZERO:
				out = _atlas_tex(r)
	_icons[key] = out
	return out


## The greyed variant of an icon (a rite out of essence, locked or waiting for a corpse): the old slot shader's `mix(grey, rgb, sat) * bright`, baked.
## `level` is DIM_SOFT (sat 0.55, bright 0.7), DIM_HARD (0.3, 0.55) or DIM_LOCKED (0.0, 0.55). The original texture when the image cannot be read.
static func dimmed(path: String, level: int, side: int = 128) -> Texture2D:
	var key := "d%d|%s|%d" % [level, path, side]
	if _icons.has(key):
		return _icons[key]
	var out: Texture2D = icon(path, side)
	if ResourceLoader.exists(path):
		var img := _readable(load(path) as Texture2D, side)
		if img != null:
			var sat := 0.55 if level == DIM_SOFT else (0.3 if level == DIM_HARD else 0.0)
			var bright := 0.7 if level == DIM_SOFT else 0.55
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					var g := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
					img.set_pixel(x, y, Color((g + (c.r - g) * sat) * bright, (g + (c.g - g) * sat) * bright, (g + (c.b - g) * sat) * bright, c.a))
			var r := add(key, img)
			if r.size != Vector2i.ZERO:
				out = _atlas_tex(r)
	_icons[key] = out
	return out


static func _atlas_tex(r: Rect2i) -> AtlasTexture:
	var at := AtlasTexture.new()
	at.atlas = texture
	at.region = Rect2(r)
	return at


## The texture's pixels as RGBA8, scaled to at most `side` on the longer edge; null when it has none (the dummy renderer) .
static func _readable(t: Texture2D, side: int) -> Image:
	if t == null:
		return null
	var img := t.get_image()
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var longest := maxi(img.get_width(), img.get_height())
	if longest > side:
		var k := float(side) / longest
		img.resize(maxi(1, roundi(img.get_width() * k)), maxi(1, roundi(img.get_height() * k)), Image.INTERPOLATE_LANCZOS)
	return img
