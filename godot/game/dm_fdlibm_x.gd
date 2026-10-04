class_name DmFdlibmX
extends RefCounted
## Bit-exact ports of V8's Math.exp and Math.asin (fdlibm e_exp.c / e_asin.c, V8 src/base/ieee754.cc), complementing godot/sim/fdlibm.gd.
## Godot's exp()/asin() call the platform libm, which differs from V8 in the last bit for ~20% of inputs (auto-combat's turn smoothing and
## dodge cone margins use them). Constants are built from their exact IEEE-754 words (GDScript's float literal parser is not correctly rounded).

static var _b: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])


static func _w(h: int, l: int) -> float:
	_b.encode_u32(4, h)
	_b.encode_u32(0, l)
	return _b.decode_double(0)


static func _hi(x: float) -> int:
	_b.encode_double(0, x)
	return _b.decode_u32(4)


static func _lo(x: float) -> int:
	_b.encode_double(0, x)
	return _b.decode_u32(0)


static var LN2HI: float = _w(0x3fe62e42, 0xfee00000)
static var LN2LO: float = _w(0x3dea39ef, 0x35793c76)
static var INVLN2: float = _w(0x3ff71547, 0x652b82fe)
static var P1: float = _w(0x3fc55555, 0x5555553e)
static var P2: float = _w(0xbf66c16c, 0x16bebd93)
static var P3: float = _w(0x3f11566a, 0xaf25de2c)
static var P4: float = _w(0xbebbbd41, 0xc5d26bf1)
static var P5: float = _w(0x3e663769, 0x72bea4d0)

static var PIO2_HI: float = _w(0x3ff921fb, 0x54442d18)
static var PIO2_LO: float = _w(0x3c91a626, 0x33145c07)
static var PIO4_HI: float = _w(0x3fe921fb, 0x54442d18)
static var PS0: float = _w(0x3fc55555, 0x55555555)
static var PS1: float = _w(0xbfd4d612, 0x03eb6f7d)
static var PS2: float = _w(0x3fc9c155, 0x0e884455)
static var PS3: float = _w(0xbfa48228, 0xb5688f3b)
static var PS4: float = _w(0x3f49efe0, 0x7501b288)
static var PS5: float = _w(0x3f023de1, 0x0dfdf709)
static var QS1: float = _w(0xc0033a27, 0x1c8a2d4b)
static var QS2: float = _w(0x40002ae5, 0x9c598ac8)
static var QS3: float = _w(0xbfe6066c, 0x1b8d0159)
static var QS4: float = _w(0x3fb3b8c5, 0xb12e9282)


## Math.exp(x) for finite |x| < ~700 (anything else falls back to the engine's exp).
static func exp_(x: float) -> float:
	var hx := _hi(x)
	var xsb := (hx >> 31) & 1
	hx &= 0x7fffffff
	if hx >= 0x40862E42 or is_nan(x):
		return exp(x)
	var hi := 0.0
	var lo := 0.0
	var k := 0
	if hx > 0x3fd62e42:  # |x| > 0.5 ln2
		if hx < 0x3FF0A2B2:  # and |x| < 1.5 ln2
			if x == 1.0:
				return _w(0x4005bf0a, 0x8b145769)  # E
			hi = x - (LN2HI if xsb == 0 else -LN2HI)
			lo = LN2LO if xsb == 0 else -LN2LO
			k = 1 - xsb - xsb
		else:
			k = int(INVLN2 * x + (0.5 if xsb == 0 else -0.5))
			var t0 := float(k)
			hi = x - t0 * LN2HI
			lo = t0 * LN2LO
		x = hi - lo
	elif hx < 0x3e300000:  # |x| < 2**-28
		return 1.0 + x
	else:
		k = 0
	var t := x * x
	var twopk := _w(0x3ff00000 + (k << 20), 0) if k >= -1021 else _w(0x3ff00000 + ((k + 1000) << 20), 0)
	var c := x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))))
	if k == 0:
		return 1.0 - ((x * c) / (c - 2.0) - x)
	var y := 1.0 - ((lo - (x * c) / (2.0 - c)) - hi)
	if k >= -1021:
		return y * twopk
	return y * twopk * _w(0x01700000, 0)  # twom1000 = 2^-1000


## Math.asin(x).
static func asin_(x: float) -> float:
	var hx := _hi(x)
	if hx >= 0x80000000:
		hx -= 0x100000000  # signed
	var ix := hx & 0x7fffffff
	var t := 0.0
	if ix >= 0x3ff00000:  # |x| >= 1
		if ((ix - 0x3ff00000) | _lo(x)) == 0:
			return x * PIO2_HI + x * PIO2_LO
		return NAN
	elif ix < 0x3fe00000:  # |x| < 0.5
		if ix < 0x3e400000:  # |x| < 2**-27
			return x
		t = x * x
		var p := t * (PS0 + t * (PS1 + t * (PS2 + t * (PS3 + t * (PS4 + t * PS5)))))
		var q := 1.0 + t * (QS1 + t * (QS2 + t * (QS3 + t * QS4)))
		return x + x * (p / q)
	# 1 > |x| >= 0.5
	var w := 1.0 - absf(x)
	t = w * 0.5
	var p2 := t * (PS0 + t * (PS1 + t * (PS2 + t * (PS3 + t * (PS4 + t * PS5)))))
	var q2 := 1.0 + t * (QS1 + t * (QS2 + t * (QS3 + t * QS4)))
	var s := sqrt(t)
	if ix >= 0x3FEF3333:  # |x| > 0.975
		w = p2 / q2
		t = PIO2_HI - (2.0 * (s + s * w) - PIO2_LO)
	else:
		w = s
		_b.encode_double(0, w)
		_b.encode_u32(0, 0)
		w = _b.decode_double(0)
		var c := (t - w * w) / (s + w)
		var r := p2 / q2
		var p3 := 2.0 * s * r - (PIO2_LO - 2.0 * c)
		var q3 := PIO4_HI - 2.0 * w
		t = PIO4_HI - (p3 - q3)
	return t if hx > 0 else -t
