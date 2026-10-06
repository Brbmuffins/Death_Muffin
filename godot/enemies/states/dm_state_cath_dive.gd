class_name DmStateCathDive
extends DmStateAttack
## Belfry Gargoyle dive (sim `diving` windup): the ATTACK slot of a kind with a def `dive`. A swing that is not a dive is the plain melee one.
## Wind-up = the telegraph (a mark under the target, aim fixed when it began); the body hangs still for the first half, then drops onto the mark
## along an ease-in (k^2) curve. At the end of the wind-up it lands, strike() slams the dive radius, and it sits grounded for
## RECOVER_TIME + dive.groundedS (the window to punish it). The kind owns the `diving` flag (DmEnemyGargoyle); exit() clears it, so a stun
## mid-dive ends the dive where the body is.

var _from := Vector3.ZERO
var _recover: float = RECOVER_TIME

func enter(prev: int) -> void:
	super(prev)
	_from = enemy.global_position
	_recover = RECOVER_TIME

func exit(_next: int) -> void:
	(enemy as DmEnemyGargoyle).diving = false

func tick(dt: float) -> int:
	if not (enemy as DmEnemyGargoyle).diving:
		return super(dt)
	if phase == Phase.WINDUP:
		var w := enemy.windup_s
		var k := clampf((t - w * 0.5) / (w * 0.5), 0.0, 1.0)
		var a := enemy.aim
		var e := k * k
		enemy.global_position = Vector3(lerpf(_from.x, a.x, e), enemy.global_position.y, lerpf(_from.z, a.z, e))
		if t >= w:
			enemy.attack_cd = enemy.cooldown_s
			enemy.strike()
			phase = Phase.RECOVER
			t = 0.0
			_recover = RECOVER_TIME + float(enemy.def["dive"]["groundedS"])
		return -1
	return enemy.post_attack_state() if t >= _recover else -1
