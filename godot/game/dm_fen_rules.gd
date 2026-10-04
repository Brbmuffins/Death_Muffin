class_name DmFenRules
extends RefCounted
## Port of the walking rules of src/content/fen.ts: bog wading slow for a body at (x, z).

static func in_bog(x: float, z: float) -> bool:
	for r in DmContent.get_export("fen", "FEN_BOG"):
		if x >= float(r["x0"]) and x <= float(r["x1"]) and z >= float(r["z0"]) and z <= float(r["z1"]):
			return true
	return false


static func hummock_at(x: float, z: float, scale: float = 1.0, pad: float = 0.0) -> bool:
	for h in DmContent.get_export("fen", "FEN_HUMMOCKS"):
		if DmSimMath.hypot(x - float(h["x"]), z - float(h["z"])) <= float(h["r"]) * scale + pad:
			return true
	return false


static func flood_scale(phase: int) -> float:
	if phase < 1:
		return 1.0
	return float(DmContent.get_export("fen", "FEN_FLOOD_SCALE")[str(mini(3, phase))])


## 1 on dry ground, BOG.* in the water. `phase` is the awake Mire Mother's (0 = none).
static func bog_mult(x: float, z: float, phase: int = 0) -> float:
	if not in_bog(x, z):
		return 1.0
	if hummock_at(x, z, flood_scale(phase)):
		return 1.0
	var bog: Dictionary = DmContent.get_export("fen", "BOG")
	if phase >= 3:
		return float(bog["slowP3"])
	return float(bog["slowP2"]) if phase == 2 else float(bog["slow"])
