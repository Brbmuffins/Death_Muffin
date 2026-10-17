class_name DmCompatAlbedo
extends RefCounted
## Today's Compatibility renderer multiplies a material's colours in sRGB space and converts the PRODUCT to linear light at the end of the fragment shader
## (scene.glsl: `albedo = srgb_to_linear(albedo)` after the material's albedo colour x texture x vertex colour); Forward+ converts each factor and multiplies in linear
## light. For a tinted dark texture (every floor, every wall: textures averaging 0.1 to 0.2 in sRGB, tints of 0.55 to 0.9) the first is 1.1 to 1.6 times brighter than the
## second, and the difference is where the eye reads the ground: a ground that is darker and has lost its red and green (the "darker, purple wash" of the first test builds).
## The area converter lifts each such material's tint by the ratio measured on its texture, so the rebuilt ground has the albedo today's has (client/README.md "Areas").
## The ratios are per (texture, tint) and measured by `measure` on the texture's source image; `tests/areas.gd` measures them again and fails when a table entry is stale.

const SAMPLES := 96   ## texels read along each side of the image (a stride): the same on every machine

## "<texture>|<tint hex>" -> the factor per channel (linear light) that turns Forward+'s albedo into Compatibility's. Written by `client/tools/compat_albedo.gd`.
const TABLE := {
	"cloister_floor|a8b4a0": Vector3(1.293, 1.193, 1.291),
	"coliseum_floor|c8bca8": Vector3(1.036, 1.051, 1.084),
	"fen_floor|a8c0bc": Vector3(1.296, 1.137, 1.125),
	"flagstone|8c86a8": Vector3(1.376, 1.419, 1.184),
	"flagstone|9a86aa": Vector3(1.297, 1.419, 1.178),
	"flagstone|9a92a8": Vector3(1.297, 1.343, 1.184),
	"grave_soil|b8aab8": Vector3(1.274, 1.388, 1.278),
	"grave_soil|e6f0d4": Vector3(1.074, 1.045, 1.142),
	"ossuary_floor|b0a4ae": Vector3(1.193, 1.269, 1.183),
	"pyre_floor|d8b498": Vector3(1.067, 1.168, 1.298),
	"skull_wall|c2b8ae": Vector3(1.081, 1.111, 1.121),
	"stone_wall|8a8296": Vector3(1.394, 1.463, 1.285),
	"stone_wall|9a92a4": Vector3(1.301, 1.354, 1.224),
	"warren_floor|8a8070": Vector3(1.423, 1.474, 1.612),
	"warren_floor|b8ac98": Vector3(1.184, 1.220, 1.310),
	"wing_floor|e8dcc8": Vector3(1.023, 1.048, 1.110),
	"wing_wall|d8ccb8": Vector3(1.050, 1.085, 1.169),
}


static func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


static func _lin_back(c: float) -> float:
	return c * 12.92 if c <= 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055


static func key(tex: String, tint: Color) -> String:
	return "%s|%s" % [tex, tint.to_html(false)]


## The ratio, per channel, between the texture's average albedo as Compatibility makes it (the product of the tint and the texel in sRGB, converted once) and as Forward+ makes it
## (each converted, then multiplied), over the image's texels (read with a stride, the same texels every time).
static func measure(img: Image, tint: Color) -> Vector3:
	var w := img.get_width()
	var h := img.get_height()
	var sx := maxi(1, w / SAMPLES)
	var sy := maxi(1, h / SAMPLES)
	var num := Vector3.ZERO
	var den := Vector3.ZERO
	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var c := img.get_pixel(x, y)
			num += Vector3(_lin(tint.r * c.r), _lin(tint.g * c.g), _lin(tint.b * c.b))
			den += Vector3(_lin(tint.r) * _lin(c.r), _lin(tint.g) * _lin(c.g), _lin(tint.b) * _lin(c.b))
	return Vector3(num.x / den.x, num.y / den.y, num.z / den.z)


## The tint a material with texture `tex` and sRGB tint `color` gets on Forward+ so its albedo is the one Compatibility makes of `color` (a tint with no entry stays as it is).
static func tint(tex: String, color: Color) -> Color:
	var r: Vector3 = TABLE.get(key(tex, color), Vector3.ONE)
	if r == Vector3.ONE:
		return color
	return lifted(color, r)


## `color` with its linear light multiplied by `r` (clamped to 1), back in sRGB.
static func lifted(color: Color, r: Vector3) -> Color:
	return Color(_lin_back(minf(_lin(color.r) * r.x, 1.0)), _lin_back(minf(_lin(color.g) * r.y, 1.0)), _lin_back(minf(_lin(color.b) * r.z, 1.0)), color.a)
