class_name DmFootstepTracker
extends RefCounted
## Port of src/audio/footsteps.ts: footstep timing for the hero in step with the walk animation. Pure: feed it the walk loop's phase
## (0..1, or -1 when no walk loop is playing) and the position each frame; it reports when a foot lands.
## A walk cycle has two footfalls, half a cycle apart; without a phase it falls back to one step per FALLBACK_STRIDE units walked.

## Where in the loop the feet plant (fractions of the cycle).
const FOOT_PHASES: Array[float] = [0.04, 0.54]
const FALLBACK_STRIDE := 1.35

var _last := -1.0
var _px := NAN
var _pz := NAN
var _dist := 0.0


## True when a foot lands this frame. `phase` < 0 means no walk loop is playing.
func step(phase: float, x: float, z: float) -> bool:
	var moved := 0.0 if is_nan(_px) else Vector2(x - _px, z - _pz).length()
	_px = x
	_pz = z
	if phase < 0.0:
		_last = -1.0
		_dist += moved
		if _dist >= FALLBACK_STRIDE:
			_dist = 0.0
			return true
		return false
	_dist = 0.0
	var prev := _last
	_last = phase
	if prev < 0.0:
		return false
	for f in FOOT_PHASES:
		# crossed f going forward, allowing for the loop wrapping from ~1 back to ~0
		var crossed: bool = (prev < f and phase >= f) if prev <= phase else (prev < f or phase >= f)
		if crossed:
			return true
	return false


## The hero stopped: the next walk starts fresh (no step on the first frame).
func reset() -> void:
	_last = -1.0
	_px = NAN
	_pz = NAN
	_dist = 0.0
