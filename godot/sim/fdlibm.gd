class_name DmFdlibm
extends RefCounted
## Bit-exact ports of the fdlibm sin / cos / atan / atan2 that V8 uses for Math.sin / Math.cos / Math.atan2 (V8 src/base/ieee754.cc).
## Godot's own sin/cos/atan2 call the platform libm, which differs from V8 in the last bit for a few percent of inputs; the sim compares
## distances and picks nearest targets, so a one-ulp difference can flip a tie (a Rend leaves thralls on a ring of equal distances) and the
## replay of a fixture then drifts. Using these keeps the GDScript sim bit-identical to the TS one. Verified against V8 on millions of inputs
## (tests/sim fixtures: trig). Arguments beyond ~2^19 (never produced by the sim) fall back to the engine's sin/cos.

static var _b: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])

## GDScript float literals are NOT correctly rounded (its parser is off by one ulp for ~20-digit literals), so every constant here is built
## from its exact IEEE-754 words instead of being written as a decimal.
static func _w(h: int, l: int) -> float:
	_b.encode_u32(4, h)
	_b.encode_u32(0, l)
	return _b.decode_double(0)


static var S1: float = _w(0xbfc55555, 0x55555549)
static var S2: float = _w(0x3f811111, 0x1110f8a6)
static var S3: float = _w(0xbf2a01a0, 0x19c161d5)
static var S4: float = _w(0x3ec71de3, 0x57b1fe7d)
static var S5: float = _w(0xbe5ae5e6, 0x8a2b9ceb)
static var S6: float = _w(0x3de5d93a, 0x5acfd57c)
static var C1: float = _w(0x3fa55555, 0x5555554c)
static var C2: float = _w(0xbf56c16c, 0x16c15177)
static var C3: float = _w(0x3efa01a0, 0x19cb1590)
static var C4: float = _w(0xbe927e4f, 0x809c52ad)
static var C5: float = _w(0x3e21ee9e, 0xbdb4b1c4)
static var C6: float = _w(0xbda8fae9, 0xbe8838d4)
static var INVPIO2: float = _w(0x3fe45f30, 0x6dc9c883)
static var PIO2_1: float = _w(0x3ff921fb, 0x54400000)
static var PIO2_1T: float = _w(0x3dd0b461, 0x1a626331)
static var PIO2_2: float = _w(0x3dd0b461, 0x1a600000)
static var PIO2_2T: float = _w(0x3ba3198a, 0x2e037073)
static var PIO2_3: float = _w(0x3ba3198a, 0x2e000000)
static var PIO2_3T: float = _w(0x397b839a, 0x252049c1)
static var PI_O_4: float = _w(0x3fe921fb, 0x54442d18)
static var PI_O_2: float = _w(0x3ff921fb, 0x54442d18)
static var PI_C: float = _w(0x400921fb, 0x54442d18)
static var PI_LO: float = _w(0x3ca1a626, 0x33145c07)
static var TINY: float = _w(0x01a56e1f, 0xc2f8f359)
static var ATANHI: Array = [_w(0x3fddac67, 0x0561bb4f), _w(0x3fe921fb, 0x54442d18), _w(0x3fef730b, 0xd281f69b), _w(0x3ff921fb, 0x54442d18)]
static var ATANLO: Array = [_w(0x3c7a2b7f, 0x222f65e2), _w(0x3c81a626, 0x33145c07), _w(0x3c700788, 0x7af0cbbd), _w(0x3c91a626, 0x33145c07)]
static var AT: Array = [_w(0x3fd55555, 0x5555550d), _w(0xbfc99999, 0x9998ebc4), _w(0x3fc24924, 0x920083ff), _w(0xbfbc71c6, 0xfe231671), _w(0x3fb745cd, 0xc54c206e), _w(0xbfb3b0f2, 0xaf749a6d), _w(0x3fb10d66, 0xa0d03d51), _w(0xbfadde2d, 0x52defd9a), _w(0x3fa97b4b, 0x24760deb), _w(0xbfa2b444, 0x2c6a6c2f), _w(0x3f90ad3a, 0xe322da11)]

