class_name DmHostileZone
extends Node3D
## A hostile ground zone (Shroud Moth dust cloud; later the sac pool, ember pools): lives `seconds`, and once a second hurts every dm_target
## standing in it (radius + 0.45 player radius, like sim_zones) for `dps` (the sim's dps x 1 s tick). Host-authoritative: only the authority
## spawns one, and clients get a visual-only copy (`damaging = false`) from the integration layer. Emits `pulsed` for VFX.

signal pulsed(zone: DmHostileZone)

const TICK_S := 1.0
const TARGET_PAD := 0.45

var kind: StringName = &"dust"
var radius: float = 2.0
var dps: float = 1.0
var lifetime: float = 3.5
var tick_s: float = TICK_S   ## pulse period; each pulse hurts for dps * tick_s
var damaging: bool = true
var source: Node = null
var _tick: float = -1.0
var _age: float = 0.0


static func spawn(parent: Node, at: Vector3, zone_kind: StringName, r: float, seconds: float, zone_dps: float, from: Node = null) -> DmHostileZone:
	var z := DmHostileZone.new()
	z.kind = zone_kind
	z.radius = r
	z.lifetime = seconds
	z.dps = zone_dps
	z.source = from
	z.position = Vector3(at.x, 0.0, at.z)
	z.add_to_group(&"dm_hostile_zone")
	parent.add_child(z)
	return z


## The sim's hurt `from` for a zone tick: burning ground is "burn", a toxic pool "toxic", the moth's cloud "dust".
func damage_kind() -> String:
	return "burn" if kind == &"ember" else String(kind)


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= lifetime:
		queue_free()
		return
	if not damaging:
		return
	if _tick < 0.0:
		_tick = tick_s
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = tick_s
	var r2 := (radius + TARGET_PAD) * (radius + TARGET_PAD)
	for n in get_tree().get_nodes_in_group(DmEnemy.TARGET_GROUP):
		var tg := n as Node3D
		if tg == null or (tg.has_method("dm_alive") and not tg.dm_alive()):
			continue
		var dx := tg.global_position.x - global_position.x
		var dz := tg.global_position.z - global_position.z
		if dx * dx + dz * dz <= r2:
			DmEnemy.deliver(tg, dps * tick_s, source if source != null and is_instance_valid(source) else self, damage_kind())
	pulsed.emit(self)
