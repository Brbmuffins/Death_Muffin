class_name DmAutoNav
extends RefCounted
## What Easy auto combat's walk asks of the ground (the decision code's `routeNav`, client/game/dm_auto_combat.gd): is the straight line to the target clear, and if not, the way round.
## Both read the game's own navmesh (`DmNextWorld`: the core's grid of the walkable triangles for the line, the navigation server's path for the way round), which is cut round every
## grave, wall and prop, so a hero that follows it never grinds against one. The decision code asks at most 5 times a second for the line and once in 0.8 s for the path, and only while
## it is closing on an enemy; nothing here runs per frame. `queries` counts both (the tests read it).

const STEP_M := 0.4      ## the samples along a line, the Gargoyle's clear line (native/README.md "The clear line")
const OFF_M := 0.35      ## a sample farther than this from the navmesh is a prop in the way

var world: DmNextWorld
var queries := {"lines": 0, "paths": 0}


## True when no stretch of the straight line is off the navmesh. Before the navmesh is ready nothing is in the way.
func clear_line(ax: float, az: float, bx: float, bz: float, _r: float = 0.45) -> bool:
	queries["lines"] += 1
	if world == null or not world.nav_ready():
		return true
	var n := maxi(1, int(ceilf(Vector2(bx - ax, bz - az).length() / STEP_M)))
	for i in range(1, n):   # (the two ends are ground the hero and the enemy stand on)
		var t := float(i) / float(n)
		var x := ax + (bx - ax) * t
		var z := az + (bz - az) * t
		var c := world.nav_closest(Vector3(x, 0.0, z))
		if Vector2(c.x - x, c.z - z).length() > OFF_M:
			return false
	return true


## The walkable way from (fx, fz) to (tx, tz) as [x, z] points, the start left out; the target alone when the navmesh knows no way (the walk then goes straight, as it did).
func find_path(fx: float, fz: float, tx: float, tz: float, _r: float = 0.45) -> Array:
	queries["paths"] += 1
	var out: Array = []
	if world != null and world.nav_ready():
		var pts := world.nav_path(Vector3(fx, 0.0, fz), Vector3(tx, 0.0, tz))
		for i in range(1, pts.size()):
			out.append([pts[i].x, pts[i].z])
	if out.is_empty():
		out.append([tx, tz])
	return out
