extends RefCounted
## Base of one part of a merged suite. A part is the body of a former stand-alone `extends SceneTree` runner: it keeps the SceneTree names it used
## (root, physics_frame, process_frame, create_timer, get_nodes_in_group, quit) so its test code is unchanged, but runs inside the
## DmSuiteRunner process. `_initialize()` is a coroutine the runner awaits; `quit(code)` records the exit code instead of ending the process.

var tree: SceneTree
var root: Window
var physics_frame: Signal
var process_frame: Signal
var exit_code := 0


func bind(t: SceneTree) -> void:
	tree = t
	root = t.root
	physics_frame = t.physics_frame
	process_frame = t.process_frame


func create_timer(sec: float, process_always := true, process_in_physics := false, ignore_time_scale := false) -> SceneTreeTimer:
	return tree.create_timer(sec, process_always, process_in_physics, ignore_time_scale)


func get_nodes_in_group(group: StringName) -> Array[Node]:
	return tree.get_nodes_in_group(group)


func quit(code: int = 0) -> void:
	exit_code = code


func get_root() -> Window:
	return root


func set_multiplayer(m: MultiplayerAPI, root_path: NodePath = NodePath()) -> void:
	tree.set_multiplayer(m, root_path)


## Hand-stepped waiting: n physics ticks (1/60 s each at the default rate), never a wall-clock timer.
func step_ticks(n: int) -> void:
	for i in n:
		await physics_frame


func step_secs(sec: float) -> void:
	await step_ticks(int(round(sec * 60.0)))

