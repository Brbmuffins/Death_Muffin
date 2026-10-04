class_name DmBossGeom
extends RefCounted
## Geometry helpers shared by the boss brains (ports of the module-level helpers in BossBrain.ts and content/fen.ts).

const Content := preload("res://rules/core/content.gd")


static func hyp(a: float, b: float) -> float:
	return sqrt(a * a + b * b)


## atan2(dx, dz): the game's facing convention (0 = +z, measured toward +x).
static func angle_to(fx: float, fz: float, tx: float, tz: float) -> float:
	return atan2(tx - fx, tz - fz)


static func angle_diff(a: float, b: float) -> float:
	var d := fmod(absf(a - b), PI * 2.0)
	return PI * 2.0 - d if d > PI else d


## Distance from P to the segment AB.
static func seg_dist(px: float, pz: float, ax: float, az: float, bx: float, bz: float) -> float:
	var vx := bx - ax
	var vz := bz - az
	var l2 := vx * vx + vz * vz
	if l2 == 0.0:
		l2 = 1.0
	var t := maxf(0.0, minf(1.0, ((px - ax) * vx + (pz - az) * vz) / l2))
	return hyp(px - (ax + vx * t), pz - (az + vz * t))


## Does segment AB cross the box {x0,z0,x1,z1} (slab test)?
static func segment_hits_box(ax: float, az: float, bx: float, bz: float, b: Dictionary) -> bool:
	var t0 := 0.0
	var t1 := 1.0
	var d := [bx - ax, bz - az]
	var o := [ax, az]
	var lo := [float(b["x0"]), float(b["z0"])]
	var hi := [float(b["x1"]), float(b["z1"])]
	for i in 2:
		if absf(d[i]) < 1e-9:
			if o[i] < lo[i] or o[i] > hi[i]:
				return false
			continue
		var ta: float = (lo[i] - o[i]) / d[i]
		var tb: float = (hi[i] - o[i]) / d[i]
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return false
	return true


## content/fen.ts inBog
static func in_bog(x: float, z: float) -> bool:
	for r in Content.get_export("fen", "FEN_BOG"):
		if x >= float(r["x0"]) and x <= float(r["x1"]) and z >= float(r["z0"]) and z <= float(r["z1"]):
			return true
	return false


## content/fen.ts hummockAt (truthiness only: the brain never needs which one).
static func on_hummock(x: float, z: float, scale: float = 1.0, pad: float = 0.0) -> bool:
	for h in Content.get_export("fen", "FEN_HUMMOCKS"):
		if hyp(x - float(h["x"]), z - float(h["z"])) <= float(h["r"]) * scale + pad:
			return true
	return false
