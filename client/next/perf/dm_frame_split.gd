class_name DmFrameSplit
extends Node
## What a frame costs, in the two parts the engine runs on the main thread, averaged over a window of frames (the benchmark's report and the F3 overlay read it):
##   physics  from the first tick's `physics_frame` to the frame's `process_frame`: every tick's `_physics_process`, the physics and navigation servers, the timers and tweens
##            of the physics clock; a frame with no tick has none, a slow one has two or three (catch-up);
##   process  from `process_frame` to the start of the last `_process` of the frame: every other `_process`, the frame's timers and tweens, the deferred calls.
## The rest of a frame (drawing, waiting for the GPU, presenting) is the frame less these two.
## Godot's own monitors (`Performance.TIME_PROCESS` / `TIME_PHYSICS_PROCESS`) are not this: they report the slowest single frame and tick of each second, refreshed once a second
## (the benchmark's "Godot peak" rows), so they read above the average frame whenever one tick in sixty is slow. Costs per frame: two signal callbacks and one `_process`, a
## handful of integer operations each; nothing runs while it is stopped.

var frames := 0              ## frames closed since the last `reset`
var ticks := 0               ## physics ticks in them
var physics_us := 0.0        ## their physics parts, added up
var process_us := 0.0        ## their process parts, added up
var worst_tick_us := 0.0     ## the slowest tick (a frame's physics part over its ticks, so exact when a frame holds one)

var _tree: SceneTree
var _tick_t0 := 0            ## µs: the first tick of this frame began
var _ticks_now := 0          ## ticks begun since the last process_frame
var _proc_t0 := 0            ## µs: this frame's process part began (0 = not yet)


func _init() -> void:
	process_priority = 2147483647   # the last `_process` of the frame: its start ends the frame's process part
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


func _exit_tree() -> void:
	stop()


## Starts counting (from the next frame).
func start(tree: SceneTree) -> void:
	if _tree != null:
		return
	_tree = tree
	_ticks_now = 0
	_proc_t0 = 0
	tree.physics_frame.connect(_on_physics_frame)
	tree.process_frame.connect(_on_process_frame)
	set_process(true)


func stop() -> void:
	set_process(false)
	if _tree != null and is_instance_valid(_tree):
		_tree.physics_frame.disconnect(_on_physics_frame)
		_tree.process_frame.disconnect(_on_process_frame)
	_tree = null


## A new window.
func reset() -> void:
	frames = 0
	ticks = 0
	physics_us = 0.0
	process_us = 0.0
	worst_tick_us = 0.0


func physics_ms() -> float:
	return physics_us / maxf(1.0, float(frames)) / 1000.0


func process_ms() -> float:
	return process_us / maxf(1.0, float(frames)) / 1000.0


func ticks_per_frame() -> float:
	return float(ticks) / maxf(1.0, float(frames))


## The average tick (a frame with no tick adds nothing).
func tick_ms() -> float:
	return physics_us / maxf(1.0, float(ticks)) / 1000.0


func _on_physics_frame() -> void:
	if _ticks_now == 0:
		_tick_t0 = Time.get_ticks_usec()
	_ticks_now += 1


func _on_process_frame() -> void:
	var now := Time.get_ticks_usec()
	if _ticks_now > 0:
		var span := float(now - _tick_t0)
		physics_us += span
		ticks += _ticks_now
		worst_tick_us = maxf(worst_tick_us, span / float(_ticks_now))
		_ticks_now = 0
	_proc_t0 = now


func _process(_dt: float) -> void:
	if _proc_t0 == 0:
		return
	process_us += float(Time.get_ticks_usec() - _proc_t0)
	frames += 1
	_proc_t0 = 0
