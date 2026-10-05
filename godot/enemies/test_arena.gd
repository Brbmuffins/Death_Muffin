class_name DmEnemyTestArena
extends Node3D
## Flat 60x60 arena with a wall, a pillar, a crate stack and a perimeter, a baked navmesh, a controllable target dummy and N robbers.
## Open test_arena.tscn in the editor and press F6: WASD/arrows move the target, robbers chase, swing and (via the dummy HP label) hurt it.
## Click-free debugging: Project Settings > Debug > Visible Navigation shows the navmesh and agent paths.
##
## Regenerate the committed navmesh after moving obstacles:  godot --headless --path godot --script res://enemies/bake_arena_navmesh.gd

@export var robber_count: int = 3
@export var spawn_ring: float = 18.0
@export var rising_spawn: bool = false

@onready var region: NavigationRegion3D = $NavRegion
@onready var target: DmTargetDummy = $Target

const ROBBER := preload("res://enemies/robber.tscn")
var enemies: Array[DmEnemy] = []

func _ready() -> void:
	if region.navigation_mesh == null or region.navigation_mesh.get_polygon_count() == 0:
		region.bake_navigation_mesh(false)   # synchronous; the committed navmesh normally makes this a no-op
	for i in robber_count:
		var a := TAU * float(i) / maxf(1.0, float(robber_count)) + 0.3
		spawn_robber(Vector3(sin(a), 0.0, cos(a)) * spawn_ring)

func spawn_robber(pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	return spawn_kind("robber", pos, props)

## Any kind that has a scene godot/enemies/<kind>.tscn.
func spawn_kind(kind: String, pos: Vector3, props: Dictionary = {}) -> DmEnemy:
	var e: DmEnemy = (ROBBER if kind == "robber" else load("res://enemies/%s.tscn" % kind)).instantiate()
	e.rising = rising_spawn
	for k in props:
		e.set(k, props[k])
	e.position = pos
	add_child(e)
	enemies.append(e)
	return e
