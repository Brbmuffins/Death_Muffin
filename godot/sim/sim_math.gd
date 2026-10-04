class_name DmSimMath
extends RefCounted
## JS-exact numeric helpers for the sim.


## Math.hypot(a, b) exactly as V8 computes it (scaled Kahan sum). The naive sqrt(a*a+b*b) differs in the last bit for ~38% of inputs,
## and the sim compares distances all the time, so use this wherever the TS says Math.hypot.
static func hypot(a: float, b: float) -> float:
	a = absf(a)
	b = absf(b)
	var m := maxf(a, b)
	if m == 0.0:
		return 0.0
	if is_inf(m):
		return INF
	var n := a / m
	var s := n * n
	var sum := s
	var comp := (sum - 0.0) - s
	n = b / m
	s = n * n - comp
	var p := sum + s
	return sqrt(p) * m


## Math.sign
static func sign_js(x: float) -> float:
	if x > 0.0:
		return 1.0
	if x < 0.0:
		return -1.0
	return x


## `Math.floor(x)` as int (x finite).
static func floor_i(x: float) -> int:
	return int(floorf(x))


## `Math.atan2(y, x)` is atan2(y, x) in both.
## JS `%` (remainder, sign of the dividend) for floats.
static func fmod_js(a: float, b: float) -> float:
	return fmod(a, b)
