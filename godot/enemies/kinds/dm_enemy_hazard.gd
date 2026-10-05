class_name DmEnemyHazard
extends DmEnemy
## "hazard" kinds (Carrion Sac): a slow brute whose blow is a ground slam of radius def.slamRadius (default 1.9) centred on the aim point fixed at
## wind-up start, hitting everything inside it. Chases like the robber. Its corpse is "toxic" (the corpse system ruptures it into a pool).

const DEFAULT_SLAM_R := 1.9

func slam_radius() -> float:
	return float(def["slamRadius"]) if def.has("slamRadius") else DEFAULT_SLAM_R


func announce_telegraph(seconds: float) -> void:
	telegraph.emit(&"slam", global_position, aim, slam_radius(), seconds)


func strike() -> void:
	for tg in targets_within(aim, slam_radius()):
		hit_target(tg, damage)
	cue.emit(&"slam", aim, slam_radius())
