class_name DmWfxBrazierFire
extends DmWfxParticles
## Brazier fire (WorldView.update "Brazier fire near the focus" through Effects' additive ParticleSystem): every lit brazier within 30 m (x) /
## 28 m (z) of the focus sheds violet flame wisps (10/s, 70% 0x8a5cf0 else 0xc6a4ff, life 0.5 s, rising) and the odd amber ember (1.5/s,
## 0xe9a86b, life 1.2 s). Particle maths: DmWfxParticles. Braziers' lit flag follows the candle groups.

const CAPACITY := 160
const RANGE_X := 30.0
const RANGE_Z := 28.0

var braziers: Array = []     # {x, y, z, group, area}
var candle_off: Dictionary = {}

## world = DmData.world(): props + propSpecs give the brazier positions and light height.
func setup(world: Dictionary) -> void:
	name = "BrazierFire"
	var ly := float(world.propSpecs.brazier.light.y)
	for p in world.props:
		if p.prop == "brazier":
			braziers.append({"x": float(p.x), "y": ly * float(p.scale), "z": float(p.z), "group": p.group, "area": p.area})
	configure(CAPACITY, DmFxTex.get_tex("glow"), true)

func is_lit(b: Dictionary) -> bool:
	return b.group == null or not candle_off.has(str(b.group))

## The web's per-frame brazier emission near the focus, then ParticleSystem.update.
func tick(dt: float, focus: Vector3) -> void:
	for b in braziers:
		if not is_lit(b) or absf(b.x - focus.x) > RANGE_X or absf(b.z - focus.z) > RANGE_Z:
			continue
		if rng.randf() < dt * 10.0:
			emit(b.x, b.y, b.z, DmWfxData.hex(0x8a5cf0) if rng.randf() < 0.7 else DmWfxData.hex(0xc6a4ff), 0.18, 0.1, 1.0, 0.5, 0.3, -0.8)
		if rng.randf() < dt * 1.5:
			emit(b.x, b.y + 0.2, b.z, DmWfxData.hex(0xe9a86b), 0.2, 0.3, 1.6, 1.2, 0.08, 0.0, 0.3)
	_update(dt)
