class_name DmStateErupt
extends DmEnemyState
## The eruption wind-up (BURROW.eruptMsGraves 1.0 s there, eruptMs 0.8 s elsewhere, x0.85 for elites): still underground and untouchable while a
## ring telegraphs at the aim fixed when it began. At the end the body surfaces at the aim, everything within eruptR of it takes
## damage x eruptMultGraves (1.25 outside the Graves), and the body gets the usual 0.3 s recovery (EMERGE) before it fights.

var windup: float = 1.0

func enter(_prev: int) -> void:
	t = 0.0
	enemy.stop()
	enemy.set_underground(true)
	var B: Dictionary = DmSimData.BURROW
	enemy.aim = enemy.target.global_position if enemy.target_valid(enemy.target) else enemy.global_position
	windup = (enemy as DmEnemyBurrower).erupt_windup()
	enemy.telegraph.emit(&"erupt", enemy.global_position, enemy.aim, float(B["eruptR"]), windup)

func tick(_dt: float) -> int:
	if t < windup:
		return -1
	var B: Dictionary = DmSimData.BURROW
	var dmg := enemy.damage * float(B["eruptMultGraves"] if enemy.in_graves else B["eruptMult"])
	enemy.global_position = Vector3(enemy.aim.x, enemy.global_position.y, enemy.aim.z)
	enemy.set_underground(false)
	enemy.attack_cd = enemy.cooldown_s
	for tg in enemy.targets_within(enemy.aim, float(B["eruptR"])):
		enemy.hit_target(tg, dmg)
	enemy.cue.emit(&"erupt", enemy.aim, float(B["eruptR"]))
	return Id.EMERGE