const NPIO2_HW: Array = [0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C, 0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C, 0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A, 0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x404147AE, 0x4042106F, 0x4042D97C, 0x4043A28A, 0x40446B9C, 0x404534A9, 0x4045FDBB, 0x4046C6CB, 0x40478FDB, 0x404858EB, 0x404921FB]


static func _hi(x: float) -> int:
	_b.encode_double(0, x)
	return _b.decode_s32(4)


static func _lo(x: float) -> int:
	_b.encode_double(0, x)
	return _b.decode_u32(0)


static func _from_words(h: int, l: int) -> float:
	_b.encode_s32(4, h)
	_b.encode_u32(0, l)
	return _b.decode_double(0)


static func _k_sin(x: float, y: float, iy: int) -> float:
	var ix := _hi(x) & 0x7fffffff
	if ix < 0x3e400000:
		if int(x) == 0:
			return x
	var z := x * x
	var v := z * x
	var r := S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
	if iy == 0:
		return x + v * (S1 + z * r)
	return x - ((z * (0.5 * y - v * r) - y) - v * S1)


static func _k_cos(x: float, y: float) -> float:
	var ix := _hi(x) & 0x7fffffff
	if ix < 0x3e400000:
		if int(x) == 0:
			return 1.0
	var z := x * x
	var r := z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
	if ix < 0x3FD33333:
		return 1.0 - (0.5 * z - (z * r - x * y))
	var qx: float
	if ix > 0x3fe90000:
		qx = 0.28125
	else:
		qx = _from_words(ix - 0x00200000, 0)
	var iz := 0.5 * z - qx
	var a := 1.0 - qx
	return a - (iz - (z * r - x * y))


## Returns n and writes y0, y1 to _y (static scratch). Returns INT_MIN-ish (-999999) when out of the ported range.
static var _y0: float = 0.0
static var _y1: float = 0.0


static func _rem_pio2(x: float) -> int:
	var hx := _hi(x)
	var ix := hx & 0x7fffffff
	if ix <= 0x3fe921fb:
		_y0 = x
		_y1 = 0.0
		return 0
	if ix < 0x4002d97c:
		var z: float
		if hx > 0:
			z = x - PIO2_1
			if ix != 0x3ff921fb:
				_y0 = z - PIO2_1T
				_y1 = (z - _y0) - PIO2_1T
			else:
				z -= PIO2_2
				_y0 = z - PIO2_2T
				_y1 = (z - _y0) - PIO2_2T
			return 1
		else:
			z = x + PIO2_1
			if ix != 0x3ff921fb:
				_y0 = z + PIO2_1T
				_y1 = (z - _y0) + PIO2_1T
			else:
				z += PIO2_2
				_y0 = z + PIO2_2T
				_y1 = (z - _y0) + PIO2_2T
			return -1
	if ix <= 0x413921fb:
		var t := absf(x)
		var n := int(t * INVPIO2 + 0.5)
		var fn := float(n)
		var r := t - fn * PIO2_1
		var w := fn * PIO2_1T
		if n < 32 and ix != NPIO2_HW[n - 1]:
			_y0 = r - w
		else:
			var j := ix >> 20
			_y0 = r - w
			var i := j - ((_hi(_y0) >> 20) & 0x7ff)
			if i > 16:
				t = r
				w = fn * PIO2_2
				r = t - w
				w = fn * PIO2_2T - ((t - r) - w)
				_y0 = r - w
				i = j - ((_hi(_y0) >> 20) & 0x7ff)
				if i > 49:
					t = r
					w = fn * PIO2_3
					r = t - w
					w = fn * PIO2_3T - ((t - r) - w)
					_y0 = r - w
		_y1 = (r - _y0) - w
		if hx < 0:
			_y0 = -_y0
			_y1 = -_y1
			return -n
		return n
	return -999999


static func sin_(x: float) -> float:
	var ix := _hi(x) & 0x7fffffff
	if ix <= 0x3fe921fb:
		return _k_sin(x, 0.0, 0)
	if ix >= 0x7ff00000:
		return NAN
	var n := _rem_pio2(x)
	if n == -999999:
		return sin(x)
	var y0 := _y0
	var y1 := _y1
	match n & 3:
		0:
			return _k_sin(y0, y1, 1)
		1:
			return _k_cos(y0, y1)
		2:
			return -_k_sin(y0, y1, 1)
		_:
			return -_k_cos(y0, y1)


