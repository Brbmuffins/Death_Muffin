class_name DmFrameCost
extends Node
## Test helper: the real cost of one game frame (physics tick + process + canvas/UI redraw + deferred calls), headless.
## Why not Performance.TIME_PROCESS / TIME_PHYSICS_PROCESS: those are windowed (they hold one stall for ~1 s), so the mean of their samples is
## dominated by a single hitch, and they leave out the redraw flush. Here the frame limiter is lifted (Engine.max_fps = 0) and the wall time
## between two process_frame signals is recorded; an iteration that ran a physics tick is a full frame (the cheap in-between iterations are
## ignored). Median for a budget, worst() for a generous cap, so a real regression fails and one stall on a shared machine does not.

var _last := 0
var _ticks := 0
var _full: Array[float] = []
var _saved_fps := 0
var _cpu_last := 0.0
## Frames over STALL_MS: [wall ms, process CPU ms, load average]. CPU ~ wall = the stall is our code; CPU << wall = the process was descheduled (contention).
var stalls: Array = []
const STALL_MS := 50.0
## A stall where the process got under this share of the wall time on a CPU was descheduled by the OS (shared VPS), not slow code.
const BUSY_SHARE := 0.4
var _worst_busy := 0.0


## utime + stime of this process in ms (/proc/self/stat, 10 ms resolution); 0 when unavailable.
static func cpu_ms() -> float:
	var f := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if f == null:
		return 0.0
	var t := f.get_as_text()
	var f2 := t.substr(t.rfind(")") + 2).split(" ")
	return (float(f2[11]) + float(f2[12])) * 10.0 if f2.size() > 12 else 0.0


static func load1() -> float:
	var f := FileAccess.open("/proc/loadavg", FileAccess.READ)
	return float(f.get_as_text().split(" ")[0]) if f != null else 0.0


static func attach(parent: Node) -> DmFrameCost:
	var c := DmFrameCost.new()
	c.name = "FrameCost"
	parent.add_child(c)
	return c


func _ready() -> void:
	_saved_fps = Engine.max_fps
	Engine.max_fps = 0
	_last = Time.get_ticks_usec()
	_ticks = Engine.get_physics_frames()
	get_tree().process_frame.connect(_on_frame)


func _exit_tree() -> void:
	Engine.max_fps = _saved_fps


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	var t := Engine.get_physics_frames()
	if t != _ticks:
		var ms := (now - _last) / 1000.0
		_full.append(ms)
		_ticks = t
		var cpu := cpu_ms() - _cpu_last
		if ms > STALL_MS:
			stalls.append([ms, cpu, load1()])
		if ms <= STALL_MS or cpu >= ms * BUSY_SHARE:
			_worst_busy = maxf(_worst_busy, ms)
	_last = now
	_cpu_last = cpu_ms()


## Forget samples so far (warm-up).
func reset() -> void:
	_full.clear()
	stalls.clear()
	_worst_busy = 0.0


func samples() -> int:
	return _full.size()


func pct(q: float) -> float:
	if _full.is_empty():
		return 0.0
	var s := _full.duplicate()
	s.sort()
	return s[clampi(int(q * (s.size() - 1) + 0.5), 0, s.size() - 1)]


func median_ms() -> float:
	return pct(0.5)


func p95_ms() -> float:
	return pct(0.95)


func worst_ms() -> float:
	return pct(1.0)


## The worst frame, ignoring stalls where the process was descheduled (CPU time << wall time: another process held the core). A real
## hitch in our code (GC, a first-use compile, an O(n^2) frame) burns CPU and still counts; use this for the generous worst-frame cap.
func worst_busy_ms() -> float:
	return _worst_busy
