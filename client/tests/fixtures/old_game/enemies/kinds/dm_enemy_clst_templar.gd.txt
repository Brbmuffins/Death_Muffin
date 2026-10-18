class_name DmEnemyClstTemplar
extends DmEnemy
## Bell-Sworn Templar: a melee body behind a bronze shield. A directed blow (one with a `from` body; DoT ticks pass allow_stagger = false and are
## undirected) that arrives within TEMPLAR_SHIELD.halfArcDeg of where it faces does only `passThrough` of its damage, unless it is Fractured.
## Each glance emits cue `shield_block` (rate-limited to 4/s) for the spark + chime.

const BLOCK_FX_GAP_MS := 250

var _block_at_ms: int = 0
var _arc_cos: float


func _ready() -> void:
	super()
	_arc_cos = cos(deg_to_rad(float(DmSimData.TEMPLAR_SHIELD["halfArcDeg"])))


func look_options() -> Dictionary:
	var o := super()
	o["fallback"] = "grave_robber"
	return o


## True when a blow from `from_pos` is stopped by the shield (it lands within the arc in front, and the body is not Fractured).
func shield_blocks(from_pos: Vector3) -> bool:
	var v := from_pos - global_position
	var l2 := v.x * v.x + v.z * v.z
	if l2 < 0.0001:
		return false
	var ss := DmStatusSet.of(self)
	if ss != null and ss.has(&"fracture"):
		return false
	var fx := sin(rotation.y)
	var fz := cos(rotation.y)
	return (v.x * fx + v.z * fz) / sqrt(l2) >= _arc_cos


func take_damage(amount: float, from: Node = null, allow_stagger: bool = true) -> bool:
	if allow_stagger and is_multiplayer_authority() and from is Node3D and is_instance_valid(from) and shield_blocks((from as Node3D).global_position):
		amount *= float(DmSimData.TEMPLAR_SHIELD["passThrough"])
		var now := Time.get_ticks_msec()
		if now >= _block_at_ms:
			_block_at_ms = now + BLOCK_FX_GAP_MS
			cue.emit(&"shield_block", global_position, 0.0)
	return super(amount, from, allow_stagger)
