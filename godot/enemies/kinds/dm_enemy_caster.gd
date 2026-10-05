class_name DmEnemyCaster
extends DmEnemy
## Ranged kinds whose blow is a telegraphed ground effect (sim "caster"): they hold range (DmStateKite) and cast on a fixed aim point.
## def.attack picks the shape: "cone" (Bellbound Penitent: 30-degree half-angle cone out to attackRange + 0.4) or "dust" (Shroud Moth:
## DUST.radius burst at the aim, then a lingering DmHostileZone cloud). Neither is a projectile in the game: the aim is where the target
## stood when the wind-up began, so walking out of the telegraph dodges it.

const CONE_HALF_ANGLE := 30.0 * PI / 180.0
const CONE_REACH_PAD := 0.4

var attack_kind: String = "cone"

func _ready() -> void:
	super()
	attack_kind = String(def.get("attack", "cone"))
	attack_anim = "cast"


func _build_states() -> void:
	super()
	sm.add(DmStateKite.new(self, DmEnemyState.Id.CHASE))


func announce_telegraph(seconds: float) -> void:
	match attack_kind:
		"dust":
			telegraph.emit(&"dust", global_position, aim, float(DmSimData.DUST["radius"]), seconds)
		_:
			telegraph.emit(&"cone", global_position, aim, 0.0, seconds)


func strike() -> void:
	match attack_kind:
		"dust":
			var r := float(DmSimData.DUST["radius"])
			for tg in targets_within(aim, r):
				hit_target(tg, damage)
			DmHostileZone.spawn(get_parent(), aim, &"dust", r, float(DmSimData.DUST["cloudS"]), damage * float(DmSimData.DUST["cloudDpsMult"]), self)
		_:
			var dir := Vector3(aim.x - global_position.x, 0.0, aim.z - global_position.z)
			var ln := dir.length()
			if ln < 0.001:
				dir = Vector3(sin(rotation.y), 0.0, cos(rotation.y))
				ln = 1.0
			var reach := attack_range + CONE_REACH_PAD
			var cos_lim := cos(CONE_HALF_ANGLE)
			for tg in targets_within(global_position, reach):
				var v := tg.global_position - global_position
				v.y = 0.0
				var d := v.length()
				if d < 0.001 or v.dot(dir) / (d * ln) > cos_lim:
					hit_target(tg, damage)