static func cos_(x: float) -> float:
	var ix := _hi(x) & 0x7fffffff
	if ix <= 0x3fe921fb:
		return _k_cos(x, 0.0)
	if ix >= 0x7ff00000:
		return NAN
	var n := _rem_pio2(x)
	if n == -999999:
		return cos(x)
	var y0 := _y0
	var y1 := _y1
	match n & 3:
		0:
			return _k_cos(y0, y1)
		1:
			return -_k_sin(y0, y1, 1)
		2:
			return -_k_cos(y0, y1)
		_:
			return _k_sin(y0, y1, 1)


static func atan_(x_in: float) -> float:
	var x := x_in
	var id := 0
	var hx := _hi(x)
	var ix := hx & 0x7fffffff
	if ix >= 0x44100000:
		if is_nan(x):
			return x + x
		return ATANHI[3] + ATANLO[3] if hx > 0 else -ATANHI[3] - ATANLO[3]
	if ix < 0x3fdc0000:
		if ix < 0x3e200000:
			if 1e300 + x > 1.0:
				return x
		id = -1
	else:
		x = absf(x)
		if ix < 0x3ff30000:
			if ix < 0x3fe60000:
				id = 0
				x = (2.0 * x - 1.0) / (2.0 + x)
			else:
				id = 1
				x = (x - 1.0) / (x + 1.0)
		else:
			if ix < 0x40038000:
				id = 2
				x = (x - 1.5) / (1.0 + 1.5 * x)
			else:
				id = 3
				x = -1.0 / x
	var z := x * x
	var w := z * z
	var s1: float = z * (AT[0] + w * (AT[2] + w * (AT[4] + w * (AT[6] + w * (AT[8] + w * AT[10])))))
	var s2: float = w * (AT[1] + w * (AT[3] + w * (AT[5] + w * (AT[7] + w * AT[9]))))
	if id < 0:
		return x - x * (s1 + s2)
	z = float(ATANHI[id]) - ((x * (s1 + s2) - float(ATANLO[id])) - x)
	return -z if hx < 0 else z


static func atan2_(y: float, x: float) -> float:
	if is_nan(x) or is_nan(y):
		return x + y
	var hx := _hi(x)
	var ix := hx & 0x7fffffff
	var lx := _lo(x)
	var hy := _hi(y)
	var iy := hy & 0x7fffffff
	var ly := _lo(y)
	if ((hx - 0x3ff00000) | lx) == 0:
		return atan_(y)
	var m := ((hy >> 31) & 1) | ((hx >> 30) & 2)
	if (iy | ly) == 0:
		match m:
			0, 1:
				return y
			2:
				return PI_C + TINY
			_:
				return -PI_C - TINY
	if (ix | lx) == 0:
		return -PI_O_2 - TINY if hy < 0 else PI_O_2 + TINY
	if ix == 0x7ff00000:
		if iy == 0x7ff00000:
			match m:
				0:
					return PI_O_4 + TINY
				1:
					return -PI_O_4 - TINY
				2:
					return 3.0 * PI_O_4 + TINY
				_:
					return -3.0 * PI_O_4 - TINY
		else:
			match m:
				0:
					return 0.0
				1:
					return -0.0
				2:
					return PI_C + TINY
				_:
					return -PI_C - TINY
	if iy == 0x7ff00000:
		return -PI_O_2 - TINY if hy < 0 else PI_O_2 + TINY
	var k := (iy - ix) >> 20
	var z: float
	if k > 60:
		z = PI_O_2 + 0.5 * PI_LO
		m &= 1
	elif hx < 0 and k < -60:
		z = 0.0
	else:
		z = atan_(absf(y / x))
	match m:
		0:
			return z
		1:
			return -z
		2:
			return PI_C - (z - PI_LO)
		_:
			return (z - PI_LO) - PI_C
