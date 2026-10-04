class_name DmRng
extends RefCounted
## Bit-exact port of src/gameplay/rng.ts (mulberry32 + helpers).
## Usage: var rng := DmRng.new(seed); rng.next() -> float in [0,1).
## Pass `rng.as_callable()` anywhere the TS took a `rand: () => number`.

const MASK := 0xFFFFFFFF

var _a: int = 0


func _init(seed_value: Variant = 0) -> void:
	set_seed(seed_value)


## `seed >>> 0` : truncate toward zero, wrap modulo 2^32.
func set_seed(seed_value: Variant) -> void:
	_a = int(seed_value) & MASK


## Imul(a,b) low 32 bits as unsigned (64-bit wraparound keeps the low 32 bits exact).
static func imul(a: int, b: int) -> int:
	return (a * b) & MASK


## Next float in [0, 1). Same sequence as the TS closure.
func next() -> float:
	_a = (_a + 0x6D2B79F5) & MASK
	var t: int = _a
	t = imul(t ^ (t >> 15), t | 1)
	t = (t ^ ((t + imul(t ^ (t >> 7), t | 61)) & MASK)) & MASK
	return float((t ^ (t >> 14)) & MASK) / 4294967296.0


func as_callable() -> Callable:
	return next


## randRange(rand, min, max)
func range_f(min_v: float, max_v: float) -> float:
	return min_v + next() * (max_v - min_v)


## randInt(rand, min, max) inclusive, Math.floor(min + r*(max-min+1))
func range_i(min_v: int, max_v: int) -> int:
	return int(floor(float(min_v) + next() * float(max_v - min_v + 1)))


## Static forms taking a `rand: Callable` returning float (mirrors the TS signatures).
static func rand_range(rand: Callable, min_v: float, max_v: float) -> float:
	return min_v + float(rand.call()) * (max_v - min_v)


static func rand_int(rand: Callable, min_v: int, max_v: int) -> int:
	return int(floor(float(min_v) + float(rand.call()) * float(max_v - min_v + 1)))


## pickWeighted(items, r): items are Dictionaries with a "weight" key. Returns the item, or null if empty.
static func pick_weighted(items: Array, r: float) -> Variant:
	if items.is_empty():
		return null
	var total := 0.0
	for it in items:
		total += float(it["weight"])
	var roll := r * total
	for it in items:
		var w := float(it["weight"])
		if roll < w:
			return it
		roll -= w
	return items[items.size() - 1]
