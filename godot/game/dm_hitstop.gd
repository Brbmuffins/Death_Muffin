class_name DmHitStop
extends RefCounted
## Port of src/graphics/hitstop.ts: a 2-4 frame micro-freeze of the PICTURE on a heavy impact (visual only: it scales the time that
## animation mixers and particles see, never the sim clock). Rationed by a minimum gap and a leaky budget (~5% of time frozen).

const FRAME := 1.0 / 60.0
const MIN_FRAMES := 2
const MAX_FRAMES := 4
const MIN_GAP := 0.3
const BUDGET_MAX := 0.1
const REFILL := 0.045

var _left := 0.0
var _gap := 0.0
var _budget := BUDGET_MAX
var total := 0.0
var count := 0
## When true requests are ignored (reduced motion).
var disabled: Callable = Callable()
## Multiplier for the frame's dt in animation and particles: 0 while frozen.
var scale := 1.0


static func hitstop_seconds(weight: float) -> float:
	var w := clampf(weight, 0.0, 1.0)
	return float(DmMath.js_round(MIN_FRAMES + w * (MAX_FRAMES - MIN_FRAMES))) * FRAME


## Ask for a freeze. Returns the seconds granted.
func request(weight: float) -> float:
	if disabled.is_valid() and bool(disabled.call()):
		return 0.0
	var sec := hitstop_seconds(weight)
	if _left > 0.0:
		if sec > _left and _budget >= sec - _left:
			_budget -= sec - _left
			total += sec - _left
			_left = sec
		return 0.0
	if _gap > 0.0 or _budget < sec:
		return 0.0
	_budget -= sec
	_left = sec
	_gap = MIN_GAP
	total += sec
	count += 1
	return sec


func tick(dt: float) -> float:
	_budget = minf(BUDGET_MAX, _budget + dt * REFILL)
	_gap = maxf(0.0, _gap - dt)
	if _left <= 0.0:
		return dt
	var used := minf(_left, dt)
	_left -= used
	return dt - used


func frozen() -> bool:
	return _left > 0.0


## Call once per frame with the real dt; sets `scale` for the visual updates that follow.
func frame(dt: float) -> void:
	scale = tick(dt) / dt if dt > 0.0 else 1.0


func reset() -> void:
	_left = 0.0
	_gap = 0.0
	_budget = BUDGET_MAX
	scale = 1.0
