class_name DmDrawScene
extends RefCounted
## The scene the draw budget is counted in (client/next/perf/DRAW-BUDGET.md): one room's area scene as the game loads it, the game's camera over the middle of the room, the Ultra
## preset's moon and environment, and a Full Party on the combat core around the camera's focus. No game scene, no hero, HUD or effects: the world and the crowd are what the budget is
## about, and both a headless test (tests/draw_budget.gd) and a rendered run (tools/draw_measure.gd) build it in seconds.

const SETTINGS := {"graphics": "ultra", "fps": 0, "auto_res": false, "brightness": 1.0, "ui_scale": 1.0, "vsync": false}   ## Helix's benchmark runs: 1440p Ultra
const THRALL_BASE := {"warrior": [1.3, 1.0, 5.6], "shieldbearer": [1.3, 1.25, 5.2], "hound": [1.2, 0.7, 7.2], "wraith": [5.5, 1.1, 5.8], "archer": [7.5, 1.3, 5.4], "bonemage": [6.5, 1.8, 5.2]}
const THRALL_KINDS := ["warrior", "warrior", "warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage"]   ## the eight each of four necromancers has out
const LEGIONS := ["ossuary", "gravecaller", "rotweaver", "mourner"]
const GRAVES_DEFS := ["robber", "robber", "hound", "ghoul", "wraith", "robber", "hound", "robber"]


## What `DmNextPerf` reads of the game scene (`world`, `core_host`, `ready_`), and what the budget's scene holds.
class Stage:
	extends Node3D
	var world: DmNextWorld
	var core_host: DmCoreHost
	var camera: DmCameraRig
	var perf: DmNextPerf
	var focus := Vector3.ZERO     ## the ground point under the camera's look: the hero's place
	var ready_ := true


## The world of `room` (its area scene, the lights builder's moon and environment), the camera on the middle of the room and the Ultra preset, under `parent`.
static func build(parent: Node, room := "graves") -> Stage:
	var stage := Stage.new()
	stage.name = "Game"
	parent.add_child(stage)
	stage.world = DmNextWorld.new()
	stage.world.name = "World"
	stage.add_child(stage.world)
	stage.world.build([room], true)
	var rect: Dictionary = DmContent.area(room)["rect"]
	stage.focus = Vector3((float(rect["x0"]) + float(rect["x1"])) * 0.5, 0.0, (float(rect["z0"]) + float(rect["z1"])) * 0.5)
	stage.camera = DmCameraRig.new()
	stage.camera.name = "Camera"
	stage.add_child(stage.camera)
	stage.camera.setup(stage.world.camera_config())
	stage.camera.snap(stage.focus)
	stage.perf = DmNextPerf.new()
	stage.perf.name = "Perf"
	stage.perf.game = stage
	stage.add_child(stage.perf)
	stage.perf.apply(SETTINGS)
	return stage


## The crowd: the combat core, the crowd view over the baked models in `baked_dir` ("" = the project's), four heroes with eight thralls each and 72 enemies in a ring 7 to 13 m round the focus.
## Nobody can hurt anybody. The preset is applied again so the crowd gets its shadow policy and the moon's direction.
static func add_crowd(stage: Stage, baked_dir := "", defs: Array = GRAVES_DEFS) -> DmCoreHost:
	var host := DmCoreHost.new()
	host.name = "Core"
	stage.add_child(host)
	var opts := {"seed": DmBenchmark.SEED, "wander": false, "bounds": stage.world.bounds()}
	if baked_dir != "":
		opts["baked_dir"] = baked_dir
	host.setup(opts)
	stage.core_host = host
	stage.perf.apply(SETTINGS)
	var core := host.core
	var at := Vector2(stage.focus.x, stage.focus.z)
	var heroes: Array = []
	for h in 4:
		var id: int = core.add_external(0, 0.4, 1.0)
		core.set_external(id, at + Vector2(4.0 * (float(h) - 1.5), 0.0), true)
		host.view.set_owner_legion(id, LEGIONS[h])
		heroes.append(id)
	for h in 4:
		for k in 8:
			var b: Array = THRALL_BASE[THRALL_KINDS[k]]
			core.raise_thrall({"kind": THRALL_KINDS[k], "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": b[1], "range": b[0], "speed": b[2], "empowered": false,
				"champion": h == 1 and k == 0, "allyHeal": 0.0}, heroes[h], at + Vector2(4.0 * (float(h) - 1.5) + float(k) - 3.0, 3.0), 0.0, 20.0)
	for e in 72:
		var a := float(e) / 72.0 * TAU
		var p := at + Vector2(cos(a), sin(a)) * (7.0 + float(e % 5) * 1.5)
		host.spawn_enemy(defs[e % defs.size()], Vector3(p.x, 0.0, p.y), 1, 1000.0, 0.0, e % 24 == 5, String(stage.world.area_id), false)
	return host
