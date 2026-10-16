class_name DmDropStream
extends RefCounted
## The shared drop stream (server authority Phase 1): sfc32 over four 32-bit words, warmed up 12 steps, exactly as dropStream in
## server/rules/gameplay/lootRules.ts. The server hands a character the seed words for its next drops; the client rolls a drop the
## instant a kill lands, and the server rolls the same drop from the same words when it is claimed. Pure integer math, so both sides
## give the same floats. `next()` -> float in [0, 1); `DmDropStream.rand(words)` is the Callable the DmLoot roll functions take.

const M := 0xFFFFFFFF
var _a := 0
var _b := 0
var _c := 0
var _d := 0


func _init(words: Array = [0, 0, 0, 0]) -> void:
	_a = int(words[0]) & M
	_b = int(words[1]) & M
	_c = int(words[2]) & M
	_d = int(words[3]) & M
	for i in 12:
		next()


func next() -> float:
	var t0 := (_a + _b) & M
	_a = (_b ^ (_b >> 9)) & M
	_b = (_c + (_c << 3)) & M
	_c = ((_c << 21) | (_c >> 11)) & M
	_d = (_d + 1) & M
	var t := (t0 + _d) & M
	_c = (_c + t) & M
	return float(t) / 4294967296.0


## A Callable over a fresh stream. The lambda holds the stream (a bound method Callable alone would not keep a RefCounted alive).
static func rand(words: Array) -> Callable:
	var s := DmDropStream.new(words)
	return func() -> float: return s.next()
