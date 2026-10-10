class_name DmResolutionGovernor
extends RefCounted
## Port of archive/legacy-web:src/app/framePacing.ts ResolutionGovernor (Settings "Auto resolution"): when frames sustainedly miss the cap's budget (a GPU that
## can't keep up), render fewer pixels; when there is headroom again, step back up. A step up that fails right away becomes the ceiling,
## so it doesn't ping-pong. Deliberately timid: several seconds of sustained misses, at most one change per MIN_GAP_S, small steps, and
## never while hold() is active (area entry / scene load). It only steps down when a lower resolution can help: slow frames whose GPU time (or,
## where the renderer reports none, whose script time) shows the frame is CPU-bound leave the image sharp, and a view already stepped down
## for nothing steps back up. `scale` drives the viewport's scaling_3d_scale (the 3D view only; the UI stays sharp).

## Absolute lowest scale (the Low preset's floor). Each graphics preset sets its own floor (DmGraphicsPreset `floor`): never below 0.85 on Medium+.
const MIN := 0.6
const STEP := 0.9
const DOWN_AFTER_S := 3.5
const UP_AFTER_S := 15.0
const MIN_GAP_S := 20.0
const HOLD_S := 10.0
## The frame counts as GPU-bound when the GPU took at least this share of it; as script-bound when script time took at least LOGIC_SHARE of it.
const GPU_SHARE := 0.7
const LOGIC_SHARE := 0.5

var scale := 1.0
## The preset's lowest scale (set_floor); the governor never steps below it.
var floor_scale := MIN
var _ceiling := 1.0
var _over := 0.0
var _under := 0.0
var _since_change := MIN_GAP_S
var _raised_from := 0.0
var _held := 0.0
var _cpu_over := 0.0


## 0 = "Max": judged against 60 (a 144 Hz miss is not a GPU problem).
static func budget_fps(cap: int) -> int:
	return cap if cap > 0 else 60


func hold(seconds: float = HOLD_S) -> void:
	_held = maxf(_held, seconds)
	_over = 0.0
	_under = 0.0
	_cpu_over = 0.0


## Can fewer pixels shorten this frame? `gpu_ms` the smoothed GPU render time (<= 0: the renderer reports none), `logic_ms` the smoothed script
## time (< 0: unknown). Unknown on both = yes (the old behaviour).
static func scalable(smooth_ms: float, gpu_ms: float = -1.0, logic_ms: float = -1.0) -> bool:
	if gpu_ms > 0.0:
		return gpu_ms >= smooth_ms * GPU_SHARE
	if logic_ms >= 0.0:
		return logic_ms < smooth_ms * LOGIC_SHARE
	return true


## One processed frame: `dt_s` real seconds, `smooth_ms` the smoothed frame time, `fps` the budget rate, `gpu_ms` / `logic_ms` as in scalable().
## True when `scale` changed.
func frame(dt_s: float, smooth_ms: float, fps: int, gpu_ms: float = -1.0, logic_ms: float = -1.0) -> bool:
	var budget := 1000.0 / float(fps)
	_since_change += dt_s
	if _held > 0.0:
		_held -= dt_s
		_over = 0.0
		_under = 0.0
		_cpu_over = 0.0
		return false
	var missed := smooth_ms > budget * 1.3
	var cpu_bound := missed and not scalable(smooth_ms, gpu_ms, logic_ms)
	_cpu_over = _cpu_over + dt_s if cpu_bound else 0.0
	if cpu_bound:
		_over = 0.0
		_under = 0.0
	elif missed:
		_over += dt_s
		_under = 0.0
	elif smooth_ms < budget * 1.08:
		_under += dt_s
		_over = 0.0
	else:
		_over = 0.0
		_under = 0.0
	var settled := _since_change >= MIN_GAP_S
	if settled and _over >= DOWN_AFTER_S and scale > floor_scale:
		if _raised_from > 0.0 and _since_change < 60.0:
			_ceiling = _raised_from
		_raised_from = 0.0
		return _set_scale(maxf(floor_scale, scale * STEP))
	if settled and _cpu_over >= DOWN_AFTER_S and scale < _ceiling:
		_raised_from = 0.0   # not a failed step up: the slow frames were never the GPU's
		return _set_scale(minf(_ceiling, scale / STEP))
	if settled and _under >= UP_AFTER_S and scale < _ceiling:
		_raised_from = scale
		return _set_scale(minf(_ceiling, scale / STEP))
	return false


## A preset change: clamp the floor to [MIN, 1] and lift the current scale (and ceiling) if it is below it.
func set_floor(f: float) -> void:
	floor_scale = clampf(f, MIN, 1.0)
	scale = maxf(scale, floor_scale)
	_ceiling = maxf(_ceiling, floor_scale)


func reset() -> void:
	scale = 1.0
	_ceiling = 1.0
	_raised_from = 0.0
	_over = 0.0
	_under = 0.0
	_cpu_over = 0.0
	_since_change = MIN_GAP_S
	_held = 0.0


func _set_scale(s: float) -> bool:
	scale = roundf(s * 100.0) / 100.0
	if scale > 0.98:
		scale = 1.0
	_over = 0.0
	_under = 0.0
	_cpu_over = 0.0
	_since_change = 0.0
	return true
