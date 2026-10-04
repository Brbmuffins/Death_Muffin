class_name DmNavObstacle
extends RefCounted
## A nav collider: a circle (x, z, r) or an axis-aligned box (x0, z0, x1, z1). Identity matters (the Depths floor's colliders are removed by reference).

var is_circle: bool = true
var x: float = 0.0
var z: float = 0.0
var r: float = 0.0
var x0: float = 0.0
var z0: float = 0.0
var x1: float = 0.0
var z1: float = 0.0


static func circle(p_x: float, p_z: float, p_r: float) -> DmNavObstacle:
	var o := DmNavObstacle.new()
	o.is_circle = true
	o.x = p_x
	o.z = p_z
	o.r = p_r
	return o


static func box(p_x0: float, p_z0: float, p_x1: float, p_z1: float) -> DmNavObstacle:
	var o := DmNavObstacle.new()
	o.is_circle = false
	o.x0 = p_x0
	o.z0 = p_z0
	o.x1 = p_x1
	o.z1 = p_z1
	return o


## From a JSON-ish dict {kind: 'circle'|'box', ...}.
static func from_dict(d: Dictionary) -> DmNavObstacle:
	if d["kind"] == "circle":
		return circle(float(d["x"]), float(d["z"]), float(d["r"]))
	return box(float(d["x0"]), float(d["z0"]), float(d["x1"]), float(d["z1"]))
