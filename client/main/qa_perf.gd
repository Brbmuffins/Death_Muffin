class_name DmQaPerf
extends RefCounted
## What the release checks' scenarios (main/qa_stutter.gd, main/qa_soak.gd; client/README.md "Release checks") measure and how they write it: frame-time statistics, the engine's pipeline compilation counters and
## memory monitors, and the results file. QA runs only; nothing here runs in play.

## Godot 4.7 counts the pipelines the renderer compiled so far, by kind: a first-use effect or material that compiles during play is a hitch (ROADMAP "first-use stutters").
## The first four kinds make the frame wait (canvas, a mesh or surface met for the first time, a draw); "specialization" compiles an optimised copy in the background
## while the general one draws, which a fast processor hides and a weak one may not.
const COMPILATIONS := {"canvas": RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS, "mesh": RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
	"surface": RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE, "draw": RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
	"specialization": RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION}
const MB := 1048576.0


## The pipelines compiled since the run began, all five kinds together (0 on a run with no renderer).
static func compilations() -> int:
	var n := 0
	for kind in COMPILATIONS.values():
		n += int(RenderingServer.get_rendering_info(kind))
	return n


## The same, per kind: {canvas, mesh, surface, draw, specialization}.
static func compilations_by_kind() -> Dictionary:
	var out := {}
	for name in COMPILATIONS:
		out[name] = int(RenderingServer.get_rendering_info(COMPILATIONS[name]))
	return out


## `after` minus `before`, kind by kind (two compilations_by_kind() readings).
static func kinds_between(before: Dictionary, after: Dictionary) -> Dictionary:
	var out := {}
	for name in COMPILATIONS:
		out[name] = int(after.get(name, 0)) - int(before.get(name, 0))
	return out


## The p-th percentile (nearest rank) of the first `n` values of an ASCENDING array; 0 for none.
static func percentile(sorted: PackedFloat32Array, n: int, p: float) -> float:
	if n <= 0:
		return 0.0
	return sorted[clampi(int(ceil(p / 100.0 * float(n))) - 1, 0, n - 1)]


## Frame time statistics of the first `n` frames of `ms` (milliseconds each): {frames, p50_ms, p99_ms, worst_ms}.
static func frame_stats(ms: PackedFloat32Array, n: int) -> Dictionary:
	var sorted := ms.slice(0, n)
	sorted.sort()
	return {"frames": n, "p50_ms": rounded(percentile(sorted, n, 50.0)), "p99_ms": rounded(percentile(sorted, n, 99.0)), "worst_ms": rounded(sorted[n - 1] if n > 0 else 0.0)}


## What the engine says the run holds right now: static memory and video memory in MB, objects and nodes in the tree (the static memory monitor counts in debug builds, which these scenarios run on).
static func memory() -> Dictionary:
	return {"static_mb": rounded(Performance.get_monitor(Performance.MEMORY_STATIC) / MB), "objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), "video_mb": rounded(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / MB)}


## Two decimals, for the results file.
static func rounded(v: float) -> float:
	return snappedf(v, 0.01)


## Writes `data` as JSON at `file` (a file of the run's own: nothing else is touched). False when it cannot be written or `file` is empty.
static func write_json(file: String, data: Variant) -> bool:
	if file == "":
		return false
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return true


## The video card the run drew with ("" when headless).
static func adapter() -> String:
	return RenderingServer.get_video_adapter_name() if DisplayServer.get_name() != "headless" else ""
