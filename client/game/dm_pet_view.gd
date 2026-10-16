class_name DmPetView
extends RefCounted
## Port of archive/legacy-web:src/graphics/PetView.ts: a companion that trails its owner (behind and to the left, walks or flies to catch up, idles when they
## stop, snaps to them if it falls far behind). Pure looks. `def` = a cosmetics PETS entry {id, model, scale, tint?, fly?{height,speed,amp,body}}.

var c: DmCreature
var def: Dictionary
var x: float
var z: float
var facing := 0.0
var _t := randf() * 10.0
var _moving := false


func _init(parent: Node, def_: Dictionary, ox: float, oz: float) -> void:
	def = def_
	var o := {"scale": float(def["scale"]), "cast_shadow": false}
	if def.get("tint") != null:
		o["tint"] = int(def["tint"])
	if def.get("fly") != null:
		o["wings"] = {"speed": def["fly"]["speed"], "amp": def["fly"]["amp"], "body": def["fly"]["body"]}
	c = DmCreature.new(String(def["model"]), o)
	parent.add_child(c.root)
	x = ox + 1.0
	z = oz + 1.0
	c.root.position = Vector3(x, 0, z)


func id() -> String:
	return String(def["id"])


static func _wrap(d: float) -> float:
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	return d


func update(dt: float, ox: float, oz: float, owner_facing: float) -> void:
	_t += dt
	var fly: bool = def.get("fly") != null
	var a := owner_facing + PI + 0.7
	var r := 1.1 if fly else 1.35
	var tx := ox + sin(a) * r
	var tz := oz + cos(a) * r
	var dx := tx - x
	var dz := tz - z
	var dist := DmSimMath.hypot(dx, dz)
	if dist > 16.0:
		x = tx
		z = tz
		dx = 0.0
		dz = 0.0
	elif dist > 0.25:
		var speed := minf(dist * 3.2, 6.0 if fly else 5.5)
		var step := minf(dist, speed * dt)
		x += (dx / dist) * step
		z += (dz / dist) * step
	var wants := dist > 0.45
	if wants != _moving:
		_moving = wants
		if wants:
			c.set_loop("walk", 1.0 if fly else 1.4)
		else:
			c.set_loop("idle", 1.0 if c.has("idle") else 0.12)
	if wants:
		facing += _wrap(atan2(dx, dz) - facing) * minf(1.0, dt * 10.0)
	else:
		facing += _wrap(owner_facing - facing) * minf(1.0, dt * 3.0)
	var y := float(def["fly"]["height"]) + sin(_t * 3.1) * 0.14 if fly else 0.0
	c.root.position = Vector3(x, y, z)
	c.root.rotation.y = facing
	c.update(dt)


func dispose() -> void:
	c.dispose()
	if is_instance_valid(c.root):
		c.root.queue_free()
