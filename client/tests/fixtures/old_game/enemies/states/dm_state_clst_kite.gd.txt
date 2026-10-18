class_name DmStateClstKite
extends DmStateChase
## Ranged / support bodies that hold range and cast (Lich Acolyte, Plague Doctor, Weeping Seraph): the sim "caster" and "support" movement in
## one state, parameterised. Like DmStateKite but a silenced body never starts a cast (it still closes in and backs off).
##   caster (acolyte, plague doctor): cast at dist <= range - 0.5, walk in beyond range - 1.5, back off under 3.5 m at 0.8x.
##   support (seraph): cast at dist <= range, walk in beyond range - 0.5, back off under 4 m at 0.7x.

var cast_pad := 0.5
var near_pad := 1.5
var back_dist := 3.5
var back_speed := 0.8
var _ss: DmStatusSet

func configure(p: Array) -> DmStateClstKite:   ## [cast_pad, near_pad, back_dist, back_speed]
	cast_pad = p[0]
	near_pad = p[1]
	back_dist = p[2]
	back_speed = p[3]
	return self

func silenced() -> bool:
	if _ss == null:
		_ss = DmStatusSet.of(enemy)   # may be attached after the state was built: keep looking until it exists
	return _ss != null and _ss.is_silenced()

func engage(tg: Node3D, d: float, dt: float) -> int:
	if d <= enemy.attack_range - cast_pad and enemy.attack_cd <= 0.0 and not silenced():
		return Id.ATTACK
	if d > enemy.attack_range - near_pad:
		enemy.steer_to(tg.global_position, 1.0)
	elif d < back_dist:
		var p := enemy.global_position
		enemy.steer_to(p * 2.0 - tg.global_position, back_speed)
		enemy.face_point(tg.global_position, dt)
	else:
		enemy.stop()
		enemy.face_point(tg.global_position, dt)
	return -1
