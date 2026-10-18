class_name DmStateCathDiveChase
extends DmStateFlankChase
## Flank chase that opens with a dive (sim "flank" behaviour + def `dive`): with the cooldown up, a target between dive.minRange and dive.range
## and an unobstructed line, the body commits to a dive (DmStateCathDive) instead of closing for a bite. Otherwise it flanks like a hound.

const LOS_S := 0.25   ## the line-of-sight ray is only cast this often while a dive is otherwise possible

var _los_t: float = 0.0
var _los_ok: bool = false

func engage(tg: Node3D, d: float, dt: float) -> int:
	if enemy.attack_cd <= 0.0:
		var D: Dictionary = enemy.def["dive"]
		if d >= float(D["minRange"]) and d <= float(D["range"]):
			_los_t -= dt
			if _los_t <= 0.0:
				_los_t = LOS_S
				_los_ok = (enemy as DmEnemyGargoyle).clear_line_to(tg.global_position)
			if _los_ok:
				(enemy as DmEnemyGargoyle).diving = true
				return Id.ATTACK
	return super(tg, d, dt)
