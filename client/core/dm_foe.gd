class_name DmFoe
extends RefCounted
## One enemy as a cast sees it: a snapshot of the combat core's record (`DmCore.enemy_info`; for a boss, DmCoreHost's record of it), read when the cast asks. The rites keep working with plain
## numbers and ids, so this is not a body: no node and no script exists per creature, and nothing in it is kept between ticks. `id` is the core's
## number; hand it back to `DmCoreHost.damage / apply_status` to act on the enemy.
## Positions are the simulation's (not the drawn, interpolated ones), on the ground plane.

var id: int = 0
var x: float = 0.0
var z: float = 0.0
var radius: float = 0.45
var hp: float = 0.0
var state: int = 0                ## DmCoreEvents.State
var elite: bool = false
var def: String = ""
var level: int = 1
var area: String = ""
var boss: bool = false            ## a boss (an external of the core, DmBoss): counted from its edge, its own reach in the Scythe's arc and the needle's range


## The record of `info` (an empty Dictionary, an enemy that is gone, gives null).
static func of(info: Dictionary) -> DmFoe:
	if info.is_empty():
		return null
	var f := DmFoe.new()
	f.id = int(info["id"])
	var p: Vector2 = info["pos"]
	f.x = p.x
	f.z = p.y
	f.radius = float(info["radius"])
	f.hp = float(info["hp"])
	f.state = int(info["state"])
	f.elite = bool(info["elite"])
	f.def = String(info["def"])
	f.level = int(info["level"])
	f.area = String(info["area"])
	f.boss = bool(info.get("boss", false))
	return f


## hp > 0: a rising or underground body is alive (the hit is refused, a cast that counts bodies still counts it), only the dead are not.
func alive() -> bool:
	return hp > 0.0


## False while the body cannot be hurt (a burrowed or erupting ghoul): DmEnemy.is_hittable.
func hittable() -> bool:
	return state != DmCoreEvents.State.BURROW and state != DmCoreEvents.State.ERUPT


func pos() -> Vector3:
	return Vector3(x, 0.0, z)


## The model scale the enemy is drawn at (its def's, times the elite's): what DmEnemy's node scale was.
func scale_x() -> float:
	var d: Variant = DmSimData.ENEMIES.get(def)
	return (float(d.get("scale", 1.0)) if d is Dictionary else 1.0) * (float(DmSimData.ELITE["scale"]) if elite else 1.0)
