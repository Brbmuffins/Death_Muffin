extends RefCounted
## Test-only stand-in for rules-core's DmRng (`DmRng.new(seed)` + `.next() -> float`), bit-exact mulberry32 from archive/legacy-web:src/gameplay/rng.ts.
## run.gd uses the real DmRng when res://rules/core/rng.gd exists and this shim otherwise.
const M := 0xFFFFFFFF
var a: int

func _init(seed_: int) -> void:
	a = seed_ & M

static func _imul(x: int, y: int) -> int:
	return (x * y) & M

func next() -> float:
	a = (a + 0x6d2b79f5) & M
	var t := a
	t = _imul(t ^ (t >> 15), t | 1)
	t = (t ^ ((t + _imul(t ^ (t >> 7), t | 61)) & M)) & M
	return float((t ^ (t >> 14)) & M) / 4294967296.0
