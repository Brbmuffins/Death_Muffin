class_name DmMath
extends RefCounted
## JS-semantics numeric helpers. Port TS code through these, never through Godot's round()/snapped().


## Math.round: ties go toward +infinity (Godot's round() rounds half away from zero).
static func js_round(x: float) -> int:
	var f := floorf(x)
	return int(f) + 1 if x - f >= 0.5 else int(f)


## Float-returning variant for values beyond int range or when the TS keeps a number.
static func js_round_f(x: float) -> float:
	var f := floorf(x)
	return f + 1.0 if x - f >= 0.5 else f


## Math.round(x * 10^d) / 10^d
static func round_dec(x: float, d: int) -> float:
	var m := pow(10.0, d)
	return js_round_f(x * m) / m


## Math.trunc
static func trunc(x: float) -> int:
	return int(x)


static func clamp_f(x: float, lo: float, hi: float) -> float:
	return minf(hi, maxf(lo, x))


static func clamp01(x: float) -> float:
	return minf(1.0, maxf(0.0, x))


static func lerp_f(a: float, b: float, t: float) -> float:
	return a + (b - a) * t


## (x - a) / (b - a), unclamped
static func inv_lerp(a: float, b: float, x: float) -> float:
	return (x - a) / (b - a)


## x >>> 0
static func u32(x: float) -> int:
	return int(x) & 0xFFFFFFFF


## x | 0  (signed 32-bit wrap)
static func i32(x: float) -> int:
	var v := int(x) & 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v


## Math.imul as signed 32-bit
static func imul(a: int, b: int) -> int:
	var v := (a * b) & 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v
