class_name DmEnemyPfCaster
extends DmEnemyCaster
## Pyre Priest, Bog Hag, Fen Wisp: casters (DmStateKite) whose blow is one of the late-area ground effects, chosen by def.attack. The aim is fixed at
## wind-up start, so walking out of the telegraph dodges it.
## - `ember` (Pyre Priest): everything within EMBER_BOLT.radius 1.7 m of the aim takes the blow, and the ground burns there 4 s at 0.4 x damage/s.
## - `hex` (Bog Hag): aimed at the thickest knot of thralls within reach (else the target); within HAG_HEX.radius 3.1 m every body takes 0.55 x damage,
##   thralls are cursed for 6 s (they hit 30% softer, `cursed_t`), players are chilled 1.8 s.
## - `pulse` (Fen Wisp): everything within WISP_PULSE.radius 2.3 m of the aim takes the blow, players are chilled 1.8 s. Its def `lure` makes it back off
##   toward the open water (`lure_point`, DmSimData.FEN_LURE) instead of straight away (DmStatePfLureKite).

@export var lure_point: Vector3 = Vector3.ZERO   ## default: DmSimData.FEN_LURE

var _ember_pool: bool = false


func _ready() -> void:
	super()
	_ember_pool = attack_kind == "ember"
	if lure_point == Vector3.ZERO:
		lure_point = Vector3(float(DmSimData.FEN_LURE["x"]), 0.0, float(DmSimData.FEN_LURE["z"]))


func _build_states() -> void:
	super()
	if bool(def.get("lure", false)):
		sm.add(DmStatePfLureKite.new(self, DmEnemyState.Id.CHASE))


func look_options() -> Dictionary:
	return DmPfUtil.look(super(), def_id)


func begin_attack() -> void:
	if attack_kind != "hex":
		super()
		return
	aim = hex_aim()
	face_point(aim, 1.0)
	announce_telegraph(windup_s)


## The centre of the thrall standing in the thickest knot (HAG_HEX radius) within attackRange of the hag; the target itself when there are none.
func hex_aim() -> Vector3:
	var r := float(DmSimData.HAG_HEX["radius"])
	var thralls: Array[Node3D] = []
	for n in get_tree().get_nodes_in_group(TARGET_GROUP):
		if DmPfUtil.is_thrall(n) and target_valid(n):
			thralls.append(n as Node3D)
	var best: Node3D = null
	var best_n := 0
	for t in thralls:
		if flat_dist_to(t) > attack_range:
			continue
		var cnt := 0
		for o in thralls:
			var dx := o.global_position.x - t.global_position.x
			var dz := o.global_position.z - t.global_position.z
			if dx * dx + dz * dz <= r * r:
				cnt += 1
		if cnt > best_n:
			best_n = cnt
			best = t
	if best != null:
		return best.global_position
	return target.global_position if target_valid(target) else global_position + Vector3(sin(rotation.y), 0.0, cos(rotation.y))


func announce_telegraph(seconds: float) -> void:
	match attack_kind:
		"ember":
			telegraph.emit(&"ember", global_position, aim, float(DmSimData.EMBER_BOLT["radius"]), seconds)
		"hex":
			telegraph.emit(&"hex", global_position, aim, float(DmSimData.HAG_HEX["radius"]), seconds)
		"pulse":
			telegraph.emit(&"pulse", global_position, aim, float(DmSimData.WISP_PULSE["radius"]), seconds)
		_:
			super(seconds)


func strike() -> void:
	var dmg := DmPfUtil.blow(self)
	match attack_kind:
		"ember":
			var EB: Dictionary = DmSimData.EMBER_BOLT
			for tg in targets_within(aim, float(EB["radius"])):
				hit_target(tg, dmg)
			DmPfUtil.ember_pool(self, aim, float(EB["radius"]), float(EB["poolS"]), dmg * float(EB["poolDpsMult"]))
		"hex":
			var H: Dictionary = DmSimData.HAG_HEX
			for tg in targets_within(aim, float(H["radius"])):
				hit_target(tg, dmg * float(H["blowMult"]))
				if DmPfUtil.is_thrall(tg):
					if target_valid(tg):
						tg.set(&"cursed_t", float(H["durationS"]))
				else:
					DmPfUtil.chill(self, tg, float(H["chillMs"]) / 1000.0)
		"pulse":
			var W: Dictionary = DmSimData.WISP_PULSE
			for tg in targets_within(aim, float(W["radius"])):
				hit_target(tg, dmg)
				if not DmPfUtil.is_thrall(tg):
					DmPfUtil.chill(self, tg, float(W["chillMs"]) / 1000.0)
		_:
			super()


func on_impact_visual() -> void:
	if _ember_pool and not is_multiplayer_authority():
		DmPfUtil.ember_pool(self, aim, float(DmSimData.EMBER_BOLT["radius"]), float(DmSimData.EMBER_BOLT["poolS"]), 0.0)
